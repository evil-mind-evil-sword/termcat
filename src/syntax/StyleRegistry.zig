const std = @import("std");
const Allocator = std.mem.Allocator;
const Cell = @import("../Cell.zig");
const Style = @import("../Style.zig");

pub const Color = Cell.Color;

pub const StyleDefinition = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    attrs: AttrMask = 0,
};

pub const AttrMask = u16;

pub const Attr = struct {
    pub const bold: AttrMask = 1 << 0;
    pub const dim: AttrMask = 1 << 1;
    pub const italic: AttrMask = 1 << 2;
    pub const underline: AttrMask = 1 << 3;
    pub const blink: AttrMask = 1 << 4;
    pub const reverse: AttrMask = 1 << 5;
    pub const strikethrough: AttrMask = 1 << 6;

    pub fn fromAttributes(attrs: Cell.Attributes) AttrMask {
        var mask: AttrMask = 0;
        if (attrs.bold) mask |= bold;
        if (attrs.dim) mask |= dim;
        if (attrs.italic) mask |= italic;
        if (attrs.underline) mask |= underline;
        if (attrs.blink) mask |= blink;
        if (attrs.reverse) mask |= reverse;
        if (attrs.strikethrough) mask |= strikethrough;
        return mask;
    }

    pub fn apply(mask: AttrMask, base: Cell.Attributes) Cell.Attributes {
        var out = base;
        if ((mask & bold) != 0) out.bold = true;
        if ((mask & dim) != 0) out.dim = true;
        if ((mask & italic) != 0) out.italic = true;
        if ((mask & underline) != 0) out.underline = true;
        if ((mask & blink) != 0) out.blink = true;
        if ((mask & reverse) != 0) out.reverse = true;
        if ((mask & strikethrough) != 0) out.strikethrough = true;
        return out;
    }
};

pub const SyntaxStyleError = error{
    OutOfMemory,
    InvalidId,
    CacheKeyTooLong,
};

pub const SyntaxStyle = struct {
    allocator: Allocator,
    global_allocator: Allocator,
    arena: *std.heap.ArenaAllocator,

    name_to_id: std.StringHashMapUnmanaged(u32),
    id_to_style: std.AutoHashMapUnmanaged(u32, StyleDefinition),
    next_id: u32,

    merged_cache: std.StringHashMapUnmanaged(StyleDefinition),

    pub fn init(global_allocator: Allocator) SyntaxStyleError!*SyntaxStyle {
        const self = global_allocator.create(SyntaxStyle) catch return SyntaxStyleError.OutOfMemory;
        errdefer global_allocator.destroy(self);

        const internal_arena = global_allocator.create(std.heap.ArenaAllocator) catch return SyntaxStyleError.OutOfMemory;
        errdefer global_allocator.destroy(internal_arena);
        internal_arena.* = std.heap.ArenaAllocator.init(global_allocator);

        const internal_allocator = internal_arena.allocator();

        self.* = .{
            .allocator = internal_allocator,
            .global_allocator = global_allocator,
            .arena = internal_arena,
            .name_to_id = .{},
            .id_to_style = .{},
            .next_id = 1,
            .merged_cache = .{},
        };

        return self;
    }

    pub fn deinit(self: *SyntaxStyle) void {
        self.arena.deinit();
        self.global_allocator.destroy(self.arena);
        self.global_allocator.destroy(self);
    }

    pub fn registerStyle(self: *SyntaxStyle, name: []const u8, fg: ?Color, bg: ?Color, attrs: AttrMask) SyntaxStyleError!u32 {
        if (self.name_to_id.get(name)) |existing_id| {
            try self.id_to_style.put(self.allocator, existing_id, StyleDefinition{
                .fg = fg,
                .bg = bg,
                .attrs = attrs,
            });
            self.clearCache();
            return existing_id;
        }

        const id = self.next_id;
        self.next_id += 1;

        const owned_name = self.allocator.dupe(u8, name) catch return SyntaxStyleError.OutOfMemory;

        try self.name_to_id.put(self.allocator, owned_name, id);
        try self.id_to_style.put(self.allocator, id, StyleDefinition{
            .fg = fg,
            .bg = bg,
            .attrs = attrs,
        });

        return id;
    }

    pub fn resolveById(self: *const SyntaxStyle, id: u32) ?StyleDefinition {
        return self.id_to_style.get(id);
    }

    pub fn resolveByName(self: *const SyntaxStyle, name: []const u8) ?u32 {
        return self.name_to_id.get(name);
    }

    pub fn mergeStyles(self: *SyntaxStyle, ids: []const u32) SyntaxStyleError!StyleDefinition {
        var cache_key_buffer: [512]u8 = undefined;
        var cache_key_stream = std.io.fixedBufferStream(&cache_key_buffer);
        const writer = cache_key_stream.writer();

        for (ids, 0..) |id, i| {
            if (i > 0) writer.writeByte(':') catch return SyntaxStyleError.CacheKeyTooLong;
            writer.print("{d}", .{id}) catch return SyntaxStyleError.CacheKeyTooLong;
        }

        const cache_key = cache_key_stream.getWritten();

        if (self.merged_cache.get(cache_key)) |cached| {
            return cached;
        }

        var merged = StyleDefinition{
            .fg = null,
            .bg = null,
            .attrs = 0,
        };

        for (ids) |id| {
            if (self.resolveById(id)) |style| {
                if (style.fg) |fg| merged.fg = fg;
                if (style.bg) |bg| merged.bg = bg;
                merged.attrs |= style.attrs;
            }
        }

        const owned_cache_key = self.allocator.dupe(u8, cache_key) catch return SyntaxStyleError.OutOfMemory;
        self.merged_cache.put(self.allocator, owned_cache_key, merged) catch return SyntaxStyleError.OutOfMemory;

        return merged;
    }

    pub fn applyDefinition(def: StyleDefinition, base: Style) Style {
        var out = base;
        if (def.fg) |fg| out.fg = fg;
        if (def.bg) |bg| out.bg = bg;
        out.attrs = Attr.apply(def.attrs, out.attrs);
        return out;
    }

    pub fn applyToStyle(self: *SyntaxStyle, ids: []const u32, base: Style) SyntaxStyleError!Style {
        const def = try self.mergeStyles(ids);
        return applyDefinition(def, base);
    }

    pub fn clearCache(self: *SyntaxStyle) void {
        self.merged_cache.clearRetainingCapacity();
    }

    pub fn getCacheSize(self: *const SyntaxStyle) usize {
        return self.merged_cache.count();
    }

    pub fn getStyleCount(self: *const SyntaxStyle) usize {
        return self.id_to_style.count();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "SyntaxStyle register and merge" {
    var style = try SyntaxStyle.init(std.testing.allocator);
    defer style.deinit();

    const keyword = try style.registerStyle("keyword", Color{ .index = 1 }, null, Attr.bold);
    const comment = try style.registerStyle("comment", Color{ .index = 8 }, null, Attr.italic);

    const merged = try style.mergeStyles(&[_]u32{ keyword, comment });
    try std.testing.expectEqual(Color{ .index = 8 }, merged.fg.?);
    try std.testing.expect((merged.attrs & Attr.bold) != 0);
    try std.testing.expect((merged.attrs & Attr.italic) != 0);
}
