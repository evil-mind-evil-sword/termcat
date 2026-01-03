//! Loading: Loading indicator with message
//!
//! Combines a spinner with an optional message for showing operation status.
//! More complete than a bare spinner for showing loading state.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const ProgressBar = @import("ProgressBar.zig");

/// Loading indicator widget
pub const Loading = struct {
    /// Loading message
    message: []const u8 = "Loading...",
    /// Spinner style
    spinner_style: ProgressBar.Spinner.SpinnerStyle = .dots,
    /// Current spinner frame (for animation)
    frame: usize = 0,
    /// Text style
    style: Style = .{},
    /// Spinner style (colors)
    spinner_color: Style = .{ .fg = .{ .index = 6 } }, // Cyan
    /// Spacing between spinner and message
    spacing: u16 = 1,
    /// Whether spinner is on the left or right
    spinner_position: SpinnerPosition = .left,

    pub const SpinnerPosition = enum {
        left,
        right,
    };

    /// Create a loading indicator with default message
    pub fn init() Loading {
        return .{};
    }

    /// Create a loading indicator with a custom message
    pub fn withMessage(message: []const u8) Loading {
        return .{ .message = message };
    }

    // Builder methods

    /// Set the message
    pub fn setMessage(self: *Loading, message: []const u8) *Loading {
        self.message = message;
        return self;
    }

    /// Set the spinner style
    pub fn setSpinnerStyle(self: *Loading, spinner_style: ProgressBar.Spinner.SpinnerStyle) *Loading {
        self.spinner_style = spinner_style;
        return self;
    }

    /// Set the text style
    pub fn setStyle(self: *Loading, style: Style) *Loading {
        self.style = style;
        return self;
    }

    /// Set the spinner color
    pub fn setSpinnerColor(self: *Loading, style: Style) *Loading {
        self.spinner_color = style;
        return self;
    }

    /// Set spacing between spinner and message
    pub fn setSpacing(self: *Loading, spacing: u16) *Loading {
        self.spacing = spacing;
        return self;
    }

    /// Set spinner position
    pub fn setSpinnerPosition(self: *Loading, position: SpinnerPosition) *Loading {
        self.spinner_position = position;
        return self;
    }

    /// Advance the spinner animation
    pub fn tick(self: *Loading) void {
        const frames = self.spinner_style.frames();
        self.frame = (self.frame + 1) % frames.len;
    }

    /// Get current spinner character
    pub fn currentSpinnerChar(self: *const Loading) u21 {
        const frames = self.spinner_style.frames();
        return frames[self.frame % frames.len];
    }

    // Widget interface

    fn measure(ptr: *anyopaque, _: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Loading = @ptrCast(@alignCast(ptr));
        // Spinner (1 char) + spacing + message length
        const msg_len: u16 = @intCast(@min(self.message.len, std.math.maxInt(u16)));
        return .{
            .width = 1 + self.spacing + msg_len,
            .height = 1,
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Loading = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0) return;

        const spinner_char = self.currentSpinnerChar();
        const spinner_cell = Cell{
            .char = spinner_char,
            .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
            .fg = self.spinner_color.fg,
            .bg = self.spinner_color.bg,
            .attrs = self.spinner_color.attrs,
        };

        switch (self.spinner_position) {
            .left => {
                // Spinner on left
                view.setCell(0, 0, spinner_cell);
                // Message after spinner + spacing
                const msg_x: u16 = 1 + self.spacing;
                if (msg_x < size.width) {
                    view.print(@intCast(msg_x), 0, self.message, self.style.fg, self.style.bg, self.style.attrs);
                }
            },
            .right => {
                // Message on left
                view.print(0, 0, self.message, self.style.fg, self.style.bg, self.style.attrs);
                // Spinner after message + spacing
                const msg_len: u16 = @intCast(@min(self.message.len, size.width));
                const spinner_x = msg_len + self.spacing;
                if (spinner_x < size.width) {
                    view.setCell(@intCast(spinner_x), 0, spinner_cell);
                }
            },
        }
    }

    /// VTable for Widget interface
    pub const widget_vtable = Widget.VTable{
        .measureFn = measure,
        .renderFn = render,
    };
};

// ============================================================================
// Tests
// ============================================================================

const Plane = @import("../Plane.zig");

test "Loading init" {
    const loading = Loading.init();
    try std.testing.expectEqualStrings("Loading...", loading.message);
}

test "Loading with custom message" {
    const loading = Loading.withMessage("Please wait");
    try std.testing.expectEqualStrings("Please wait", loading.message);
}

test "Loading tick advances frame" {
    var loading = Loading.init();
    const initial_frame = loading.frame;

    loading.tick();
    try std.testing.expectEqual(initial_frame + 1, loading.frame);

    loading.tick();
    try std.testing.expectEqual(initial_frame + 2, loading.frame);
}

test "Loading measure" {
    var loading = Loading.withMessage("Test");
    const widget = Widget.Widget.init(Loading, &loading);

    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));
    // 1 (spinner) + 1 (spacing) + 4 (message) = 6
    try std.testing.expectEqual(@as(u16, 6), measured.width);
    try std.testing.expectEqual(@as(u16, 1), measured.height);
}

test "Loading render spinner left" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 1 });
    defer root.deinit();

    var loading = Loading.withMessage("Loading");
    const widget = Widget.Widget.init(Loading, &loading);

    var view = PlaneView.init(root);
    widget.render(&view);

    // First char should be spinner (dots style starts with ⠋)
    const spinner_char = loading.currentSpinnerChar();
    try std.testing.expectEqual(spinner_char, view.getCell(0, 0).?.char);

    // Message should start at position 2 (after spinner + 1 space)
    try std.testing.expectEqual(@as(u21, 'L'), view.getCell(2, 0).?.char);
}

test "Loading render spinner right" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 1 });
    defer root.deinit();

    var loading = Loading.withMessage("Wait");
    _ = loading.setSpinnerPosition(.right);
    const widget = Widget.Widget.init(Loading, &loading);

    var view = PlaneView.init(root);
    widget.render(&view);

    // Message should start at position 0
    try std.testing.expectEqual(@as(u21, 'W'), view.getCell(0, 0).?.char);

    // Spinner should be at position 5 (4 chars + 1 space)
    const spinner_char = loading.currentSpinnerChar();
    try std.testing.expectEqual(spinner_char, view.getCell(5, 0).?.char);
}

test "Loading builder pattern" {
    var loading = Loading.init();
    _ = loading
        .setMessage("Custom")
        .setSpinnerStyle(.line)
        .setSpacing(2)
        .setSpinnerPosition(.right);

    try std.testing.expectEqualStrings("Custom", loading.message);
    try std.testing.expectEqual(ProgressBar.Spinner.SpinnerStyle.line, loading.spinner_style);
    try std.testing.expectEqual(@as(u16, 2), loading.spacing);
    try std.testing.expectEqual(Loading.SpinnerPosition.right, loading.spinner_position);
}
