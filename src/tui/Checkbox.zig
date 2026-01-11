//! Checkbox: Boolean toggle widget
//!
//! A classic checkbox for boolean values with label support.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const Event = @import("../Event.zig");

/// Checkbox style variants
pub const CheckboxStyle = enum {
    /// [x] [ ] style
    bracket,
    /// ☑ ☐ style
    box,
    /// ✓ ✗ style (just the mark)
    mark,

    pub fn chars(self: CheckboxStyle) struct { checked: u21, unchecked: u21 } {
        return switch (self) {
            .bracket => .{ .checked = 'x', .unchecked = ' ' },
            .box => .{ .checked = '☑', .unchecked = '☐' },
            .mark => .{ .checked = '✓', .unchecked = '✗' },
        };
    }
};

/// Checkbox widget
pub const Checkbox = struct {
    /// Label text
    label: []const u8 = "",
    /// Checked state
    checked: bool = false,
    /// Visual style
    checkbox_style: CheckboxStyle = .bracket,
    /// Text style
    style: Style = .{},
    /// Checked indicator color
    checked_style: Style = .{ .fg = .{ .index = 2 } }, // Green
    /// Unchecked indicator color
    unchecked_style: Style = .{},
    /// Widget state
    widget_state: Widget.WidgetState = .{},
    /// Change callback
    on_change: ?*const fn (ctx: ?*anyopaque, checked: bool) void = null,
    /// Callback context
    callback_ctx: ?*anyopaque = null,

    /// Create a checkbox with label
    pub fn init(label: []const u8) Checkbox {
        return .{ .label = label };
    }

    /// Create a checkbox with initial checked state
    pub fn initChecked(label: []const u8, checked: bool) Checkbox {
        return .{ .label = label, .checked = checked };
    }

    // Builder methods

    /// Set checked state
    pub fn setChecked(self: *Checkbox, checked: bool) *Checkbox {
        self.checked = checked;
        return self;
    }

    /// Toggle checked state
    pub fn toggle(self: *Checkbox) *Checkbox {
        self.checked = !self.checked;
        if (self.on_change) |callback| {
            callback(self.callback_ctx, self.checked);
        }
        return self;
    }

    /// Set checkbox style
    pub fn withCheckboxStyle(self: *Checkbox, checkbox_style: CheckboxStyle) *Checkbox {
        self.checkbox_style = checkbox_style;
        return self;
    }

    /// Set text style
    pub fn withStyle(self: *Checkbox, style: Style) *Checkbox {
        self.style = style;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *Checkbox, state: Widget.WidgetState) *Checkbox {
        self.widget_state = state;
        return self;
    }

    /// Set change callback
    pub fn withOnChange(self: *Checkbox, callback: *const fn (ctx: ?*anyopaque, checked: bool) void, ctx: ?*anyopaque) *Checkbox {
        self.on_change = callback;
        self.callback_ctx = ctx;
        return self;
    }

    // Widget interface

    fn measure(ptr: *anyopaque, _: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Checkbox = @ptrCast(@alignCast(ptr));
        // [x] or ☑ (1-3 chars) + space + label
        const box_width: u16 = switch (self.checkbox_style) {
            .bracket => 3, // [x]
            .box, .mark => 1,
        };
        const label_len: u16 = @intCast(@min(self.label.len, std.math.maxInt(u16)));
        return .{
            .width = box_width + 1 + label_len,
            .height = 1,
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Checkbox = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0) return;

        const chars = self.checkbox_style.chars();
        const indicator_style = if (self.checked) self.checked_style else self.unchecked_style;

        var x: u16 = 0;

        switch (self.checkbox_style) {
            .bracket => {
                // Draw [ ]
                view.setCell(0, 0, Cell.simple('[', self.style.fg, self.style.bg));
                view.setCell(1, 0, Cell.simple(
                    if (self.checked) chars.checked else chars.unchecked,
                    indicator_style.fg,
                    indicator_style.bg,
                ));
                view.setCell(2, 0, Cell.simple(']', self.style.fg, self.style.bg));
                x = 3;
            },
            .box, .mark => {
                view.setCell(0, 0, Cell.simple(
                    if (self.checked) chars.checked else chars.unchecked,
                    indicator_style.fg,
                    indicator_style.bg,
                ));
                x = 1;
            },
        }

        // Draw space and label
        if (x < size.width and self.label.len > 0) {
            x += 1; // Space
            const text_style = if (self.widget_state.disabled)
                Style{ .fg = .{ .index = 8 } }
            else if (self.widget_state.focused)
                self.style.merge(.{ .attrs = .{ .bold = true } })
            else
                self.style;

            view.print(@intCast(x), 0, self.label, text_style.fg, text_style.bg, text_style.attrs);
        }
    }

    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *Checkbox = @ptrCast(@alignCast(ptr));

        if (self.widget_state.disabled) {
            return .ignored;
        }

        switch (event) {
            .key => |key| {
                // Space or Enter toggles
                if (key.special == .enter or (key.codepoint == ' ' and key.mods.eql(Event.Modifiers.none))) {
                    _ = self.toggle();
                    return .consumed;
                }
            },
            .mouse => |mouse| {
                if (mouse.button == .left and mouse.button_state == .released) {
                    _ = self.toggle();
                    return .consumed;
                }
            },
            else => {},
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

/// Radio button within a group
pub const RadioButton = struct {
    /// Label text
    label: []const u8 = "",
    /// Whether this option is selected
    selected: bool = false,
    /// Value identifier
    value: u32 = 0,
    /// Text style
    style: Style = .{},
    /// Selected indicator color
    selected_style: Style = .{ .fg = .{ .index = 6 } }, // Cyan
    /// Widget state
    widget_state: Widget.WidgetState = .{},
    /// Selection callback
    on_select: ?*const fn (ctx: ?*anyopaque, value: u32) void = null,
    /// Callback context
    callback_ctx: ?*anyopaque = null,

    /// Create a radio button
    pub fn init(label: []const u8, value: u32) RadioButton {
        return .{ .label = label, .value = value };
    }

    // Builder methods

    /// Set selected state
    pub fn setSelected(self: *RadioButton, selected: bool) *RadioButton {
        self.selected = selected;
        return self;
    }

    /// Set style
    pub fn withStyle(self: *RadioButton, style: Style) *RadioButton {
        self.style = style;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *RadioButton, state: Widget.WidgetState) *RadioButton {
        self.widget_state = state;
        return self;
    }

    /// Set selection callback
    pub fn withOnSelect(self: *RadioButton, callback: *const fn (ctx: ?*anyopaque, value: u32) void, ctx: ?*anyopaque) *RadioButton {
        self.on_select = callback;
        self.callback_ctx = ctx;
        return self;
    }

    /// Select this radio button (triggers callback)
    pub fn select(self: *RadioButton) void {
        self.selected = true;
        if (self.on_select) |callback| {
            callback(self.callback_ctx, self.value);
        }
    }

    // Widget interface

    fn measure(ptr: *anyopaque, _: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *RadioButton = @ptrCast(@alignCast(ptr));
        // (○) or (●) = 3 chars + space + label
        const label_len: u16 = @intCast(@min(self.label.len, std.math.maxInt(u16)));
        return .{
            .width = 3 + 1 + label_len,
            .height = 1,
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *RadioButton = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0) return;

        const indicator_style = if (self.selected) self.selected_style else self.style;

        // Draw ( ) or (●)
        view.setCell(0, 0, Cell.simple('(', self.style.fg, self.style.bg));
        view.setCell(1, 0, Cell.simple(
            if (self.selected) '●' else ' ',
            indicator_style.fg,
            indicator_style.bg,
        ));
        view.setCell(2, 0, Cell.simple(')', self.style.fg, self.style.bg));

        // Draw label
        if (self.label.len > 0 and size.width > 4) {
            const text_style = if (self.widget_state.disabled)
                Style{ .fg = .{ .index = 8 } }
            else if (self.widget_state.focused)
                self.style.merge(.{ .attrs = .{ .bold = true } })
            else
                self.style;

            view.print(4, 0, self.label, text_style.fg, text_style.bg, text_style.attrs);
        }
    }

    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *RadioButton = @ptrCast(@alignCast(ptr));

        if (self.widget_state.disabled) {
            return .ignored;
        }

        switch (event) {
            .key => |key| {
                if (key.special == .enter or (key.codepoint == ' ' and key.mods.eql(Event.Modifiers.none))) {
                    self.select();
                    return .consumed;
                }
            },
            .mouse => |mouse| {
                if (mouse.button == .left and mouse.button_state == .released) {
                    self.select();
                    return .consumed;
                }
            },
            else => {},
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

/// Switch (toggle) widget
pub const Switch = struct {
    /// Label text
    label: []const u8 = "",
    /// On/off state
    on: bool = false,
    /// Text style
    style: Style = .{},
    /// On state style
    on_style: Style = .{ .fg = .{ .index = 2 } }, // Green
    /// Off state style
    off_style: Style = .{ .fg = .{ .index = 8 } }, // Gray
    /// Widget state
    widget_state: Widget.WidgetState = .{},
    /// Change callback
    on_change: ?*const fn (ctx: ?*anyopaque, on: bool) void = null,
    /// Callback context
    callback_ctx: ?*anyopaque = null,

    /// Create a switch
    pub fn init(label: []const u8) Switch {
        return .{ .label = label };
    }

    /// Create a switch with initial state
    pub fn initWithState(label: []const u8, on: bool) Switch {
        return .{ .label = label, .on = on };
    }

    // Builder methods

    /// Set on/off state
    pub fn setOn(self: *Switch, on: bool) *Switch {
        self.on = on;
        return self;
    }

    /// Toggle on/off state
    pub fn toggle(self: *Switch) *Switch {
        self.on = !self.on;
        if (self.on_change) |callback| {
            callback(self.callback_ctx, self.on);
        }
        return self;
    }

    /// Set style
    pub fn withStyle(self: *Switch, style: Style) *Switch {
        self.style = style;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *Switch, state: Widget.WidgetState) *Switch {
        self.widget_state = state;
        return self;
    }

    /// Set change callback
    pub fn withOnChange(self: *Switch, callback: *const fn (ctx: ?*anyopaque, on: bool) void, ctx: ?*anyopaque) *Switch {
        self.on_change = callback;
        self.callback_ctx = ctx;
        return self;
    }

    // Widget interface

    fn measure(ptr: *anyopaque, _: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Switch = @ptrCast(@alignCast(ptr));
        // [●○○] or [○○●] = 5 chars + space + label
        const label_len: u16 = @intCast(@min(self.label.len, std.math.maxInt(u16)));
        return .{
            .width = 5 + 1 + label_len,
            .height = 1,
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Switch = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0) return;

        // Draw switch track: [●○○] (on) or [○○●] (off)
        const track_style = if (self.on) self.on_style else self.off_style;

        view.setCell(0, 0, Cell.simple('[', self.style.fg, self.style.bg));

        if (self.on) {
            view.setCell(1, 0, Cell.simple('●', track_style.fg, track_style.bg));
            view.setCell(2, 0, Cell.simple('─', track_style.fg, track_style.bg));
            view.setCell(3, 0, Cell.simple('○', self.off_style.fg, self.off_style.bg));
        } else {
            view.setCell(1, 0, Cell.simple('○', self.off_style.fg, self.off_style.bg));
            view.setCell(2, 0, Cell.simple('─', self.style.fg, self.style.bg));
            view.setCell(3, 0, Cell.simple('●', track_style.fg, track_style.bg));
        }

        view.setCell(4, 0, Cell.simple(']', self.style.fg, self.style.bg));

        // Draw label
        if (self.label.len > 0 and size.width > 6) {
            const text_style = if (self.widget_state.disabled)
                Style{ .fg = .{ .index = 8 } }
            else if (self.widget_state.focused)
                self.style.merge(.{ .attrs = .{ .bold = true } })
            else
                self.style;

            view.print(6, 0, self.label, text_style.fg, text_style.bg, text_style.attrs);
        }
    }

    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *Switch = @ptrCast(@alignCast(ptr));

        if (self.widget_state.disabled) {
            return .ignored;
        }

        switch (event) {
            .key => |key| {
                if (key.special == .enter or (key.codepoint == ' ' and key.mods.eql(Event.Modifiers.none))) {
                    _ = self.toggle();
                    return .consumed;
                }
            },
            .mouse => |mouse| {
                if (mouse.button == .left and mouse.button_state == .released) {
                    _ = self.toggle();
                    return .consumed;
                }
            },
            else => {},
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

test "Checkbox init" {
    const cb = Checkbox.init("Accept terms");
    try std.testing.expectEqualStrings("Accept terms", cb.label);
    try std.testing.expect(!cb.checked);
}

test "Checkbox toggle" {
    var cb = Checkbox.init("Test");
    try std.testing.expect(!cb.checked);

    _ = cb.toggle();
    try std.testing.expect(cb.checked);

    _ = cb.toggle();
    try std.testing.expect(!cb.checked);
}

test "Checkbox measure bracket style" {
    var cb = Checkbox.init("Test");
    const widget = Widget.Widget.init(Checkbox, &cb);

    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));
    // [x] + space + "Test" = 3 + 1 + 4 = 8
    try std.testing.expectEqual(@as(u16, 8), measured.width);
    try std.testing.expectEqual(@as(u16, 1), measured.height);
}

test "Checkbox render checked" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 1 });
    defer root.deinit();

    var cb = Checkbox.initChecked("Yes", true);
    const widget = Widget.Widget.init(Checkbox, &cb);

    var view = PlaneView.init(root);
    widget.render(&view);

    try std.testing.expectEqual(@as(u21, '['), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'x'), view.getCell(1, 0).?.char);
    try std.testing.expectEqual(@as(u21, ']'), view.getCell(2, 0).?.char);
}

test "Checkbox callback" {
    var new_value: ?bool = null;

    const callback = struct {
        fn cb(ctx: ?*anyopaque, checked: bool) void {
            const ptr: *?bool = @ptrCast(@alignCast(ctx.?));
            ptr.* = checked;
        }
    }.cb;

    var cb = Checkbox.init("Test");
    _ = cb.withOnChange(callback, &new_value);

    _ = cb.toggle();
    try std.testing.expect(new_value.?);
}

test "RadioButton init" {
    const rb = RadioButton.init("Option A", 1);
    try std.testing.expectEqualStrings("Option A", rb.label);
    try std.testing.expectEqual(@as(u32, 1), rb.value);
    try std.testing.expect(!rb.selected);
}

test "RadioButton select" {
    var selected_value: ?u32 = null;

    const callback = struct {
        fn cb(ctx: ?*anyopaque, value: u32) void {
            const ptr: *?u32 = @ptrCast(@alignCast(ctx.?));
            ptr.* = value;
        }
    }.cb;

    var rb = RadioButton.init("Option", 42);
    _ = rb.withOnSelect(callback, &selected_value);

    rb.select();
    try std.testing.expect(rb.selected);
    try std.testing.expectEqual(@as(u32, 42), selected_value.?);
}

test "RadioButton render" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 1 });
    defer root.deinit();

    var rb = RadioButton.init("Choice", 1);
    _ = rb.setSelected(true);
    const widget = Widget.Widget.init(RadioButton, &rb);

    var view = PlaneView.init(root);
    widget.render(&view);

    try std.testing.expectEqual(@as(u21, '('), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, '●'), view.getCell(1, 0).?.char);
    try std.testing.expectEqual(@as(u21, ')'), view.getCell(2, 0).?.char);
}

test "Switch init" {
    const sw = Switch.init("Dark mode");
    try std.testing.expectEqualStrings("Dark mode", sw.label);
    try std.testing.expect(!sw.on);
}

test "Switch toggle" {
    var sw = Switch.init("Test");
    try std.testing.expect(!sw.on);

    _ = sw.toggle();
    try std.testing.expect(sw.on);

    _ = sw.toggle();
    try std.testing.expect(!sw.on);
}

test "Switch measure" {
    var sw = Switch.init("Test");
    const widget = Widget.Widget.init(Switch, &sw);

    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));
    // [●○○] + space + "Test" = 5 + 1 + 4 = 10
    try std.testing.expectEqual(@as(u16, 10), measured.width);
    try std.testing.expectEqual(@as(u16, 1), measured.height);
}

test "Switch render on" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 1 });
    defer root.deinit();

    var sw = Switch.initWithState("Enabled", true);
    const widget = Widget.Widget.init(Switch, &sw);

    var view = PlaneView.init(root);
    widget.render(&view);

    try std.testing.expectEqual(@as(u21, '['), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, '●'), view.getCell(1, 0).?.char);
}
