//! UTF-8 helpers shared across text widgets.

const std = @import("std");
const unicode = @import("../unicode/width.zig");

/// Get the length of a UTF-8 codepoint from its lead byte.
pub fn codepointLength(lead: u8) usize {
    if (lead < 0x80) return 1; // ASCII
    if (lead & 0xE0 == 0xC0) return 2; // 110xxxxx
    if (lead & 0xF0 == 0xE0) return 3; // 1110xxxx
    if (lead & 0xF8 == 0xF0) return 4; // 11110xxx
    return 1; // Invalid, treat as single byte
}

/// Find the start of the UTF-8 codepoint at or before the given byte position.
pub fn findCodepointStart(text: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    if (pos >= text.len) return text.len;
    var i = pos;
    while (i > 0 and (text[i] & 0xC0) == 0x80) {
        i -= 1;
    }
    return i;
}

/// Calculate display width (columns) for text up to a byte position.
pub fn displayWidthUpTo(text: []const u8, byte_pos: usize) u16 {
    const slice = text[0..@min(byte_pos, text.len)];
    return @intCast(@min(unicode.stringWidth(slice), std.math.maxInt(u16)));
}

/// Calculate display width (columns) between two byte offsets.
pub fn displayWidthBetween(text: []const u8, start: usize, end: usize) u16 {
    const clamped_start = @min(start, text.len);
    const clamped_end = @min(end, text.len);
    if (clamped_end <= clamped_start) return 0;
    return @intCast(@min(unicode.stringWidth(text[clamped_start..clamped_end]), std.math.maxInt(u16)));
}

/// Find byte position for a target display column.
/// Returns 0 if text is invalid UTF-8.
pub fn byteIndexForDisplayColumn(text: []const u8, target_col: usize) usize {
    if (target_col == 0) return 0;
    var col: usize = 0;
    var byte_pos: usize = 0;
    const view = std.unicode.Utf8View.init(text) catch return 0;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        if (col >= target_col) break;
        col += unicode.codePointWidth(cp);
        byte_pos = iter.i;
    }
    return byte_pos;
}

/// Decode a UTF-8 codepoint at the given byte position.
pub fn decodeCodepointAt(text: []const u8, pos: usize) u21 {
    if (pos >= text.len) return ' ';
    const len = std.unicode.utf8ByteSequenceLength(text[pos]) catch return text[pos];
    if (pos + len > text.len) return text[pos];
    return std.unicode.utf8Decode(text[pos..][0..len]) catch text[pos];
}

/// Find the start of the previous character (for cursor left).
pub fn prevCharBoundary(text: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var i = pos - 1;
    while (i > 0 and (text[i] & 0xC0) == 0x80) {
        i -= 1;
    }
    return i;
}

/// Find the start of the next character (for cursor right).
pub fn nextCharBoundary(text: []const u8, pos: usize) usize {
    if (pos >= text.len) return text.len;
    var i = pos + 1;
    while (i < text.len and (text[i] & 0xC0) == 0x80) {
        i += 1;
    }
    return i;
}

test "displayWidthUpTo ASCII" {
    const width = displayWidthUpTo("Hello", 3);
    try std.testing.expectEqual(@as(u16, 3), width);
}

test "displayWidthUpTo UTF-8" {
    const width = displayWidthUpTo("中文", 6); // 6 bytes for 2 chars
    try std.testing.expectEqual(@as(u16, 4), width);
}

test "prevCharBoundary ASCII" {
    const text = "Hello";
    try std.testing.expectEqual(@as(usize, 2), prevCharBoundary(text, 3));
    try std.testing.expectEqual(@as(usize, 0), prevCharBoundary(text, 0));
}

test "prevCharBoundary UTF-8" {
    const text = "中文";
    try std.testing.expectEqual(@as(usize, 0), prevCharBoundary(text, 3));
    try std.testing.expectEqual(@as(usize, 3), prevCharBoundary(text, 6));
}

test "nextCharBoundary ASCII" {
    const text = "Hello";
    try std.testing.expectEqual(@as(usize, 3), nextCharBoundary(text, 2));
    try std.testing.expectEqual(@as(usize, 5), nextCharBoundary(text, 5));
}

test "nextCharBoundary UTF-8" {
    const text = "中文";
    try std.testing.expectEqual(@as(usize, 3), nextCharBoundary(text, 0));
    try std.testing.expectEqual(@as(usize, 6), nextCharBoundary(text, 3));
}

test "byteIndexForDisplayColumn" {
    const text = "a中b";
    try std.testing.expectEqual(@as(usize, 0), byteIndexForDisplayColumn(text, 0));
    try std.testing.expectEqual(@as(usize, 1), byteIndexForDisplayColumn(text, 1));
    try std.testing.expectEqual(@as(usize, 4), byteIndexForDisplayColumn(text, 3));
}
