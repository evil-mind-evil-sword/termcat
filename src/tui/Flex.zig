//! Flex: Container widget that arranges children along an axis
//!
//! Flex is the foundation for composable widget trees. It arranges children
//! either horizontally (Row) or vertically (Column) using the Constraint system
//! for space distribution.
//!
//! Example:
//! ```
//! var flex = Flex.column();
//! _ = flex.addChild(header, Constraint.fromFixed(3));
//! _ = flex.addChild(content, Constraint.fill());
//! _ = flex.addChild(footer, Constraint.fromFixed(1));
//! ```

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Constraint = @import("Constraint.zig").Constraint;
const constraint_mod = @import("Constraint.zig");
const Event = @import("../Event.zig");

/// Direction for flex layout
pub const Direction = enum {
    horizontal, // Row - children arranged left-to-right
    vertical, // Column - children arranged top-to-bottom
};

/// A child entry in the flex container
pub const FlexChild = struct {
    widget: Widget.Widget,
    constraint: Constraint,
};

/// Maximum number of children in a flex container
/// Using a fixed size to avoid allocations during layout
pub const MAX_CHILDREN = 32;

/// Flex container widget
pub const Flex = struct {
    direction: Direction,
    gap: u16 = 0,
    children: [MAX_CHILDREN]FlexChild = undefined,
    child_count: usize = 0,

    /// Create a horizontal (row) flex container
    pub fn row() Flex {
        return .{ .direction = .horizontal };
    }

    /// Create a vertical (column) flex container
    pub fn column() Flex {
        return .{ .direction = .vertical };
    }

    /// Set the gap between children
    pub fn withGap(self: *Flex, gap: u16) *Flex {
        self.gap = gap;
        return self;
    }

    /// Add a child widget with its constraint
    /// Returns self for chaining, or null if max children exceeded
    pub fn addChild(self: *Flex, widget: Widget.Widget, constraint: Constraint) ?*Flex {
        if (self.child_count >= MAX_CHILDREN) return null;
        self.children[self.child_count] = .{
            .widget = widget,
            .constraint = constraint,
        };
        self.child_count += 1;
        return self;
    }

    /// Get the children as a slice
    pub fn getChildren(self: *const Flex) []const FlexChild {
        return self.children[0..self.child_count];
    }

    /// Measure: aggregate child sizes along main axis, max along cross axis
    fn measure(ptr: *anyopaque, parent_constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Flex = @ptrCast(@alignCast(ptr));

        if (self.child_count == 0) {
            return Widget.MeasuredSize.zero();
        }

        var total_main: u32 = 0; // Total size along main axis
        var max_cross: u16 = 0; // Max size along cross axis
        var fixed_total: u32 = 0; // Total fixed space needed
        var has_flexible: bool = false;

        // First pass: measure fixed children and find max cross size
        for (self.children[0..self.child_count]) |child| {
            // Create constraint for child measurement
            const child_constraint = switch (self.direction) {
                .horizontal => Widget.SizeConstraint{
                    .max_width = parent_constraint.max_width,
                    .max_height = parent_constraint.max_height,
                },
                .vertical => Widget.SizeConstraint{
                    .max_width = parent_constraint.max_width,
                    .max_height = parent_constraint.max_height,
                },
            };

            const child_size = child.widget.measure(child_constraint);

            switch (child.constraint) {
                .fixed => |size| {
                    fixed_total += size;
                },
                .ratio, .minimum => {
                    has_flexible = true;
                    // For flexible children, use their measured size as minimum
                    switch (self.direction) {
                        .horizontal => fixed_total += child_size.width,
                        .vertical => fixed_total += child_size.height,
                    }
                },
            }

            // Track max cross axis size
            switch (self.direction) {
                .horizontal => max_cross = @max(max_cross, child_size.height),
                .vertical => max_cross = @max(max_cross, child_size.width),
            }
        }

        // Add gap space
        const gap_total: u32 = if (self.child_count > 1)
            @as(u32, self.gap) * @as(u32, @intCast(self.child_count - 1))
        else
            0;

        total_main = fixed_total + gap_total;

        // If we have flexible children and a max constraint, use the max
        if (has_flexible) {
            const max_main: u32 = switch (self.direction) {
                .horizontal => parent_constraint.max_width,
                .vertical => parent_constraint.max_height,
            };
            if (max_main < std.math.maxInt(u16)) {
                total_main = @max(total_main, max_main);
            }
        }

        // Build final size
        const result = switch (self.direction) {
            .horizontal => Widget.MeasuredSize{
                .width = @intCast(@min(total_main, std.math.maxInt(u16))),
                .height = max_cross,
            },
            .vertical => Widget.MeasuredSize{
                .width = max_cross,
                .height = @intCast(@min(total_main, std.math.maxInt(u16))),
            },
        };

        return parent_constraint.clamp(result);
    }

    /// Render: position and render each child
    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Flex = @ptrCast(@alignCast(ptr));

        if (self.child_count == 0) return;

        const view_size = view.size();
        const available_main: u16 = switch (self.direction) {
            .horizontal => view_size.width,
            .vertical => view_size.height,
        };

        // Calculate total gap space
        const gap_total: u16 = if (self.child_count > 1)
            self.gap *| @as(u16, @intCast(self.child_count - 1))
        else
            0;

        const available_for_children = available_main -| gap_total;

        // Build constraint array for resolution
        var constraints: [MAX_CHILDREN]Constraint = undefined;
        for (self.children[0..self.child_count], 0..) |child, i| {
            constraints[i] = child.constraint;
        }

        // Resolve constraints to actual sizes
        const sizes_opt = constraint_mod.resolveWithAllocator(
            std.heap.page_allocator,
            constraints[0..self.child_count],
            available_for_children,
        );

        if (sizes_opt == null) {
            // Constraints couldn't be satisfied - render nothing
            return;
        }
        var sizes = sizes_opt.?;
        defer sizes.deinit();

        // Position and render each child
        var offset: u16 = 0;
        for (self.children[0..self.child_count], 0..) |child, i| {
            const child_main_size = sizes.sizes[i];

            // Create sub-view for this child
            var child_view = switch (self.direction) {
                .horizontal => view.subView(.{
                    .x = offset,
                    .y = 0,
                    .width = child_main_size,
                    .height = view_size.height,
                }),
                .vertical => view.subView(.{
                    .x = 0,
                    .y = offset,
                    .width = view_size.width,
                    .height = child_main_size,
                }),
            };

            child.widget.render(&child_view);

            offset +|= child_main_size +| self.gap;
        }
    }

    /// Handle events - forward to children (could be extended for focus management)
    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *Flex = @ptrCast(@alignCast(ptr));

        // Forward event to all children until one consumes it
        for (self.children[0..self.child_count]) |child| {
            if (child.widget.handleEvent(event) == .consumed) {
                return .consumed;
            }
        }
        return .ignored;
    }

    /// VTable for Widget interface
    pub const widget_vtable = Widget.VTable{
        .measureFn = measure,
        .renderFn = render,
        .handleEventFn = handleEvent,
    };
};

// ============================================================================
// Tests
// ============================================================================

const Plane = @import("../Plane.zig");
const Cell = @import("../Cell.zig");

// Test widget that fills with a character and reports fixed size
const TestWidget = struct {
    char: u21,
    width: u16,
    height: u16,

    fn measure(ptr: *anyopaque, _: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *TestWidget = @ptrCast(@alignCast(ptr));
        return .{ .width = self.width, .height = self.height };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *TestWidget = @ptrCast(@alignCast(ptr));
        const size = view.size();
        var y: i32 = 0;
        while (y < size.height) : (y += 1) {
            var x: i32 = 0;
            while (x < size.width) : (x += 1) {
                view.setCell(x, y, Cell{
                    .char = self.char,
                    .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                    .fg = .default,
                    .bg = .default,
                    .attrs = .{},
                });
            }
        }
    }

    pub const widget_vtable = Widget.VTable{
        .measureFn = measure,
        .renderFn = render,
    };
};

test "Flex.row creates horizontal container" {
    const flex = Flex.row();
    try std.testing.expectEqual(Direction.horizontal, flex.direction);
    try std.testing.expectEqual(@as(usize, 0), flex.child_count);
}

test "Flex.column creates vertical container" {
    const flex = Flex.column();
    try std.testing.expectEqual(Direction.vertical, flex.direction);
}

test "Flex.addChild adds children" {
    var widget1 = TestWidget{ .char = 'A', .width = 5, .height = 1 };
    var widget2 = TestWidget{ .char = 'B', .width = 5, .height = 1 };

    var flex = Flex.row();
    _ = flex.addChild(Widget.Widget.init(TestWidget, &widget1), Constraint.fill());
    _ = flex.addChild(Widget.Widget.init(TestWidget, &widget2), Constraint.fill());

    try std.testing.expectEqual(@as(usize, 2), flex.child_count);
}

test "Flex.withGap sets gap" {
    var flex = Flex.row();
    _ = flex.withGap(2);
    try std.testing.expectEqual(@as(u16, 2), flex.gap);
}

test "Flex horizontal measure" {
    var widget1 = TestWidget{ .char = 'A', .width = 10, .height = 3 };
    var widget2 = TestWidget{ .char = 'B', .width = 15, .height = 5 };

    var flex = Flex.row();
    _ = flex.addChild(Widget.Widget.init(TestWidget, &widget1), .{ .fixed = 10 });
    _ = flex.addChild(Widget.Widget.init(TestWidget, &widget2), .{ .fixed = 15 });

    const widget = Widget.Widget.init(Flex, &flex);
    const size = widget.measure(Widget.SizeConstraint{});

    // Width should be sum of fixed sizes (10 + 15 = 25)
    // Height should be max of children (5)
    try std.testing.expectEqual(@as(u16, 25), size.width);
    try std.testing.expectEqual(@as(u16, 5), size.height);
}

test "Flex vertical measure" {
    var widget1 = TestWidget{ .char = 'A', .width = 10, .height = 3 };
    var widget2 = TestWidget{ .char = 'B', .width = 15, .height = 5 };

    var flex = Flex.column();
    _ = flex.addChild(Widget.Widget.init(TestWidget, &widget1), .{ .fixed = 3 });
    _ = flex.addChild(Widget.Widget.init(TestWidget, &widget2), .{ .fixed = 5 });

    const widget = Widget.Widget.init(Flex, &flex);
    const size = widget.measure(Widget.SizeConstraint{});

    // Width should be max of children (15)
    // Height should be sum of fixed sizes (3 + 5 = 8)
    try std.testing.expectEqual(@as(u16, 15), size.width);
    try std.testing.expectEqual(@as(u16, 8), size.height);
}

test "Flex measure with gap" {
    var widget1 = TestWidget{ .char = 'A', .width = 10, .height = 1 };
    var widget2 = TestWidget{ .char = 'B', .width = 10, .height = 1 };
    var widget3 = TestWidget{ .char = 'C', .width = 10, .height = 1 };

    var flex = Flex.row();
    _ = flex.withGap(2);
    _ = flex.addChild(Widget.Widget.init(TestWidget, &widget1), .{ .fixed = 10 });
    _ = flex.addChild(Widget.Widget.init(TestWidget, &widget2), .{ .fixed = 10 });
    _ = flex.addChild(Widget.Widget.init(TestWidget, &widget3), .{ .fixed = 10 });

    const widget = Widget.Widget.init(Flex, &flex);
    const size = widget.measure(Widget.SizeConstraint{});

    // Width: 10 + 2 + 10 + 2 + 10 = 34
    try std.testing.expectEqual(@as(u16, 34), size.width);
}

test "Flex horizontal render fixed" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 30, .height = 5 });
    defer root.deinit();

    var widget1 = TestWidget{ .char = 'A', .width = 10, .height = 5 };
    var widget2 = TestWidget{ .char = 'B', .width = 10, .height = 5 };

    var flex = Flex.row();
    _ = flex.addChild(Widget.Widget.init(TestWidget, &widget1), .{ .fixed = 10 });
    _ = flex.addChild(Widget.Widget.init(TestWidget, &widget2), .{ .fixed = 10 });

    var view = PlaneView.init(root);
    const widget = Widget.Widget.init(Flex, &flex);
    widget.render(&view);

    // First widget fills 0-9
    try std.testing.expectEqual(@as(u21, 'A'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'A'), view.getCell(9, 0).?.char);

    // Second widget fills 10-19
    try std.testing.expectEqual(@as(u21, 'B'), view.getCell(10, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'B'), view.getCell(19, 0).?.char);
}

test "Flex vertical render fixed" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    var widget1 = TestWidget{ .char = 'A', .width = 20, .height = 3 };
    var widget2 = TestWidget{ .char = 'B', .width = 20, .height = 3 };

    var flex = Flex.column();
    _ = flex.addChild(Widget.Widget.init(TestWidget, &widget1), .{ .fixed = 3 });
    _ = flex.addChild(Widget.Widget.init(TestWidget, &widget2), .{ .fixed = 3 });

    var view = PlaneView.init(root);
    const widget = Widget.Widget.init(Flex, &flex);
    widget.render(&view);

    // First widget fills rows 0-2
    try std.testing.expectEqual(@as(u21, 'A'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'A'), view.getCell(0, 2).?.char);

    // Second widget fills rows 3-5
    try std.testing.expectEqual(@as(u21, 'B'), view.getCell(0, 3).?.char);
    try std.testing.expectEqual(@as(u21, 'B'), view.getCell(0, 5).?.char);
}

test "Flex render with gap" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 30, .height = 5 });
    defer root.deinit();

    var widget1 = TestWidget{ .char = 'A', .width = 10, .height = 5 };
    var widget2 = TestWidget{ .char = 'B', .width = 10, .height = 5 };

    var flex = Flex.row();
    _ = flex.withGap(2);
    _ = flex.addChild(Widget.Widget.init(TestWidget, &widget1), .{ .fixed = 10 });
    _ = flex.addChild(Widget.Widget.init(TestWidget, &widget2), .{ .fixed = 10 });

    var view = PlaneView.init(root);
    const widget = Widget.Widget.init(Flex, &flex);
    widget.render(&view);

    // First widget fills 0-9
    try std.testing.expectEqual(@as(u21, 'A'), view.getCell(9, 0).?.char);

    // Gap at 10-11 (should be empty/default)
    try std.testing.expect(view.getCell(10, 0).?.eql(Cell{}));
    try std.testing.expect(view.getCell(11, 0).?.eql(Cell{}));

    // Second widget starts at 12
    try std.testing.expectEqual(@as(u21, 'B'), view.getCell(12, 0).?.char);
}

test "Flex render with ratio constraints" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 30, .height = 5 });
    defer root.deinit();

    var widget1 = TestWidget{ .char = 'A', .width = 10, .height = 5 };
    var widget2 = TestWidget{ .char = 'B', .width = 10, .height = 5 };

    var flex = Flex.row();
    // 1:2 ratio split of 30 cells = 10:20
    _ = flex.addChild(Widget.Widget.init(TestWidget, &widget1), Constraint.fromRatio(1, 3));
    _ = flex.addChild(Widget.Widget.init(TestWidget, &widget2), Constraint.fromRatio(2, 3));

    var view = PlaneView.init(root);
    const widget = Widget.Widget.init(Flex, &flex);
    widget.render(&view);

    // First widget gets ~10 cells (1/3 of 30)
    try std.testing.expectEqual(@as(u21, 'A'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'A'), view.getCell(9, 0).?.char);

    // Second widget gets ~20 cells (2/3 of 30)
    try std.testing.expectEqual(@as(u21, 'B'), view.getCell(10, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'B'), view.getCell(29, 0).?.char);
}

test "Flex empty container" {
    var flex = Flex.row();
    const widget = Widget.Widget.init(Flex, &flex);

    const size = widget.measure(Widget.SizeConstraint{});
    try std.testing.expectEqual(@as(u16, 0), size.width);
    try std.testing.expectEqual(@as(u16, 0), size.height);
}
