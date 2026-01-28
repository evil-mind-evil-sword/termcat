//! ASCII font parsing + rendering for termcat.tui.
//!
//! Font assets are sourced from cfonts (via OpenTUI) and embedded as JSON.

const std = @import("std");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const unicode = @import("../unicode/width.zig");

pub const FontName = enum {
    tiny,
    block,
    shade,
    slick,
    huge,
    grid,
    pallet,
};

pub const Size = struct {
    width: u16,
    height: u16,
};

pub const Segment = struct {
    text: []const u8,
    color_index: u8,
};

pub const GlyphLine = struct {
    segments: []const Segment,
    width: u16,
};

pub const Glyph = struct {
    lines: []const GlyphLine,
    width: u16,
};

pub const Font = struct {
    name: []const u8,
    lines: u16,
    letterspace_size: u16,
    colors: u8,
    glyphs: std.StringHashMapUnmanaged(Glyph),
    space_width: u16,
};

const FontStore = struct {
    arena: std.heap.ArenaAllocator,
    fonts: std.AutoHashMap(FontName, Font),

    fn init(backing_allocator: std.mem.Allocator) FontStore {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .fonts = std.AutoHashMap(FontName, Font).init(backing_allocator),
        };
    }

    fn arenaAllocator(self: *FontStore) std.mem.Allocator {
        return self.arena.allocator();
    }
};

var store: ?*FontStore = null;

fn ensureStore() !*FontStore {
    if (store) |existing| return existing;

    const allocator = std.heap.page_allocator;
    const store_ptr = try allocator.create(FontStore);
    store_ptr.* = FontStore.init(allocator);

    try loadFont(store_ptr, .tiny, @embedFile("fonts/tiny.json"));
    try loadFont(store_ptr, .block, @embedFile("fonts/block.json"));
    try loadFont(store_ptr, .shade, @embedFile("fonts/shade.json"));
    try loadFont(store_ptr, .slick, @embedFile("fonts/slick.json"));
    try loadFont(store_ptr, .huge, @embedFile("fonts/huge.json"));
    try loadFont(store_ptr, .grid, @embedFile("fonts/grid.json"));
    try loadFont(store_ptr, .pallet, @embedFile("fonts/pallet.json"));

    store = store_ptr;
    return store_ptr;
}

fn loadFont(store_ptr: *FontStore, name: FontName, data: []const u8) !void {
    const allocator = store_ptr.arenaAllocator();
    const font = try parseFont(allocator, data);
    try store_ptr.fonts.put(name, font);
}

pub fn getFont(name: FontName) ?*const Font {
    const store_ptr = ensureStore() catch return null;
    return store_ptr.fonts.getPtr(name);
}

fn parseFont(allocator: std.mem.Allocator, data: []const u8) !Font {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    // Keep arena allocations alive; do not deinit parsed.

    const root = parsed.value;
    if (root != .object) return error.InvalidFontData;
    const obj = root.object;

    const name_value = obj.get("name") orelse return error.InvalidFontData;
    const name = switch (name_value) {
        .string => |value| value,
        else => return error.InvalidFontData,
    };

    const lines = try expectU16(obj, "lines");
    const letterspace_size = try expectU16(obj, "letterspace_size");

    var colors: u8 = 1;
    if (obj.get("colors")) |color_value| {
        colors = @intCast(try expectU16Value(color_value));
    }

    const chars_value = obj.get("chars") orelse return error.InvalidFontData;
    if (chars_value != .object) return error.InvalidFontData;

    var glyphs = std.StringHashMapUnmanaged(Glyph){};
    try glyphs.ensureTotalCapacity(allocator, chars_value.object.count());

    var iter = chars_value.object.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (value != .array) return error.InvalidFontData;

        const line_values = value.array.items;
        var glyph_lines = try allocator.alloc(GlyphLine, line_values.len);
        var glyph_width: u16 = 0;

        for (line_values, 0..) |line_value, line_idx| {
            const line = switch (line_value) {
                .string => |str| str,
                else => return error.InvalidFontData,
            };
            const segments = try parseSegments(allocator, line);
            const line_width = segmentListWidth(segments);
            glyph_lines[line_idx] = .{ .segments = segments, .width = line_width };
            glyph_width = @max(glyph_width, line_width);
        }

        try glyphs.put(allocator, key, .{ .lines = glyph_lines, .width = glyph_width });
    }

    var space_width: u16 = 1;
    if (glyphs.get(" ")) |space_glyph| {
        space_width = @max(space_glyph.width, @as(u16, 1));
    }

    return .{
        .name = name,
        .lines = lines,
        .letterspace_size = letterspace_size,
        .colors = colors,
        .glyphs = glyphs,
        .space_width = space_width,
    };
}

fn expectU16(obj: std.json.ObjectMap, key: []const u8) !u16 {
    const value = obj.get(key) orelse return error.InvalidFontData;
    return expectU16Value(value);
}

fn expectU16Value(value: std.json.Value) !u16 {
    const int_value = switch (value) {
        .integer => |val| val,
        else => return error.InvalidFontData,
    };
    if (int_value < 0 or int_value > std.math.maxInt(u16)) return error.InvalidFontData;
    return @intCast(int_value);
}

fn parseSegments(allocator: std.mem.Allocator, line: []const u8) ![]Segment {
    var segments: std.ArrayListUnmanaged(Segment) = .{};
    errdefer segments.deinit(allocator);

    var index: usize = 0;
    while (index < line.len) {
        if (std.mem.indexOf(u8, line[index..], "<c")) |rel_tag| {
            const tag_start = index + rel_tag;
            if (tag_start > index) {
                try appendSegment(allocator, &segments, line[index..tag_start], 0);
            }

            const number_start = tag_start + 2;
            const number_end_rel = std.mem.indexOfScalar(u8, line[number_start..], '>') orelse {
                try appendSegment(allocator, &segments, line[tag_start..], 0);
                break;
            };
            const number_end = number_start + number_end_rel;
            const number_slice = line[number_start..number_end];
            const color_num = std.fmt.parseInt(u8, number_slice, 10) catch {
                try appendSegment(allocator, &segments, line[tag_start..], 0);
                break;
            };
            const content_start = number_end + 1;
            const close_rel = std.mem.indexOf(u8, line[content_start..], "</c") orelse {
                try appendSegment(allocator, &segments, line[tag_start..], 0);
                break;
            };
            const close_start = content_start + close_rel;
            const close_end_rel = std.mem.indexOfScalar(u8, line[close_start..], '>') orelse {
                try appendSegment(allocator, &segments, line[tag_start..], 0);
                break;
            };
            const close_end = close_start + close_end_rel;

            if (close_start > content_start) {
                const color_index: u8 = if (color_num == 0) 0 else color_num - 1;
                try appendSegment(allocator, &segments, line[content_start..close_start], color_index);
            }

            index = close_end + 1;
            continue;
        }

        try appendSegment(allocator, &segments, line[index..], 0);
        break;
    }

    return segments.toOwnedSlice(allocator);
}

fn appendSegment(allocator: std.mem.Allocator, segments: *std.ArrayListUnmanaged(Segment), text: []const u8, color_index: u8) !void {
    if (text.len == 0) return;
    try segments.append(allocator, .{ .text = text, .color_index = color_index });
}

fn segmentListWidth(segments: []const Segment) u16 {
    var width: u16 = 0;
    for (segments) |segment| {
        const increment = unicode.stringWidth(segment.text);
        const total = @as(usize, width) + increment;
        width = @intCast(@min(std.math.maxInt(u16), total));
    }
    return width;
}

fn glyphFor(font: *const Font, cp: u21) ?*const Glyph {
    if (cp > 0x7f) return null;
    var buf: [1]u8 = .{@intCast(cp)};
    buf[0] = std.ascii.toUpper(buf[0]);
    return font.glyphs.getPtr(buf[0..1]);
}

pub fn measureText(text: []const u8, font_name: FontName) Size {
    const font = getFont(font_name) orelse return .{ .width = 0, .height = 0 };

    var width: u16 = 0;
    var iter = std.unicode.Utf8View.initUnchecked(text).iterator();
    var first = true;

    while (iter.nextCodepoint()) |cp| {
        if (!first) {
            const total = @as(u32, width) + font.letterspace_size;
            width = @intCast(@min(std.math.maxInt(u16), total));
        }
        first = false;

        if (glyphFor(font, cp)) |glyph| {
            const total = @as(u32, width) + glyph.width;
            width = @intCast(@min(std.math.maxInt(u16), total));
        } else {
            const total = @as(u32, width) + font.space_width;
            width = @intCast(@min(std.math.maxInt(u16), total));
        }
    }

    return .{ .width = width, .height = font.lines };
}

pub fn renderFont(view: *PlaneView, x: i32, y: i32, text: []const u8, font_name: FontName, style: Style, colors: []const Cell.Color) Size {
    const font = getFont(font_name) orelse return .{ .width = 0, .height = 0 };

    const fallback_color = if (colors.len > 0) colors[0] else style.fg;
    var current_x = x;

    var iter = std.unicode.Utf8View.initUnchecked(text).iterator();
    var first = true;

    while (iter.nextCodepoint()) |cp| {
        if (!first) {
            current_x += @intCast(font.letterspace_size);
        }
        first = false;

        const glyph = glyphFor(font, cp) orelse {
            current_x += @intCast(font.space_width);
            continue;
        };

        var line_idx: usize = 0;
        while (line_idx < glyph.lines.len and line_idx < font.lines) : (line_idx += 1) {
            const line = glyph.lines[line_idx];
            var segment_x = current_x;

            for (line.segments) |segment| {
                const segment_color = if (segment.color_index < colors.len) colors[segment.color_index] else fallback_color;
                segment_x = renderSegment(view, segment_x, y + @as(i32, @intCast(line_idx)), segment.text, segment_color, style.bg, style.attrs);
            }
        }

        current_x += @intCast(glyph.width);
    }

    const width_i32 = current_x - x;
    const width_clamped = if (width_i32 <= 0) 0 else @as(u32, @intCast(width_i32));
    return .{ .width = @intCast(@min(std.math.maxInt(u16), width_clamped)), .height = font.lines };
}

fn renderSegment(
    view: *PlaneView,
    start_x: i32,
    y: i32,
    text: []const u8,
    fg: Cell.Color,
    bg: Cell.Color,
    attrs: Cell.Attributes,
) i32 {
    var col = start_x;
    var iter = std.unicode.Utf8View.initUnchecked(text).iterator();

    while (iter.nextCodepoint()) |cp| {
        const width = unicode.codePointWidth(cp);
        if (width == 0) continue;

        if (cp != ' ') {
            view.setCell(col, y, Cell{
                .char = cp,
                .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                .fg = fg,
                .bg = bg,
                .attrs = attrs,
            });

            if (width == 2) {
                view.setCell(col + 1, y, Cell{
                    .char = Cell.WIDE_CONTINUATION,
                    .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                    .fg = fg,
                    .bg = bg,
                    .attrs = attrs,
                });
            }
        }

        col += @intCast(width);
    }

    return col;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "ascii font measure tiny" {
    const size = measureText("A", .tiny);
    try testing.expectEqual(@as(u16, 3), size.width);
    try testing.expectEqual(@as(u16, 2), size.height);
}

test "ascii font measure spacing" {
    const size = measureText("AB", .tiny);
    // A (3) + letterspace (1) + B (3) = 7
    try testing.expectEqual(@as(u16, 7), size.width);
}
