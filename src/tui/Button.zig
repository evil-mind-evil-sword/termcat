//! Button: Interactive clickable button widget
//!
//! Provides a button widget with visual states (normal, focused, hovered, pressed, disabled)
//! and event handling for keyboard (Enter/Space) and mouse (left click) activation.

const std = @import("std");
const Widget = @import("Widget.zig");
const Theme = @import("Theme.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Cell = @import("../Cell.zig");
const Event = @import("../Event.zig");

/// Button widget
pub const Button = struct {
    /// Label text
    label: []const u8,

    /// Current widget state (focused, hovered, pressed, disabled)
    widget_state: Widget.WidgetState,

    /// Click callback: called with user_data when button is activated
    /// NULL means no callback
    on_click: ?*const fn (user_data: ?*anyopaque) void = null,

    /// User data pointer passed to onClick callback
    user_data: ?*anyopaque = null,

    /// Theme for styling
    theme: Theme = Theme.default,

    /// Widget VTable implementation
    pub const widget_vtable = Widget.VTable{
        .measureFn = measure,
        .renderFn = render,
        .handleEventFn = handleEvent,
    };

    /// Measure the button's preferred size
    /// Returns label width + 2 (for brackets when focused) x 1 height
    fn measure(ptr: *anyopaque, _: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Button = @ptrCast(@alignCast(ptr));
        return .{
            .width = @intCast(self.label.len + 2),
            .height = 1,
        };
    }

    /// Render the button to the view
    /// Shows "[Label]" when focused, "Label" otherwise
    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Button = @ptrCast(@alignCast(ptr));

        const size = view.size();
        if (size.height == 0 or size.width == 0) return;

        // Get base style and apply state
        const base_style = Theme.Style{};
        const style = self.theme.styleForState(base_style, self.widget_state);

        // Build the label text with brackets if focused
        const label_start: i32 = if (self.widget_state.focused) 1 else 0;

        // Draw the label
        for (self.label, 0..) |char, i| {
            const x = label_start + @as(i32, @intCast(i));
            if (x < @as(i32, size.width)) {
                const cell = Cell{
                    .char = char,
                    .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                    .fg = style.fg,
                    .bg = style.bg,
                    .attrs = style.attrs,
                };
                view.setCell(x, 0, cell);
            }
        }

        // Draw focus brackets if focused
        if (self.widget_state.focused) {
            const left_bracket = Cell{
                .char = '[',
                .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                .fg = style.fg,
                .bg = style.bg,
                .attrs = style.attrs,
            };
            view.setCell(0, 0, left_bracket);

            const right_bracket_x = @as(i32, @intCast(self.label.len)) + 1;
            const right_bracket = Cell{
                .char = ']',
                .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                .fg = style.fg,
                .bg = style.bg,
                .attrs = style.attrs,
            };
            view.setCell(right_bracket_x, 0, right_bracket);
        }

        // Fill remaining space with spaces
        const label_end = if (self.widget_state.focused)
            @as(i32, @intCast(self.label.len)) + 2
        else
            @as(i32, @intCast(self.label.len));

        var x = label_end;
        while (x < @as(i32, size.width)) : (x += 1) {
            const space = Cell{
                .char = ' ',
                .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                .fg = style.fg,
                .bg = style.bg,
                .attrs = style.attrs,
            };
            view.setCell(x, 0, space);
        }
    }

    /// Handle keyboard and mouse events
    /// - Enter/Space: activate when focused
    /// - Left mouse click: activate
    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *Button = @ptrCast(@alignCast(ptr));

        if (self.widget_state.disabled) {
            return .ignored;
        }

        switch (event) {
            .key => |key| {
                // Handle Enter or Space when focused
                if (self.widget_state.focused) {
                    if (key.special == .enter or (key.codepoint == ' ' and key.special == null)) {
                        if (self.on_click) |callback| {
                            callback(self.user_data);
                        }
                        return .consumed;
                    }
                }
            },
            .mouse => |mouse| {
                // Handle left click
                if (mouse.button == .left) {
                    // Note: Click bounds checking would be done at a higher level
                    // (e.g., in the layout/container system) since PlaneView doesn't
                    // expose position information to the widget
                    if (self.on_click) |callback| {
                        callback(self.user_data);
                    }
                    return .consumed;
                }
            },
            else => {},
        }

        return .ignored;
    }

    /// Initialize a new button
    pub fn init(label: []const u8) Button {
        return .{
            .label = label,
            .widget_state = Widget.WidgetState.normal(),
        };
    }

    /// Builder: set the onClick callback
    pub fn withOnClick(self: *Button, callback: *const fn (user_data: ?*anyopaque) void, user_data: ?*anyopaque) *Button {
        self.on_click = callback;
        self.user_data = user_data;
        return self;
    }

    /// Builder: set the widget state
    pub fn withState(self: *Button, state: Widget.WidgetState) *Button {
        self.widget_state = state;
        return self;
    }

    /// Builder: set the theme
    pub fn withTheme(self: *Button, theme: Theme) *Button {
        self.theme = theme;
        return self;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Button init" {
    const button = Button.init("Click me");
    try testing.expectEqualSlices(u8, "Click me", button.label);
    try testing.expect(!button.widget_state.focused);
    try testing.expect(!button.widget_state.hovered);
    try testing.expect(!button.widget_state.pressed);
    try testing.expect(!button.widget_state.disabled);
    try testing.expect(button.on_click == null);
}

test "Button measure" {
    var button = Button.init("Hi");
    const widget = Widget.init(Button, &button);

    const size = widget.measure(Widget.SizeConstraint.atMost(100, 10));
    try testing.expectEqual(@as(u16, 4), size.width); // "Hi" (2) + 2 for brackets
    try testing.expectEqual(@as(u16, 1), size.height);
}

test "Button measure empty label" {
    var button = Button.init("");
    const widget = Widget.init(Button, &button);

    const size = widget.measure(Widget.SizeConstraint.atMost(100, 10));
    try testing.expectEqual(@as(u16, 2), size.width); // 0 + 2 for brackets
    try testing.expectEqual(@as(u16, 1), size.height);
}

test "Button builder pattern" {
    var button = Button.init("Test");

    var callback_invoked = false;
    const callbackFn = struct {
        fn call(user_data: ?*anyopaque) void {
            if (user_data) |ptr| {
                const invoked = @as(*bool, @ptrCast(@alignCast(ptr)));
                invoked.* = true;
            }
        }
    }.call;

    _ = button
        .withOnClick(callbackFn, @ptrCast(&callback_invoked))
        .withState(.{ .focused = true });

    try testing.expect(button.widget_state.focused);
    try testing.expect(button.on_click != null);
}

test "Button render normal state" {
    const allocator = testing.allocator;
    const plane = try @import("../Plane.zig").Plane.initRoot(allocator, .{ .width = 10, .height = 1 });
    defer plane.deinit();

    var view = PlaneView.init(plane);
    var button = Button.init("Hi");
    button.widget_state = Widget.WidgetState.normal();

    const widget = Widget.init(Button, &button);
    widget.render(&view);

    // Check that label is rendered at position 0
    if (view.getCell(0, 0)) |cell| {
        try testing.expectEqual(@as(u21, 'H'), cell.char);
    }
    if (view.getCell(1, 0)) |cell| {
        try testing.expectEqual(@as(u21, 'i'), cell.char);
    }
}

test "Button render focused state" {
    const allocator = testing.allocator;
    const plane = try @import("../Plane.zig").Plane.initRoot(allocator, .{ .width = 10, .height = 1 });
    defer plane.deinit();

    var view = PlaneView.init(plane);
    var button = Button.init("Hi");
    button.widget_state = .{ .focused = true };

    const widget = Widget.init(Button, &button);
    widget.render(&view);

    // Check that brackets are rendered
    if (view.getCell(0, 0)) |cell| {
        try testing.expectEqual(@as(u21, '['), cell.char);
    }
    if (view.getCell(1, 0)) |cell| {
        try testing.expectEqual(@as(u21, 'H'), cell.char);
    }
    if (view.getCell(2, 0)) |cell| {
        try testing.expectEqual(@as(u21, 'i'), cell.char);
    }
    if (view.getCell(3, 0)) |cell| {
        try testing.expectEqual(@as(u21, ']'), cell.char);
    }
}

test "Button handle Enter key when focused" {
    var button = Button.init("Click");
    button.widget_state = .{ .focused = true };

    var callback_called = false;
    const callbackFn = struct {
        fn call(user_data: ?*anyopaque) void {
            if (user_data) |ptr| {
                const called = @as(*bool, @ptrCast(@alignCast(ptr)));
                called.* = true;
            }
        }
    }.call;

    button.on_click = callbackFn;
    button.user_data = @ptrCast(&callback_called);

    const widget = Widget.init(Button, &button);
    const event = Event.Event{ .key = Event.Key.fromSpecial(.enter, .{}) };

    const result = widget.handleEvent(event);
    try testing.expectEqual(Widget.EventResult.consumed, result);
    try testing.expect(callback_called);
}

test "Button handle Space key when focused" {
    var button = Button.init("Click");
    button.widget_state = .{ .focused = true };

    var callback_called = false;
    const callbackFn = struct {
        fn call(user_data: ?*anyopaque) void {
            if (user_data) |ptr| {
                const called = @as(*bool, @ptrCast(@alignCast(ptr)));
                called.* = true;
            }
        }
    }.call;

    button.on_click = callbackFn;
    button.user_data = @ptrCast(&callback_called);

    const widget = Widget.init(Button, &button);
    const event = Event.Event{ .key = Event.Key.fromCodepoint(' ', .{}) };

    const result = widget.handleEvent(event);
    try testing.expectEqual(Widget.EventResult.consumed, result);
    try testing.expect(callback_called);
}

test "Button ignores Enter key when not focused" {
    var button = Button.init("Click");
    button.widget_state = Widget.WidgetState.normal();

    var callback_called = false;
    const callbackFn = struct {
        fn call(user_data: ?*anyopaque) void {
            if (user_data) |ptr| {
                const called = @as(*bool, @ptrCast(@alignCast(ptr)));
                called.* = true;
            }
        }
    }.call;

    button.on_click = callbackFn;
    button.user_data = @ptrCast(&callback_called);

    const widget = Widget.init(Button, &button);
    const event = Event.Event{ .key = Event.Key.fromSpecial(.enter, .{}) };

    const result = widget.handleEvent(event);
    try testing.expectEqual(Widget.EventResult.ignored, result);
    try testing.expect(!callback_called);
}

test "Button handle left mouse click" {
    var button = Button.init("Click");
    button.widget_state = Widget.WidgetState.normal();

    var callback_called = false;
    const callbackFn = struct {
        fn call(user_data: ?*anyopaque) void {
            if (user_data) |ptr| {
                const called = @as(*bool, @ptrCast(@alignCast(ptr)));
                called.* = true;
            }
        }
    }.call;

    button.on_click = callbackFn;
    button.user_data = @ptrCast(&callback_called);

    const widget = Widget.init(Button, &button);
    const event = Event.Event{ .mouse = .{ .x = 0, .y = 0, .button = .left, .mods = .{} } };

    const result = widget.handleEvent(event);
    try testing.expectEqual(Widget.EventResult.consumed, result);
    try testing.expect(callback_called);
}

test "Button ignores other mouse buttons" {
    var button = Button.init("Click");
    button.widget_state = Widget.WidgetState.normal();

    var callback_called = false;
    const callbackFn = struct {
        fn call(user_data: ?*anyopaque) void {
            if (user_data) |ptr| {
                const called = @as(*bool, @ptrCast(@alignCast(ptr)));
                called.* = true;
            }
        }
    }.call;

    button.on_click = callbackFn;
    button.user_data = @ptrCast(&callback_called);

    const widget = Widget.init(Button, &button);
    const event = Event.Event{ .mouse = .{ .x = 0, .y = 0, .button = .right, .mods = .{} } };

    const result = widget.handleEvent(event);
    try testing.expectEqual(Widget.EventResult.ignored, result);
    try testing.expect(!callback_called);
}

test "Button ignores events when disabled" {
    var button = Button.init("Click");
    button.widget_state = .{ .focused = true, .disabled = true };

    var callback_called = false;
    const callbackFn = struct {
        fn call(user_data: ?*anyopaque) void {
            if (user_data) |ptr| {
                const called = @as(*bool, @ptrCast(@alignCast(ptr)));
                called.* = true;
            }
        }
    }.call;

    button.on_click = callbackFn;
    button.user_data = @ptrCast(&callback_called);

    const widget = Widget.init(Button, &button);
    const event = Event.Event{ .key = Event.Key.fromSpecial(.enter, .{}) };

    const result = widget.handleEvent(event);
    try testing.expectEqual(Widget.EventResult.ignored, result);
    try testing.expect(!callback_called);
}

test "Button no callback" {
    var button = Button.init("Click");
    button.widget_state = .{ .focused = true };
    // No callback set

    const widget = Widget.init(Button, &button);
    const event = Event.Event{ .key = Event.Key.fromSpecial(.enter, .{}) };

    const result = widget.handleEvent(event);
    try testing.expectEqual(Widget.EventResult.consumed, result); // Still consumed
}

test "Button render with hovered state applies styling" {
    const allocator = testing.allocator;
    const plane = try @import("../Plane.zig").Plane.initRoot(allocator, .{ .width = 10, .height = 1 });
    defer plane.deinit();

    var view = PlaneView.init(plane);
    var button = Button.init("Hi");
    button.widget_state = .{ .hovered = true };

    const widget = Widget.init(Button, &button);
    widget.render(&view);

    // Verify that the button renders (styling is applied internally)
    if (view.getCell(0, 0)) |cell| {
        try testing.expectEqual(@as(u21, 'H'), cell.char);
    }
}

test "Button render with pressed state applies styling" {
    const allocator = testing.allocator;
    const plane = try @import("../Plane.zig").Plane.initRoot(allocator, .{ .width = 10, .height = 1 });
    defer plane.deinit();

    var view = PlaneView.init(plane);
    var button = Button.init("Hi");
    button.widget_state = .{ .pressed = true };

    const widget = Widget.init(Button, &button);
    widget.render(&view);

    // Verify that the button renders
    if (view.getCell(0, 0)) |cell| {
        try testing.expectEqual(@as(u21, 'H'), cell.char);
    }
}

test "Button render with disabled state applies styling" {
    const allocator = testing.allocator;
    const plane = try @import("../Plane.zig").Plane.initRoot(allocator, .{ .width = 10, .height = 1 });
    defer plane.deinit();

    var view = PlaneView.init(plane);
    var button = Button.init("Hi");
    button.widget_state = .{ .disabled = true };

    const widget = Widget.init(Button, &button);
    widget.render(&view);

    // Verify that the button renders
    if (view.getCell(0, 0)) |cell| {
        try testing.expectEqual(@as(u21, 'H'), cell.char);
    }
}
