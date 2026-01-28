//! TextArea: Multi-line text input widget
//!
//! A multi-line text editor with cursor navigation, selection, and scrolling.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const Event = @import("../Event.zig");
const unicode = @import("../unicode/width.zig");
const TextBuffer = @import("../text/TextBuffer.zig").TextBuffer;

/// TextArea widget for multi-line editing
pub const TextArea = struct {
    /// Text content buffer
    buffer: TextBuffer,
    /// Allocator for dynamic content
    allocator: std.mem.Allocator,
    /// Cursor position
    cursor_line: usize = 0,
    cursor_col: usize = 0,
    /// Scroll offset
    scroll_y: usize = 0,
    scroll_x: usize = 0,
    /// Visible dimensions
    visible_width: u16 = 40,
    visible_height: u16 = 10,
    /// Show line numbers
    show_line_numbers: bool = false,
    /// Text style
    style: Style = .{},
    /// Cursor style
    cursor_style: Style = .{ .attrs = .{ .reverse = true } },
    /// Line number style
    line_number_style: Style = .{ .fg = .{ .index = 8 } },
    /// Widget state
    widget_state: Widget.WidgetState = .{},
    /// Read-only mode
    read_only: bool = false,
    /// Change callback
    on_change: ?*const fn (ctx: ?*anyopaque) void = null,
    /// Callback context
    callback_ctx: ?*anyopaque = null,

    /// Create an empty text area
    pub fn init(allocator: std.mem.Allocator) !TextArea {
        const buffer = try TextBuffer.init(allocator);

        return .{
            .buffer = buffer,
            .allocator = allocator,
        };
    }

    /// Create a text area with initial content
    pub fn initWithContent(allocator: std.mem.Allocator, content: []const u8) !TextArea {
        var ta = try init(allocator);
        try ta.setText(content);
        return ta;
    }

    /// Clean up resources
    pub fn deinit(self: *TextArea) void {
        self.buffer.deinit();
    }

    // Builder methods

    /// Set visible dimensions
    pub fn withSize(self: *TextArea, width: u16, height: u16) *TextArea {
        self.visible_width = width;
        self.visible_height = height;
        return self;
    }

    /// Set line numbers visibility
    pub fn withLineNumbers(self: *TextArea, show: bool) *TextArea {
        self.show_line_numbers = show;
        return self;
    }

    /// Set read-only mode
    pub fn withReadOnly(self: *TextArea, read_only: bool) *TextArea {
        self.read_only = read_only;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *TextArea, state: Widget.WidgetState) *TextArea {
        self.widget_state = state;
        return self;
    }

    /// Set change callback
    pub fn withOnChange(self: *TextArea, callback: *const fn (ctx: ?*anyopaque) void, ctx: ?*anyopaque) *TextArea {
        self.on_change = callback;
        self.callback_ctx = ctx;
        return self;
    }

    // Content methods

    /// Set text content (replaces all)
    /// Note: Bypasses read_only to allow programmatic updates (e.g., history navigation)
    /// Use setTextForced for explicit bypass, or check read_only at the call site if needed.
    pub fn setText(self: *TextArea, content: []const u8) !void {
        try self.buffer.setText(content);

        self.cursor_line = 0;
        self.cursor_col = 0;
        self.scroll_y = 0;
        self.scroll_x = 0;
    }

    /// Get text content
    pub fn getText(self: *const TextArea, allocator: std.mem.Allocator) ![]u8 {
        return self.buffer.getText(allocator);
    }

    /// Get line count
    pub fn lineCount(self: *const TextArea) usize {
        return self.buffer.lineCount();
    }

    /// Check if cursor is on the first line
    pub fn isOnFirstLine(self: *const TextArea) bool {
        return self.cursor_line == 0;
    }

    /// Check if cursor is on the last line
    pub fn isOnLastLine(self: *const TextArea) bool {
        return self.cursor_line + 1 >= self.buffer.lineCount();
    }

    /// Check if content is empty
    pub fn isEmpty(self: *const TextArea) bool {
        return self.buffer.lineCount() == 0 or
            (self.buffer.lineCount() == 1 and self.buffer.lineLen(0) == 0);
    }

    /// Clear all content
    pub fn clear(self: *TextArea) !void {
        try self.buffer.clear();
        self.cursor_line = 0;
        self.cursor_col = 0;
        self.scroll_y = 0;
        self.scroll_x = 0;
        self.notifyChange();
    }

    /// Kill text from cursor to end of line (Ctrl+K)
    pub fn killToEndOfLine(self: *TextArea) !void {
        if (self.read_only) return;
        if (self.cursor_line >= self.buffer.lineCount()) return;

        self.buffer.truncateLine(self.cursor_line, self.cursor_col) catch return;
        self.notifyChange();
    }

    /// Clear entire line content (Ctrl+U)
    pub fn clearLine(self: *TextArea) void {
        if (self.read_only) return;
        if (self.cursor_line >= self.buffer.lineCount()) return;

        self.buffer.clearLine(self.cursor_line) catch return;
        self.cursor_col = 0;
        self.notifyChange();
    }

    // Cursor methods

    /// Move cursor up
    pub fn cursorUp(self: *TextArea) void {
        if (self.cursor_line > 0) {
            self.cursor_line -= 1;
            self.clampCursorCol();
            self.ensureCursorVisible();
        }
    }

    /// Move cursor down
    pub fn cursorDown(self: *TextArea) void {
        if (self.cursor_line + 1 < self.buffer.lineCount()) {
            self.cursor_line += 1;
            self.clampCursorCol();
            self.ensureCursorVisible();
        }
    }

    /// Move cursor left (UTF-8 aware)
    pub fn cursorLeft(self: *TextArea) void {
        if (self.cursor_col > 0) {
            // Move back to start of previous UTF-8 codepoint
            const line = self.buffer.lineSlice(self.cursor_line);
            var i = self.cursor_col - 1;
            // Skip continuation bytes (10xxxxxx pattern)
            while (i > 0 and (line[i] & 0xC0) == 0x80) {
                i -= 1;
            }
            self.cursor_col = i;
        } else if (self.cursor_line > 0) {
            self.cursor_line -= 1;
            self.cursor_col = self.currentLineLen();
        }
        self.ensureCursorVisible();
    }

    /// Move cursor right (UTF-8 aware)
    pub fn cursorRight(self: *TextArea) void {
        const line_len = self.currentLineLen();
        if (self.cursor_col < line_len) {
            const line = self.buffer.lineSlice(self.cursor_line);
            // Decode codepoint length from lead byte and skip forward
            const lead = line[self.cursor_col];
            const cp_len = utf8CodepointLength(lead);
            self.cursor_col = @min(self.cursor_col + cp_len, line_len);
        } else if (self.cursor_line + 1 < self.buffer.lineCount()) {
            self.cursor_line += 1;
            self.cursor_col = 0;
        }
        self.ensureCursorVisible();
    }

    /// Get the length of a UTF-8 codepoint from its lead byte
    fn utf8CodepointLength(lead: u8) usize {
        if (lead < 0x80) return 1; // ASCII
        if (lead & 0xE0 == 0xC0) return 2; // 110xxxxx
        if (lead & 0xF0 == 0xE0) return 3; // 1110xxxx
        if (lead & 0xF8 == 0xF0) return 4; // 11110xxx
        return 1; // Invalid, treat as single byte
    }

    /// Find the start of the UTF-8 codepoint at or before the given byte position
    fn findCodepointStart(line: []const u8, pos: usize) usize {
        if (pos == 0) return 0;
        // End of line is always a valid codepoint boundary
        if (pos >= line.len) return line.len;
        var i = pos;
        // If we're in the middle of a codepoint, back up to its start
        while (i > 0 and (line[i] & 0xC0) == 0x80) {
            i -= 1;
        }
        return i;
    }

    /// Calculate display width (columns) for text up to a byte position
    fn displayWidthUpTo(text: []const u8, byte_pos: usize) u16 {
        const slice = text[0..@min(byte_pos, text.len)];
        return @intCast(@min(unicode.stringWidth(slice), std.math.maxInt(u16)));
    }

    /// Find byte position for a target display column.
    /// Returns the byte index where display width reaches or exceeds target_col.
    /// Always returns a valid codepoint boundary.
    fn byteIndexForDisplayColumn(text: []const u8, target_col: usize) usize {
        if (target_col == 0) return 0;
        var byte_pos: usize = 0;
        var display_col: usize = 0;
        var iter = std.unicode.Utf8View.initUnchecked(text).iterator();
        while (iter.nextCodepoint()) |cp| {
            if (display_col >= target_col) break;
            const cp_width = unicode.codePointWidth(cp);
            display_col += cp_width;
            byte_pos = iter.i;
        }
        return byte_pos;
    }

    /// Decode a UTF-8 codepoint at the given byte position
    fn decodeCodepointAt(line: []const u8, pos: usize) u21 {
        if (pos >= line.len) return ' ';
        const len = std.unicode.utf8ByteSequenceLength(line[pos]) catch return line[pos];
        if (pos + len > line.len) return line[pos];
        return std.unicode.utf8Decode(line[pos..][0..len]) catch line[pos];
    }

    /// Move to start of line
    pub fn cursorHome(self: *TextArea) void {
        self.cursor_col = 0;
        self.ensureCursorVisible();
    }

    /// Move to end of line
    pub fn cursorEnd(self: *TextArea) void {
        self.cursor_col = self.currentLineLen();
        self.ensureCursorVisible();
    }

    fn currentLineLen(self: *const TextArea) usize {
        if (self.cursor_line < self.buffer.lineCount()) {
            return self.buffer.lineLen(self.cursor_line);
        }
        return 0;
    }

    /// Clamp cursor column to valid position within current line.
    /// Ensures cursor lands on a valid UTF-8 codepoint boundary.
    fn clampCursorCol(self: *TextArea) void {
        const line_len = self.currentLineLen();
        if (self.cursor_col > line_len) {
            self.cursor_col = line_len;
        }
        // Ensure cursor is on a valid UTF-8 codepoint boundary
        if (self.cursor_col > 0 and self.cursor_line < self.buffer.lineCount()) {
            const line = self.buffer.lineSlice(self.cursor_line);
            self.cursor_col = findCodepointStart(line, self.cursor_col);
        }
    }

    fn ensureCursorVisible(self: *TextArea) void {
        // Vertical scroll
        if (self.cursor_line < self.scroll_y) {
            self.scroll_y = self.cursor_line;
        } else if (self.cursor_line >= self.scroll_y + self.visible_height) {
            self.scroll_y = self.cursor_line - self.visible_height + 1;
        }

        // Horizontal scroll - work in display columns, then convert back to bytes
        const text_width = if (self.show_line_numbers) self.visible_width -| 5 else self.visible_width;
        if (self.cursor_line >= self.buffer.lineCount()) return;
        const line = self.buffer.lineSlice(self.cursor_line);

        // Convert byte positions to display columns for comparison
        const cursor_display_col = displayWidthUpTo(line, self.cursor_col);
        const scroll_display_col = displayWidthUpTo(line, self.scroll_x);

        if (cursor_display_col < scroll_display_col) {
            // Cursor is left of visible area - scroll left to cursor
            self.scroll_x = self.cursor_col;
        } else if (cursor_display_col >= scroll_display_col + text_width) {
            // Cursor is right of visible area - scroll right
            // Find the byte position where display width reaches (cursor_display_col - text_width + 1)
            const target_scroll_col = cursor_display_col - text_width + 1;
            self.scroll_x = byteIndexForDisplayColumn(line, target_scroll_col);
        }
    }

    // Editing methods

    /// Insert single-byte character at cursor
    pub fn insertChar(self: *TextArea, char: u8) !void {
        if (self.read_only) return;
        if (self.cursor_line >= self.buffer.lineCount()) return;

        try self.buffer.insertByte(self.cursor_line, self.cursor_col, char);
        self.cursor_col += 1;
        self.ensureCursorVisible();
        self.notifyChange();
    }

    /// Insert UTF-8 codepoint at cursor (supports multi-byte characters)
    pub fn insertCodepoint(self: *TextArea, codepoint: u21) !void {
        if (self.read_only) return;
        if (self.cursor_line >= self.buffer.lineCount()) return;

        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch return;
        try self.buffer.insertBytes(self.cursor_line, self.cursor_col, buf[0..len]);
        self.cursor_col += len;
        self.ensureCursorVisible();
        self.notifyChange();
    }

    /// Insert a string at cursor position
    pub fn insertString(self: *TextArea, str: []const u8) !void {
        if (self.read_only) return;
        if (self.cursor_line >= self.buffer.lineCount()) return;

        // Handle multi-line strings by splitting on newlines
        var iter = std.mem.splitScalar(u8, str, '\n');
        var first = true;
        while (iter.next()) |segment| {
            if (!first) {
                try self.insertNewline();
            }
            first = false;

            try self.buffer.insertBytes(self.cursor_line, self.cursor_col, segment);
            self.cursor_col += segment.len;
        }
        self.ensureCursorVisible();
        self.notifyChange();
    }

    /// Insert newline at cursor
    pub fn insertNewline(self: *TextArea) !void {
        if (self.read_only) return;
        if (self.cursor_line >= self.buffer.lineCount()) return;
        try self.buffer.splitLine(self.cursor_line, self.cursor_col);
        self.cursor_line += 1;
        self.cursor_col = 0;
        self.ensureCursorVisible();
        self.notifyChange();
    }

    /// Delete character before cursor (backspace) - UTF-8 aware
    pub fn deleteBack(self: *TextArea) !void {
        if (self.read_only) return;
        if (self.cursor_line >= self.buffer.lineCount()) return;

        if (self.cursor_col > 0) {
            const line = self.buffer.lineSlice(self.cursor_line);
            // Find start of previous codepoint
            var start = self.cursor_col - 1;
            while (start > 0 and (line[start] & 0xC0) == 0x80) {
                start -= 1;
            }
            // Remove all bytes of the codepoint
            const cp_len = self.cursor_col - start;
            try self.buffer.deleteRangeInLine(self.cursor_line, start, cp_len);
            self.cursor_col = start;
        } else if (self.cursor_line > 0) {
            // Merge with previous line
            const prev_len = try self.buffer.mergeLineWithPrevious(self.cursor_line);
            self.cursor_line -= 1;
            self.cursor_col = prev_len;
        }
        self.ensureCursorVisible();
        self.notifyChange();
    }

    /// Delete character at cursor (forward delete) - UTF-8 aware
    pub fn deleteForward(self: *TextArea) !void {
        if (self.read_only) return;
        if (self.cursor_line >= self.buffer.lineCount()) return;

        const line = self.buffer.lineSlice(self.cursor_line);
        if (self.cursor_col < line.len) {
            // Get length of codepoint at cursor
            const lead = line[self.cursor_col];
            const cp_len = utf8CodepointLength(lead);
            // Remove all bytes of the codepoint
            if (self.cursor_col < line.len) {
                try self.buffer.deleteRangeInLine(self.cursor_line, self.cursor_col, cp_len);
            }
        } else if (self.cursor_line + 1 < self.buffer.lineCount()) {
            // Merge with next line
            try self.buffer.mergeLineWithNext(self.cursor_line);
        }
        self.notifyChange();
    }

    fn notifyChange(self: *TextArea) void {
        if (self.on_change) |callback| {
            callback(self.callback_ctx);
        }
    }

    // Widget interface

    fn measure(ptr: *anyopaque, _: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *TextArea = @ptrCast(@alignCast(ptr));
        return .{
            .width = self.visible_width,
            .height = self.visible_height,
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *TextArea = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0) return;

        const line_num_width: u16 = if (self.show_line_numbers) 5 else 0;
        const text_start_x = line_num_width;

        var y: u16 = 0;
        while (y < size.height) : (y += 1) {
            const line_idx = self.scroll_y + y;

            // Clear line
            var x: i32 = 0;
            while (x < size.width) : (x += 1) {
                view.setCell(x, @intCast(y), .{
                    .char = ' ',
                    .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                    .fg = self.style.fg,
                    .bg = self.style.bg,
                    .attrs = .{},
                });
            }

            // Draw line number
            if (self.show_line_numbers and line_idx < self.buffer.lineCount()) {
                var num_buf: [8]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d:>4} ", .{line_idx + 1}) catch "???? ";
                view.print(0, @intCast(y), num_str, self.line_number_style.fg, self.line_number_style.bg, .{});
            }

            // Draw line content
            if (line_idx < self.buffer.lineCount()) {
                const line = self.buffer.lineSlice(line_idx);
                // scroll_x is always on a valid codepoint boundary (enforced by ensureCursorVisible)
                const start_byte = @min(self.scroll_x, line.len);

                if (start_byte < line.len) {
                    // Pass the rest of the line from scroll position; PlaneView.print clips to view bounds
                    view.print(@intCast(text_start_x), @intCast(y), line[start_byte..], self.style.fg, self.style.bg, self.style.attrs);
                }

                // Draw cursor
                if (self.widget_state.focused and line_idx == self.cursor_line) {
                    // Calculate display width up to cursor position (not byte offset)
                    const cursor_display_col = displayWidthUpTo(line, self.cursor_col);
                    const scroll_display_col = displayWidthUpTo(line, self.scroll_x);
                    const cursor_x = text_start_x + cursor_display_col -| scroll_display_col;
                    if (cursor_x < size.width) {
                        // Decode the actual codepoint at cursor position
                        const cursor_char: u21 = decodeCodepointAt(line, self.cursor_col);
                        view.setCell(@intCast(cursor_x), @intCast(y), .{
                            .char = cursor_char,
                            .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                            .fg = self.cursor_style.fg,
                            .bg = self.cursor_style.bg,
                            .attrs = self.cursor_style.attrs,
                        });
                    }
                }
            }
        }
    }

    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *TextArea = @ptrCast(@alignCast(ptr));

        if (self.widget_state.disabled) {
            return .ignored;
        }

        switch (event) {
            .key => |key| {
                // Navigation
                if (key.special == .up) {
                    self.cursorUp();
                    return .consumed;
                } else if (key.special == .down) {
                    self.cursorDown();
                    return .consumed;
                } else if (key.special == .left) {
                    self.cursorLeft();
                    return .consumed;
                } else if (key.special == .right) {
                    self.cursorRight();
                    return .consumed;
                } else if (key.special == .home) {
                    self.cursorHome();
                    return .consumed;
                } else if (key.special == .end) {
                    self.cursorEnd();
                    return .consumed;
                }
                // Editing
                else if (key.special == .enter) {
                    self.insertNewline() catch {};
                    return .consumed;
                } else if (key.special == .backspace) {
                    self.deleteBack() catch {};
                    return .consumed;
                } else if (key.special == .delete) {
                    self.deleteForward() catch {};
                    return .consumed;
                }
                // Character input
                else if (key.codepoint) |cp| {
                    if (cp >= 0x20 and cp < 0x7F) {
                        self.insertChar(@intCast(cp)) catch {};
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

test "TextArea init" {
    var ta = try TextArea.init(std.testing.allocator);
    defer ta.deinit();

    try std.testing.expectEqual(@as(usize, 1), ta.lineCount());
    try std.testing.expectEqual(@as(usize, 0), ta.cursor_line);
    try std.testing.expectEqual(@as(usize, 0), ta.cursor_col);
}

test "TextArea setText" {
    var ta = try TextArea.init(std.testing.allocator);
    defer ta.deinit();

    try ta.setText("Line 1\nLine 2\nLine 3");
    try std.testing.expectEqual(@as(usize, 3), ta.lineCount());
}

test "TextArea getText" {
    var ta = try TextArea.init(std.testing.allocator);
    defer ta.deinit();

    try ta.setText("Hello\nWorld");
    const text = try ta.getText(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("Hello\nWorld", text);
}

test "TextArea cursor navigation" {
    var ta = try TextArea.init(std.testing.allocator);
    defer ta.deinit();

    try ta.setText("ABC\nDEF");

    ta.cursorRight();
    try std.testing.expectEqual(@as(usize, 1), ta.cursor_col);

    ta.cursorDown();
    try std.testing.expectEqual(@as(usize, 1), ta.cursor_line);

    ta.cursorEnd();
    try std.testing.expectEqual(@as(usize, 3), ta.cursor_col);

    ta.cursorHome();
    try std.testing.expectEqual(@as(usize, 0), ta.cursor_col);
}

test "TextArea insert char" {
    var ta = try TextArea.init(std.testing.allocator);
    defer ta.deinit();

    try ta.insertChar('A');
    try ta.insertChar('B');

    const text = try ta.getText(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("AB", text);
}

test "TextArea insert newline" {
    var ta = try TextArea.init(std.testing.allocator);
    defer ta.deinit();

    try ta.insertChar('A');
    try ta.insertNewline();
    try ta.insertChar('B');

    try std.testing.expectEqual(@as(usize, 2), ta.lineCount());
}

test "TextArea backspace" {
    var ta = try TextArea.init(std.testing.allocator);
    defer ta.deinit();

    try ta.insertChar('A');
    try ta.insertChar('B');
    try ta.deleteBack();

    const text = try ta.getText(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("A", text);
}

test "TextArea measure" {
    var ta = try TextArea.init(std.testing.allocator);
    defer ta.deinit();
    _ = ta.withSize(30, 10);

    const widget = Widget.Widget.init(TextArea, &ta);
    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));

    try std.testing.expectEqual(@as(u16, 30), measured.width);
    try std.testing.expectEqual(@as(u16, 10), measured.height);
}

test "TextArea render" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 5 });
    defer root.deinit();

    var ta = try TextArea.init(allocator);
    defer ta.deinit();
    try ta.setText("Hello");
    ta.widget_state.focused = true;

    const widget = Widget.Widget.init(TextArea, &ta);

    var view = PlaneView.init(root);
    widget.render(&view);

    try std.testing.expectEqual(@as(u21, 'H'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'e'), view.getCell(1, 0).?.char);
}

test "TextArea insertCodepoint" {
    var ta = try TextArea.init(std.testing.allocator);
    defer ta.deinit();

    try ta.insertCodepoint('H');
    try ta.insertCodepoint('é'); // multi-byte
    try ta.insertCodepoint('!');

    const text = try ta.getText(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("Hé!", text);
}

test "TextArea insertString with newlines" {
    var ta = try TextArea.init(std.testing.allocator);
    defer ta.deinit();

    try ta.insertString("Line1\nLine2\nLine3");

    try std.testing.expectEqual(@as(usize, 3), ta.lineCount());

    const text = try ta.getText(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("Line1\nLine2\nLine3", text);
}

test "TextArea clear" {
    var ta = try TextArea.init(std.testing.allocator);
    defer ta.deinit();

    try ta.insertString("Hello\nWorld");
    try std.testing.expectEqual(@as(usize, 2), ta.lineCount());
    try std.testing.expect(!ta.isEmpty());

    try ta.clear();
    try std.testing.expectEqual(@as(usize, 1), ta.lineCount());
    try std.testing.expect(ta.isEmpty());
}

test "TextArea cursor position checks" {
    var ta = try TextArea.init(std.testing.allocator);
    defer ta.deinit();

    try ta.insertString("Line1\nLine2\nLine3");

    // Start at line 0
    ta.cursor_line = 0;
    try std.testing.expect(ta.isOnFirstLine());
    try std.testing.expect(!ta.isOnLastLine());

    // Move to last line
    ta.cursor_line = 2;
    try std.testing.expect(!ta.isOnFirstLine());
    try std.testing.expect(ta.isOnLastLine());
}

test "TextArea killToEndOfLine" {
    var ta = try TextArea.init(std.testing.allocator);
    defer ta.deinit();

    try ta.insertString("Hello World");
    ta.cursor_col = 5; // After "Hello"
    try ta.killToEndOfLine();

    const text = try ta.getText(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("Hello", text);
}

test "TextArea clearLine" {
    var ta = try TextArea.init(std.testing.allocator);
    defer ta.deinit();

    try ta.insertString("Line1\nLine2");
    ta.cursor_line = 0;
    ta.cursor_col = 3;
    ta.clearLine();

    try std.testing.expectEqual(@as(usize, 0), ta.cursor_col);
    try std.testing.expectEqual(@as(usize, 2), ta.lineCount());

    const text = try ta.getText(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("\nLine2", text);
}

test "TextArea UTF-8 cursor navigation" {
    var ta = try TextArea.init(std.testing.allocator);
    defer ta.deinit();

    // Insert multi-byte characters: "Hé!" where é is 2 bytes
    try ta.insertCodepoint('H'); // 1 byte
    try ta.insertCodepoint('é'); // 2 bytes (0xC3 0xA9)
    try ta.insertCodepoint('!'); // 1 byte

    // Cursor should be at byte position 4 (1 + 2 + 1)
    try std.testing.expectEqual(@as(usize, 4), ta.cursor_col);

    // Move left should skip the entire 'é' codepoint (2 bytes back)
    ta.cursorLeft();
    try std.testing.expectEqual(@as(usize, 3), ta.cursor_col); // After 'é'

    ta.cursorLeft();
    try std.testing.expectEqual(@as(usize, 1), ta.cursor_col); // After 'H', before 'é'

    ta.cursorLeft();
    try std.testing.expectEqual(@as(usize, 0), ta.cursor_col); // Start

    // Move right should skip entire codepoints
    ta.cursorRight();
    try std.testing.expectEqual(@as(usize, 1), ta.cursor_col); // After 'H'

    ta.cursorRight();
    try std.testing.expectEqual(@as(usize, 3), ta.cursor_col); // After 'é' (skipped 2 bytes)
}

test "TextArea UTF-8 backspace" {
    var ta = try TextArea.init(std.testing.allocator);
    defer ta.deinit();

    // Insert "Hé!" then delete 'é'
    try ta.insertCodepoint('H');
    try ta.insertCodepoint('é');
    try ta.insertCodepoint('!');

    // Cursor at end, delete '!'
    try ta.deleteBack();
    const text = try ta.getText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Hé", text);

    // Delete 'é' (should remove both bytes)
    try ta.deleteBack();
    const text2 = try ta.getText(std.testing.allocator);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings("H", text2);
    try std.testing.expectEqual(@as(usize, 1), ta.cursor_col);
}

test "TextArea UTF-8 3-byte characters (CJK)" {
    var ta = try TextArea.init(std.testing.allocator);
    defer ta.deinit();

    // Insert "A中B" where 中 is 3 bytes (U+4E2D = 0xE4 0xB8 0xAD)
    try ta.insertCodepoint('A'); // 1 byte
    try ta.insertCodepoint('中'); // 3 bytes
    try ta.insertCodepoint('B'); // 1 byte

    // Cursor should be at byte position 5 (1 + 3 + 1)
    try std.testing.expectEqual(@as(usize, 5), ta.cursor_col);

    // Move left should skip the entire 'B' (1 byte)
    ta.cursorLeft();
    try std.testing.expectEqual(@as(usize, 4), ta.cursor_col);

    // Move left should skip the entire '中' (3 bytes)
    ta.cursorLeft();
    try std.testing.expectEqual(@as(usize, 1), ta.cursor_col);

    // Delete '中' using forward delete
    try ta.deleteForward();
    const text = try ta.getText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("AB", text);
}

test "TextArea UTF-8 4-byte characters (emoji)" {
    var ta = try TextArea.init(std.testing.allocator);
    defer ta.deinit();

    // Insert "A😀B" where 😀 is 4 bytes (U+1F600 = 0xF0 0x9F 0x98 0x80)
    try ta.insertCodepoint('A'); // 1 byte
    try ta.insertCodepoint(0x1F600); // 4 bytes (grinning face emoji)
    try ta.insertCodepoint('B'); // 1 byte

    // Cursor should be at byte position 6 (1 + 4 + 1)
    try std.testing.expectEqual(@as(usize, 6), ta.cursor_col);

    // Backspace should remove 'B'
    try ta.deleteBack();
    try std.testing.expectEqual(@as(usize, 5), ta.cursor_col);

    // Backspace should remove entire emoji (4 bytes)
    try ta.deleteBack();
    try std.testing.expectEqual(@as(usize, 1), ta.cursor_col);

    const text = try ta.getText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("A", text);
}

test "TextArea UTF-8 vertical cursor movement" {
    var ta = try TextArea.init(std.testing.allocator);
    defer ta.deinit();

    // Set up: Line 0 = "abc", Line 1 = "éd" (é is 2 bytes)
    try ta.setText("abc\néd");

    // Move to position 2 on line 0
    ta.cursor_line = 0;
    ta.cursor_col = 2;

    // Move down - position 2 on line 1 would be inside 'é'
    // clampCursorCol should snap to codepoint boundary (position 0 or 2)
    ta.cursorDown();
    try std.testing.expectEqual(@as(usize, 1), ta.cursor_line);

    // Cursor should be on a valid codepoint boundary (0 or 2, not 1)
    const col = ta.cursor_col;
    try std.testing.expect(col == 0 or col == 2); // Either start of 'é' or start of 'd'

    // Verify we can safely insert without corruption
    try ta.insertCodepoint('X');
    const text = try ta.getText(std.testing.allocator);
    defer std.testing.allocator.free(text);

    // Text should be valid UTF-8 regardless of where cursor landed
    _ = std.unicode.Utf8View.init(text) catch |err| {
        std.debug.print("Invalid UTF-8 after insert: {}\n", .{err});
        return error.InvalidUtf8;
    };
}

test "TextArea displayWidthUpTo for cursor rendering" {
    // Test that display width calculation is correct for cursor positioning
    // "A中B" = 1 byte + 3 bytes + 1 byte = 5 bytes total
    // Display width: A(1) + 中(2) + B(1) = 4 columns
    const text = "A中B";

    // At position 0 (before 'A'), display width = 0
    try std.testing.expectEqual(@as(u16, 0), TextArea.displayWidthUpTo(text, 0));

    // At position 1 (after 'A'), display width = 1
    try std.testing.expectEqual(@as(u16, 1), TextArea.displayWidthUpTo(text, 1));

    // At position 4 (after '中'), display width = 3 (A=1 + 中=2)
    try std.testing.expectEqual(@as(u16, 3), TextArea.displayWidthUpTo(text, 4));

    // At position 5 (after 'B'), display width = 4 (A=1 + 中=2 + B=1)
    try std.testing.expectEqual(@as(u16, 4), TextArea.displayWidthUpTo(text, 5));
}

test "TextArea decodeCodepointAt" {
    // Test codepoint decoding for cursor character display
    const text = "A中B";

    // ASCII 'A' at position 0
    try std.testing.expectEqual(@as(u21, 'A'), TextArea.decodeCodepointAt(text, 0));

    // CJK '中' at position 1
    try std.testing.expectEqual(@as(u21, '中'), TextArea.decodeCodepointAt(text, 1));

    // ASCII 'B' at position 4
    try std.testing.expectEqual(@as(u21, 'B'), TextArea.decodeCodepointAt(text, 4));

    // End of text returns space
    try std.testing.expectEqual(@as(u21, ' '), TextArea.decodeCodepointAt(text, 5));
}

test "TextArea byteIndexForDisplayColumn" {
    // Test finding byte position for display column
    // "A中B" = A(1 byte, 1 col) + 中(3 bytes, 2 cols) + B(1 byte, 1 col)
    const text = "A中B";

    // Display column 0 -> byte 0
    try std.testing.expectEqual(@as(usize, 0), TextArea.byteIndexForDisplayColumn(text, 0));

    // Display column 1 -> byte 1 (after 'A')
    try std.testing.expectEqual(@as(usize, 1), TextArea.byteIndexForDisplayColumn(text, 1));

    // Display column 2 -> byte 4 (in middle of '中', so after '中')
    // Note: CJK '中' is 2 columns wide, so col 2 is still inside it
    try std.testing.expectEqual(@as(usize, 4), TextArea.byteIndexForDisplayColumn(text, 2));

    // Display column 3 -> byte 4 (after '中')
    try std.testing.expectEqual(@as(usize, 4), TextArea.byteIndexForDisplayColumn(text, 3));

    // Display column 4 -> byte 5 (after 'B', end of text)
    try std.testing.expectEqual(@as(usize, 5), TextArea.byteIndexForDisplayColumn(text, 4));
}
