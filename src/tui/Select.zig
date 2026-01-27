//! Select: Dropdown selection widget
//!
//! A widget for selecting a single value from a list of options.
//! Shows current selection with expandable options list.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const Event = @import("../Event.zig");

/// A single option in the select
pub const Option = struct {
    /// Display text
    text: []const u8,
    /// Option value
    value: u32 = 0,
    /// Whether selectable
    enabled: bool = true,
};

/// Select dropdown widget
pub const Select = struct {
    /// Available options
    options: []const Option,
    /// Currently selected index
    selected: usize = 0,
    /// Currently highlighted option (when expanded)
    highlighted: usize = 0,
    /// Whether the dropdown is expanded
    expanded: bool = false,
    /// Placeholder text when no selection
    placeholder: []const u8 = "Select...",
    /// Width of the dropdown
    width: u16 = 20,
    /// Max visible options when expanded
    max_visible: u16 = 5,
    /// Normal style
    style: Style = .{},
    /// Focused style
    focused_style: Style = .{ .attrs = .{ .bold = true } },
    /// Option highlight style
    highlight_style: Style = .{ .attrs = .{ .reverse = true } },
    /// Disabled option style
    disabled_style: Style = .{ .fg = .{ .index = 8 } },
    /// Widget state
    widget_state: Widget.WidgetState = .{},
    /// Selection callback
    on_change: ?*const fn (ctx: ?*anyopaque, index: usize, value: u32) void = null,
    /// Callback context
    callback_ctx: ?*anyopaque = null,

    /// Create a select with options
    pub fn init(options: []const Option) Select {
        return .{ .options = options };
    }

    // Builder methods

    /// Set selected index
    pub fn withSelected(self: *Select, index: usize) *Select {
        if (index < self.options.len) {
            self.selected = index;
            self.highlighted = index;
        }
        return self;
    }

    /// Set placeholder
    pub fn withPlaceholder(self: *Select, placeholder: []const u8) *Select {
        self.placeholder = placeholder;
        return self;
    }

    /// Set width
    pub fn withWidth(self: *Select, width: u16) *Select {
        self.width = width;
        return self;
    }

    /// Set max visible options
    pub fn withMaxVisible(self: *Select, max: u16) *Select {
        self.max_visible = max;
        return self;
    }

    /// Set selection callback
    pub fn withOnChange(self: *Select, callback: *const fn (ctx: ?*anyopaque, index: usize, value: u32) void, ctx: ?*anyopaque) *Select {
        self.on_change = callback;
        self.callback_ctx = ctx;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *Select, state: Widget.WidgetState) *Select {
        self.widget_state = state;
        return self;
    }

    // Methods

    /// Toggle expanded state
    pub fn toggle(self: *Select) void {
        self.expanded = !self.expanded;
        if (self.expanded) {
            self.highlighted = self.selected;
        }
    }

    /// Expand dropdown
    pub fn expand(self: *Select) void {
        self.expanded = true;
        self.highlighted = self.selected;
    }

    /// Collapse dropdown
    pub fn collapse(self: *Select) void {
        self.expanded = false;
    }

    /// Move highlight up
    pub fn highlightUp(self: *Select) void {
        if (self.options.len == 0) return;

        var new_idx = self.highlighted;
        while (new_idx > 0) {
            new_idx -= 1;
            if (self.options[new_idx].enabled) {
                self.highlighted = new_idx;
                return;
            }
        }
    }

    /// Move highlight down
    pub fn highlightDown(self: *Select) void {
        if (self.options.len == 0) return;

        var new_idx = self.highlighted;
        while (new_idx + 1 < self.options.len) {
            new_idx += 1;
            if (self.options[new_idx].enabled) {
                self.highlighted = new_idx;
                return;
            }
        }
    }

    /// Confirm selection
    pub fn confirmSelection(self: *Select) void {
        if (self.options.len == 0) return;
        if (!self.options[self.highlighted].enabled) return;

        self.selected = self.highlighted;
        self.expanded = false;

        if (self.on_change) |callback| {
            callback(self.callback_ctx, self.selected, self.options[self.selected].value);
        }
    }

    /// Get current selection text
    pub fn selectedText(self: *const Select) []const u8 {
        if (self.options.len == 0) return self.placeholder;
        return self.options[self.selected].text;
    }

    // Widget interface

    fn measure(ptr: *anyopaque, _: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Select = @ptrCast(@alignCast(ptr));

        const height: u16 = if (self.expanded)
            1 + @min(@as(u16, @intCast(self.options.len)), self.max_visible)
        else
            1;

        return .{
            .width = self.width,
            .height = height,
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Select = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0) return;

        const base_style = if (self.widget_state.focused) self.focused_style else self.style;

        // Draw the main select box
        const current_text = self.selectedText();
        const arrow: u21 = if (self.expanded) '▲' else '▼';

        // Fill background
        var x: i32 = 0;
        while (x < size.width) : (x += 1) {
            view.setCell(x, 0, .{
                .char = ' ',
                .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                .fg = base_style.fg,
                .bg = base_style.bg,
                .attrs = base_style.attrs,
            });
        }

        // Draw current selection text
        view.print(0, 0, current_text, base_style.fg, base_style.bg, base_style.attrs);

        // Draw arrow on right
        if (size.width > 0) {
            view.setCell(@intCast(size.width - 1), 0, .{
                .char = arrow,
                .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                .fg = base_style.fg,
                .bg = base_style.bg,
                .attrs = base_style.attrs,
            });
        }

        // Draw expanded options
        if (self.expanded and size.height > 1) {
            const visible_options = @min(self.options.len, size.height - 1);

            var y: u16 = 1;
            for (self.options[0..visible_options], 0..) |option, i| {
                const opt_style = if (!option.enabled)
                    self.disabled_style
                else if (i == self.highlighted)
                    self.highlight_style
                else
                    self.style;

                // Fill line
                x = 0;
                while (x < size.width) : (x += 1) {
                    view.setCell(x, @intCast(y), .{
                        .char = ' ',
                        .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                        .fg = opt_style.fg,
                        .bg = opt_style.bg,
                        .attrs = opt_style.attrs,
                    });
                }

                // Draw option text
                view.print(1, @intCast(y), option.text, opt_style.fg, opt_style.bg, opt_style.attrs);

                y += 1;
            }
        }
    }

    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *Select = @ptrCast(@alignCast(ptr));

        if (self.widget_state.disabled) {
            return .ignored;
        }

        switch (event) {
            .key => |key| {
                if (self.expanded) {
                    if (key.special == .up or key.codepoint == 'k') {
                        self.highlightUp();
                        return .consumed;
                    } else if (key.special == .down or key.codepoint == 'j') {
                        self.highlightDown();
                        return .consumed;
                    } else if (key.special == .enter or (key.codepoint == ' ' and key.mods.eql(Event.Modifiers.none))) {
                        self.confirmSelection();
                        return .consumed;
                    } else if (key.special == .escape) {
                        self.collapse();
                        return .consumed;
                    }
                } else {
                    if (key.special == .enter or (key.codepoint == ' ' and key.mods.eql(Event.Modifiers.none)) or key.special == .down) {
                        self.expand();
                        return .consumed;
                    }
                }
            },
            .mouse => |mouse| {
                if (mouse.button == .left) {
                    if (mouse.y == 0) {
                        self.toggle();
                    } else if (self.expanded) {
                        const opt_idx: usize = @intCast(mouse.y - 1);
                        if (opt_idx < self.options.len and self.options[opt_idx].enabled) {
                            self.highlighted = opt_idx;
                            self.confirmSelection();
                        }
                    }
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

test "Select init" {
    const options = [_]Option{
        .{ .text = "Option A", .value = 1 },
        .{ .text = "Option B", .value = 2 },
    };
    const select = Select.init(&options);
    try std.testing.expectEqual(@as(usize, 2), select.options.len);
    try std.testing.expectEqual(@as(usize, 0), select.selected);
    try std.testing.expect(!select.expanded);
}

test "Select toggle" {
    const options = [_]Option{.{ .text = "A" }};
    var select = Select.init(&options);

    try std.testing.expect(!select.expanded);
    select.toggle();
    try std.testing.expect(select.expanded);
    select.toggle();
    try std.testing.expect(!select.expanded);
}

test "Select navigation" {
    const options = [_]Option{
        .{ .text = "A" },
        .{ .text = "B" },
        .{ .text = "C" },
    };
    var select = Select.init(&options);
    select.expand();

    try std.testing.expectEqual(@as(usize, 0), select.highlighted);

    select.highlightDown();
    try std.testing.expectEqual(@as(usize, 1), select.highlighted);

    select.highlightDown();
    try std.testing.expectEqual(@as(usize, 2), select.highlighted);

    select.highlightUp();
    try std.testing.expectEqual(@as(usize, 1), select.highlighted);
}

test "Select confirm selection" {
    const options = [_]Option{
        .{ .text = "A", .value = 10 },
        .{ .text = "B", .value = 20 },
    };
    var select = Select.init(&options);
    select.expand();
    select.highlightDown();
    select.confirmSelection();

    try std.testing.expectEqual(@as(usize, 1), select.selected);
    try std.testing.expect(!select.expanded);
    try std.testing.expectEqualStrings("B", select.selectedText());
}

test "Select skips disabled options" {
    const options = [_]Option{
        .{ .text = "A", .enabled = true },
        .{ .text = "B", .enabled = false },
        .{ .text = "C", .enabled = true },
    };
    var select = Select.init(&options);
    select.expand();

    select.highlightDown();
    // Should skip B and go to C
    try std.testing.expectEqual(@as(usize, 2), select.highlighted);
}

test "Select measure collapsed" {
    const options = [_]Option{.{ .text = "A" }};
    var select = Select.init(&options);
    const widget = Widget.Widget.init(Select, &select);

    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));
    try std.testing.expectEqual(@as(u16, 20), measured.width); // default width
    try std.testing.expectEqual(@as(u16, 1), measured.height);
}

test "Select measure expanded" {
    const options = [_]Option{
        .{ .text = "A" },
        .{ .text = "B" },
        .{ .text = "C" },
    };
    var select = Select.init(&options);
    select.expand();
    const widget = Widget.Widget.init(Select, &select);

    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));
    try std.testing.expectEqual(@as(u16, 4), measured.height); // 1 header + 3 options
}

test "Select render" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 1 });
    defer root.deinit();

    const options = [_]Option{.{ .text = "Apple" }};
    var select = Select.init(&options);
    const widget = Widget.Widget.init(Select, &select);

    var view = PlaneView.init(root);
    widget.render(&view);

    // Current selection should be visible
    try std.testing.expectEqual(@as(u21, 'A'), view.getCell(0, 0).?.char);
    // Arrow should be on right
    try std.testing.expectEqual(@as(u21, '▼'), view.getCell(19, 0).?.char);
}

test "Select callback" {
    var selected_value: ?u32 = null;

    const callback = struct {
        fn cb(ctx: ?*anyopaque, _: usize, value: u32) void {
            const ptr: *?u32 = @ptrCast(@alignCast(ctx.?));
            ptr.* = value;
        }
    }.cb;

    const options = [_]Option{
        .{ .text = "A", .value = 42 },
    };
    var select = Select.init(&options);
    _ = select.withOnChange(callback, &selected_value);

    select.expand();
    select.confirmSelection();

    try std.testing.expectEqual(@as(u32, 42), selected_value.?);
}
