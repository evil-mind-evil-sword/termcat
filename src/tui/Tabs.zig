//! Tabs: Tabbed content switching widget
//!
//! A container widget that displays a row of tabs and shows the content
//! of the currently selected tab. Supports keyboard navigation (left/right arrows)
//! and mouse clicks on tabs.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Theme = @import("Theme.zig").Theme;
const Style = @import("Theme.zig").Style;
const Event = @import("../Event.zig");
const unicode = @import("../unicode/width.zig");

/// Tab definition
pub const Tab = struct {
    /// Tab label
    label: []const u8,
    /// Tab content widget
    content: Widget.Widget,
};

/// Tabs widget
pub const Tabs = struct {
    /// Array of tabs
    tabs: []const Tab,
    /// Currently selected tab index
    selected: usize = 0,
    /// Tab bar style (active tab)
    active_style: Style = .{ .attrs = .{ .bold = true, .reverse = true } },
    /// Tab bar style (inactive tab)
    inactive_style: Style = .{},
    /// Separator between tabs
    separator: []const u8 = " | ",
    /// Widget state
    widget_state: Widget.WidgetState = .{},
    /// Callback context
    callback_ctx: ?*anyopaque = null,
    /// Called when tab changes (ctx, new_index)
    on_change: ?*const fn (ctx: ?*anyopaque, index: usize) void = null,

    /// Create tabs with a list of tab definitions
    pub fn init(tabs: []const Tab) Tabs {
        return .{ .tabs = tabs };
    }

    /// Set selected tab index
    pub fn withSelected(self: *Tabs, index: usize) *Tabs {
        if (self.tabs.len > 0) {
            self.selected = @min(index, self.tabs.len - 1);
        }
        return self;
    }

    /// Set active tab style
    pub fn withActiveStyle(self: *Tabs, style: Style) *Tabs {
        self.active_style = style;
        return self;
    }

    /// Set inactive tab style
    pub fn withInactiveStyle(self: *Tabs, style: Style) *Tabs {
        self.inactive_style = style;
        return self;
    }

    /// Set separator between tabs
    pub fn withSeparator(self: *Tabs, sep: []const u8) *Tabs {
        self.separator = sep;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *Tabs, state: Widget.WidgetState) *Tabs {
        self.widget_state = state;
        return self;
    }

    /// Set change callback
    pub fn withOnChange(self: *Tabs, callback: *const fn (ctx: ?*anyopaque, index: usize) void, ctx: ?*anyopaque) *Tabs {
        self.on_change = callback;
        self.callback_ctx = ctx;
        return self;
    }

    /// Calculate the width of the tab bar (saturating to prevent overflow)
    fn tabBarWidth(self: *const Tabs) u16 {
        if (self.tabs.len == 0) return 0;

        var width: u16 = 0;
        const sep_width: u16 = @intCast(@min(unicode.stringWidth(self.separator), std.math.maxInt(u16)));

        for (self.tabs, 0..) |tab, i| {
            const label_width: u16 = @intCast(@min(unicode.stringWidth(tab.label), std.math.maxInt(u16)));
            width +|= label_width; // Saturating add to prevent overflow
            if (i < self.tabs.len - 1) {
                width +|= sep_width;
            }
        }
        return width;
    }

    /// Find the tab index at a given x position, or null if not on a tab label
    fn tabAtPosition(self: *const Tabs, x: u16) ?usize {
        if (self.tabs.len == 0) return null;

        var col: u16 = 0;
        const sep_width: u16 = @intCast(@min(unicode.stringWidth(self.separator), std.math.maxInt(u16)));

        for (self.tabs, 0..) |tab, i| {
            const label_width: u16 = @intCast(@min(unicode.stringWidth(tab.label), std.math.maxInt(u16)));
            const tab_end = col +| label_width;

            // Check if x is within this tab label
            if (x >= col and x < tab_end) {
                return i;
            }

            col = tab_end;

            // Skip separator (clicks on separator don't select a tab)
            if (i < self.tabs.len - 1) {
                col +|= sep_width;
            }
        }
        return null;
    }

    /// Measure the tabs widget
    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Tabs = @ptrCast(@alignCast(ptr));

        if (self.tabs.len == 0) {
            return constraint.clamp(.{ .width = 0, .height = 0 });
        }

        // Tab bar takes 1 row
        const tab_bar_height: u16 = 1;

        // Measure all tabs and use max height for consistent sizing
        const content_constraint = Widget.SizeConstraint{
            .min_width = constraint.min_width,
            .max_width = constraint.max_width,
            .min_height = constraint.min_height -| tab_bar_height,
            .max_height = constraint.max_height -| tab_bar_height,
        };

        var max_content_height: u16 = 0;
        for (self.tabs) |tab| {
            const content_size = tab.content.measure(content_constraint);
            max_content_height = @max(max_content_height, content_size.height);
        }

        return constraint.clamp(.{
            .width = @max(self.tabBarWidth(), constraint.max_width),
            .height = tab_bar_height + max_content_height,
        });
    }

    /// Render the tabs
    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Tabs = @ptrCast(@alignCast(ptr));

        const view_size = view.size();
        if (view_size.height == 0 or view_size.width == 0) return;
        if (self.tabs.len == 0) return;

        const theme = Theme.default;
        const active_style = theme.styleForState(self.active_style, self.widget_state);
        const inactive_style = theme.styleForState(self.inactive_style, self.widget_state);

        // Render tab bar
        var col: i32 = 0;
        for (self.tabs, 0..) |tab, i| {
            const is_active = i == self.selected;
            const style = if (is_active) active_style else inactive_style;

            // Render tab label
            const label_width: u16 = @intCast(@min(unicode.stringWidth(tab.label), std.math.maxInt(u16)));
            view.print(col, 0, tab.label, style.fg, style.bg, style.attrs);
            col += @intCast(label_width);

            // Render separator if not last
            if (i < self.tabs.len - 1) {
                view.print(col, 0, self.separator, inactive_style.fg, inactive_style.bg, inactive_style.attrs);
                col += @intCast(@min(unicode.stringWidth(self.separator), std.math.maxInt(u16)));
            }
        }

        // Render content area
        if (view_size.height > 1 and self.selected < self.tabs.len) {
            var content_view = view.subView(.{
                .x = 0,
                .y = 1,
                .width = view_size.width,
                .height = view_size.height - 1,
            });
            self.tabs[self.selected].content.render(&content_view);
        }
    }

    /// Handle keyboard and mouse events for tab switching
    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *Tabs = @ptrCast(@alignCast(ptr));

        if (self.widget_state.disabled or self.tabs.len == 0) {
            return .ignored;
        }

        switch (event) {
            .key => |key| {
                if (self.widget_state.focused) {
                    if (key.special) |special| {
                        switch (special) {
                            .left => {
                                if (self.selected > 0) {
                                    self.selected -= 1;
                                    if (self.on_change) |callback| {
                                        callback(self.callback_ctx, self.selected);
                                    }
                                    return .consumed;
                                }
                            },
                            .right => {
                                if (self.selected < self.tabs.len - 1) {
                                    self.selected += 1;
                                    if (self.on_change) |callback| {
                                        callback(self.callback_ctx, self.selected);
                                    }
                                    return .consumed;
                                }
                            },
                            else => {},
                        }
                    }
                }
            },
            .mouse => |mouse| {
                // Handle left-click on tab bar (row 0)
                if (mouse.button == .left and mouse.y == 0) {
                    if (self.tabAtPosition(mouse.x)) |tab_index| {
                        if (tab_index != self.selected) {
                            self.selected = tab_index;
                            if (self.on_change) |callback| {
                                callback(self.callback_ctx, self.selected);
                            }
                        }
                        return .consumed;
                    }
                }
            },
            else => {},
        }

        // Forward event to selected tab's content
        if (self.selected < self.tabs.len) {
            return self.tabs[self.selected].content.handleEvent(event);
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

// A simple test widget with fixed size
const TestContent = struct {
    text: []const u8,
    height: u16 = 2,

    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *TestContent = @ptrCast(@alignCast(ptr));
        return constraint.clamp(.{ .width = 10, .height = self.height });
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *TestContent = @ptrCast(@alignCast(ptr));
        view.print(0, 0, self.text, .default, .default, .{});
    }

    pub const widget_vtable = Widget.VTable{
        .measureFn = measure,
        .renderFn = render,
    };
};

test "Tabs init" {
    var content1 = TestContent{ .text = "Tab 1" };
    var content2 = TestContent{ .text = "Tab 2" };

    const tabs_arr = [_]Tab{
        .{ .label = "First", .content = Widget.Widget.init(TestContent, &content1) },
        .{ .label = "Second", .content = Widget.Widget.init(TestContent, &content2) },
    };

    const tabs = Tabs.init(&tabs_arr);
    try std.testing.expectEqual(@as(usize, 0), tabs.selected);
    try std.testing.expectEqual(@as(usize, 2), tabs.tabs.len);
}

test "Tabs withSelected clamps" {
    var content = TestContent{ .text = "Content" };

    const tabs_arr = [_]Tab{
        .{ .label = "One", .content = Widget.Widget.init(TestContent, &content) },
    };

    var tabs = Tabs.init(&tabs_arr);
    _ = tabs.withSelected(100);
    try std.testing.expectEqual(@as(usize, 0), tabs.selected);
}

test "Tabs tabBarWidth" {
    var content = TestContent{ .text = "X" };

    const tabs_arr = [_]Tab{
        .{ .label = "Tab1", .content = Widget.Widget.init(TestContent, &content) },
        .{ .label = "Tab2", .content = Widget.Widget.init(TestContent, &content) },
    };

    const tabs = Tabs.init(&tabs_arr);
    // "Tab1" (4) + " | " (3) + "Tab2" (4) = 11
    try std.testing.expectEqual(@as(u16, 11), tabs.tabBarWidth());
}

test "Tabs measure" {
    var content = TestContent{ .text = "Content" };

    const tabs_arr = [_]Tab{
        .{ .label = "Tab", .content = Widget.Widget.init(TestContent, &content) },
    };

    var tabs = Tabs.init(&tabs_arr);
    const widget = Widget.Widget.init(Tabs, &tabs);

    const measured = widget.measure(Widget.SizeConstraint.atMost(40, 10));
    try std.testing.expectEqual(@as(u16, 40), measured.width);
    // 1 (tab bar) + 2 (content) = 3
    try std.testing.expectEqual(@as(u16, 3), measured.height);
}

test "Tabs measure uses max height across all tabs" {
    // Create tabs with different heights
    var short_content = TestContent{ .text = "Short", .height = 2 };
    var tall_content = TestContent{ .text = "Tall", .height = 5 };

    const tabs_arr = [_]Tab{
        .{ .label = "Short", .content = Widget.Widget.init(TestContent, &short_content) },
        .{ .label = "Tall", .content = Widget.Widget.init(TestContent, &tall_content) },
    };

    // Start with short tab selected
    var tabs = Tabs.init(&tabs_arr);
    try std.testing.expectEqual(@as(usize, 0), tabs.selected);

    const widget = Widget.Widget.init(Tabs, &tabs);
    const measured = widget.measure(Widget.SizeConstraint.atMost(40, 20));

    // Height should be max of all tabs (5) + tab bar (1) = 6
    try std.testing.expectEqual(@as(u16, 6), measured.height);

    // Changing selected tab should not affect measured height
    _ = tabs.withSelected(1); // Select tall tab
    const measured2 = widget.measure(Widget.SizeConstraint.atMost(40, 20));
    try std.testing.expectEqual(@as(u16, 6), measured2.height);
}

test "Tabs render tab bar" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 30, .height = 5 });
    defer root.deinit();

    var content1 = TestContent{ .text = "Content1" };
    var content2 = TestContent{ .text = "Content2" };

    const tabs_arr = [_]Tab{
        .{ .label = "Tab1", .content = Widget.Widget.init(TestContent, &content1) },
        .{ .label = "Tab2", .content = Widget.Widget.init(TestContent, &content2) },
    };

    var tabs = Tabs.init(&tabs_arr);
    const widget = Widget.Widget.init(Tabs, &tabs);

    var view = PlaneView.init(root);
    widget.render(&view);

    // Check tab labels
    try std.testing.expectEqual(@as(u21, 'T'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'a'), view.getCell(1, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'b'), view.getCell(2, 0).?.char);
    try std.testing.expectEqual(@as(u21, '1'), view.getCell(3, 0).?.char);

    // Check separator
    try std.testing.expectEqual(@as(u21, '|'), view.getCell(5, 0).?.char);

    // Check content
    try std.testing.expectEqual(@as(u21, 'C'), view.getCell(0, 1).?.char);
    try std.testing.expectEqual(@as(u21, 'o'), view.getCell(1, 1).?.char);
}

test "Tabs handle left/right keys" {
    var content1 = TestContent{ .text = "C1" };
    var content2 = TestContent{ .text = "C2" };

    const tabs_arr = [_]Tab{
        .{ .label = "T1", .content = Widget.Widget.init(TestContent, &content1) },
        .{ .label = "T2", .content = Widget.Widget.init(TestContent, &content2) },
    };

    var tabs = Tabs.init(&tabs_arr);
    _ = tabs.withState(.{ .focused = true });
    const widget = Widget.Widget.init(Tabs, &tabs);

    // Move right
    const right_event = Event.Event{ .key = Event.Key.fromSpecial(.right, .{}) };
    const result1 = widget.handleEvent(right_event);
    try std.testing.expectEqual(Widget.EventResult.consumed, result1);
    try std.testing.expectEqual(@as(usize, 1), tabs.selected);

    // Move left
    const left_event = Event.Event{ .key = Event.Key.fromSpecial(.left, .{}) };
    const result2 = widget.handleEvent(left_event);
    try std.testing.expectEqual(Widget.EventResult.consumed, result2);
    try std.testing.expectEqual(@as(usize, 0), tabs.selected);
}

test "Tabs callback on change" {
    var content1 = TestContent{ .text = "C1" };
    var content2 = TestContent{ .text = "C2" };

    const tabs_arr = [_]Tab{
        .{ .label = "T1", .content = Widget.Widget.init(TestContent, &content1) },
        .{ .label = "T2", .content = Widget.Widget.init(TestContent, &content2) },
    };

    var tabs = Tabs.init(&tabs_arr);
    _ = tabs.withState(.{ .focused = true });

    var changed_to: usize = 999;
    const callback = struct {
        fn call(ctx: ?*anyopaque, index: usize) void {
            if (ctx) |ptr| {
                const target: *usize = @ptrCast(@alignCast(ptr));
                target.* = index;
            }
        }
    }.call;

    _ = tabs.withOnChange(callback, @ptrCast(&changed_to));

    const widget = Widget.Widget.init(Tabs, &tabs);
    const event = Event.Event{ .key = Event.Key.fromSpecial(.right, .{}) };
    _ = widget.handleEvent(event);

    try std.testing.expectEqual(@as(usize, 1), changed_to);
}

test "Tabs empty" {
    const empty: []const Tab = &.{};
    var tabs = Tabs.init(empty);
    const widget = Widget.Widget.init(Tabs, &tabs);

    const measured = widget.measure(Widget.SizeConstraint.atMost(40, 10));
    try std.testing.expectEqual(@as(u16, 0), measured.width);
    try std.testing.expectEqual(@as(u16, 0), measured.height);
}

test "Tabs tabAtPosition" {
    var content = TestContent{ .text = "X" };

    const tabs_arr = [_]Tab{
        .{ .label = "Tab1", .content = Widget.Widget.init(TestContent, &content) },
        .{ .label = "Tab2", .content = Widget.Widget.init(TestContent, &content) },
    };

    const tabs = Tabs.init(&tabs_arr);
    // Layout: "Tab1" (0-3) + " | " (4-6) + "Tab2" (7-10)
    try std.testing.expectEqual(@as(?usize, 0), tabs.tabAtPosition(0)); // First char of Tab1
    try std.testing.expectEqual(@as(?usize, 0), tabs.tabAtPosition(3)); // Last char of Tab1
    try std.testing.expectEqual(@as(?usize, null), tabs.tabAtPosition(4)); // Separator space
    try std.testing.expectEqual(@as(?usize, null), tabs.tabAtPosition(5)); // Separator |
    try std.testing.expectEqual(@as(?usize, null), tabs.tabAtPosition(6)); // Separator space
    try std.testing.expectEqual(@as(?usize, 1), tabs.tabAtPosition(7)); // First char of Tab2
    try std.testing.expectEqual(@as(?usize, 1), tabs.tabAtPosition(10)); // Last char of Tab2
    try std.testing.expectEqual(@as(?usize, null), tabs.tabAtPosition(11)); // Past end
}

test "Tabs handle mouse click" {
    var content1 = TestContent{ .text = "C1" };
    var content2 = TestContent{ .text = "C2" };

    const tabs_arr = [_]Tab{
        .{ .label = "Tab1", .content = Widget.Widget.init(TestContent, &content1) },
        .{ .label = "Tab2", .content = Widget.Widget.init(TestContent, &content2) },
    };

    var tabs = Tabs.init(&tabs_arr);
    const widget = Widget.Widget.init(Tabs, &tabs);

    // Click on second tab (position 7 = first char of "Tab2")
    const click_event = Event.Event{ .mouse = .{
        .x = 7,
        .y = 0,
        .button = .left,
        .mods = .{},
    } };
    const result = widget.handleEvent(click_event);
    try std.testing.expectEqual(Widget.EventResult.consumed, result);
    try std.testing.expectEqual(@as(usize, 1), tabs.selected);

    // Click on first tab (position 0)
    const click_back = Event.Event{ .mouse = .{
        .x = 0,
        .y = 0,
        .button = .left,
        .mods = .{},
    } };
    const result2 = widget.handleEvent(click_back);
    try std.testing.expectEqual(Widget.EventResult.consumed, result2);
    try std.testing.expectEqual(@as(usize, 0), tabs.selected);
}

test "Tabs mouse click on separator ignored" {
    var content1 = TestContent{ .text = "C1" };
    var content2 = TestContent{ .text = "C2" };

    const tabs_arr = [_]Tab{
        .{ .label = "Tab1", .content = Widget.Widget.init(TestContent, &content1) },
        .{ .label = "Tab2", .content = Widget.Widget.init(TestContent, &content2) },
    };

    var tabs = Tabs.init(&tabs_arr);
    const widget = Widget.Widget.init(Tabs, &tabs);

    // Click on separator (position 5 = "|")
    const click_event = Event.Event{ .mouse = .{
        .x = 5,
        .y = 0,
        .button = .left,
        .mods = .{},
    } };
    const result = widget.handleEvent(click_event);
    try std.testing.expectEqual(Widget.EventResult.ignored, result);
    try std.testing.expectEqual(@as(usize, 0), tabs.selected); // Unchanged
}

test "Tabs mouse click callback" {
    var content1 = TestContent{ .text = "C1" };
    var content2 = TestContent{ .text = "C2" };

    const tabs_arr = [_]Tab{
        .{ .label = "T1", .content = Widget.Widget.init(TestContent, &content1) },
        .{ .label = "T2", .content = Widget.Widget.init(TestContent, &content2) },
    };

    var tabs = Tabs.init(&tabs_arr);

    var changed_to: usize = 999;
    const callback = struct {
        fn call(ctx: ?*anyopaque, index: usize) void {
            if (ctx) |ptr| {
                const target: *usize = @ptrCast(@alignCast(ptr));
                target.* = index;
            }
        }
    }.call;

    _ = tabs.withOnChange(callback, @ptrCast(&changed_to));

    const widget = Widget.Widget.init(Tabs, &tabs);
    // Click on T2 (layout: "T1" (0-1) + " | " (2-4) + "T2" (5-6))
    const click_event = Event.Event{ .mouse = .{
        .x = 5,
        .y = 0,
        .button = .left,
        .mods = .{},
    } };
    _ = widget.handleEvent(click_event);

    try std.testing.expectEqual(@as(usize, 1), changed_to);
}

test "Tabs mouse click on content area forwarded" {
    var content1 = TestContent{ .text = "C1" };
    var content2 = TestContent{ .text = "C2" };

    const tabs_arr = [_]Tab{
        .{ .label = "Tab1", .content = Widget.Widget.init(TestContent, &content1) },
        .{ .label = "Tab2", .content = Widget.Widget.init(TestContent, &content2) },
    };

    var tabs = Tabs.init(&tabs_arr);
    const widget = Widget.Widget.init(Tabs, &tabs);

    // Click on content area (y > 0) should be forwarded to child
    const click_event = Event.Event{ .mouse = .{
        .x = 0,
        .y = 1,
        .button = .left,
        .mods = .{},
    } };
    const result = widget.handleEvent(click_event);
    // TestContent doesn't handle events, so it should be ignored
    try std.testing.expectEqual(Widget.EventResult.ignored, result);
    try std.testing.expectEqual(@as(usize, 0), tabs.selected); // Unchanged
}
