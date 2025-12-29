//! HitTest: Mouse hit-testing for widget click/hover detection
//!
//! Routes mouse events to the correct widget based on screen position:
//! - Widgets register hit rectangles during render
//! - On mouse event, walks rects in z-order to find target
//! - Tracks hover state for effects

const std = @import("std");
const Id = @import("Id.zig").Id;

/// Screen rectangle
pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    /// Check if a point is inside this rectangle
    pub fn contains(self: Rect, px: u16, py: u16) bool {
        return px >= self.x and px < self.x + self.width and
            py >= self.y and py < self.y + self.height;
    }
};

/// Options for a hit rect
pub const HitOptions = struct {
    clickable: bool = true,
    hoverable: bool = true,
    /// Z-index for stacking (higher is on top)
    z_index: i16 = 0,
};

/// A registered hit rectangle
const HitRect = struct {
    id: Id,
    rect: Rect,
    options: HitOptions,
};

/// Result of a hit test
pub const HitResult = struct {
    id: Id,
    /// Position relative to the widget's top-left
    local_x: u16,
    local_y: u16,
};

/// Manager for hit rectangles and hover state
pub const HitTester = struct {
    /// Registered hit rectangles (cleared each frame)
    rects: std.ArrayList(HitRect),
    /// Currently hovered widget ID (if any)
    hovered_id: ?Id,
    /// Widget that was clicked this frame (if any)
    clicked_id: ?Id,
    /// Memory allocator
    allocator: std.mem.Allocator,

    /// Create a new HitTester
    pub fn init(allocator: std.mem.Allocator) HitTester {
        return .{
            .rects = std.ArrayList(HitRect).init(allocator),
            .hovered_id = null,
            .clicked_id = null,
            .allocator = allocator,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *HitTester) void {
        self.rects.deinit();
    }

    /// Clear all hit rects (call at start of each frame)
    pub fn beginFrame(self: *HitTester) void {
        self.rects.clearRetainingCapacity();
        self.clicked_id = null;
    }

    /// Register a hit rectangle for a widget
    pub fn registerHitRect(self: *HitTester, id: Id, rect: Rect, options: HitOptions) !void {
        try self.rects.append(.{
            .id = id,
            .rect = rect,
            .options = options,
        });
    }

    /// Perform hit test at position, returning the topmost widget
    pub fn hitTest(self: *const HitTester, x: u16, y: u16) ?HitResult {
        // Walk rects in reverse order (last registered = on top at same z-index)
        // For proper z-ordering, we need to find the highest z-index hit
        var best_hit: ?HitResult = null;
        var best_z: i16 = std.math.minInt(i16);

        for (self.rects.items) |hit_rect| {
            if (hit_rect.rect.contains(x, y)) {
                if (hit_rect.options.z_index >= best_z) {
                    best_z = hit_rect.options.z_index;
                    best_hit = .{
                        .id = hit_rect.id,
                        .local_x = x - hit_rect.rect.x,
                        .local_y = y - hit_rect.rect.y,
                    };
                }
            }
        }

        return best_hit;
    }

    /// Update hover state based on mouse position
    pub fn updateHover(self: *HitTester, x: u16, y: u16) void {
        if (self.hitTest(x, y)) |result| {
            self.hovered_id = result.id;
        } else {
            self.hovered_id = null;
        }
    }

    /// Record a click at position
    pub fn recordClick(self: *HitTester, x: u16, y: u16) ?HitResult {
        if (self.hitTest(x, y)) |result| {
            // Check if this widget is clickable
            for (self.rects.items) |hit_rect| {
                if (hit_rect.id.eql(result.id) and hit_rect.options.clickable) {
                    self.clicked_id = result.id;
                    return result;
                }
            }
        }
        return null;
    }

    /// Check if a widget is currently hovered
    pub fn isHovered(self: *const HitTester, id: Id) bool {
        if (self.hovered_id) |hovered| {
            return hovered.eql(id);
        }
        return false;
    }

    /// Check if a widget was clicked this frame
    pub fn isClicked(self: *const HitTester, id: Id) bool {
        if (self.clicked_id) |clicked| {
            return clicked.eql(id);
        }
        return false;
    }

    /// Get the hit rect for a widget ID (if registered)
    pub fn getRectForId(self: *const HitTester, id: Id) ?Rect {
        for (self.rects.items) |hit_rect| {
            if (hit_rect.id.eql(id)) {
                return hit_rect.rect;
            }
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "HitTester init and deinit" {
    var ht = HitTester.init(std.testing.allocator);
    defer ht.deinit();

    try std.testing.expect(ht.hovered_id == null);
    try std.testing.expect(ht.clicked_id == null);
}

test "HitTester register and hit test" {
    var ht = HitTester.init(std.testing.allocator);
    defer ht.deinit();

    const id1 = Id.init("button1");
    const id2 = Id.init("button2");

    try ht.registerHitRect(id1, .{ .x = 0, .y = 0, .width = 10, .height = 5 }, .{});
    try ht.registerHitRect(id2, .{ .x = 15, .y = 0, .width = 10, .height = 5 }, .{});

    // Hit first button
    const result1 = ht.hitTest(5, 2);
    try std.testing.expect(result1 != null);
    try std.testing.expect(result1.?.id.eql(id1));
    try std.testing.expectEqual(@as(u16, 5), result1.?.local_x);
    try std.testing.expectEqual(@as(u16, 2), result1.?.local_y);

    // Hit second button
    const result2 = ht.hitTest(20, 2);
    try std.testing.expect(result2 != null);
    try std.testing.expect(result2.?.id.eql(id2));

    // Miss (between buttons)
    const result3 = ht.hitTest(12, 2);
    try std.testing.expect(result3 == null);
}

test "HitTester z-order" {
    var ht = HitTester.init(std.testing.allocator);
    defer ht.deinit();

    const id_back = Id.init("background");
    const id_front = Id.init("overlay");

    // Register overlapping rects with different z-index
    try ht.registerHitRect(id_back, .{ .x = 0, .y = 0, .width = 20, .height = 10 }, .{ .z_index = 0 });
    try ht.registerHitRect(id_front, .{ .x = 5, .y = 2, .width = 10, .height = 5 }, .{ .z_index = 1 });

    // Hit in overlap area should return front widget
    const result = ht.hitTest(10, 4);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.id.eql(id_front));

    // Hit outside overlay should return background
    const result2 = ht.hitTest(2, 2);
    try std.testing.expect(result2 != null);
    try std.testing.expect(result2.?.id.eql(id_back));
}

test "HitTester hover state" {
    var ht = HitTester.init(std.testing.allocator);
    defer ht.deinit();

    const id = Id.init("button");
    try ht.registerHitRect(id, .{ .x = 0, .y = 0, .width = 10, .height = 5 }, .{});

    // Not hovered initially
    try std.testing.expect(!ht.isHovered(id));

    // Update hover
    ht.updateHover(5, 2);
    try std.testing.expect(ht.isHovered(id));

    // Move outside
    ht.updateHover(20, 20);
    try std.testing.expect(!ht.isHovered(id));
}

test "HitTester click tracking" {
    var ht = HitTester.init(std.testing.allocator);
    defer ht.deinit();

    const id = Id.init("button");
    try ht.registerHitRect(id, .{ .x = 0, .y = 0, .width = 10, .height = 5 }, .{});

    // Not clicked initially
    try std.testing.expect(!ht.isClicked(id));

    // Click
    const result = ht.recordClick(5, 2);
    try std.testing.expect(result != null);
    try std.testing.expect(ht.isClicked(id));

    // Begin new frame clears click state
    ht.beginFrame();
    try std.testing.expect(!ht.isClicked(id));
}

test "HitTester beginFrame clears rects" {
    var ht = HitTester.init(std.testing.allocator);
    defer ht.deinit();

    const id = Id.init("button");
    try ht.registerHitRect(id, .{ .x = 0, .y = 0, .width = 10, .height = 5 }, .{});

    try std.testing.expectEqual(@as(usize, 1), ht.rects.items.len);

    ht.beginFrame();
    try std.testing.expectEqual(@as(usize, 0), ht.rects.items.len);
}

test "Rect.contains" {
    const rect = Rect{ .x = 10, .y = 20, .width = 5, .height = 3 };

    // Inside
    try std.testing.expect(rect.contains(12, 21));

    // On edges
    try std.testing.expect(rect.contains(10, 20)); // top-left
    try std.testing.expect(rect.contains(14, 22)); // bottom-right (exclusive, so this should be last valid)

    // Outside (exclusive right/bottom edge)
    try std.testing.expect(!rect.contains(15, 21)); // right edge
    try std.testing.expect(!rect.contains(12, 23)); // bottom edge
    try std.testing.expect(!rect.contains(9, 21)); // left of rect
    try std.testing.expect(!rect.contains(12, 19)); // above rect
}
