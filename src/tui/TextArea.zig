//! TextArea: Multi-line text input widget
//!
//! A multi-line text editor with cursor navigation, selection, and scrolling.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const Event = @import("../Event.zig");

/// TextArea widget for multi-line editing
pub const TextArea = struct {
    /// Text content (lines)
    lines: std.ArrayList(std.ArrayList(u8)),
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
        var lines = std.ArrayList(std.ArrayList(u8)).init(allocator);
        // Start with one empty line
        const first_line = std.ArrayList(u8).init(allocator);
        try lines.append(first_line);

        return .{
            .lines = lines,
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
        for (self.lines.items) |*line| {
            line.deinit();
        }
        self.lines.deinit();
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
    pub fn setText(self: *TextArea, content: []const u8) !void {
        // Clear existing lines
        for (self.lines.items) |*line| {
            line.deinit();
        }
        self.lines.clearRetainingCapacity();

        // Split by newlines
        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line_content| {
            var new_line = std.ArrayList(u8).init(self.allocator);
            try new_line.appendSlice(line_content);
            try self.lines.append(new_line);
        }

        // Ensure at least one line
        if (self.lines.items.len == 0) {
            const empty = std.ArrayList(u8).init(self.allocator);
            try self.lines.append(empty);
        }

        self.cursor_line = 0;
        self.cursor_col = 0;
        self.scroll_y = 0;
        self.scroll_x = 0;
    }

    /// Get text content
    pub fn getText(self: *const TextArea, allocator: std.mem.Allocator) ![]u8 {
        var total_len: usize = 0;
        for (self.lines.items, 0..) |line, i| {
            total_len += line.items.len;
            if (i < self.lines.items.len - 1) total_len += 1; // newline
        }

        var result = try allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (self.lines.items, 0..) |line, i| {
            @memcpy(result[pos .. pos + line.items.len], line.items);
            pos += line.items.len;
            if (i < self.lines.items.len - 1) {
                result[pos] = '\n';
                pos += 1;
            }
        }

        return result;
    }

    /// Get line count
    pub fn lineCount(self: *const TextArea) usize {
        return self.lines.items.len;
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
        if (self.cursor_line + 1 < self.lines.items.len) {
            self.cursor_line += 1;
            self.clampCursorCol();
            self.ensureCursorVisible();
        }
    }

    /// Move cursor left
    pub fn cursorLeft(self: *TextArea) void {
        if (self.cursor_col > 0) {
            self.cursor_col -= 1;
        } else if (self.cursor_line > 0) {
            self.cursor_line -= 1;
            self.cursor_col = self.currentLineLen();
        }
        self.ensureCursorVisible();
    }

    /// Move cursor right
    pub fn cursorRight(self: *TextArea) void {
        const line_len = self.currentLineLen();
        if (self.cursor_col < line_len) {
            self.cursor_col += 1;
        } else if (self.cursor_line + 1 < self.lines.items.len) {
            self.cursor_line += 1;
            self.cursor_col = 0;
        }
        self.ensureCursorVisible();
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
        if (self.cursor_line < self.lines.items.len) {
            return self.lines.items[self.cursor_line].items.len;
        }
        return 0;
    }

    fn clampCursorCol(self: *TextArea) void {
        const line_len = self.currentLineLen();
        if (self.cursor_col > line_len) {
            self.cursor_col = line_len;
        }
    }

    fn ensureCursorVisible(self: *TextArea) void {
        // Vertical scroll
        if (self.cursor_line < self.scroll_y) {
            self.scroll_y = self.cursor_line;
        } else if (self.cursor_line >= self.scroll_y + self.visible_height) {
            self.scroll_y = self.cursor_line - self.visible_height + 1;
        }

        // Horizontal scroll
        const text_width = if (self.show_line_numbers) self.visible_width -| 5 else self.visible_width;
        if (self.cursor_col < self.scroll_x) {
            self.scroll_x = self.cursor_col;
        } else if (self.cursor_col >= self.scroll_x + text_width) {
            self.scroll_x = self.cursor_col - text_width + 1;
        }
    }

    // Editing methods

    /// Insert character at cursor
    pub fn insertChar(self: *TextArea, char: u8) !void {
        if (self.read_only) return;
        if (self.cursor_line >= self.lines.items.len) return;

        try self.lines.items[self.cursor_line].insert(self.cursor_col, char);
        self.cursor_col += 1;
        self.ensureCursorVisible();
        self.notifyChange();
    }

    /// Insert newline at cursor
    pub fn insertNewline(self: *TextArea) !void {
        if (self.read_only) return;
        if (self.cursor_line >= self.lines.items.len) return;

        // Split current line at cursor
        const current_line = &self.lines.items[self.cursor_line];
        var new_line = std.ArrayList(u8).init(self.allocator);

        // Move content after cursor to new line
        if (self.cursor_col < current_line.items.len) {
            try new_line.appendSlice(current_line.items[self.cursor_col..]);
            current_line.shrinkRetainingCapacity(self.cursor_col);
        }

        // Insert new line after current
        try self.lines.insert(self.cursor_line + 1, new_line);
        self.cursor_line += 1;
        self.cursor_col = 0;
        self.ensureCursorVisible();
        self.notifyChange();
    }

    /// Delete character before cursor (backspace)
    pub fn deleteBack(self: *TextArea) !void {
        if (self.read_only) return;
        if (self.cursor_line >= self.lines.items.len) return;

        if (self.cursor_col > 0) {
            _ = self.lines.items[self.cursor_line].orderedRemove(self.cursor_col - 1);
            self.cursor_col -= 1;
        } else if (self.cursor_line > 0) {
            // Merge with previous line
            const prev_len = self.lines.items[self.cursor_line - 1].items.len;
            try self.lines.items[self.cursor_line - 1].appendSlice(self.lines.items[self.cursor_line].items);
            self.lines.items[self.cursor_line].deinit();
            _ = self.lines.orderedRemove(self.cursor_line);
            self.cursor_line -= 1;
            self.cursor_col = prev_len;
        }
        self.ensureCursorVisible();
        self.notifyChange();
    }

    /// Delete character at cursor
    pub fn deleteForward(self: *TextArea) !void {
        if (self.read_only) return;
        if (self.cursor_line >= self.lines.items.len) return;

        const line = &self.lines.items[self.cursor_line];
        if (self.cursor_col < line.items.len) {
            _ = line.orderedRemove(self.cursor_col);
        } else if (self.cursor_line + 1 < self.lines.items.len) {
            // Merge with next line
            try line.appendSlice(self.lines.items[self.cursor_line + 1].items);
            self.lines.items[self.cursor_line + 1].deinit();
            _ = self.lines.orderedRemove(self.cursor_line + 1);
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
            if (self.show_line_numbers and line_idx < self.lines.items.len) {
                var num_buf: [8]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d:>4} ", .{line_idx + 1}) catch "???? ";
                view.print(0, @intCast(y), num_str, self.line_number_style.fg, self.line_number_style.bg, .{});
            }

            // Draw line content
            if (line_idx < self.lines.items.len) {
                const line = self.lines.items[line_idx].items;
                const start_col = @min(self.scroll_x, line.len);
                const visible_len = @min(line.len - start_col, size.width - text_start_x);

                if (visible_len > 0) {
                    view.print(@intCast(text_start_x), @intCast(y), line[start_col .. start_col + visible_len], self.style.fg, self.style.bg, self.style.attrs);
                }

                // Draw cursor
                if (self.widget_state.focused and line_idx == self.cursor_line) {
                    const cursor_x = text_start_x + @as(u16, @intCast(self.cursor_col)) -| @as(u16, @intCast(self.scroll_x));
                    if (cursor_x < size.width) {
                        const cursor_char: u21 = if (self.cursor_col < line.len) line[self.cursor_col] else ' ';
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
                else if (key.codepoint != 0 and key.codepoint >= 0x20 and key.codepoint < 0x7F) {
                    self.insertChar(@intCast(key.codepoint)) catch {};
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
