//! HitGrid: Per-cell hit testing with clip scissoring.
//!
//! Maintains a dense grid of widget ids for fast hit lookup and supports
//! nested clip rectangles via a stack.

const std = @import("std");
const Event = @import("../Event.zig");
const Id = @import("Id.zig").Id;

pub const Size = Event.Size;
pub const Rect = Event.Rect;

pub const HitGrid = struct {
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,
    cells: []u64,
    clip_stack: std.ArrayList(Rect),

    pub fn init(allocator: std.mem.Allocator, size: Size) !HitGrid {
        const total = @as(usize, size.width) * @as(usize, size.height);
        const cells = try allocator.alloc(u64, total);
        @memset(cells, 0);

        return .{
            .allocator = allocator,
            .width = size.width,
            .height = size.height,
            .cells = cells,
            .clip_stack = std.ArrayList(Rect).init(allocator),
        };
    }

    pub fn deinit(self: *HitGrid) void {
        self.allocator.free(self.cells);
        self.clip_stack.deinit();
        self.* = undefined;
    }

    pub fn resize(self: *HitGrid, size: Size) !void {
        const total = @as(usize, size.width) * @as(usize, size.height);
        const cells = try self.allocator.alloc(u64, total);
        @memset(cells, 0);

        self.allocator.free(self.cells);
        self.cells = cells;
        self.width = size.width;
        self.height = size.height;
        self.clip_stack.clearRetainingCapacity();
    }

    /// Clear grid and clip stack at frame start.
    pub fn beginFrame(self: *HitGrid) void {
        self.clear();
        self.clip_stack.clearRetainingCapacity();
    }

    pub fn clear(self: *HitGrid) void {
        @memset(self.cells, 0);
    }

    pub fn pushClip(self: *HitGrid, rect: Rect) !void {
        const clipped = self.clipToGrid(rect) orelse Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
        const effective = if (self.currentClip()) |top|
            rectIntersect(top, clipped) orelse Rect{ .x = 0, .y = 0, .width = 0, .height = 0 }
        else
            clipped;

        try self.clip_stack.append(effective);
    }

    pub fn popClip(self: *HitGrid) void {
        if (self.clip_stack.items.len > 0) {
            _ = self.clip_stack.pop();
        }
    }

    pub fn currentClip(self: *const HitGrid) ?Rect {
        if (self.clip_stack.items.len == 0) return null;
        return self.clip_stack.items[self.clip_stack.items.len - 1];
    }

    pub fn markRect(self: *HitGrid, rect: Rect, id: Id) void {
        const clipped = self.clipRect(rect) orelse return;
        var y = clipped.y;
        while (y < clipped.y + clipped.height) : (y += 1) {
            var x = clipped.x;
            while (x < clipped.x + clipped.width) : (x += 1) {
                self.setCell(x, y, id);
            }
        }
    }

    pub fn markCell(self: *HitGrid, x: u16, y: u16, id: Id) void {
        if (self.clipRect(.{ .x = x, .y = y, .width = 1, .height = 1 }) == null) return;
        self.setCell(x, y, id);
    }

    pub fn hitAt(self: *const HitGrid, x: u16, y: u16) ?Id {
        if (x >= self.width or y >= self.height) return null;
        const idx = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
        const hash = self.cells[idx];
        if (hash == 0) return null;
        return Id{ .hash = hash };
    }

    fn setCell(self: *HitGrid, x: u16, y: u16, id: Id) void {
        if (x >= self.width or y >= self.height) return;
        const idx = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
        self.cells[idx] = id.hash;
    }

    fn clipRect(self: *const HitGrid, rect: Rect) ?Rect {
        const clipped = self.clipToGrid(rect) orelse return null;
        if (self.currentClip()) |top| {
            return rectIntersect(top, clipped);
        }
        return clipped;
    }

    fn clipToGrid(self: *const HitGrid, rect: Rect) ?Rect {
        if (self.width == 0 or self.height == 0) return null;
        const grid = Rect{ .x = 0, .y = 0, .width = self.width, .height = self.height };
        return rectIntersect(rect, grid);
    }
};

fn rectIntersect(a: Rect, b: Rect) ?Rect {
    const a_right = @as(u32, a.x) + @as(u32, a.width);
    const b_right = @as(u32, b.x) + @as(u32, b.width);
    const a_bottom = @as(u32, a.y) + @as(u32, a.height);
    const b_bottom = @as(u32, b.y) + @as(u32, b.height);

    const left = @max(@as(u32, a.x), @as(u32, b.x));
    const top = @max(@as(u32, a.y), @as(u32, b.y));
    const right = @min(a_right, b_right);
    const bottom = @min(a_bottom, b_bottom);

    if (right <= left or bottom <= top) return null;

    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

// =============================================================================
// Tests
// =============================================================================

test "HitGrid markRect and hitAt" {
    var grid = try HitGrid.init(std.testing.allocator, .{ .width = 10, .height = 5 });
    defer grid.deinit();

    const id = Id.child(Id.root, "button");
    grid.markRect(.{ .x = 2, .y = 1, .width = 3, .height = 2 }, id);

    try std.testing.expect(grid.hitAt(2, 1).?.eql(id));
    try std.testing.expect(grid.hitAt(4, 2).?.eql(id));
    try std.testing.expect(grid.hitAt(1, 1) == null);
}

test "HitGrid clip stack limits hits" {
    var grid = try HitGrid.init(std.testing.allocator, .{ .width = 8, .height = 6 });
    defer grid.deinit();

    const id = Id.child(Id.root, "panel");
    try grid.pushClip(.{ .x = 2, .y = 2, .width = 3, .height = 3 });
    grid.markRect(.{ .x = 0, .y = 0, .width = 8, .height = 6 }, id);

    try std.testing.expect(grid.hitAt(2, 2).?.eql(id));
    try std.testing.expect(grid.hitAt(4, 4).?.eql(id));
    try std.testing.expect(grid.hitAt(1, 1) == null);
    try std.testing.expect(grid.hitAt(6, 2) == null);
}

test "HitGrid overlay wins" {
    var grid = try HitGrid.init(std.testing.allocator, .{ .width = 6, .height = 4 });
    defer grid.deinit();

    const back = Id.child(Id.root, "back");
    const front = Id.child(Id.root, "front");

    grid.markRect(.{ .x = 0, .y = 0, .width = 6, .height = 4 }, back);
    grid.markRect(.{ .x = 2, .y = 1, .width = 2, .height = 2 }, front);

    try std.testing.expect(grid.hitAt(0, 0).?.eql(back));
    try std.testing.expect(grid.hitAt(2, 1).?.eql(front));
}

test "HitGrid beginFrame clears" {
    var grid = try HitGrid.init(std.testing.allocator, .{ .width = 4, .height = 3 });
    defer grid.deinit();

    const id = Id.child(Id.root, "a");
    grid.markRect(.{ .x = 0, .y = 0, .width = 4, .height = 3 }, id);
    grid.beginFrame();

    try std.testing.expect(grid.hitAt(1, 1) == null);
    try std.testing.expect(grid.currentClip() == null);
}
