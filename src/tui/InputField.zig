//! InputField: Single-line text input widget
//!
//! A text input widget with cursor navigation and text editing.
//! State (text content, cursor position) comes from external Model.
//! Callbacks are used to report changes back to the application.
//!
//! ## Callback Design
//!
//! This widget follows a stateless pattern where text is owned by an external Model.
//! The `on_change` callback notifies when the user attempts an edit operation:
//! - Cursor movement: callback with new cursor position
//! - Backspace/Delete: callback indicates cursor moved; Model should delete char at cursor
//! - Character input: callback provides current state; Model should insert typed char
//!
//! The Model is responsible for tracking what operation was triggered (by comparing
//! old and new cursor positions) and performing the actual text mutation.
//!
//! ## UTF-8 Handling
//!
//! The text parameter should be valid UTF-8. Invalid UTF-8 sequences are handled
//! gracefully: rendering will skip invalid text, and cursor navigation will return
//! safe default positions.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Theme = @import("Theme.zig").Theme;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const Event = @import("../Event.zig");
const unicode = @import("../unicode/width.zig");

/// Edit action type for on_edit callback
pub const EditAction = union(enum) {
    /// Cursor moved to new position (no text change)
    cursor_move: usize,
    /// Delete character before cursor (backspace)
    delete_before: usize,
    /// Delete character at cursor (delete key)
    delete_at: usize,
    /// Insert character at cursor
    insert_char: struct {
        cursor: usize,
        char: u21,
    },
};

/// InputField widget for single-line text entry
pub const InputField = struct {
    /// Current text content (owned by external Model)
    text: []const u8,
    /// Cursor position in bytes (not display columns)
    cursor: usize = 0,
    /// Scroll offset for horizontal scrolling (display column offset)
    scroll_offset: u16 = 0,
    /// Placeholder text shown when empty and unfocused
    placeholder: ?[]const u8 = null,
    /// Text style
    text_style: Style = .{},
    /// Placeholder style
    placeholder_style: Style = .{ .fg = .{ .index = 8 } }, // Gray
    /// Cursor style
    cursor_style: Style = .{ .attrs = .{ .reverse = true } },
    /// Widget state
    widget_state: Widget.WidgetState = .{},
    /// Callback context
    callback_ctx: ?*anyopaque = null,
    /// Called when an edit action occurs (ctx, action)
    on_edit: ?*const fn (ctx: ?*anyopaque, action: EditAction) void = null,
    /// Called when Enter is pressed (ctx, text)
    on_submit: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,

    /// Initialize an InputField with text content
    pub fn init(text: []const u8) InputField {
        return .{
            .text = text,
            .cursor = text.len,
        };
    }

    /// Set cursor position
    pub fn withCursor(self: *InputField, cursor: usize) *InputField {
        self.cursor = @min(cursor, self.text.len);
        return self;
    }

    /// Set scroll offset
    pub fn withScrollOffset(self: *InputField, offset: u16) *InputField {
        self.scroll_offset = offset;
        return self;
    }

    /// Set placeholder text
    pub fn withPlaceholder(self: *InputField, placeholder: []const u8) *InputField {
        self.placeholder = placeholder;
        return self;
    }

    /// Set text style
    pub fn withTextStyle(self: *InputField, style: Style) *InputField {
        self.text_style = style;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *InputField, state: Widget.WidgetState) *InputField {
        self.widget_state = state;
        return self;
    }

    /// Set edit callback
    pub fn withOnEdit(self: *InputField, callback: *const fn (ctx: ?*anyopaque, action: EditAction) void, ctx: ?*anyopaque) *InputField {
        self.on_edit = callback;
        self.callback_ctx = ctx;
        return self;
    }

    /// Set submit callback
    pub fn withOnSubmit(self: *InputField, callback: *const fn (ctx: ?*anyopaque, text: []const u8) void, ctx: ?*anyopaque) *InputField {
        self.on_submit = callback;
        if (self.callback_ctx == null) self.callback_ctx = ctx;
        return self;
    }

    /// Get the display width of text up to a byte position
    fn displayWidthUpTo(text: []const u8, byte_pos: usize) u16 {
        const slice = text[0..@min(byte_pos, text.len)];
        return @intCast(@min(unicode.stringWidth(slice), std.math.maxInt(u16)));
    }

    /// Get byte position from display column.
    /// Returns 0 if text is invalid UTF-8.
    fn bytePositionFromColumn(text: []const u8, target_col: u16) usize {
        var col: u16 = 0;
        var byte_pos: usize = 0;
        const view = std.unicode.Utf8View.init(text) catch return 0;
        var iter = view.iterator();
        while (iter.nextCodepoint()) |cp| {
            if (col >= target_col) break;
            const char_width: u16 = @intCast(unicode.codePointWidth(cp));
            col += char_width;
            byte_pos = iter.i;
        }
        return byte_pos;
    }

    /// Find the start of the previous character (for cursor left)
    fn prevCharBoundary(text: []const u8, pos: usize) usize {
        if (pos == 0) return 0;
        var i = pos - 1;
        // Walk back through UTF-8 continuation bytes
        while (i > 0 and (text[i] & 0xC0) == 0x80) {
            i -= 1;
        }
        return i;
    }

    /// Find the start of the next character (for cursor right)
    fn nextCharBoundary(text: []const u8, pos: usize) usize {
        if (pos >= text.len) return text.len;
        var i = pos + 1;
        // Walk forward through UTF-8 continuation bytes
        while (i < text.len and (text[i] & 0xC0) == 0x80) {
            i += 1;
        }
        return i;
    }

    /// Measure the input field's preferred size
    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *InputField = @ptrCast(@alignCast(ptr));

        // Prefer full width, at least enough for placeholder or some minimum
        var min_width: u16 = 10;
        if (self.placeholder) |ph| {
            min_width = @max(min_width, @as(u16, @intCast(@min(unicode.stringWidth(ph), std.math.maxInt(u16)))));
        }

        return constraint.clamp(.{
            .width = @max(min_width, constraint.max_width),
            .height = 1,
        });
    }

    /// Render the input field
    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *InputField = @ptrCast(@alignCast(ptr));

        const view_size = view.size();
        if (view_size.height == 0 or view_size.width == 0) return;

        const theme = Theme.default;
        const text_style = theme.styleForState(self.text_style, self.widget_state);
        const placeholder_style = theme.styleForState(self.placeholder_style, self.widget_state);

        // Show placeholder if empty and not focused
        if (self.text.len == 0 and !self.widget_state.focused) {
            if (self.placeholder) |ph| {
                view.print(0, 0, ph, placeholder_style.fg, placeholder_style.bg, placeholder_style.attrs);
            }
            return;
        }

        // Calculate cursor display position
        const cursor_col = displayWidthUpTo(self.text, self.cursor);

        // Adjust scroll to keep cursor visible and persist the change
        if (cursor_col < self.scroll_offset) {
            self.scroll_offset = cursor_col;
        } else if (cursor_col >= self.scroll_offset + view_size.width) {
            self.scroll_offset = cursor_col - view_size.width + 1;
        }
        const scroll = self.scroll_offset;

        // Render text with scrolling
        var col: i32 = 0;
        var display_col: u16 = 0;
        // Use safe UTF-8 validation; if invalid, skip rendering text
        const utf8_view = std.unicode.Utf8View.init(self.text) catch return;
        var iter = utf8_view.iterator();
        var byte_pos: usize = 0;

        while (iter.nextCodepoint()) |cp| {
            const char_width: u16 = @intCast(unicode.codePointWidth(cp));

            // Skip characters before scroll offset
            if (display_col + char_width <= scroll) {
                display_col += char_width;
                byte_pos = iter.i;
                continue;
            }

            // Stop if past visible area
            if (col >= view_size.width) break;

            // Determine if cursor is at this position
            const is_cursor = self.widget_state.focused and byte_pos == self.cursor;

            // Choose style
            const style = if (is_cursor) self.cursor_style else text_style;

            // Render character
            const render_col = col - @as(i32, @intCast(scroll)) + @as(i32, @intCast(display_col));
            if (render_col >= 0 and render_col < view_size.width) {
                const cell = Cell{
                    .char = cp,
                    .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                    .fg = style.fg,
                    .bg = style.bg,
                    .attrs = style.attrs,
                };
                view.setCell(render_col, 0, cell);

                // Handle wide characters
                if (char_width == 2 and render_col + 1 < view_size.width) {
                    const cont_cell = Cell{
                        .char = Cell.WIDE_CONTINUATION,
                        .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                        .fg = style.fg,
                        .bg = style.bg,
                        .attrs = style.attrs,
                    };
                    view.setCell(render_col + 1, 0, cont_cell);
                }
            }

            col += @intCast(char_width);
            display_col += char_width;
            byte_pos = iter.i;
        }

        // Render cursor at end of text if focused
        if (self.widget_state.focused and self.cursor >= self.text.len) {
            const cursor_render_col: i32 = @as(i32, @intCast(cursor_col)) - @as(i32, @intCast(scroll));
            if (cursor_render_col >= 0 and cursor_render_col < view_size.width) {
                const cursor_cell = Cell{
                    .char = ' ',
                    .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                    .fg = self.cursor_style.fg,
                    .bg = self.cursor_style.bg,
                    .attrs = self.cursor_style.attrs,
                };
                view.setCell(cursor_render_col, 0, cursor_cell);
            }
        }
    }

    /// Handle keyboard events for text editing
    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *InputField = @ptrCast(@alignCast(ptr));

        if (self.widget_state.disabled or !self.widget_state.focused) {
            return .ignored;
        }

        switch (event) {
            .key => |key| {
                // Handle special keys
                if (key.special) |special| {
                    switch (special) {
                        .left => {
                            if (self.cursor > 0) {
                                const new_cursor = prevCharBoundary(self.text, self.cursor);
                                self.cursor = new_cursor;
                                if (self.on_edit) |callback| {
                                    callback(self.callback_ctx, .{ .cursor_move = self.cursor });
                                }
                            }
                            return .consumed;
                        },
                        .right => {
                            if (self.cursor < self.text.len) {
                                const new_cursor = nextCharBoundary(self.text, self.cursor);
                                self.cursor = new_cursor;
                                if (self.on_edit) |callback| {
                                    callback(self.callback_ctx, .{ .cursor_move = self.cursor });
                                }
                            }
                            return .consumed;
                        },
                        .home => {
                            self.cursor = 0;
                            if (self.on_edit) |callback| {
                                callback(self.callback_ctx, .{ .cursor_move = self.cursor });
                            }
                            return .consumed;
                        },
                        .end => {
                            self.cursor = self.text.len;
                            if (self.on_edit) |callback| {
                                callback(self.callback_ctx, .{ .cursor_move = self.cursor });
                            }
                            return .consumed;
                        },
                        .enter => {
                            if (self.on_submit) |callback| {
                                callback(self.callback_ctx, self.text);
                            }
                            return .consumed;
                        },
                        .backspace => {
                            if (self.cursor > 0) {
                                const prev = prevCharBoundary(self.text, self.cursor);
                                if (self.on_edit) |callback| {
                                    callback(self.callback_ctx, .{ .delete_before = self.cursor });
                                }
                                self.cursor = prev;
                            }
                            return .consumed;
                        },
                        .delete => {
                            if (self.cursor < self.text.len) {
                                if (self.on_edit) |callback| {
                                    callback(self.callback_ctx, .{ .delete_at = self.cursor });
                                }
                            }
                            return .consumed;
                        },
                        else => return .ignored,
                    }
                }

                // Handle regular character input
                if (key.codepoint) |cp| {
                    // Filter non-printable characters
                    if (cp >= 32 and cp != 127) {
                        if (self.on_edit) |callback| {
                            callback(self.callback_ctx, .{ .insert_char = .{ .cursor = self.cursor, .char = cp } });
                        }
                        return .consumed;
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

test "InputField init" {
    const field = InputField.init("Hello");
    try std.testing.expectEqualStrings("Hello", field.text);
    try std.testing.expectEqual(@as(usize, 5), field.cursor);
}

test "InputField with cursor" {
    var field = InputField.init("Hello");
    _ = field.withCursor(2);
    try std.testing.expectEqual(@as(usize, 2), field.cursor);
}

test "InputField cursor clamps to text length" {
    var field = InputField.init("Hi");
    _ = field.withCursor(100);
    try std.testing.expectEqual(@as(usize, 2), field.cursor);
}

test "InputField builder pattern" {
    var field = InputField.init("Test");
    _ = field.withPlaceholder("Enter text...")
        .withState(.{ .focused = true });

    try std.testing.expectEqualStrings("Enter text...", field.placeholder.?);
    try std.testing.expect(field.widget_state.focused);
}

test "InputField measure" {
    var field = InputField.init("Hello World");
    const widget = Widget.Widget.init(InputField, &field);

    const measured = widget.measure(Widget.SizeConstraint.atMost(40, 1));
    try std.testing.expectEqual(@as(u16, 40), measured.width);
    try std.testing.expectEqual(@as(u16, 1), measured.height);
}

test "InputField displayWidthUpTo ASCII" {
    const width = InputField.displayWidthUpTo("Hello", 3);
    try std.testing.expectEqual(@as(u16, 3), width);
}

test "InputField displayWidthUpTo UTF-8" {
    // "中文" = 2 chars, each width 2
    const width = InputField.displayWidthUpTo("中文", 6); // 6 bytes for 2 chars
    try std.testing.expectEqual(@as(u16, 4), width);
}

test "InputField prevCharBoundary ASCII" {
    const text = "Hello";
    try std.testing.expectEqual(@as(usize, 2), InputField.prevCharBoundary(text, 3));
    try std.testing.expectEqual(@as(usize, 0), InputField.prevCharBoundary(text, 0));
}

test "InputField prevCharBoundary UTF-8" {
    const text = "中文"; // 6 bytes: 3 + 3
    try std.testing.expectEqual(@as(usize, 0), InputField.prevCharBoundary(text, 3));
    try std.testing.expectEqual(@as(usize, 3), InputField.prevCharBoundary(text, 6));
}

test "InputField nextCharBoundary ASCII" {
    const text = "Hello";
    try std.testing.expectEqual(@as(usize, 3), InputField.nextCharBoundary(text, 2));
    try std.testing.expectEqual(@as(usize, 5), InputField.nextCharBoundary(text, 5));
}

test "InputField nextCharBoundary UTF-8" {
    const text = "中文"; // 6 bytes: 3 + 3
    try std.testing.expectEqual(@as(usize, 3), InputField.nextCharBoundary(text, 0));
    try std.testing.expectEqual(@as(usize, 6), InputField.nextCharBoundary(text, 3));
}

test "InputField render with placeholder" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 1 });
    defer root.deinit();

    var view = PlaneView.init(root);
    var field = InputField.init("");
    _ = field.withPlaceholder("Type here...");
    // Not focused, so placeholder should show
    const widget = Widget.Widget.init(InputField, &field);

    widget.render(&view);

    try std.testing.expectEqual(@as(u21, 'T'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'y'), view.getCell(1, 0).?.char);
}

test "InputField render with text" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 1 });
    defer root.deinit();

    var view = PlaneView.init(root);
    var field = InputField.init("Hello");
    _ = field.withCursor(0);
    const widget = Widget.Widget.init(InputField, &field);

    widget.render(&view);

    try std.testing.expectEqual(@as(u21, 'H'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'e'), view.getCell(1, 0).?.char);
}

test "InputField handle left arrow" {
    var field = InputField.init("Hello");
    _ = field.withCursor(3).withState(.{ .focused = true });

    const widget = Widget.Widget.init(InputField, &field);
    const event = Event.Event{ .key = Event.Key.fromSpecial(.left, .{}) };

    const result = widget.handleEvent(event);
    try std.testing.expectEqual(Widget.EventResult.consumed, result);
    try std.testing.expectEqual(@as(usize, 2), field.cursor);
}

test "InputField handle right arrow" {
    var field = InputField.init("Hello");
    _ = field.withCursor(2).withState(.{ .focused = true });

    const widget = Widget.Widget.init(InputField, &field);
    const event = Event.Event{ .key = Event.Key.fromSpecial(.right, .{}) };

    const result = widget.handleEvent(event);
    try std.testing.expectEqual(Widget.EventResult.consumed, result);
    try std.testing.expectEqual(@as(usize, 3), field.cursor);
}

test "InputField handle home key" {
    var field = InputField.init("Hello");
    _ = field.withCursor(3).withState(.{ .focused = true });

    const widget = Widget.Widget.init(InputField, &field);
    const event = Event.Event{ .key = Event.Key.fromSpecial(.home, .{}) };

    const result = widget.handleEvent(event);
    try std.testing.expectEqual(Widget.EventResult.consumed, result);
    try std.testing.expectEqual(@as(usize, 0), field.cursor);
}

test "InputField handle end key" {
    var field = InputField.init("Hello");
    _ = field.withCursor(0).withState(.{ .focused = true });

    const widget = Widget.Widget.init(InputField, &field);
    const event = Event.Event{ .key = Event.Key.fromSpecial(.end, .{}) };

    const result = widget.handleEvent(event);
    try std.testing.expectEqual(Widget.EventResult.consumed, result);
    try std.testing.expectEqual(@as(usize, 5), field.cursor);
}

test "InputField handle enter with callback" {
    var field = InputField.init("Hello");
    _ = field.withState(.{ .focused = true });

    var submitted = false;
    const callback = struct {
        fn call(ctx: ?*anyopaque, _: []const u8) void {
            if (ctx) |ptr| {
                const s: *bool = @ptrCast(@alignCast(ptr));
                s.* = true;
            }
        }
    }.call;

    _ = field.withOnSubmit(callback, @ptrCast(&submitted));

    const widget = Widget.Widget.init(InputField, &field);
    const event = Event.Event{ .key = Event.Key.fromSpecial(.enter, .{}) };

    const result = widget.handleEvent(event);
    try std.testing.expectEqual(Widget.EventResult.consumed, result);
    try std.testing.expect(submitted);
}

test "InputField ignores events when not focused" {
    var field = InputField.init("Hello");
    // Not focused

    const widget = Widget.Widget.init(InputField, &field);
    const event = Event.Event{ .key = Event.Key.fromSpecial(.left, .{}) };

    const result = widget.handleEvent(event);
    try std.testing.expectEqual(Widget.EventResult.ignored, result);
}

test "InputField ignores events when disabled" {
    var field = InputField.init("Hello");
    _ = field.withState(.{ .focused = true, .disabled = true });

    const widget = Widget.Widget.init(InputField, &field);
    const event = Event.Event{ .key = Event.Key.fromSpecial(.left, .{}) };

    const result = widget.handleEvent(event);
    try std.testing.expectEqual(Widget.EventResult.ignored, result);
}

test "InputField scroll_offset persists across renders" {
    const allocator = std.testing.allocator;
    // Create a narrow view (5 chars wide)
    const root = try Plane.initRoot(allocator, .{ .width = 5, .height = 1 });
    defer root.deinit();

    var view = PlaneView.init(root);
    // "Hello World" = 11 chars, cursor at end
    var field = InputField.init("Hello World");
    _ = field.withCursor(11).withState(.{ .focused = true });
    const widget = Widget.Widget.init(InputField, &field);

    // Initial scroll_offset is 0
    try std.testing.expectEqual(@as(u16, 0), field.scroll_offset);

    // After render, scroll_offset should be adjusted to show cursor
    widget.render(&view);

    // cursor_col = 11, view_width = 5
    // scroll should be: 11 - 5 + 1 = 7
    try std.testing.expectEqual(@as(u16, 7), field.scroll_offset);

    // Re-render should preserve scroll_offset (not reset to 0)
    widget.render(&view);
    try std.testing.expectEqual(@as(u16, 7), field.scroll_offset);
}
