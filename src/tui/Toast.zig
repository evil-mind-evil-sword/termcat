//! Toast: Non-intrusive notification widget
//!
//! Displays brief notifications that auto-dismiss after a timeout.
//! Supports multiple severity levels and stacking.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const Event = @import("../Event.zig");
const Layout = @import("../Layout.zig");

/// Toast severity level
pub const ToastLevel = enum {
    info,
    success,
    warning,
    err,

    pub fn style(self: ToastLevel) Style {
        return switch (self) {
            .info => .{ .fg = .{ .index = 7 }, .bg = .{ .index = 4 } }, // White on blue
            .success => .{ .fg = .{ .index = 0 }, .bg = .{ .index = 2 } }, // Black on green
            .warning => .{ .fg = .{ .index = 0 }, .bg = .{ .index = 3 } }, // Black on yellow
            .err => .{ .fg = .{ .index = 15 }, .bg = .{ .index = 1 } }, // White on red
        };
    }

    pub fn icon(self: ToastLevel) u21 {
        return switch (self) {
            .info => 'ℹ',
            .success => '✓',
            .warning => '⚠',
            .err => '✗',
        };
    }
};

/// A single toast message
pub const ToastMessage = struct {
    text: []const u8,
    level: ToastLevel = .info,
    /// Remaining display time in ticks (0 = dismiss)
    remaining_ticks: u32 = 50, // ~5 seconds at 10 ticks/sec
    /// Whether text is owned
    owned: bool = false,
};

/// Toast container widget
pub const Toast = struct {
    /// Active toasts (most recent at end)
    toasts: std.ArrayList(ToastMessage),
    /// Memory allocator
    allocator: std.mem.Allocator,
    /// Max visible toasts
    max_visible: usize = 5,
    /// Toast width
    width: u16 = 40,
    /// Position
    position: Position = .top_right,
    /// Show icons
    show_icons: bool = true,
    /// Border style
    border_style: Layout.BoxStyle = Layout.BoxStyle.rounded,
    /// Widget state
    widget_state: Widget.WidgetState = .{},

    pub const Position = enum {
        top_left,
        top_right,
        bottom_left,
        bottom_right,
    };

    /// Create a toast container
    pub fn init(allocator: std.mem.Allocator) Toast {
        return .{
            .toasts = std.ArrayList(ToastMessage).init(allocator),
            .allocator = allocator,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Toast) void {
        for (self.toasts.items) |toast| {
            if (toast.owned) {
                self.allocator.free(toast.text);
            }
        }
        self.toasts.deinit();
    }

    // Builder methods

    /// Set max visible toasts
    pub fn withMaxVisible(self: *Toast, max: usize) *Toast {
        self.max_visible = max;
        return self;
    }

    /// Set width
    pub fn withWidth(self: *Toast, width: u16) *Toast {
        self.width = width;
        return self;
    }

    /// Set position
    pub fn withPosition(self: *Toast, position: Position) *Toast {
        self.position = position;
        return self;
    }

    /// Set show icons
    pub fn withShowIcons(self: *Toast, show_icons: bool) *Toast {
        self.show_icons = show_icons;
        return self;
    }

    // Methods

    /// Show a toast message (copies text)
    pub fn show(self: *Toast, text: []const u8, level: ToastLevel) !void {
        const owned_text = try self.allocator.dupe(u8, text);
        try self.toasts.append(.{
            .text = owned_text,
            .level = level,
            .owned = true,
        });
        self.pruneOldest();
    }

    /// Show info toast
    pub fn info(self: *Toast, text: []const u8) !void {
        try self.show(text, .info);
    }

    /// Show success toast
    pub fn success(self: *Toast, text: []const u8) !void {
        try self.show(text, .success);
    }

    /// Show warning toast
    pub fn warning(self: *Toast, text: []const u8) !void {
        try self.show(text, .warning);
    }

    /// Show error toast
    pub fn err(self: *Toast, text: []const u8) !void {
        try self.show(text, .err);
    }

    /// Advance time (call each tick/frame)
    pub fn tick(self: *Toast) void {
        var i: usize = 0;
        while (i < self.toasts.items.len) {
            if (self.toasts.items[i].remaining_ticks > 0) {
                self.toasts.items[i].remaining_ticks -= 1;
                i += 1;
            } else {
                // Remove expired toast
                const removed = self.toasts.orderedRemove(i);
                if (removed.owned) {
                    self.allocator.free(removed.text);
                }
            }
        }
    }

    /// Dismiss all toasts
    pub fn dismissAll(self: *Toast) void {
        for (self.toasts.items) |toast| {
            if (toast.owned) {
                self.allocator.free(toast.text);
            }
        }
        self.toasts.clearRetainingCapacity();
    }

    /// Get visible toast count
    pub fn count(self: *const Toast) usize {
        return @min(self.toasts.items.len, self.max_visible);
    }

    fn pruneOldest(self: *Toast) void {
        while (self.toasts.items.len > self.max_visible) {
            const removed = self.toasts.orderedRemove(0);
            if (removed.owned) {
                self.allocator.free(removed.text);
            }
        }
    }

    // Widget interface

    fn measure(ptr: *anyopaque, _: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Toast = @ptrCast(@alignCast(ptr));
        const visible = self.count();
        if (visible == 0) return .{ .width = 0, .height = 0 };

        // Each toast is 3 lines (border + content + border)
        return .{
            .width = self.width,
            .height = @intCast(visible * 3),
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Toast = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0) return;

        const visible = self.count();
        if (visible == 0) return;

        // Render from most recent (bottom of visual stack)
        const start_idx = if (self.toasts.items.len > self.max_visible)
            self.toasts.items.len - self.max_visible
        else
            0;

        var y: u16 = 0;
        for (self.toasts.items[start_idx..]) |toast| {
            if (y + 3 > size.height) break;

            const style = toast.level.style();
            const box = self.border_style;

            // Draw box
            // Top border
            view.setCell(0, @intCast(y), Cell.simple(box.top_left, style.fg, style.bg));
            var x: u16 = 1;
            while (x < self.width - 1 and x < size.width - 1) : (x += 1) {
                view.setCell(@intCast(x), @intCast(y), Cell.simple(box.horizontal, style.fg, style.bg));
            }
            if (self.width - 1 < size.width) {
                view.setCell(@intCast(self.width - 1), @intCast(y), Cell.simple(box.top_right, style.fg, style.bg));
            }

            // Content line
            y += 1;
            view.setCell(0, @intCast(y), Cell.simple(box.vertical, style.fg, style.bg));

            // Fill content background
            x = 1;
            while (x < self.width - 1 and x < size.width - 1) : (x += 1) {
                view.setCell(@intCast(x), @intCast(y), Cell.simple(' ', style.fg, style.bg));
            }

            // Draw icon and text
            var text_x: u16 = 2;
            if (self.show_icons) {
                view.setCell(2, @intCast(y), Cell.simple(toast.level.icon(), style.fg, style.bg));
                text_x = 4;
            }

            const available = self.width -| text_x -| 2;
            const display_len = @min(toast.text.len, available);
            if (display_len > 0) {
                view.print(@intCast(text_x), @intCast(y), toast.text[0..display_len], style.fg, style.bg, style.attrs);
            }

            if (self.width - 1 < size.width) {
                view.setCell(@intCast(self.width - 1), @intCast(y), Cell.simple(box.vertical, style.fg, style.bg));
            }

            // Bottom border
            y += 1;
            view.setCell(0, @intCast(y), Cell.simple(box.bottom_left, style.fg, style.bg));
            x = 1;
            while (x < self.width - 1 and x < size.width - 1) : (x += 1) {
                view.setCell(@intCast(x), @intCast(y), Cell.simple(box.horizontal, style.fg, style.bg));
            }
            if (self.width - 1 < size.width) {
                view.setCell(@intCast(self.width - 1), @intCast(y), Cell.simple(box.bottom_right, style.fg, style.bg));
            }

            y += 1;
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

test "Toast init" {
    var toast = Toast.init(std.testing.allocator);
    defer toast.deinit();

    try std.testing.expectEqual(@as(usize, 0), toast.count());
}

test "Toast show" {
    var toast = Toast.init(std.testing.allocator);
    defer toast.deinit();

    try toast.info("Hello");
    try std.testing.expectEqual(@as(usize, 1), toast.count());

    try toast.success("World");
    try std.testing.expectEqual(@as(usize, 2), toast.count());
}

test "Toast tick expires" {
    var toast = Toast.init(std.testing.allocator);
    defer toast.deinit();

    // Add toast with 2 ticks remaining
    try toast.toasts.append(.{ .text = "Test", .level = .info, .remaining_ticks = 2, .owned = false });

    try std.testing.expectEqual(@as(usize, 1), toast.count());

    toast.tick();
    try std.testing.expectEqual(@as(usize, 1), toast.count());

    toast.tick();
    try std.testing.expectEqual(@as(usize, 1), toast.count());

    toast.tick(); // Should expire
    try std.testing.expectEqual(@as(usize, 0), toast.count());
}

test "Toast max visible" {
    var toast = Toast.init(std.testing.allocator);
    defer toast.deinit();
    _ = toast.withMaxVisible(2);

    try toast.info("1");
    try toast.info("2");
    try toast.info("3");

    try std.testing.expectEqual(@as(usize, 2), toast.count());
}

test "Toast dismissAll" {
    var toast = Toast.init(std.testing.allocator);
    defer toast.deinit();

    try toast.info("1");
    try toast.info("2");
    try std.testing.expectEqual(@as(usize, 2), toast.count());

    toast.dismissAll();
    try std.testing.expectEqual(@as(usize, 0), toast.count());
}

test "Toast measure empty" {
    var toast = Toast.init(std.testing.allocator);
    defer toast.deinit();

    const widget = Widget.Widget.init(Toast, &toast);
    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));

    try std.testing.expectEqual(@as(u16, 0), measured.width);
    try std.testing.expectEqual(@as(u16, 0), measured.height);
}

test "Toast measure with content" {
    var toast = Toast.init(std.testing.allocator);
    defer toast.deinit();

    try toast.info("Test");

    const widget = Widget.Widget.init(Toast, &toast);
    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));

    try std.testing.expectEqual(@as(u16, 40), measured.width);
    try std.testing.expectEqual(@as(u16, 3), measured.height);
}

test "ToastLevel styles" {
    try std.testing.expectEqual(Cell.Color{ .index = 4 }, ToastLevel.info.style().bg);
    try std.testing.expectEqual(Cell.Color{ .index = 2 }, ToastLevel.success.style().bg);
    try std.testing.expectEqual(Cell.Color{ .index = 3 }, ToastLevel.warning.style().bg);
    try std.testing.expectEqual(Cell.Color{ .index = 1 }, ToastLevel.err.style().bg);
}
