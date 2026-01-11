//! Border: Decorator widget that draws a box around a child widget
//!
//! Wraps another widget and draws a border using box-drawing characters.
//! Supports multiple styles (light, heavy, double, rounded, ascii) and
//! an optional title in the top border.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Layout = @import("../Layout.zig");
const Event = @import("../Event.zig");
const Cell = @import("../Cell.zig");
const unicode = @import("../unicode/width.zig");

/// Re-export BoxStyle for convenience
pub const BoxStyle = Layout.BoxStyle;

/// Border widget decorator
pub const Border = struct {
    child: Widget.Widget,
    style: BoxStyle = BoxStyle.light,
    title: ?[]const u8 = null,
    fg: Cell.Color = .default,
    bg: Cell.Color = .default,
    attrs: Cell.Attributes = .{},

    /// Create a border wrapper around a child widget with light style
    pub fn init(child: Widget.Widget) Border {
        return .{ .child = child };
    }

    /// Set the border style
    pub fn withStyle(self: *Border, style: BoxStyle) *Border {
        self.style = style;
        return self;
    }

    /// Set a title in the top border
    pub fn withTitle(self: *Border, title: []const u8) *Border {
        self.title = title;
        return self;
    }

    /// Set the foreground color
    pub fn withFg(self: *Border, fg: Cell.Color) *Border {
        self.fg = fg;
        return self;
    }

    /// Set the background color
    pub fn withBg(self: *Border, bg: Cell.Color) *Border {
        self.bg = bg;
        return self;
    }

    /// Set the attributes
    pub fn withAttrs(self: *Border, attrs: Cell.Attributes) *Border {
        self.attrs = attrs;
        return self;
    }

    /// Measure: child size plus 1 cell on each side for border
    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Border = @ptrCast(@alignCast(ptr));

        // Border takes 1 cell on each side
        const border_overhead: u16 = 2; // left + right, or top + bottom

        // Reduce available space for child by border
        const child_constraint = Widget.SizeConstraint{
            .min_width = constraint.min_width -| border_overhead,
            .max_width = constraint.max_width -| border_overhead,
            .min_height = constraint.min_height -| border_overhead,
            .max_height = constraint.max_height -| border_overhead,
        };

        const child_size = self.child.measure(child_constraint);

        // Add border to child's measured size
        return constraint.clamp(.{
            .width = child_size.width +| border_overhead,
            .height = child_size.height +| border_overhead,
        });
    }

    /// Render: draw box and render child in interior
    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Border = @ptrCast(@alignCast(ptr));

        const view_size = view.size();
        if (view_size.width < 2 or view_size.height < 2) return;

        // Draw corners
        view.setCell(0, 0, Cell.styled(self.style.top_left, self.fg, self.bg, self.attrs));
        view.setCell(@intCast(view_size.width - 1), 0, Cell.styled(self.style.top_right, self.fg, self.bg, self.attrs));
        view.setCell(0, @intCast(view_size.height - 1), Cell.styled(self.style.bottom_left, self.fg, self.bg, self.attrs));
        view.setCell(@intCast(view_size.width - 1), @intCast(view_size.height - 1), Cell.styled(self.style.bottom_right, self.fg, self.bg, self.attrs));

        // Draw horizontal lines
        if (view_size.width > 2) {
            var x: u16 = 1;
            while (x < view_size.width - 1) : (x += 1) {
                view.setCell(@intCast(x), 0, Cell.styled(self.style.horizontal, self.fg, self.bg, self.attrs));
                view.setCell(@intCast(x), @intCast(view_size.height - 1), Cell.styled(self.style.horizontal, self.fg, self.bg, self.attrs));
            }
        }

        // Draw vertical lines
        if (view_size.height > 2) {
            var y: u16 = 1;
            while (y < view_size.height - 1) : (y += 1) {
                view.setCell(0, @intCast(y), Cell.styled(self.style.vertical, self.fg, self.bg, self.attrs));
                view.setCell(@intCast(view_size.width - 1), @intCast(y), Cell.styled(self.style.vertical, self.fg, self.bg, self.attrs));
            }
        }

        // Draw title if present
        if (self.title) |title| {
            const title_width: u16 = @intCast(@min(unicode.stringWidth(title), std.math.maxInt(u16)));
            const available_width = view_size.width -| 4; // Leave room for corners and spaces

            if (title_width > 0 and available_width > 0) {
                // Draw title with a space on each side
                const display_width = @min(title_width, available_width);
                const start_x: i32 = 2; // After corner and space

                // Print space before title
                view.setCell(1, 0, Cell.styled(' ', self.fg, self.bg, self.attrs));

                // Print title (clipped if needed)
                view.print(start_x, 0, title, self.fg, self.bg, self.attrs);

                // Print space after title (if room)
                if (start_x + @as(i32, display_width) < view_size.width - 1) {
                    view.setCell(start_x + @as(i32, display_width), 0, Cell.styled(' ', self.fg, self.bg, self.attrs));
                }
            }
        }

        // Calculate content area
        const content_width = view_size.width -| 2;
        const content_height = view_size.height -| 2;

        if (content_width == 0 or content_height == 0) return;

        // Create sub-view for child at (1, 1)
        var child_view = view.subView(.{
            .x = 1,
            .y = 1,
            .width = content_width,
            .height = content_height,
        });

        self.child.render(&child_view);
    }

    /// Handle events - forward to child
    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *Border = @ptrCast(@alignCast(ptr));
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

// A simple test widget that fills its space with a character
const FillWidget = struct {
    char: u21,

    fn measure(_: *anyopaque, _: Widget.SizeConstraint) Widget.MeasuredSize {
        return .{ .width = 3, .height = 1 };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *FillWidget = @ptrCast(@alignCast(ptr));
        const size = view.size();
        var y: i32 = 0;
        while (y < size.height) : (y += 1) {
            var x: i32 = 0;
            while (x < size.width) : (x += 1) {
                view.setCell(x, y, Cell.styled(self.char, .default, .default, .{}));
            }
        }
    }

    pub const widget_vtable = Widget.VTable{
        .measureFn = measure,
        .renderFn = render,
    };
};

test "Border measure adds border to child size" {
    var fill = FillWidget{ .char = 'X' };
    const child = Widget.Widget.init(FillWidget, &fill);

    var border = Border.init(child);
    const widget = Widget.Widget.init(Border, &border);

    const size = widget.measure(Widget.SizeConstraint{});

    // Child is 3x1, border adds 1 on each side = 5x3
    try std.testing.expectEqual(@as(u16, 5), size.width);
    try std.testing.expectEqual(@as(u16, 3), size.height);
}

test "Border render draws light box" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 10, .height = 5 });
    defer root.deinit();

    var fill = FillWidget{ .char = 'X' };
    const child = Widget.Widget.init(FillWidget, &fill);

    var border = Border.init(child);
    const widget = Widget.Widget.init(Border, &border);

    var view = PlaneView.init(root);
    widget.render(&view);

    // Check corners
    try std.testing.expectEqual(@as(u21, '┌'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, '┐'), view.getCell(9, 0).?.char);
    try std.testing.expectEqual(@as(u21, '└'), view.getCell(0, 4).?.char);
    try std.testing.expectEqual(@as(u21, '┘'), view.getCell(9, 4).?.char);

    // Check horizontal lines
    try std.testing.expectEqual(@as(u21, '─'), view.getCell(1, 0).?.char);
    try std.testing.expectEqual(@as(u21, '─'), view.getCell(1, 4).?.char);

    // Check vertical lines
    try std.testing.expectEqual(@as(u21, '│'), view.getCell(0, 1).?.char);
    try std.testing.expectEqual(@as(u21, '│'), view.getCell(9, 1).?.char);

    // Check child content is rendered inside
    try std.testing.expectEqual(@as(u21, 'X'), view.getCell(1, 1).?.char);
}

test "Border render with heavy style" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 10, .height = 5 });
    defer root.deinit();

    var fill = FillWidget{ .char = 'X' };
    const child = Widget.Widget.init(FillWidget, &fill);

    var border = Border.init(child);
    _ = border.withStyle(BoxStyle.heavy);
    const widget = Widget.Widget.init(Border, &border);

    var view = PlaneView.init(root);
    widget.render(&view);

    // Check heavy style corners
    try std.testing.expectEqual(@as(u21, '┏'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, '┓'), view.getCell(9, 0).?.char);
    try std.testing.expectEqual(@as(u21, '━'), view.getCell(1, 0).?.char);
    try std.testing.expectEqual(@as(u21, '┃'), view.getCell(0, 1).?.char);
}

test "Border render with title" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 5 });
    defer root.deinit();

    var fill = FillWidget{ .char = 'X' };
    const child = Widget.Widget.init(FillWidget, &fill);

    var border = Border.init(child);
    _ = border.withTitle("Title");
    const widget = Widget.Widget.init(Border, &border);

    var view = PlaneView.init(root);
    widget.render(&view);

    // Check title characters at position 2 (after corner and space)
    try std.testing.expectEqual(@as(u21, 'T'), view.getCell(2, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'i'), view.getCell(3, 0).?.char);
    try std.testing.expectEqual(@as(u21, 't'), view.getCell(4, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'l'), view.getCell(5, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'e'), view.getCell(6, 0).?.char);
}

test "Border with rounded style" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 10, .height = 5 });
    defer root.deinit();

    var fill = FillWidget{ .char = 'X' };
    const child = Widget.Widget.init(FillWidget, &fill);

    var border = Border.init(child);
    _ = border.withStyle(BoxStyle.rounded);
    const widget = Widget.Widget.init(Border, &border);

    var view = PlaneView.init(root);
    widget.render(&view);

    try std.testing.expectEqual(@as(u21, '╭'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, '╮'), view.getCell(9, 0).?.char);
    try std.testing.expectEqual(@as(u21, '╰'), view.getCell(0, 4).?.char);
    try std.testing.expectEqual(@as(u21, '╯'), view.getCell(9, 4).?.char);
}

test "Border minimum size" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 2, .height = 2 });
    defer root.deinit();

    var fill = FillWidget{ .char = 'X' };
    const child = Widget.Widget.init(FillWidget, &fill);

    var border = Border.init(child);
    const widget = Widget.Widget.init(Border, &border);

    var view = PlaneView.init(root);
    widget.render(&view);

    // 2x2 is minimum - just corners
    try std.testing.expectEqual(@as(u21, '┌'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, '┐'), view.getCell(1, 0).?.char);
    try std.testing.expectEqual(@as(u21, '└'), view.getCell(0, 1).?.char);
    try std.testing.expectEqual(@as(u21, '┘'), view.getCell(1, 1).?.char);
}

test "Border builder pattern" {
    var fill = FillWidget{ .char = 'X' };
    const child = Widget.Widget.init(FillWidget, &fill);

    var border = Border.init(child);
    _ = border.withStyle(BoxStyle.double)
        .withTitle("Test")
        .withFg(Cell.Color.red);

    try std.testing.expectEqual(BoxStyle.double.top_left, border.style.top_left);
    try std.testing.expectEqualStrings("Test", border.title.?);
    try std.testing.expectEqual(Cell.Color.red, border.fg);
}
