//! ListView: Scrollable list of selectable items
//!
//! A vertical list widget with keyboard navigation and selection support.
//! Supports single and multi-selection modes.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const Event = @import("../Event.zig");

/// A single item in the list
pub const ListItem = struct {
    /// Display text
    text: []const u8,
    /// Optional value/id
    value: u32 = 0,
    /// Whether this item is selectable
    enabled: bool = true,
};

/// ListView widget
pub const ListView = struct {
    /// List items
    items: []const ListItem,
    /// Currently highlighted index
    cursor: usize = 0,
    /// Scroll offset (first visible item)
    scroll_offset: usize = 0,
    /// Selected indices (for multi-select)
    selected: std.StaticBitSet(256) = std.StaticBitSet(256).initEmpty(),
    /// Selection mode
    multi_select: bool = false,
    /// Normal item style
    style: Style = .{},
    /// Highlighted item style
    cursor_style: Style = .{ .attrs = .{ .reverse = true } },
    /// Selected item style
    selected_style: Style = .{ .fg = .{ .index = 6 } },
    /// Disabled item style
    disabled_style: Style = .{ .fg = .{ .index = 8 } },
    /// Show selection indicator
    show_indicator: bool = true,
    /// Widget state
    widget_state: Widget.WidgetState = .{},
    /// Selection callback
    on_select: ?*const fn (ctx: ?*anyopaque, index: usize, value: u32) void = null,
    /// Callback context
    callback_ctx: ?*anyopaque = null,
    /// Visible height (for scrolling)
    visible_height: u16 = 10,

    /// Create a list view with items
    pub fn init(items: []const ListItem) ListView {
        return .{ .items = items };
    }

    // Builder methods

    /// Set multi-select mode
    pub fn withMultiSelect(self: *ListView, multi: bool) *ListView {
        self.multi_select = multi;
        return self;
    }

    /// Set cursor style
    pub fn withCursorStyle(self: *ListView, style: Style) *ListView {
        self.cursor_style = style;
        return self;
    }

    /// Set selection callback
    pub fn withOnSelect(self: *ListView, callback: *const fn (ctx: ?*anyopaque, index: usize, value: u32) void, ctx: ?*anyopaque) *ListView {
        self.on_select = callback;
        self.callback_ctx = ctx;
        return self;
    }

    /// Set visible height
    pub fn withVisibleHeight(self: *ListView, height: u16) *ListView {
        self.visible_height = height;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *ListView, state: Widget.WidgetState) *ListView {
        self.widget_state = state;
        return self;
    }

    // Navigation methods

    /// Move cursor up
    pub fn cursorUp(self: *ListView) void {
        if (self.items.len == 0) return;

        // Find previous enabled item
        var new_cursor = self.cursor;
        while (new_cursor > 0) {
            new_cursor -= 1;
            if (self.items[new_cursor].enabled) {
                self.cursor = new_cursor;
                self.ensureCursorVisible();
                return;
            }
        }
    }

    /// Move cursor down
    pub fn cursorDown(self: *ListView) void {
        if (self.items.len == 0) return;

        // Find next enabled item
        var new_cursor = self.cursor;
        while (new_cursor + 1 < self.items.len) {
            new_cursor += 1;
            if (self.items[new_cursor].enabled) {
                self.cursor = new_cursor;
                self.ensureCursorVisible();
                return;
            }
        }
    }

    /// Jump to first item
    pub fn cursorHome(self: *ListView) void {
        if (self.items.len == 0) return;

        for (self.items, 0..) |item, i| {
            if (item.enabled) {
                self.cursor = i;
                self.ensureCursorVisible();
                return;
            }
        }
    }

    /// Jump to last item
    pub fn cursorEnd(self: *ListView) void {
        if (self.items.len == 0) return;

        var i = self.items.len;
        while (i > 0) {
            i -= 1;
            if (self.items[i].enabled) {
                self.cursor = i;
                self.ensureCursorVisible();
                return;
            }
        }
    }

    /// Toggle selection at cursor
    pub fn toggleSelection(self: *ListView) void {
        if (self.items.len == 0) return;
        if (!self.items[self.cursor].enabled) return;

        if (self.multi_select) {
            self.selected.toggle(self.cursor);
        } else {
            // Single select: clear others, select this one
            self.selected = std.StaticBitSet(256).initEmpty();
            self.selected.set(self.cursor);
        }

        if (self.on_select) |callback| {
            callback(self.callback_ctx, self.cursor, self.items[self.cursor].value);
        }
    }

    /// Ensure cursor is visible within scroll window
    fn ensureCursorVisible(self: *ListView) void {
        if (self.cursor < self.scroll_offset) {
            self.scroll_offset = self.cursor;
        } else if (self.cursor >= self.scroll_offset + self.visible_height) {
            self.scroll_offset = self.cursor - self.visible_height + 1;
        }
    }

    /// Check if an item is selected
    pub fn isSelected(self: *const ListView, index: usize) bool {
        return self.selected.isSet(index);
    }

    // Widget interface

    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *ListView = @ptrCast(@alignCast(ptr));

        // Find max item width
        var max_width: u16 = 0;
        for (self.items) |item| {
            const item_width: u16 = @intCast(@min(item.text.len, std.math.maxInt(u16)));
            const total_width = if (self.show_indicator) item_width + 2 else item_width;
            max_width = @max(max_width, total_width);
        }

        const height: u16 = @intCast(@min(self.items.len, self.visible_height));

        return .{
            .width = @min(max_width, constraint.max_width),
            .height = @min(height, constraint.max_height),
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *ListView = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0 or self.items.len == 0) return;

        const visible_items = @min(self.items.len - self.scroll_offset, size.height);

        var y: u16 = 0;
        while (y < visible_items) : (y += 1) {
            const item_idx = self.scroll_offset + y;
            const item = self.items[item_idx];

            // Determine style
            var item_style = self.style;
            if (!item.enabled) {
                item_style = self.disabled_style;
            } else if (item_idx == self.cursor and self.widget_state.focused) {
                item_style = self.cursor_style;
            } else if (self.isSelected(item_idx)) {
                item_style = self.selected_style;
            }

            // Clear line
            const clear_cell = Cell{
                .char = ' ',
                .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                .fg = item_style.fg,
                .bg = item_style.bg,
                .attrs = item_style.attrs,
            };
            var x: i32 = 0;
            while (x < size.width) : (x += 1) {
                view.setCell(x, @intCast(y), clear_cell);
            }

            // Draw selection indicator
            var text_x: u16 = 0;
            if (self.show_indicator) {
                const indicator: u21 = if (self.isSelected(item_idx)) '●' else ' ';
                view.setCell(0, @intCast(y), .{
                    .char = indicator,
                    .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                    .fg = if (self.isSelected(item_idx)) self.selected_style.fg else item_style.fg,
                    .bg = item_style.bg,
                    .attrs = item_style.attrs,
                });
                text_x = 2;
            }

            // Draw item text
            view.print(@intCast(text_x), @intCast(y), item.text, item_style.fg, item_style.bg, item_style.attrs);
        }
    }

    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *ListView = @ptrCast(@alignCast(ptr));

        if (self.widget_state.disabled or self.items.len == 0) {
            return .ignored;
        }

        switch (event) {
            .key => |key| {
                if (key.special == .up or key.codepoint == 'k') {
                    self.cursorUp();
                    return .consumed;
                } else if (key.special == .down or key.codepoint == 'j') {
                    self.cursorDown();
                    return .consumed;
                } else if (key.special == .home) {
                    self.cursorHome();
                    return .consumed;
                } else if (key.special == .end) {
                    self.cursorEnd();
                    return .consumed;
                } else if (key.special == .enter or (key.codepoint == ' ' and key.mods.eql(Event.Modifiers.none))) {
                    self.toggleSelection();
                    return .consumed;
                }
            },
            .mouse => |mouse| {
                if (mouse.button == .left and mouse.button_state == .released) {
                    const click_y: usize = @intCast(mouse.y);
                    const item_idx = self.scroll_offset + click_y;
                    if (item_idx < self.items.len and self.items[item_idx].enabled) {
                        self.cursor = item_idx;
                        self.toggleSelection();
                        return .consumed;
                    }
                } else if (mouse.button == .wheel_up) {
                    self.cursorUp();
                    return .consumed;
                } else if (mouse.button == .wheel_down) {
                    self.cursorDown();
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

test "ListView init" {
    const items = [_]ListItem{
        .{ .text = "Item 1", .value = 1 },
        .{ .text = "Item 2", .value = 2 },
    };
    const list = ListView.init(&items);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqual(@as(usize, 0), list.cursor);
}

test "ListView cursor navigation" {
    const items = [_]ListItem{
        .{ .text = "A" },
        .{ .text = "B" },
        .{ .text = "C" },
    };
    var list = ListView.init(&items);

    try std.testing.expectEqual(@as(usize, 0), list.cursor);

    list.cursorDown();
    try std.testing.expectEqual(@as(usize, 1), list.cursor);

    list.cursorDown();
    try std.testing.expectEqual(@as(usize, 2), list.cursor);

    list.cursorDown(); // Should stay at 2
    try std.testing.expectEqual(@as(usize, 2), list.cursor);

    list.cursorUp();
    try std.testing.expectEqual(@as(usize, 1), list.cursor);
}

test "ListView cursor skips disabled" {
    const items = [_]ListItem{
        .{ .text = "A", .enabled = true },
        .{ .text = "B", .enabled = false },
        .{ .text = "C", .enabled = true },
    };
    var list = ListView.init(&items);

    list.cursorDown();
    // Should skip disabled item B and go to C
    try std.testing.expectEqual(@as(usize, 2), list.cursor);
}

test "ListView selection single" {
    const items = [_]ListItem{
        .{ .text = "A", .value = 1 },
        .{ .text = "B", .value = 2 },
    };
    var list = ListView.init(&items);

    list.toggleSelection();
    try std.testing.expect(list.isSelected(0));
    try std.testing.expect(!list.isSelected(1));

    list.cursorDown();
    list.toggleSelection();
    // Single select: previous should be deselected
    try std.testing.expect(!list.isSelected(0));
    try std.testing.expect(list.isSelected(1));
}

test "ListView selection multi" {
    const items = [_]ListItem{
        .{ .text = "A" },
        .{ .text = "B" },
    };
    var list = ListView.init(&items);
    _ = list.withMultiSelect(true);

    list.toggleSelection();
    try std.testing.expect(list.isSelected(0));

    list.cursorDown();
    list.toggleSelection();
    // Multi select: both should be selected
    try std.testing.expect(list.isSelected(0));
    try std.testing.expect(list.isSelected(1));

    // Toggle off
    list.toggleSelection();
    try std.testing.expect(list.isSelected(0));
    try std.testing.expect(!list.isSelected(1));
}

test "ListView measure" {
    const items = [_]ListItem{
        .{ .text = "Short" },
        .{ .text = "Longer item" },
        .{ .text = "Medium" },
    };
    var list = ListView.init(&items);
    const widget = Widget.Widget.init(ListView, &list);

    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));
    // "Longer item" = 11 chars + 2 indicator = 13
    try std.testing.expectEqual(@as(u16, 13), measured.width);
    try std.testing.expectEqual(@as(u16, 3), measured.height);
}

test "ListView render" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 5 });
    defer root.deinit();

    const items = [_]ListItem{
        .{ .text = "Apple" },
        .{ .text = "Banana" },
    };
    var list = ListView.init(&items);
    list.widget_state.focused = true;
    const widget = Widget.Widget.init(ListView, &list);

    var view = PlaneView.init(root);
    widget.render(&view);

    // First item text should be visible
    try std.testing.expectEqual(@as(u21, 'A'), view.getCell(2, 0).?.char);
}

test "ListView callback" {
    var selected_idx: ?usize = null;

    const callback = struct {
        fn cb(ctx: ?*anyopaque, index: usize, _: u32) void {
            const ptr: *?usize = @ptrCast(@alignCast(ctx.?));
            ptr.* = index;
        }
    }.cb;

    const items = [_]ListItem{
        .{ .text = "A", .value = 1 },
    };
    var list = ListView.init(&items);
    _ = list.withOnSelect(callback, &selected_idx);

    list.toggleSelection();
    try std.testing.expectEqual(@as(usize, 0), selected_idx.?);
}
