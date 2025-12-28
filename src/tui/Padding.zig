//! Padding: Decorator widget that adds spacing around a child widget
//!
//! Wraps another widget and adds configurable padding on each side.
//! The padding is accounted for in measure() and creates an offset
//! sub-view for the child in render().

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Event = @import("../Event.zig");

/// Padding values for each side
pub const Insets = struct {
    top: u16 = 0,
    right: u16 = 0,
    bottom: u16 = 0,
    left: u16 = 0,

    /// Create uniform padding on all sides
    pub fn all(value: u16) Insets {
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }

    /// Create symmetric padding (vertical, horizontal)
    pub fn symmetric(vert: u16, horiz: u16) Insets {
        return .{ .top = vert, .right = horiz, .bottom = vert, .left = horiz };
    }

    /// Create padding for only horizontal sides
    pub fn horizontal(value: u16) Insets {
        return .{ .left = value, .right = value };
    }

    /// Create padding for only vertical sides
    pub fn vertical(value: u16) Insets {
        return .{ .top = value, .bottom = value };
    }

    /// Total horizontal padding
    pub fn totalHorizontal(self: Insets) u16 {
        return self.left +| self.right;
    }

    /// Total vertical padding
    pub fn totalVertical(self: Insets) u16 {
        return self.top +| self.bottom;
    }
};

/// Padding widget decorator
pub const Padding = struct {
    child: Widget.Widget,
    insets: Insets,

    /// Create a padding wrapper around a child widget with uniform padding
    pub fn init(child: Widget.Widget, value: u16) Padding {
        return .{
            .child = child,
            .insets = Insets.all(value),
        };
    }

    /// Create a padding wrapper with custom insets
    pub fn withInsets(child: Widget.Widget, insets: Insets) Padding {
        return .{
            .child = child,
            .insets = insets,
        };
    }

    /// Measure: child size plus padding
    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Padding = @ptrCast(@alignCast(ptr));

        // Reduce available space for child by padding
        const child_constraint = Widget.SizeConstraint{
            .min_width = constraint.min_width -| self.insets.totalHorizontal(),
            .max_width = constraint.max_width -| self.insets.totalHorizontal(),
            .min_height = constraint.min_height -| self.insets.totalVertical(),
            .max_height = constraint.max_height -| self.insets.totalVertical(),
        };

        const child_size = self.child.measure(child_constraint);

        // Add padding to child's measured size
        return constraint.clamp(.{
            .width = child_size.width +| self.insets.totalHorizontal(),
            .height = child_size.height +| self.insets.totalVertical(),
        });
    }

    /// Render: create an offset sub-view for the child
    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Padding = @ptrCast(@alignCast(ptr));

        const view_size = view.size();

        // Calculate available space for child after padding
        const content_width = view_size.width -| self.insets.totalHorizontal();
        const content_height = view_size.height -| self.insets.totalVertical();

        if (content_width == 0 or content_height == 0) return;

        // Create sub-view offset by left/top padding
        var child_view = view.subView(.{
            .x = self.insets.left,
            .y = self.insets.top,
            .width = content_width,
            .height = content_height,
        });

        self.child.render(&child_view);
    }

    /// Handle events - forward to child
    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *Padding = @ptrCast(@alignCast(ptr));
        return self.child.handleEvent(event);
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

// A simple test widget that fills its space with a character
const FillWidget = struct {
    char: u21,
    measured_width: u16,
    measured_height: u16,

    fn measure(_: *anyopaque, _: Widget.SizeConstraint) Widget.MeasuredSize {
        // Return fixed 3x1 size for tests
        return .{ .width = 3, .height = 1 };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *FillWidget = @ptrCast(@alignCast(ptr));
        const size = view.size();
        var y: i32 = 0;
        while (y < size.height) : (y += 1) {
            var x: i32 = 0;
            while (x < size.width) : (x += 1) {
                view.setCell(x, y, Cell{
                    .char = self.char,
                    .combining = .{ 0, 0 },
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

test "Insets.all" {
    const insets = Insets.all(5);
    try std.testing.expectEqual(@as(u16, 5), insets.top);
    try std.testing.expectEqual(@as(u16, 5), insets.right);
    try std.testing.expectEqual(@as(u16, 5), insets.bottom);
    try std.testing.expectEqual(@as(u16, 5), insets.left);
}

test "Insets.symmetric" {
    const insets = Insets.symmetric(3, 5);
    try std.testing.expectEqual(@as(u16, 3), insets.top);
    try std.testing.expectEqual(@as(u16, 5), insets.right);
    try std.testing.expectEqual(@as(u16, 3), insets.bottom);
    try std.testing.expectEqual(@as(u16, 5), insets.left);
}

test "Insets.totalHorizontal" {
    const insets = Insets{ .left = 3, .right = 5, .top = 2, .bottom = 2 };
    try std.testing.expectEqual(@as(u16, 8), insets.totalHorizontal());
}

test "Insets.totalVertical" {
    const insets = Insets{ .left = 3, .right = 5, .top = 2, .bottom = 4 };
    try std.testing.expectEqual(@as(u16, 6), insets.totalVertical());
}

test "Padding measure adds padding to child size" {
    var fill = FillWidget{ .char = 'X', .measured_width = 3, .measured_height = 1 };
    const child = Widget.Widget.init(FillWidget, &fill);

    var padding = Padding.init(child, 2);
    const widget = Widget.Widget.init(Padding, &padding);

    const size = widget.measure(Widget.SizeConstraint{});

    // Child is 3x1, padding adds 2 on each side = 7x5
    try std.testing.expectEqual(@as(u16, 7), size.width);
    try std.testing.expectEqual(@as(u16, 5), size.height);
}

test "Padding render offsets child" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    var fill = FillWidget{ .char = 'X', .measured_width = 3, .measured_height = 1 };
    const child = Widget.Widget.init(FillWidget, &fill);

    var padding = Padding.withInsets(child, .{ .top = 2, .left = 3, .bottom = 0, .right = 0 });
    const widget = Widget.Widget.init(Padding, &padding);

    var view = PlaneView.init(root);
    widget.render(&view);

    // The fill widget should render at offset (3, 2)
    try std.testing.expectEqual(@as(u21, 'X'), view.getCell(3, 2).?.char);
    try std.testing.expectEqual(@as(u21, 'X'), view.getCell(4, 2).?.char);
    // Padding area should be empty (default cell)
    try std.testing.expect(view.getCell(0, 0).?.eql(Cell{}));
    try std.testing.expect(view.getCell(2, 2).?.eql(Cell{}));
}
