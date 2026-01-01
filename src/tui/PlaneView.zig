//! PlaneView: A clipped, offset view into a Plane for widget rendering
//!
//! Widgets render through PlaneView to respect their allocated bounds.
//! PlaneView forwards drawing calls to the underlying Plane with
//! automatic clipping and offset translation.

const std = @import("std");
const Plane = @import("../Plane.zig");
const Cell = @import("../Cell.zig");
const Event = @import("../Event.zig");

pub const Position = Event.Position;
pub const Size = Event.Size;
pub const Rect = Event.Rect;

pub const PlaneView = struct {
    plane: *Plane,
    clip_rect: Rect, // Absolute bounds in plane coordinates
    origin: Position, // Origin offset for relative coordinates

    /// Create a PlaneView from a Plane covering the full size
    pub fn init(plane: *Plane) PlaneView {
        return .{
            .plane = plane,
            .clip_rect = .{
                .x = 0,
                .y = 0,
                .width = plane.width,
                .height = plane.height,
            },
            .origin = .{ .x = 0, .y = 0 },
        };
    }

    /// Create a sub-view with relative offset and intersection clipping
    pub fn subView(self: PlaneView, rect: Rect) PlaneView {
        const abs_x = self.origin.x + rect.x;
        const abs_y = self.origin.y + rect.y;

        // Compute intersection of the requested rect (in absolute coords) with clip_rect
        const clip_left = @max(@as(i32, self.clip_rect.x), abs_x);
        const clip_top = @max(@as(i32, self.clip_rect.y), abs_y);
        const clip_right = @min(
            @as(i32, self.clip_rect.x) + @as(i32, self.clip_rect.width),
            abs_x + @as(i32, rect.width),
        );
        const clip_bottom = @min(
            @as(i32, self.clip_rect.y) + @as(i32, self.clip_rect.height),
            abs_y + @as(i32, rect.height),
        );

        const new_clip_width = @max(@as(i32, 0), clip_right - clip_left);
        const new_clip_height = @max(@as(i32, 0), clip_bottom - clip_top);

        return .{
            .plane = self.plane,
            .clip_rect = .{
                .x = @intCast(@max(@as(i32, 0), clip_left)),
                .y = @intCast(@max(@as(i32, 0), clip_top)),
                .width = @intCast(new_clip_width),
                .height = @intCast(new_clip_height),
            },
            .origin = .{ .x = abs_x, .y = abs_y },
        };
    }

    /// Get the size available for drawing
    pub fn size(self: PlaneView) Size {
        return .{
            .width = self.clip_rect.width,
            .height = self.clip_rect.height,
        };
    }

    /// Check if a relative coordinate is within bounds
    fn isInBounds(self: PlaneView, x: i32, y: i32) bool {
        const abs_x = self.origin.x + x;
        const abs_y = self.origin.y + y;
        return abs_x >= @as(i32, self.clip_rect.x) and
            abs_x < @as(i32, self.clip_rect.x) + @as(i32, self.clip_rect.width) and
            abs_y >= @as(i32, self.clip_rect.y) and
            abs_y < @as(i32, self.clip_rect.y) + @as(i32, self.clip_rect.height);
    }

    /// Set a cell at relative coordinates (clipped)
    pub fn setCell(self: *PlaneView, x: i32, y: i32, cell: Cell) void {
        const abs_x = self.origin.x + x;
        const abs_y = self.origin.y + y;
        if (!self.isInBounds(x, y)) return;
        self.plane.setCell(@intCast(abs_x), @intCast(abs_y), cell);
    }

    /// Get a cell at relative coordinates (returns null if outside bounds)
    pub fn getCell(self: PlaneView, x: i32, y: i32) ?Cell {
        const abs_x = self.origin.x + x;
        const abs_y = self.origin.y + y;
        if (!self.isInBounds(x, y)) return null;
        return self.plane.getCell(@intCast(abs_x), @intCast(abs_y));
    }

    /// Write a string at relative coordinates (clipped per character)
    pub fn writeString(self: *PlaneView, x: i32, y: i32, str: []const u8, style: Cell.Color) void {
        var col = x;
        for (str) |char| {
            if (self.isInBounds(col, y)) {
                self.setCell(col, y, Cell{
                    .char = char,
                    .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                    .fg = style,
                    .bg = .default,
                    .attrs = .{},
                });
            }
            col += 1;
        }
    }

    /// Print a UTF-8 string with full styling at relative coordinates (clipped per character)
    /// Handles wide characters correctly.
    pub fn print(
        self: *PlaneView,
        x: i32,
        y: i32,
        str: []const u8,
        fg: Cell.Color,
        bg: Cell.Color,
        attrs: Cell.Attributes,
    ) void {
        const unicode = @import("../unicode/width.zig");
        var col = x;
        var iter = std.unicode.Utf8View.initUnchecked(str).iterator();
        while (iter.nextCodepoint()) |cp| {
            const char_width = unicode.codePointWidth(cp);
            if (char_width == 0) continue;

            if (self.isInBounds(col, y)) {
                self.setCell(col, y, Cell{
                    .char = cp,
                    .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                    .fg = fg,
                    .bg = bg,
                    .attrs = attrs,
                });
                // For wide characters, set continuation cell
                if (char_width == 2 and self.isInBounds(col + 1, y)) {
                    self.setCell(col + 1, y, Cell{
                        .char = Cell.WIDE_CONTINUATION,
                        .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                        .fg = fg,
                        .bg = bg,
                        .attrs = attrs,
                    });
                }
            }
            col += @intCast(char_width);
        }
    }

    /// Fill the entire view with a cell
    pub fn fill(self: *PlaneView, cell: Cell) void {
        var y: i32 = 0;
        while (y < @as(i32, self.clip_rect.height)) : (y += 1) {
            var x: i32 = 0;
            while (x < @as(i32, self.clip_rect.width)) : (x += 1) {
                self.setCell(x, y, cell);
            }
        }
    }

    /// Clear the view (fill with default cell)
    pub fn clear(self: *PlaneView) void {
        self.fill(Cell{});
    }
};

test "PlaneView init" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const view = PlaneView.init(root);
    try std.testing.expectEqual(@as(u16, 80), view.size().width);
    try std.testing.expectEqual(@as(u16, 24), view.size().height);
    try std.testing.expectEqual(@as(u16, 0), view.clip_rect.x);
    try std.testing.expectEqual(@as(u16, 0), view.clip_rect.y);
    try std.testing.expectEqual(@as(u16, 0), view.origin.x);
    try std.testing.expectEqual(@as(u16, 0), view.origin.y);
}

test "PlaneView setCell and getCell" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    var view = PlaneView.init(root);

    const cell = Cell{
        .char = 'X',
        .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };

    view.setCell(5, 3, cell);
    const got = view.getCell(5, 3);
    try std.testing.expect(got != null);
    try std.testing.expect(got.?.eql(cell));
}

test "PlaneView out of bounds setCell" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    var view = PlaneView.init(root);

    const cell = Cell{
        .char = 'X',
        .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };

    // Try to set cell outside bounds - should be silently ignored
    view.setCell(-1, 0, cell);
    view.setCell(80, 0, cell);
    view.setCell(0, 24, cell);

    // Should return null
    try std.testing.expect(view.getCell(-1, 0) == null);
    try std.testing.expect(view.getCell(80, 0) == null);
    try std.testing.expect(view.getCell(0, 24) == null);
}

test "PlaneView subView basic" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const view = PlaneView.init(root);
    const sub = view.subView(.{ .x = 10, .y = 5, .width = 20, .height = 10 });

    // Sub-view should have the requested size
    try std.testing.expectEqual(@as(u16, 20), sub.size().width);
    try std.testing.expectEqual(@as(u16, 10), sub.size().height);

    // Origin should be offset
    try std.testing.expectEqual(@as(u16, 10), sub.origin.x);
    try std.testing.expectEqual(@as(u16, 5), sub.origin.y);
}

test "PlaneView subView clipping" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const view = PlaneView.init(root);
    // Request a sub-view that extends beyond the parent
    const sub = view.subView(.{ .x = 70, .y = 20, .width = 20, .height = 10 });

    // Should be clipped to parent bounds
    try std.testing.expectEqual(@as(u16, 10), sub.size().width); // 80 - 70 = 10
    try std.testing.expectEqual(@as(u16, 4), sub.size().height); // 24 - 20 = 4
}

test "PlaneView clear" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    var view = PlaneView.init(root);

    // Set a cell
    const cell = Cell{
        .char = 'X',
        .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };
    view.setCell(5, 3, cell);

    // Clear should fill with default
    view.clear();

    const default_cell = Cell{};
    const got = view.getCell(5, 3);
    try std.testing.expect(got != null);
    try std.testing.expect(got.?.eql(default_cell));
}

test "PlaneView fill" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    var view = PlaneView.init(root);

    const fill_cell = Cell{
        .char = '#',
        .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };

    view.fill(fill_cell);

    // Check a few cells
    try std.testing.expect(view.getCell(0, 0).?.eql(fill_cell));
    try std.testing.expect(view.getCell(40, 12).?.eql(fill_cell));
    try std.testing.expect(view.getCell(79, 23).?.eql(fill_cell));
}

test "PlaneView writeString" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    var view = PlaneView.init(root);

    view.writeString(5, 3, "Hello", Cell.Color.red);

    try std.testing.expectEqual(@as(u21, 'H'), view.getCell(5, 3).?.char);
    try std.testing.expectEqual(@as(u21, 'e'), view.getCell(6, 3).?.char);
    try std.testing.expectEqual(@as(u21, 'l'), view.getCell(7, 3).?.char);
    try std.testing.expectEqual(@as(u21, 'l'), view.getCell(8, 3).?.char);
    try std.testing.expectEqual(@as(u21, 'o'), view.getCell(9, 3).?.char);
}

test "PlaneView nested subviews" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    const view = PlaneView.init(root);
    const sub1 = view.subView(.{ .x = 10, .y = 5, .width = 40, .height = 15 });
    const sub2 = sub1.subView(.{ .x = 5, .y = 3, .width = 20, .height = 10 });

    // sub2 should be: origin (10+5, 5+3) = (15, 8), size (20, 10)
    try std.testing.expectEqual(@as(u16, 15), sub2.origin.x);
    try std.testing.expectEqual(@as(u16, 8), sub2.origin.y);
    try std.testing.expectEqual(@as(u16, 20), sub2.size().width);
    try std.testing.expectEqual(@as(u16, 10), sub2.size().height);
}

test "PlaneView subView respects clip" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 80, .height = 24 });
    defer root.deinit();

    // Create a view that covers only part of the plane
    const view = PlaneView.init(root);
    const view1 = view.subView(.{ .x = 10, .y = 5, .width = 20, .height = 10 });

    // Try to create a sub-view of view1 that extends beyond view1's bounds
    const sub2 = view1.subView(.{ .x = 15, .y = 8, .width = 20, .height = 10 });

    // The sub2 should be clipped to view1's boundaries
    // view1 ends at x=30, y=15 (10+20, 5+10)
    // sub2 requested (10+15, 5+8, 20, 10) = (25, 13) with size (20, 10)
    // Should be clipped to (25, 13) with size (5, 2) = (30-25, 15-13)
    try std.testing.expectEqual(@as(u16, 5), sub2.size().width);
    try std.testing.expectEqual(@as(u16, 2), sub2.size().height);
}
