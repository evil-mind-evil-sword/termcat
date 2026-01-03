//! ScreenStack: Screen navigation and stack management
//!
//! A container widget that manages a stack of screens (views):
//! - Push screens onto the stack for navigation
//! - Pop screens to return to previous views
//! - Replace current screen for transitions
//! - Only the top screen receives events and renders
//! - Each screen maintains independent focus state

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const Event = @import("../Event.zig");

/// A screen in the navigation stack
pub const Screen = struct {
    /// The screen's root widget
    widget: Widget.Widget,
    /// Optional identifier for the screen
    name: ?[]const u8 = null,
    /// Whether this screen shows a backdrop over previous screens
    modal: bool = false,
    /// Backdrop style for modal screens
    backdrop_style: Style = .{ .bg = .{ .index = 0 } },
    /// Opacity level for backdrop (0-255, 255 = fully opaque)
    backdrop_opacity: u8 = 128,
};

/// Screen stack widget for navigation
pub const ScreenStack = struct {
    /// Stack of screens (bottom to top)
    screens: std.ArrayList(Screen),
    /// Memory allocator
    allocator: std.mem.Allocator,
    /// Whether the stack is visible
    visible: bool = true,
    /// Widget state
    widget_state: Widget.WidgetState = .{},
    /// Callback when screen stack changes
    on_change: ?*const fn (ctx: ?*anyopaque, depth: usize) void = null,
    /// Context for callback
    callback_ctx: ?*anyopaque = null,

    /// Create a new empty screen stack
    pub fn init(allocator: std.mem.Allocator) ScreenStack {
        return .{
            .screens = std.ArrayList(Screen).init(allocator),
            .allocator = allocator,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *ScreenStack) void {
        self.screens.deinit();
    }

    /// Push a widget as a new screen
    pub fn push(self: *ScreenStack, widget: Widget.Widget) !void {
        try self.pushScreen(.{ .widget = widget });
    }

    /// Push a widget as a modal screen (with backdrop)
    pub fn pushModal(self: *ScreenStack, widget: Widget.Widget) !void {
        try self.pushScreen(.{ .widget = widget, .modal = true });
    }

    /// Push a full screen configuration
    pub fn pushScreen(self: *ScreenStack, screen: Screen) !void {
        try self.screens.append(screen);
        if (self.on_change) |cb| {
            cb(self.callback_ctx, self.screens.items.len);
        }
    }

    /// Pop the top screen, returns the popped screen or null if empty
    pub fn pop(self: *ScreenStack) ?Screen {
        if (self.screens.items.len == 0) {
            return null;
        }
        const screen = self.screens.pop();
        if (self.on_change) |cb| {
            cb(self.callback_ctx, self.screens.items.len);
        }
        return screen;
    }

    /// Pop all screens down to and including one with the given name
    /// Returns the number of screens popped
    pub fn popTo(self: *ScreenStack, name: []const u8) usize {
        var popped: usize = 0;
        while (self.screens.items.len > 0) {
            const top = self.screens.items[self.screens.items.len - 1];
            _ = self.screens.pop();
            popped += 1;
            if (top.name) |n| {
                if (std.mem.eql(u8, n, name)) {
                    break;
                }
            }
        }
        if (popped > 0) {
            if (self.on_change) |cb| {
                cb(self.callback_ctx, self.screens.items.len);
            }
        }
        return popped;
    }

    /// Replace the top screen with a new one
    /// If stack is empty, just pushes the new screen
    pub fn replace(self: *ScreenStack, widget: Widget.Widget) !void {
        try self.replaceScreen(.{ .widget = widget });
    }

    /// Replace top screen with full configuration
    pub fn replaceScreen(self: *ScreenStack, screen: Screen) !void {
        if (self.screens.items.len > 0) {
            _ = self.screens.pop();
        }
        try self.screens.append(screen);
        if (self.on_change) |cb| {
            cb(self.callback_ctx, self.screens.items.len);
        }
    }

    /// Get the current (top) screen
    pub fn current(self: *const ScreenStack) ?*const Screen {
        if (self.screens.items.len == 0) {
            return null;
        }
        return &self.screens.items[self.screens.items.len - 1];
    }

    /// Get mutable reference to current screen
    pub fn currentMut(self: *ScreenStack) ?*Screen {
        if (self.screens.items.len == 0) {
            return null;
        }
        return &self.screens.items[self.screens.items.len - 1];
    }

    /// Get stack depth
    pub fn depth(self: *const ScreenStack) usize {
        return self.screens.items.len;
    }

    /// Check if stack is empty
    pub fn isEmpty(self: *const ScreenStack) bool {
        return self.screens.items.len == 0;
    }

    /// Clear all screens
    pub fn clear(self: *ScreenStack) void {
        self.screens.clearRetainingCapacity();
        if (self.on_change) |cb| {
            cb(self.callback_ctx, 0);
        }
    }

    // Builder methods

    /// Set visibility
    pub fn withVisible(self: *ScreenStack, visible: bool) *ScreenStack {
        self.visible = visible;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *ScreenStack, state: Widget.WidgetState) *ScreenStack {
        self.widget_state = state;
        return self;
    }

    /// Set change callback
    pub fn withOnChange(self: *ScreenStack, callback: *const fn (ctx: ?*anyopaque, depth: usize) void, ctx: ?*anyopaque) *ScreenStack {
        self.on_change = callback;
        self.callback_ctx = ctx;
        return self;
    }

    // Widget interface implementation

    /// Measure - returns size of top screen, or zero if empty
    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *ScreenStack = @ptrCast(@alignCast(ptr));
        if (self.screens.items.len == 0) {
            return .{ .width = 0, .height = 0 };
        }
        // Top screen determines size
        const top = &self.screens.items[self.screens.items.len - 1];
        return top.widget.measure(constraint);
    }

    /// Render the screen stack
    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *ScreenStack = @ptrCast(@alignCast(ptr));

        if (!self.visible or self.screens.items.len == 0) {
            return;
        }

        const view_size = view.size();
        if (view_size.width == 0 or view_size.height == 0) return;

        // Find the first non-modal screen from the top, or render from bottom
        // For simplicity, we render bottom-up but only visible portions
        var start_idx: usize = 0;

        // Find the lowest modal screen to start rendering from
        // (screens below a non-modal screen don't need rendering)
        var i = self.screens.items.len;
        while (i > 0) {
            i -= 1;
            if (!self.screens.items[i].modal) {
                start_idx = i;
                break;
            }
        }

        // Render from start_idx to top
        for (self.screens.items[start_idx..]) |*screen| {
            // Draw backdrop for modal screens
            if (screen.modal and start_idx > 0) {
                const backdrop_cell = Cell{
                    .char = ' ',
                    .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                    .fg = screen.backdrop_style.fg,
                    .bg = screen.backdrop_style.bg,
                    .attrs = screen.backdrop_style.attrs,
                };

                var y: i32 = 0;
                while (y < view_size.height) : (y += 1) {
                    var x: i32 = 0;
                    while (x < view_size.width) : (x += 1) {
                        view.setCell(x, y, backdrop_cell);
                    }
                }
            }

            // Render the screen
            screen.widget.render(view);
        }
    }

    /// Handle events - forward to top screen only
    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *ScreenStack = @ptrCast(@alignCast(ptr));

        if (!self.visible or self.widget_state.disabled or self.screens.items.len == 0) {
            return .ignored;
        }

        // Only top screen receives events
        const top = &self.screens.items[self.screens.items.len - 1];
        const result = top.widget.handleEvent(event);

        // Modal screens consume all mouse events (prevent click-through)
        if (result == .ignored and top.modal) {
            switch (event) {
                .mouse => return .consumed,
                else => {},
            }
        }

        return result;
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

// Test widget that fills with a character
const FillWidget = struct {
    char: u21,
    width: u16 = 10,
    height: u16 = 5,

    fn measure(ptr: *anyopaque, _: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *FillWidget = @ptrCast(@alignCast(ptr));
        return .{ .width = self.width, .height = self.height };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *FillWidget = @ptrCast(@alignCast(ptr));
        const size = view.size();
        const cell = Cell{
            .char = self.char,
            .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
            .fg = .default,
            .bg = .default,
            .attrs = .{},
        };
        var y: i32 = 0;
        while (y < size.height) : (y += 1) {
            var x: i32 = 0;
            while (x < size.width) : (x += 1) {
                view.setCell(x, y, cell);
            }
        }
    }

    pub const widget_vtable = Widget.VTable{
        .measureFn = measure,
        .renderFn = render,
    };
};

test "ScreenStack init and deinit" {
    var stack = ScreenStack.init(std.testing.allocator);
    defer stack.deinit();

    try std.testing.expect(stack.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), stack.depth());
    try std.testing.expect(stack.current() == null);
}

test "ScreenStack push and pop" {
    var stack = ScreenStack.init(std.testing.allocator);
    defer stack.deinit();

    var fill1 = FillWidget{ .char = 'A' };
    var fill2 = FillWidget{ .char = 'B' };

    try stack.push(Widget.Widget.init(FillWidget, &fill1));
    try std.testing.expectEqual(@as(usize, 1), stack.depth());

    try stack.push(Widget.Widget.init(FillWidget, &fill2));
    try std.testing.expectEqual(@as(usize, 2), stack.depth());

    const popped = stack.pop();
    try std.testing.expect(popped != null);
    try std.testing.expectEqual(@as(usize, 1), stack.depth());

    _ = stack.pop();
    try std.testing.expect(stack.isEmpty());

    // Pop from empty stack returns null
    try std.testing.expect(stack.pop() == null);
}

test "ScreenStack replace" {
    var stack = ScreenStack.init(std.testing.allocator);
    defer stack.deinit();

    var fill1 = FillWidget{ .char = 'A' };
    var fill2 = FillWidget{ .char = 'B' };

    try stack.push(Widget.Widget.init(FillWidget, &fill1));
    try std.testing.expectEqual(@as(usize, 1), stack.depth());

    try stack.replace(Widget.Widget.init(FillWidget, &fill2));
    try std.testing.expectEqual(@as(usize, 1), stack.depth());
}

test "ScreenStack measure returns top screen size" {
    var stack = ScreenStack.init(std.testing.allocator);
    defer stack.deinit();

    var fill1 = FillWidget{ .char = 'A', .width = 10, .height = 5 };
    var fill2 = FillWidget{ .char = 'B', .width = 20, .height = 8 };

    try stack.push(Widget.Widget.init(FillWidget, &fill1));
    try stack.push(Widget.Widget.init(FillWidget, &fill2));

    const widget = Widget.Widget.init(ScreenStack, &stack);
    const measured = widget.measure(Widget.SizeConstraint.atMost(100, 100));

    // Should return top screen's size
    try std.testing.expectEqual(@as(u16, 20), measured.width);
    try std.testing.expectEqual(@as(u16, 8), measured.height);
}

test "ScreenStack render shows top screen" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    var stack = ScreenStack.init(allocator);
    defer stack.deinit();

    var fill1 = FillWidget{ .char = 'A', .width = 20, .height = 10 };
    var fill2 = FillWidget{ .char = 'B', .width = 20, .height = 10 };

    try stack.push(Widget.Widget.init(FillWidget, &fill1));
    try stack.push(Widget.Widget.init(FillWidget, &fill2));

    const widget = Widget.Widget.init(ScreenStack, &stack);
    var view = PlaneView.init(root);
    widget.render(&view);

    // Should show 'B' (top screen), not 'A'
    try std.testing.expectEqual(@as(u21, 'B'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'B'), view.getCell(10, 5).?.char);
}

test "ScreenStack modal screen with backdrop" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    var stack = ScreenStack.init(allocator);
    defer stack.deinit();

    var fill1 = FillWidget{ .char = 'A', .width = 20, .height = 10 };
    var fill2 = FillWidget{ .char = 'B', .width = 5, .height = 3 };

    try stack.push(Widget.Widget.init(FillWidget, &fill1));
    try stack.pushModal(Widget.Widget.init(FillWidget, &fill2));

    const widget = Widget.Widget.init(ScreenStack, &stack);
    var view = PlaneView.init(root);
    widget.render(&view);

    // Modal screen renders over backdrop
    // The fill2 widget will fill its render area with 'B'
    try std.testing.expectEqual(@as(u21, 'B'), view.getCell(0, 0).?.char);
}

test "ScreenStack empty renders nothing" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    var stack = ScreenStack.init(allocator);
    defer stack.deinit();

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

    const widget = Widget.Widget.init(ScreenStack, &stack);
    widget.render(&view);

    // Should still be dots (nothing rendered)
    try std.testing.expectEqual(@as(u21, '.'), view.getCell(0, 0).?.char);
}

test "ScreenStack named screens with popTo" {
    var stack = ScreenStack.init(std.testing.allocator);
    defer stack.deinit();

    var fill1 = FillWidget{ .char = 'A' };
    var fill2 = FillWidget{ .char = 'B' };
    var fill3 = FillWidget{ .char = 'C' };

    try stack.pushScreen(.{ .widget = Widget.Widget.init(FillWidget, &fill1), .name = "home" });
    try stack.pushScreen(.{ .widget = Widget.Widget.init(FillWidget, &fill2), .name = "settings" });
    try stack.pushScreen(.{ .widget = Widget.Widget.init(FillWidget, &fill3), .name = "detail" });

    try std.testing.expectEqual(@as(usize, 3), stack.depth());

    // Pop to "settings" (should pop "detail" and "settings")
    const popped = stack.popTo("settings");
    try std.testing.expectEqual(@as(usize, 2), popped);
    try std.testing.expectEqual(@as(usize, 1), stack.depth());
}

test "ScreenStack on_change callback" {
    var callback_depth: usize = 999;

    const callback = struct {
        fn cb(ctx: ?*anyopaque, d: usize) void {
            const ptr: *usize = @ptrCast(@alignCast(ctx.?));
            ptr.* = d;
        }
    }.cb;

    var stack = ScreenStack.init(std.testing.allocator);
    defer stack.deinit();
    _ = stack.withOnChange(callback, &callback_depth);

    var fill1 = FillWidget{ .char = 'A' };

    try stack.push(Widget.Widget.init(FillWidget, &fill1));
    try std.testing.expectEqual(@as(usize, 1), callback_depth);

    _ = stack.pop();
    try std.testing.expectEqual(@as(usize, 0), callback_depth);
}

test "ScreenStack clear" {
    var stack = ScreenStack.init(std.testing.allocator);
    defer stack.deinit();

    var fill1 = FillWidget{ .char = 'A' };
    var fill2 = FillWidget{ .char = 'B' };

    try stack.push(Widget.Widget.init(FillWidget, &fill1));
    try stack.push(Widget.Widget.init(FillWidget, &fill2));
    try std.testing.expectEqual(@as(usize, 2), stack.depth());

    stack.clear();
    try std.testing.expect(stack.isEmpty());
}

test "ScreenStack not visible skips render" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 10 });
    defer root.deinit();

    var stack = ScreenStack.init(allocator);
    defer stack.deinit();
    _ = stack.withVisible(false);

    var fill1 = FillWidget{ .char = 'X', .width = 20, .height = 10 };
    try stack.push(Widget.Widget.init(FillWidget, &fill1));

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

    const widget = Widget.Widget.init(ScreenStack, &stack);
    widget.render(&view);

    // Should still be dots (not visible)
    try std.testing.expectEqual(@as(u21, '.'), view.getCell(0, 0).?.char);
}
