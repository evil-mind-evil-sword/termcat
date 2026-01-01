//! Truncation: Text truncation policies for widgets
//!
//! Provides different strategies for handling text that exceeds available width:
//! - Clip: Simply cut off text at the boundary
//! - Ellipsis: Add "..." at the end when truncated
//! - EllipsisStart: Add "..." at the start when truncated
//! - EllipsisMiddle: Add "..." in the middle, preserving start and end
//! - Fade: Dim the last few characters (visual fade effect)

const std = @import("std");
const Cell = @import("../Cell.zig");
const unicode = @import("../unicode/width.zig");

/// Truncation policy for text that exceeds available width
pub const Policy = enum {
    /// Simply clip text at the boundary (default)
    clip,
    /// Add ellipsis (...) at the end
    ellipsis,
    /// Add ellipsis at the start, preserving the end
    ellipsis_start,
    /// Add ellipsis in the middle, preserving start and end
    ellipsis_middle,
    /// Fade effect: dim the last few characters
    fade,
};

/// Result of truncation operation
pub const Result = struct {
    /// The truncated text (may be the original if no truncation needed)
    text: []const u8,
    /// Whether text was actually truncated
    truncated: bool,
    /// For allocation-based truncation, the allocated buffer (null if no allocation)
    allocated: ?[]u8,
};

/// Truncate text according to the given policy.
/// Returns the visible portion of text and whether it was truncated.
/// For policies that add ellipsis, provides the byte range to show.
pub fn truncate(
    text: []const u8,
    max_width: usize,
    policy: Policy,
    allocator: std.mem.Allocator,
) !Result {
    const text_width = unicode.stringWidth(text);

    // No truncation needed
    if (text_width <= max_width) {
        return .{
            .text = text,
            .truncated = false,
            .allocated = null,
        };
    }

    switch (policy) {
        .clip => {
            // Find byte offset for max_width
            const byte_end = findByteOffsetForWidth(text, max_width);
            return .{
                .text = text[0..byte_end],
                .truncated = true,
                .allocated = null,
            };
        },
        .ellipsis => {
            // Need room for "..." (3 chars)
            if (max_width < 3) {
                return .{
                    .text = text[0..findByteOffsetForWidth(text, max_width)],
                    .truncated = true,
                    .allocated = null,
                };
            }

            const content_width = max_width - 3;
            const byte_end = findByteOffsetForWidth(text, content_width);

            // Allocate buffer for truncated text + ellipsis
            const buf = try allocator.alloc(u8, byte_end + 3);
            @memcpy(buf[0..byte_end], text[0..byte_end]);
            buf[byte_end] = '.';
            buf[byte_end + 1] = '.';
            buf[byte_end + 2] = '.';

            return .{
                .text = buf,
                .truncated = true,
                .allocated = buf,
            };
        },
        .ellipsis_start => {
            // Need room for "..." (3 chars)
            if (max_width < 3) {
                return .{
                    .text = text[0..findByteOffsetForWidth(text, max_width)],
                    .truncated = true,
                    .allocated = null,
                };
            }

            const content_width = max_width - 3;
            // Find where to start from the end
            const byte_start = findByteOffsetFromEndForWidth(text, content_width);

            const content_len = text.len - byte_start;
            const buf = try allocator.alloc(u8, 3 + content_len);
            buf[0] = '.';
            buf[1] = '.';
            buf[2] = '.';
            @memcpy(buf[3..], text[byte_start..]);

            return .{
                .text = buf,
                .truncated = true,
                .allocated = buf,
            };
        },
        .ellipsis_middle => {
            // Need room for "..." (3 chars) plus at least 2 chars
            if (max_width < 5) {
                return truncate(text, max_width, .ellipsis, allocator);
            }

            const content_width = max_width - 3;
            const start_width = content_width / 2;
            const end_width = content_width - start_width;

            const byte_end_start = findByteOffsetForWidth(text, start_width);
            const byte_start_end = findByteOffsetFromEndForWidth(text, end_width);

            const end_len = text.len - byte_start_end;
            const buf = try allocator.alloc(u8, byte_end_start + 3 + end_len);
            @memcpy(buf[0..byte_end_start], text[0..byte_end_start]);
            buf[byte_end_start] = '.';
            buf[byte_end_start + 1] = '.';
            buf[byte_end_start + 2] = '.';
            @memcpy(buf[byte_end_start + 3 ..], text[byte_start_end..]);

            return .{
                .text = buf,
                .truncated = true,
                .allocated = buf,
            };
        },
        .fade => {
            // Fade doesn't modify text, just returns truncated portion
            // The caller is responsible for applying dim attributes
            const byte_end = findByteOffsetForWidth(text, max_width);
            return .{
                .text = text[0..byte_end],
                .truncated = true,
                .allocated = null,
            };
        },
    }
}

/// Apply fade effect to cells (dims the last few characters)
pub fn applyFade(cells: []Cell, fade_width: usize) void {
    if (cells.len == 0) return;

    const start = if (cells.len > fade_width) cells.len - fade_width else 0;
    for (cells[start..]) |*cell| {
        cell.attrs.dim = true;
    }
}

/// Free the result if it was allocated
pub fn freeResult(result: Result, allocator: std.mem.Allocator) void {
    if (result.allocated) |buf| {
        allocator.free(buf);
    }
}

/// Find the byte offset that corresponds to a given display width
fn findByteOffsetForWidth(text: []const u8, target_width: usize) usize {
    var width: usize = 0;
    var byte_idx: usize = 0;

    while (byte_idx < text.len and width < target_width) {
        const len = std.unicode.utf8ByteSequenceLength(text[byte_idx]) catch 1;
        if (byte_idx + len > text.len) break;

        const codepoint = std.unicode.utf8Decode(text[byte_idx..][0..len]) catch '?';
        const char_width = unicode.codePointWidth(codepoint);

        if (width + char_width > target_width) break;

        width += char_width;
        byte_idx += len;
    }

    return byte_idx;
}

/// Find the byte offset from the end that corresponds to a given display width
fn findByteOffsetFromEndForWidth(text: []const u8, target_width: usize) usize {
    var width: usize = 0;
    var byte_idx: usize = text.len;

    while (byte_idx > 0 and width < target_width) {
        // Find the start of the previous codepoint
        var prev_idx = byte_idx - 1;
        while (prev_idx > 0 and (text[prev_idx] & 0xC0) == 0x80) {
            prev_idx -= 1;
        }

        const len = byte_idx - prev_idx;
        const codepoint = std.unicode.utf8Decode(text[prev_idx..byte_idx]) catch '?';
        const char_width = unicode.codePointWidth(codepoint);

        if (width + char_width > target_width) break;

        width += char_width;
        byte_idx = prev_idx;
        _ = len;
    }

    return byte_idx;
}

// ============================================================================
// Tests
// ============================================================================

test "truncate clip" {
    const allocator = std.testing.allocator;
    const result = try truncate("Hello, World!", 5, .clip, allocator);
    defer freeResult(result, allocator);

    try std.testing.expectEqualStrings("Hello", result.text);
    try std.testing.expect(result.truncated);
    try std.testing.expect(result.allocated == null);
}

test "truncate no truncation needed" {
    const allocator = std.testing.allocator;
    const result = try truncate("Hi", 10, .clip, allocator);
    defer freeResult(result, allocator);

    try std.testing.expectEqualStrings("Hi", result.text);
    try std.testing.expect(!result.truncated);
}

test "truncate ellipsis" {
    const allocator = std.testing.allocator;
    const result = try truncate("Hello, World!", 8, .ellipsis, allocator);
    defer freeResult(result, allocator);

    try std.testing.expectEqualStrings("Hello...", result.text);
    try std.testing.expect(result.truncated);
    try std.testing.expect(result.allocated != null);
}

test "truncate ellipsis_start" {
    const allocator = std.testing.allocator;
    const result = try truncate("Hello, World!", 8, .ellipsis_start, allocator);
    defer freeResult(result, allocator);

    try std.testing.expectEqualStrings("...orld!", result.text);
    try std.testing.expect(result.truncated);
}

test "truncate ellipsis_middle" {
    const allocator = std.testing.allocator;
    const result = try truncate("Hello, World!", 10, .ellipsis_middle, allocator);
    defer freeResult(result, allocator);

    try std.testing.expectEqualStrings("Hel...rld!", result.text);
    try std.testing.expect(result.truncated);
}

test "truncate with wide characters" {
    const allocator = std.testing.allocator;
    // "中文测试" is 8 display width (2 each)
    const result = try truncate("中文测试", 5, .ellipsis, allocator);
    defer freeResult(result, allocator);

    // Should get "中..." (2 + 3 = 5 width)
    try std.testing.expectEqualStrings("中...", result.text);
    try std.testing.expect(result.truncated);
}

test "applyFade" {
    var cells = [_]Cell{
        Cell.default,
        Cell.default,
        Cell.default,
        Cell.default,
        Cell.default,
    };

    applyFade(&cells, 2);

    try std.testing.expect(!cells[0].attrs.dim);
    try std.testing.expect(!cells[1].attrs.dim);
    try std.testing.expect(!cells[2].attrs.dim);
    try std.testing.expect(cells[3].attrs.dim);
    try std.testing.expect(cells[4].attrs.dim);
}

test "findByteOffsetForWidth ASCII" {
    try std.testing.expectEqual(@as(usize, 5), findByteOffsetForWidth("Hello, World!", 5));
    try std.testing.expectEqual(@as(usize, 0), findByteOffsetForWidth("Hello", 0));
    try std.testing.expectEqual(@as(usize, 5), findByteOffsetForWidth("Hello", 10));
}

test "findByteOffsetForWidth Unicode" {
    // "中文" = 6 bytes, 4 display width
    try std.testing.expectEqual(@as(usize, 3), findByteOffsetForWidth("中文", 2));
    try std.testing.expectEqual(@as(usize, 6), findByteOffsetForWidth("中文", 4));
}

test "findByteOffsetFromEndForWidth" {
    try std.testing.expectEqual(@as(usize, 8), findByteOffsetFromEndForWidth("Hello, World!", 5));
    // "orld!" is 5 characters from position 8
}
