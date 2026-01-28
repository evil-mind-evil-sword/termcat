//! TextBuffer: reusable text model for editable multi-line text.
//!
//! Provides line-aware editing helpers for widgets like TextArea while
//! keeping the storage and mutation logic centralized.

const std = @import("std");

pub const TextBuffer = struct {
    const Line = std.ArrayListUnmanaged(u8);

    lines: std.ArrayListUnmanaged(Line) = .empty,
    allocator: std.mem.Allocator,

    pub const Error = error{
        OutOfRange,
        OutOfMemory,
    };

    pub fn init(allocator: std.mem.Allocator) !TextBuffer {
        var lines: std.ArrayListUnmanaged(Line) = .empty;
        try lines.append(allocator, .empty);
        return .{
            .lines = lines,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TextBuffer) void {
        for (self.lines.items) |*line| {
            line.deinit(self.allocator);
        }
        self.lines.deinit(self.allocator);
    }

    pub fn setText(self: *TextBuffer, content: []const u8) !void {
        self.clearLines();

        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line_content| {
            var new_line: Line = .empty;
            try new_line.appendSlice(self.allocator, line_content);
            try self.lines.append(self.allocator, new_line);
        }

        if (self.lines.items.len == 0) {
            try self.lines.append(self.allocator, .empty);
        }
    }

    pub fn getText(self: *const TextBuffer, allocator: std.mem.Allocator) ![]u8 {
        var total_len: usize = 0;
        for (self.lines.items, 0..) |line, i| {
            total_len += line.items.len;
            if (i + 1 < self.lines.items.len) total_len += 1;
        }

        var result = try allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (self.lines.items, 0..) |line, i| {
            @memcpy(result[pos .. pos + line.items.len], line.items);
            pos += line.items.len;
            if (i + 1 < self.lines.items.len) {
                result[pos] = '\n';
                pos += 1;
            }
        }

        return result;
    }

    pub fn lineCount(self: *const TextBuffer) usize {
        return self.lines.items.len;
    }

    pub fn lineLen(self: *const TextBuffer, line_idx: usize) usize {
        if (line_idx >= self.lines.items.len) return 0;
        return self.lines.items[line_idx].items.len;
    }

    pub fn lineSlice(self: *const TextBuffer, line_idx: usize) []const u8 {
        if (line_idx >= self.lines.items.len) return "";
        return self.lines.items[line_idx].items;
    }

    pub fn insertByte(self: *TextBuffer, line_idx: usize, col: usize, byte: u8) Error!void {
        if (line_idx >= self.lines.items.len) return error.OutOfRange;
        const line = &self.lines.items[line_idx];
        const pos = @min(col, line.items.len);
        try line.insert(self.allocator, pos, byte);
    }

    pub fn insertBytes(self: *TextBuffer, line_idx: usize, col: usize, bytes: []const u8) Error!void {
        if (line_idx >= self.lines.items.len) return error.OutOfRange;
        if (bytes.len == 0) return;
        const line = &self.lines.items[line_idx];
        const pos = @min(col, line.items.len);
        try line.insertSlice(self.allocator, pos, bytes);
    }

    pub fn splitLine(self: *TextBuffer, line_idx: usize, col: usize) Error!void {
        if (line_idx >= self.lines.items.len) return error.OutOfRange;
        const line = &self.lines.items[line_idx];
        const split_col = @min(col, line.items.len);

        var new_line: Line = .empty;
        errdefer new_line.deinit(self.allocator);

        if (split_col < line.items.len) {
            try new_line.appendSlice(self.allocator, line.items[split_col..]);
            line.shrinkRetainingCapacity(split_col);
        }

        try self.lines.insert(self.allocator, line_idx + 1, new_line);
    }

    pub fn mergeLineWithPrevious(self: *TextBuffer, line_idx: usize) Error!usize {
        if (line_idx == 0 or line_idx >= self.lines.items.len) return error.OutOfRange;
        const prev = &self.lines.items[line_idx - 1];
        const curr = &self.lines.items[line_idx];
        const prev_len = prev.items.len;
        try prev.appendSlice(self.allocator, curr.items);
        curr.deinit(self.allocator);
        _ = self.lines.orderedRemove(line_idx);
        return prev_len;
    }

    pub fn mergeLineWithNext(self: *TextBuffer, line_idx: usize) Error!void {
        if (line_idx + 1 >= self.lines.items.len) return error.OutOfRange;
        const current = &self.lines.items[line_idx];
        const next = &self.lines.items[line_idx + 1];
        try current.appendSlice(self.allocator, next.items);
        next.deinit(self.allocator);
        _ = self.lines.orderedRemove(line_idx + 1);
    }

    pub fn deleteRangeInLine(self: *TextBuffer, line_idx: usize, start: usize, len: usize) Error!void {
        if (line_idx >= self.lines.items.len) return error.OutOfRange;
        if (len == 0) return;
        const line = &self.lines.items[line_idx];
        if (start >= line.items.len) return;
        const end = @min(line.items.len, start + len);
        var i: usize = end;
        while (i > start) : (i -= 1) {
            _ = line.orderedRemove(i - 1);
        }
    }

    /// Delete a range that may span multiple lines.
    /// Start is inclusive, end is exclusive. Positions are byte offsets.
    pub fn deleteRange(self: *TextBuffer, start_line: usize, start_col: usize, end_line: usize, end_col: usize) Error!void {
        if (start_line >= self.lines.items.len or end_line >= self.lines.items.len) return error.OutOfRange;
        if (start_line > end_line) return error.OutOfRange;
        if (start_line == end_line) {
            if (end_col <= start_col) return;
            return self.deleteRangeInLine(start_line, start_col, end_col - start_col);
        }

        const start_line_ptr = &self.lines.items[start_line];
        const end_line_ptr = &self.lines.items[end_line];

        const start_clamped = @min(start_col, start_line_ptr.items.len);
        const end_clamped = @min(end_col, end_line_ptr.items.len);

        start_line_ptr.shrinkRetainingCapacity(start_clamped);
        if (end_clamped < end_line_ptr.items.len) {
            try start_line_ptr.appendSlice(self.allocator, end_line_ptr.items[end_clamped..]);
        }

        var idx = end_line;
        while (idx > start_line) : (idx -= 1) {
            self.removeLine(idx);
        }
    }

    pub fn truncateLine(self: *TextBuffer, line_idx: usize, len: usize) Error!void {
        if (line_idx >= self.lines.items.len) return error.OutOfRange;
        const line = &self.lines.items[line_idx];
        line.shrinkRetainingCapacity(@min(len, line.items.len));
    }

    pub fn clearLine(self: *TextBuffer, line_idx: usize) Error!void {
        if (line_idx >= self.lines.items.len) return error.OutOfRange;
        self.lines.items[line_idx].clearRetainingCapacity();
    }

    pub fn clear(self: *TextBuffer) !void {
        self.clearLines();
        try self.lines.append(self.allocator, .empty);
    }

    fn clearLines(self: *TextBuffer) void {
        for (self.lines.items) |*line| {
            line.deinit(self.allocator);
        }
        self.lines.clearRetainingCapacity();
    }

    fn removeLine(self: *TextBuffer, line_idx: usize) void {
        if (line_idx >= self.lines.items.len) return;
        self.lines.items[line_idx].deinit(self.allocator);
        _ = self.lines.orderedRemove(line_idx);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "TextBuffer set/get text" {
    var buffer = try TextBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.setText("hello\nworld");
    try std.testing.expectEqual(@as(usize, 2), buffer.lineCount());
    try std.testing.expectEqualStrings("hello", buffer.lineSlice(0));
    try std.testing.expectEqualStrings("world", buffer.lineSlice(1));

    const text = try buffer.getText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello\nworld", text);
}

test "TextBuffer insert and split" {
    var buffer = try TextBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.insertBytes(0, 0, "hello");
    try buffer.splitLine(0, 2);

    try std.testing.expectEqual(@as(usize, 2), buffer.lineCount());
    try std.testing.expectEqualStrings("he", buffer.lineSlice(0));
    try std.testing.expectEqualStrings("llo", buffer.lineSlice(1));
}

test "TextBuffer merge and delete" {
    var buffer = try TextBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.setText("ab\ncd");
    const merged_col = try buffer.mergeLineWithPrevious(1);
    try std.testing.expectEqual(@as(usize, 2), merged_col);
    try std.testing.expectEqual(@as(usize, 1), buffer.lineCount());
    try std.testing.expectEqualStrings("abcd", buffer.lineSlice(0));

    try buffer.deleteRangeInLine(0, 1, 2);
    try std.testing.expectEqualStrings("ad", buffer.lineSlice(0));
}

test "TextBuffer deleteRange across lines" {
    var buffer = try TextBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.setText("ab\ncd\nef");
    try buffer.deleteRange(0, 1, 2, 1);

    try std.testing.expectEqual(@as(usize, 1), buffer.lineCount());
    try std.testing.expectEqualStrings("af", buffer.lineSlice(0));
}
