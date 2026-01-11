//! Autocomplete: Input field with suggestions dropdown
//!
//! A widget that provides autocomplete suggestions as the user types.
//! Combines an InputField with a filtered suggestion list.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const Event = @import("../Event.zig");
const Layout = @import("../Layout.zig");

/// A suggestion item
pub const Suggestion = struct {
    /// The text to insert
    value: []const u8,
    /// Optional display text (if different from value)
    label: ?[]const u8 = null,
    /// Optional description
    description: ?[]const u8 = null,

    /// Get display text
    pub fn displayText(self: Suggestion) []const u8 {
        return self.label orelse self.value;
    }
};

/// Filter function type
pub const FilterFn = *const fn (query: []const u8, suggestion: Suggestion) bool;

/// Default prefix filter
pub fn prefixFilter(query: []const u8, suggestion: Suggestion) bool {
    const value = suggestion.value;
    if (query.len > value.len) return false;
    return std.mem.startsWith(u8, value, query);
}

/// Case-insensitive prefix filter
pub fn prefixFilterIgnoreCase(query: []const u8, suggestion: Suggestion) bool {
    const value = suggestion.value;
    if (query.len > value.len) return false;

    for (query, 0..) |qc, i| {
        const vc = value[i];
        const qc_lower = if (qc >= 'A' and qc <= 'Z') qc + 32 else qc;
        const vc_lower = if (vc >= 'A' and vc <= 'Z') vc + 32 else vc;
        if (qc_lower != vc_lower) return false;
    }
    return true;
}

/// Contains filter (substring match)
pub fn containsFilter(query: []const u8, suggestion: Suggestion) bool {
    if (query.len == 0) return true;
    return std.mem.indexOf(u8, suggestion.value, query) != null;
}

/// Autocomplete widget
pub const Autocomplete = struct {
    /// Current input text (owned externally)
    text: []const u8,
    /// Cursor position
    cursor: usize = 0,
    /// All available suggestions
    suggestions: []const Suggestion,
    /// Currently selected index in filtered list
    selected_index: usize = 0,
    /// Whether dropdown is visible
    dropdown_visible: bool = false,
    /// Max visible suggestions
    max_visible: usize = 5,
    /// Minimum chars before showing suggestions
    min_chars: usize = 1,
    /// Filter function
    filter_fn: FilterFn = prefixFilter,
    /// Width for dropdown (0 = auto)
    dropdown_width: u16 = 0,
    /// Placeholder text
    placeholder: ?[]const u8 = null,
    /// Text style
    text_style: Style = .{},
    /// Placeholder style
    placeholder_style: Style = .{ .fg = .{ .index = 8 } },
    /// Cursor style
    cursor_style: Style = .{ .attrs = .{ .reverse = true } },
    /// Dropdown style
    dropdown_style: Style = .{ .bg = .{ .index = 0 } },
    /// Selected item style
    selected_style: Style = .{ .bg = .{ .index = 4 }, .fg = .{ .index = 15 } },
    /// Border style
    border_style: Layout.BoxStyle = Layout.BoxStyle.single,
    /// Widget state
    widget_state: Widget.WidgetState = .{},
    /// Callback context
    callback_ctx: ?*anyopaque = null,
    /// Called when text changes
    on_change: ?*const fn (ctx: ?*anyopaque, text: []const u8, cursor: usize) void = null,
    /// Called when a suggestion is selected
    on_select: ?*const fn (ctx: ?*anyopaque, suggestion: Suggestion) void = null,

    // Cached filtered indices
    filtered_indices: [64]usize = undefined,
    filtered_count: usize = 0,

    /// Create an autocomplete widget
    pub fn init(text: []const u8, suggestions: []const Suggestion) Autocomplete {
        var ac = Autocomplete{
            .text = text,
            .cursor = text.len,
            .suggestions = suggestions,
        };
        ac.updateFiltered();
        return ac;
    }

    // Builder methods

    /// Set placeholder
    pub fn withPlaceholder(self: *Autocomplete, placeholder: []const u8) *Autocomplete {
        self.placeholder = placeholder;
        return self;
    }

    /// Set max visible suggestions
    pub fn withMaxVisible(self: *Autocomplete, max: usize) *Autocomplete {
        self.max_visible = max;
        return self;
    }

    /// Set minimum chars before suggestions
    pub fn withMinChars(self: *Autocomplete, min: usize) *Autocomplete {
        self.min_chars = min;
        return self;
    }

    /// Set filter function
    pub fn withFilter(self: *Autocomplete, filter: FilterFn) *Autocomplete {
        self.filter_fn = filter;
        return self;
    }

    /// Set dropdown width
    pub fn withDropdownWidth(self: *Autocomplete, width: u16) *Autocomplete {
        self.dropdown_width = width;
        return self;
    }

    /// Set text style
    pub fn withTextStyle(self: *Autocomplete, style: Style) *Autocomplete {
        self.text_style = style;
        return self;
    }

    /// Set selected style
    pub fn withSelectedStyle(self: *Autocomplete, style: Style) *Autocomplete {
        self.selected_style = style;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *Autocomplete, state: Widget.WidgetState) *Autocomplete {
        self.widget_state = state;
        return self;
    }

    /// Set change callback
    pub fn withOnChange(self: *Autocomplete, callback: *const fn (ctx: ?*anyopaque, text: []const u8, cursor: usize) void, ctx: ?*anyopaque) *Autocomplete {
        self.on_change = callback;
        self.callback_ctx = ctx;
        return self;
    }

    /// Set select callback
    pub fn withOnSelect(self: *Autocomplete, callback: *const fn (ctx: ?*anyopaque, suggestion: Suggestion) void, ctx: ?*anyopaque) *Autocomplete {
        self.on_select = callback;
        if (self.callback_ctx == null) self.callback_ctx = ctx;
        return self;
    }

    // Methods

    /// Update text (call when external text changes)
    pub fn setText(self: *Autocomplete, text: []const u8, cursor: usize) void {
        self.text = text;
        self.cursor = cursor;
        self.updateFiltered();
        self.selected_index = 0;

        // Show dropdown if enough chars
        if (text.len >= self.min_chars and self.filtered_count > 0) {
            self.dropdown_visible = true;
        } else {
            self.dropdown_visible = false;
        }
    }

    /// Get current selection (if any)
    pub fn selectedSuggestion(self: *const Autocomplete) ?Suggestion {
        if (self.filtered_count == 0) return null;
        if (self.selected_index >= self.filtered_count) return null;
        const idx = self.filtered_indices[self.selected_index];
        return self.suggestions[idx];
    }

    /// Select next suggestion
    pub fn selectNext(self: *Autocomplete) void {
        if (self.filtered_count > 0) {
            self.selected_index = (self.selected_index + 1) % self.filtered_count;
        }
    }

    /// Select previous suggestion
    pub fn selectPrev(self: *Autocomplete) void {
        if (self.filtered_count > 0) {
            if (self.selected_index == 0) {
                self.selected_index = self.filtered_count - 1;
            } else {
                self.selected_index -= 1;
            }
        }
    }

    /// Confirm current selection
    pub fn confirm(self: *Autocomplete) void {
        if (self.selectedSuggestion()) |suggestion| {
            if (self.on_select) |callback| {
                callback(self.callback_ctx, suggestion);
            }
        }
        self.dropdown_visible = false;
    }

    /// Cancel/hide dropdown
    pub fn cancel(self: *Autocomplete) void {
        self.dropdown_visible = false;
    }

    /// Show dropdown
    pub fn showDropdown(self: *Autocomplete) void {
        if (self.filtered_count > 0) {
            self.dropdown_visible = true;
        }
    }

    fn updateFiltered(self: *Autocomplete) void {
        self.filtered_count = 0;
        for (self.suggestions, 0..) |suggestion, i| {
            if (self.filter_fn(self.text, suggestion)) {
                if (self.filtered_count < self.filtered_indices.len) {
                    self.filtered_indices[self.filtered_count] = i;
                    self.filtered_count += 1;
                }
            }
        }
    }

    // Widget interface

    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Autocomplete = @ptrCast(@alignCast(ptr));

        // Height: 1 for input + dropdown if visible
        var height: u16 = 1;
        if (self.dropdown_visible and self.filtered_count > 0) {
            const visible = @min(self.filtered_count, self.max_visible);
            height += @as(u16, @intCast(visible)) + 2; // +2 for borders
        }

        return .{
            .width = constraint.max_width,
            .height = @min(height, constraint.max_height),
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Autocomplete = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0) return;

        // Render input line
        renderInputLine(self, view, size.width);

        // Render dropdown if visible
        if (self.dropdown_visible and self.filtered_count > 0 and size.height > 1) {
            renderDropdown(self, view, size);
        }
    }

    fn renderInputLine(self: *Autocomplete, view: *PlaneView, width: u16) void {
        // Show placeholder if empty and not focused
        if (self.text.len == 0 and !self.widget_state.focused) {
            if (self.placeholder) |ph| {
                const display_len = @min(ph.len, width);
                view.print(0, 0, ph[0..display_len], self.placeholder_style.fg, self.placeholder_style.bg, self.placeholder_style.attrs);
            }
            return;
        }

        // Render text
        const display_len = @min(self.text.len, width);
        if (display_len > 0) {
            view.print(0, 0, self.text[0..display_len], self.text_style.fg, self.text_style.bg, self.text_style.attrs);
        }

        // Render cursor if focused
        if (self.widget_state.focused) {
            const cursor_x: i32 = @intCast(@min(self.cursor, width -| 1));
            const cursor_char: u21 = if (self.cursor < self.text.len) self.text[self.cursor] else ' ';
            view.setCell(cursor_x, 0, .{
                .char = cursor_char,
                .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                .fg = self.cursor_style.fg,
                .bg = self.cursor_style.bg,
                .attrs = self.cursor_style.attrs,
            });
        }
    }

    fn renderDropdown(self: *Autocomplete, view: *PlaneView, size: struct { width: u16, height: u16 }) void {
        const visible = @min(self.filtered_count, self.max_visible);
        const dropdown_height = @min(visible + 2, size.height - 1);
        if (dropdown_height < 3) return;

        const box = self.border_style;
        const dropdown_width = if (self.dropdown_width > 0) @min(self.dropdown_width, size.width) else size.width;

        // Top border
        view.setCell(0, 1, Cell.simple(box.top_left, self.dropdown_style.fg, self.dropdown_style.bg));
        var x: u16 = 1;
        while (x < dropdown_width - 1) : (x += 1) {
            view.setCell(@intCast(x), 1, Cell.simple(box.horizontal, self.dropdown_style.fg, self.dropdown_style.bg));
        }
        view.setCell(@intCast(dropdown_width - 1), 1, Cell.simple(box.top_right, self.dropdown_style.fg, self.dropdown_style.bg));

        // Content rows
        var row: u16 = 0;
        while (row < visible and row + 2 < dropdown_height) : (row += 1) {
            const y: i32 = @as(i32, row) + 2;
            const idx = self.filtered_indices[row];
            const suggestion = self.suggestions[idx];
            const is_selected = row == self.selected_index;
            const style = if (is_selected) self.selected_style else self.dropdown_style;

            // Left border
            view.setCell(0, y, Cell.simple(box.vertical, self.dropdown_style.fg, self.dropdown_style.bg));

            // Fill background and content
            x = 1;
            while (x < dropdown_width - 1) : (x += 1) {
                view.setCell(@intCast(x), y, Cell.simple(' ', style.fg, style.bg));
            }

            // Print suggestion text
            const display_text = suggestion.displayText();
            const text_len = @min(display_text.len, dropdown_width -| 3);
            if (text_len > 0) {
                view.print(2, y, display_text[0..text_len], style.fg, style.bg, style.attrs);
            }

            // Right border
            view.setCell(@intCast(dropdown_width - 1), y, Cell.simple(box.vertical, self.dropdown_style.fg, self.dropdown_style.bg));
        }

        // Bottom border
        const bottom_y: i32 = @as(i32, @intCast(visible)) + 2;
        if (bottom_y < size.height) {
            view.setCell(0, bottom_y, Cell.simple(box.bottom_left, self.dropdown_style.fg, self.dropdown_style.bg));
            x = 1;
            while (x < dropdown_width - 1) : (x += 1) {
                view.setCell(@intCast(x), bottom_y, Cell.simple(box.horizontal, self.dropdown_style.fg, self.dropdown_style.bg));
            }
            view.setCell(@intCast(dropdown_width - 1), bottom_y, Cell.simple(box.bottom_right, self.dropdown_style.fg, self.dropdown_style.bg));
        }
    }

    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *Autocomplete = @ptrCast(@alignCast(ptr));

        if (self.widget_state.disabled or !self.widget_state.focused) {
            return .ignored;
        }

        switch (event) {
            .key => |key| {
                if (key.special) |special| {
                    switch (special) {
                        .down => {
                            if (self.dropdown_visible) {
                                self.selectNext();
                                return .consumed;
                            } else if (self.filtered_count > 0) {
                                self.showDropdown();
                                return .consumed;
                            }
                        },
                        .up => {
                            if (self.dropdown_visible) {
                                self.selectPrev();
                                return .consumed;
                            }
                        },
                        .tab, .enter => {
                            if (self.dropdown_visible and self.selectedSuggestion() != null) {
                                self.confirm();
                                return .consumed;
                            }
                        },
                        .escape => {
                            if (self.dropdown_visible) {
                                self.cancel();
                                return .consumed;
                            }
                        },
                        else => {},
                    }
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

test "Autocomplete init" {
    const suggestions = [_]Suggestion{
        .{ .value = "apple" },
        .{ .value = "banana" },
        .{ .value = "cherry" },
    };
    const ac = Autocomplete.init("", &suggestions);
    try std.testing.expectEqual(@as(usize, 3), ac.suggestions.len);
    try std.testing.expectEqual(false, ac.dropdown_visible);
}

test "Autocomplete prefix filter" {
    const suggestions = [_]Suggestion{
        .{ .value = "apple" },
        .{ .value = "apricot" },
        .{ .value = "banana" },
    };
    const ac = Autocomplete.init("ap", &suggestions);

    try std.testing.expectEqual(@as(usize, 2), ac.filtered_count);
    try std.testing.expectEqual(@as(usize, 0), ac.filtered_indices[0]); // apple
    try std.testing.expectEqual(@as(usize, 1), ac.filtered_indices[1]); // apricot
}

test "Autocomplete setText updates filter" {
    const suggestions = [_]Suggestion{
        .{ .value = "apple" },
        .{ .value = "apricot" },
        .{ .value = "banana" },
    };
    var ac = Autocomplete.init("", &suggestions);
    _ = ac.withMinChars(1);

    ac.setText("b", 1);
    try std.testing.expectEqual(@as(usize, 1), ac.filtered_count);
    try std.testing.expectEqual(@as(usize, 2), ac.filtered_indices[0]); // banana
    try std.testing.expect(ac.dropdown_visible);
}

test "Autocomplete selectNext/selectPrev" {
    const suggestions = [_]Suggestion{
        .{ .value = "a" },
        .{ .value = "b" },
        .{ .value = "c" },
    };
    var ac = Autocomplete.init("", &suggestions);

    try std.testing.expectEqual(@as(usize, 0), ac.selected_index);

    ac.selectNext();
    try std.testing.expectEqual(@as(usize, 1), ac.selected_index);

    ac.selectNext();
    try std.testing.expectEqual(@as(usize, 2), ac.selected_index);

    ac.selectNext(); // Wraps
    try std.testing.expectEqual(@as(usize, 0), ac.selected_index);

    ac.selectPrev(); // Wraps back
    try std.testing.expectEqual(@as(usize, 2), ac.selected_index);
}

test "Autocomplete selectedSuggestion" {
    const suggestions = [_]Suggestion{
        .{ .value = "apple" },
        .{ .value = "banana" },
    };
    var ac = Autocomplete.init("", &suggestions);

    const selected = ac.selectedSuggestion();
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("apple", selected.?.value);

    ac.selectNext();
    const next = ac.selectedSuggestion();
    try std.testing.expectEqualStrings("banana", next.?.value);
}

test "Autocomplete measure" {
    const suggestions = [_]Suggestion{
        .{ .value = "a" },
        .{ .value = "b" },
    };
    var ac = Autocomplete.init("", &suggestions);
    const widget = Widget.Widget.init(Autocomplete, &ac);

    // Not visible
    var measured = widget.measure(Widget.SizeConstraint.atMost(40, 10));
    try std.testing.expectEqual(@as(u16, 1), measured.height);

    // With dropdown
    ac.dropdown_visible = true;
    measured = widget.measure(Widget.SizeConstraint.atMost(40, 10));
    try std.testing.expectEqual(@as(u16, 5), measured.height); // 1 + 2 suggestions + 2 borders
}

test "Autocomplete handle down arrow" {
    const suggestions = [_]Suggestion{
        .{ .value = "a" },
        .{ .value = "b" },
    };
    var ac = Autocomplete.init("", &suggestions);
    _ = ac.withState(.{ .focused = true });
    ac.dropdown_visible = true;

    const widget = Widget.Widget.init(Autocomplete, &ac);
    const event = Event.Event{ .key = Event.Key.fromSpecial(.down, .{}) };

    const result = widget.handleEvent(event);
    try std.testing.expectEqual(Widget.EventResult.consumed, result);
    try std.testing.expectEqual(@as(usize, 1), ac.selected_index);
}

test "Autocomplete handle escape" {
    const suggestions = [_]Suggestion{
        .{ .value = "a" },
    };
    var ac = Autocomplete.init("", &suggestions);
    _ = ac.withState(.{ .focused = true });
    ac.dropdown_visible = true;

    const widget = Widget.Widget.init(Autocomplete, &ac);
    const event = Event.Event{ .key = Event.Key.fromSpecial(.escape, .{}) };

    const result = widget.handleEvent(event);
    try std.testing.expectEqual(Widget.EventResult.consumed, result);
    try std.testing.expect(!ac.dropdown_visible);
}

test "Autocomplete case-insensitive filter" {
    const suggestions = [_]Suggestion{
        .{ .value = "Apple" },
        .{ .value = "APRICOT" },
        .{ .value = "banana" },
    };
    var ac = Autocomplete.init("ap", &suggestions);
    _ = ac.withFilter(prefixFilterIgnoreCase);
    ac.setText("ap", 2); // This triggers updateFiltered()

    try std.testing.expectEqual(@as(usize, 2), ac.filtered_count);
}

test "Autocomplete contains filter" {
    const suggestions = [_]Suggestion{
        .{ .value = "pineapple" },
        .{ .value = "banana" },
        .{ .value = "grape" },
    };
    var ac = Autocomplete.init("ap", &suggestions);
    _ = ac.withFilter(containsFilter);
    ac.setText("ap", 2); // This triggers updateFiltered()

    try std.testing.expectEqual(@as(usize, 2), ac.filtered_count); // pineapple, grape
}

test "Autocomplete render" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 5 });
    defer root.deinit();

    const suggestions = [_]Suggestion{
        .{ .value = "hello" },
    };
    var ac = Autocomplete.init("hel", &suggestions);

    const widget = Widget.Widget.init(Autocomplete, &ac);
    var view = PlaneView.init(root);
    widget.render(&view);

    // Text should be visible
    try std.testing.expectEqual(@as(u21, 'h'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'e'), view.getCell(1, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'l'), view.getCell(2, 0).?.char);
}
