//! Modal: Centered overlay dialog widget
//!
//! A container widget that centers its child content in the available space
//! with an optional backdrop. Used for dialogs, popups, and modal interactions.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const Event = @import("../Event.zig");
const Layout = @import("../Layout.zig");
const unicode = @import("../unicode/width.zig");

/// Modal dialog widget
pub const Modal = struct {
    /// Child content widget
    child: Widget.Widget,
    /// Whether to draw a backdrop overlay
    show_backdrop: bool = true,
    /// Backdrop character (usually space or block)
    backdrop_char: u21 = ' ',
    /// Backdrop style
    backdrop_style: Style = .{ .bg = .{ .index = 0 } }, // Black
    /// Border style
    border_style: Layout.BoxStyle = Layout.BoxStyle.rounded,
    /// Border colors
    border_fg: Cell.Color = .default,
    border_bg: Cell.Color = .default,
    /// Optional title
    title: ?[]const u8 = null,
    /// Whether the modal is visible
    visible: bool = true,
    /// Widget state
    widget_state: Widget.WidgetState = .{},

    /// Create a modal wrapping a child widget
    pub fn init(child: Widget.Widget) Modal {
        return .{ .child = child };
    }

    /// Set whether to show backdrop
    pub fn withBackdrop(self: *Modal, show: bool) *Modal {
        self.show_backdrop = show;
        return self;
    }

    /// Set backdrop character
    pub fn withBackdropChar(self: *Modal, char: u21) *Modal {
        self.backdrop_char = char;
        return self;
    }

    /// Set backdrop style
    pub fn withBackdropStyle(self: *Modal, style: Style) *Modal {
        self.backdrop_style = style;
        return self;
    }

    /// Set border style
    pub fn withBorderStyle(self: *Modal, style: Layout.BoxStyle) *Modal {
        self.border_style = style;
        return self;
    }

    /// Set border colors
    pub fn withBorderColors(self: *Modal, fg: Cell.Color, bg: Cell.Color) *Modal {
        self.border_fg = fg;
        self.border_bg = bg;
        return self;
    }

    /// Set title
    pub fn withTitle(self: *Modal, title: []const u8) *Modal {
        self.title = title;
        return self;
    }

    /// Set visibility
    pub fn withVisible(self: *Modal, visible: bool) *Modal {
        self.visible = visible;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *Modal, state: Widget.WidgetState) *Modal {
        self.widget_state = state;
        return self;
    }

    /// Measure the modal - takes full available space for centering
    fn measure(_: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        // Modal always wants full available space for backdrop and centering
        return .{
            .width = constraint.max_width,
            .height = constraint.max_height,
        };
    }

    /// Render the modal with backdrop and centered child
    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Modal = @ptrCast(@alignCast(ptr));

        if (!self.visible) return;

        const view_size = view.size();
        if (view_size.width == 0 or view_size.height == 0) return;

        // Draw backdrop if enabled
        if (self.show_backdrop) {
            const backdrop_cell = Cell{
                .char = self.backdrop_char,
                .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                .fg = self.backdrop_style.fg,
                .bg = self.backdrop_style.bg,
                .attrs = self.backdrop_style.attrs,
            };

            var y: i32 = 0;
            while (y < view_size.height) : (y += 1) {
                var x: i32 = 0;
                while (x < view_size.width) : (x += 1) {
                    view.setCell(x, y, backdrop_cell);
                }
            }
        }

        // Measure child to determine dialog size
        const child_constraint = Widget.SizeConstraint{
            .max_width = view_size.width -| 4, // Leave room for border and margin
            .max_height = view_size.height -| 4,
        };
        const child_size = self.child.measure(child_constraint);

        // Calculate dialog size (child + border)
        const dialog_width = @min(child_size.width +| 2, view_size.width);
        const dialog_height = @min(child_size.height +| 2, view_size.height);

        // Center the dialog
        const dialog_x: u16 = (view_size.width -| dialog_width) / 2;
        const dialog_y: u16 = (view_size.height -| dialog_height) / 2;

        // Create subview for dialog
        var dialog_view = view.subView(.{
            .x = dialog_x,
            .y = dialog_y,
            .width = dialog_width,
            .height = dialog_height,
        });

        // Fill dialog background
        const fill_cell = Cell{
            .char = ' ',
            .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
            .fg = self.border_fg,
            .bg = self.border_bg,
            .attrs = .{},
        };
        dialog_view.fill(fill_cell);

        // Draw border
        if (dialog_width >= 2 and dialog_height >= 2) {
            // Corners
            dialog_view.setCell(0, 0, makeCell(self.border_style.top_left, self.border_fg, self.border_bg));
            dialog_view.setCell(@intCast(dialog_width - 1), 0, makeCell(self.border_style.top_right, self.border_fg, self.border_bg));
            dialog_view.setCell(0, @intCast(dialog_height - 1), makeCell(self.border_style.bottom_left, self.border_fg, self.border_bg));
            dialog_view.setCell(@intCast(dialog_width - 1), @intCast(dialog_height - 1), makeCell(self.border_style.bottom_right, self.border_fg, self.border_bg));

            // Horizontal lines
            if (dialog_width > 2) {
                var x: u16 = 1;
                while (x < dialog_width - 1) : (x += 1) {
                    dialog_view.setCell(@intCast(x), 0, makeCell(self.border_style.horizontal, self.border_fg, self.border_bg));
                    dialog_view.setCell(@intCast(x), @intCast(dialog_height - 1), makeCell(self.border_style.horizontal, self.border_fg, self.border_bg));
                }
            }

            // Vertical lines
            if (dialog_height > 2) {
                var y: u16 = 1;
                while (y < dialog_height - 1) : (y += 1) {
                    dialog_view.setCell(0, @intCast(y), makeCell(self.border_style.vertical, self.border_fg, self.border_bg));
                    dialog_view.setCell(@intCast(dialog_width - 1), @intCast(y), makeCell(self.border_style.vertical, self.border_fg, self.border_bg));
                }
            }

            // Draw title if present
            if (self.title) |title| {
                const title_width: u16 = @intCast(@min(unicode.stringWidth(title), std.math.maxInt(u16)));
                const available_width = dialog_width -| 4;

                if (title_width > 0 and available_width > 0) {
                    dialog_view.setCell(1, 0, makeCell(' ', self.border_fg, self.border_bg));
                    dialog_view.print(2, 0, title, self.border_fg, self.border_bg, .{});

                    const display_width = @min(title_width, available_width);
                    if (2 + display_width < dialog_width - 1) {
                        dialog_view.setCell(@intCast(2 + display_width), 0, makeCell(' ', self.border_fg, self.border_bg));
                    }
                }
            }
        }

        // Render child in content area
        if (dialog_width > 2 and dialog_height > 2) {
            var content_view = dialog_view.subView(.{
                .x = 1,
                .y = 1,
                .width = dialog_width - 2,
                .height = dialog_height - 2,
            });
            self.child.render(&content_view);
        }
    }

    /// Handle events - forward to child, but consume clicks on backdrop
    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *Modal = @ptrCast(@alignCast(ptr));

        if (!self.visible or self.widget_state.disabled) {
            return .ignored;
        }

        // Forward to child first
        const child_result = self.child.handleEvent(event);
        if (child_result == .consumed) {
            return .consumed;
        }

        // Consume mouse clicks on backdrop to prevent click-through
        switch (event) {
            .mouse => |_| {
                if (self.show_backdrop) {
                    return .consumed;
                }
            },
            else => {},
        }

        return .ignored;
    }

    fn makeCell(char: u21, fg: Cell.Color, bg: Cell.Color) Cell {
        return .{
            .char = char,
            .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
            .fg = fg,
            .bg = bg,
            .attrs = .{},
        };
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
    width: u16 = 5,
    height: u16 = 3,

    fn measure(ptr: *anyopaque, _: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *FillWidget = @ptrCast(@alignCast(ptr));
        return .{ .width = self.width, .height = self.height };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *FillWidget = @ptrCast(@alignCast(ptr));
        const size = view.size();
        var y: i32 = 0;
        while (y < size.height) : (y += 1) {
            var x: i32 = 0;
            while (x < size.width) : (x += 1) {
                view.setCell(x, y, Modal.makeCell(self.char, .default, .default));
            }
        }
    }

    pub const widget_vtable = Widget.VTable{
        .measureFn = measure,
        .renderFn = render,
    };
};

test "Modal init" {
    var fill = FillWidget{ .char = 'X' };
    const child = Widget.Widget.init(FillWidget, &fill);

    const modal = Modal.init(child);
    try std.testing.expect(modal.show_backdrop);
    try std.testing.expect(modal.visible);
}

test "Modal measure takes full space" {
    var fill = FillWidget{ .char = 'X' };
    const child = Widget.Widget.init(FillWidget, &fill);

    var modal = Modal.init(child);
    const widget = Widget.Widget.init(Modal, &modal);

    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));
    try std.testing.expectEqual(@as(u16, 80), measured.width);
    try std.testing.expectEqual(@as(u16, 24), measured.height);
}

test "Modal render with backdrop" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    var fill = FillWidget{ .char = 'X', .width = 6, .height = 2 };
    const child = Widget.Widget.init(FillWidget, &fill);

    var modal = Modal.init(child);
    const widget = Widget.Widget.init(Modal, &modal);

    var view = PlaneView.init(root);
    widget.render(&view);

    // Check backdrop is drawn in corners
    try std.testing.expectEqual(@as(u21, ' '), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, ' '), view.getCell(19, 9).?.char);

    // Check that dialog is centered (dialog size = 8x4, centered in 20x10)
    // Center x = (20 - 8) / 2 = 6
    // Center y = (10 - 4) / 2 = 3
    try std.testing.expectEqual(@as(u21, '╭'), view.getCell(6, 3).?.char);
    try std.testing.expectEqual(@as(u21, '╮'), view.getCell(13, 3).?.char);
}

test "Modal render without backdrop" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    // Fill with dots first
    var view = PlaneView.init(root);
    const dot_cell = Cell{
        .char = '.',
        .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };
    view.fill(dot_cell);

    var fill = FillWidget{ .char = 'X', .width = 4, .height = 2 };
    const child = Widget.Widget.init(FillWidget, &fill);

    var modal = Modal.init(child);
    _ = modal.withBackdrop(false);
    const widget = Widget.Widget.init(Modal, &modal);

    widget.render(&view);

    // Backdrop should NOT be drawn, so corners should still be dots
    try std.testing.expectEqual(@as(u21, '.'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, '.'), view.getCell(19, 9).?.char);
}

test "Modal render with title" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 30, .height = 10 });
    defer root.deinit();

    var fill = FillWidget{ .char = 'X', .width = 10, .height = 2 };
    const child = Widget.Widget.init(FillWidget, &fill);

    var modal = Modal.init(child);
    _ = modal.withTitle("Dialog");
    const widget = Widget.Widget.init(Modal, &modal);

    var view = PlaneView.init(root);
    widget.render(&view);

    // Dialog centered in 30x10 with size 12x4
    // Center x = (30 - 12) / 2 = 9
    // Center y = (10 - 4) / 2 = 3
    // Title at x=11 (9 + 2)
    try std.testing.expectEqual(@as(u21, 'D'), view.getCell(11, 3).?.char);
    try std.testing.expectEqual(@as(u21, 'i'), view.getCell(12, 3).?.char);
}

test "Modal not visible skips render" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    // Fill with dots
    var view = PlaneView.init(root);
    const dot_cell = Cell{
        .char = '.',
        .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };
    view.fill(dot_cell);

    var fill = FillWidget{ .char = 'X' };
    const child = Widget.Widget.init(FillWidget, &fill);

    var modal = Modal.init(child);
    _ = modal.withVisible(false);
    const widget = Widget.Widget.init(Modal, &modal);

    widget.render(&view);

    // Nothing should have changed
    try std.testing.expectEqual(@as(u21, '.'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, '.'), view.getCell(10, 5).?.char);
}

test "Modal builder pattern" {
    var fill = FillWidget{ .char = 'X' };
    const child = Widget.Widget.init(FillWidget, &fill);

    var modal = Modal.init(child);
    _ = modal.withBackdrop(false)
        .withBorderStyle(Layout.BoxStyle.double)
        .withTitle("Test")
        .withVisible(true);

    try std.testing.expect(!modal.show_backdrop);
    try std.testing.expectEqual(Layout.BoxStyle.double.top_left, modal.border_style.top_left);
    try std.testing.expectEqualStrings("Test", modal.title.?);
}
