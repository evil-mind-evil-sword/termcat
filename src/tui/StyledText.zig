//! StyledText: Rich text with style ranges
//!
//! Provides efficient specification of styled text spans without allocating
//! per-cell. Supports overlapping spans where later spans override earlier ones.

const std = @import("std");
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const unicode = @import("../unicode/width.zig");

/// A styled text span
pub const Span = struct {
    /// Start byte offset (inclusive, UTF-8 byte position)
    start: usize,
    /// End byte offset (exclusive, UTF-8 byte position)
    end: usize,
    /// Style to apply to this span
    style: Style,

    /// Check if this span contains the given byte offset
    pub fn contains(self: Span, byte_offset: usize) bool {
        return byte_offset >= self.start and byte_offset < self.end;
    }
};

/// Rich text with style ranges
pub const StyledText = struct {
    /// The text content (UTF-8)
    text: []const u8,
    /// Style spans (may overlap, later spans take precedence)
    spans: []const Span,
    /// Default style for unstyled regions
    default_style: Style,

    const Self = @This();

    /// Create a StyledText with default style
    pub fn init(text: []const u8) Self {
        return .{
            .text = text,
            .spans = &.{},
            .default_style = .{},
        };
    }

    /// Create a StyledText with spans
    pub fn initWithSpans(text: []const u8, spans: []const Span) Self {
        return .{
            .text = text,
            .spans = spans,
            .default_style = .{},
        };
    }

    /// Get the display width of this text
    pub fn displayWidth(self: Self) usize {
        return unicode.stringWidth(self.text);
    }

    /// Get the effective style at a given byte offset.
    /// Later spans override earlier ones.
    pub fn styleAt(self: Self, byte_offset: usize) Style {
        var result = self.default_style;
        for (self.spans) |span| {
            if (span.contains(byte_offset)) {
                result = result.merge(span.style);
            }
        }
        return result;
    }

    /// Render this styled text to cells.
    /// Returns the number of cells written.
    pub fn renderToCells(self: Self, cells: []Cell, max_width: usize) usize {
        var cell_idx: usize = 0;
        var byte_idx: usize = 0;

        while (byte_idx < self.text.len and cell_idx < max_width and cell_idx < cells.len) {
            // Get the style at this byte position
            const style = self.styleAt(byte_idx);

            // Decode the codepoint
            const len = std.unicode.utf8ByteSequenceLength(self.text[byte_idx]) catch 1;
            if (byte_idx + len > self.text.len) break;

            const codepoint = std.unicode.utf8Decode(self.text[byte_idx..][0..len]) catch '?';
            const char_width = unicode.codePointWidth(codepoint);

            // Skip zero-width characters (they'll be handled as combining marks)
            if (char_width == 0) {
                // Try to add as combining mark to previous cell
                if (cell_idx > 0) {
                    _ = cells[cell_idx - 1].addCombining(codepoint);
                }
                byte_idx += len;
                continue;
            }

            // Check if we have room for this character
            if (cell_idx + char_width > max_width or cell_idx + char_width > cells.len) {
                break;
            }

            // Write the cell
            cells[cell_idx] = .{
                .char = codepoint,
                .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                .fg = style.fg,
                .bg = style.bg,
                .attrs = style.attrs,
            };

            // Handle wide characters
            if (char_width == 2 and cell_idx + 1 < cells.len) {
                cells[cell_idx + 1] = Cell.continuation(style.fg, style.bg, style.attrs);
            }

            cell_idx += char_width;
            byte_idx += len;
        }

        return cell_idx;
    }

    /// Iterator for styled text segments
    pub const SegmentIterator = struct {
        styled_text: *const StyledText,
        byte_idx: usize,

        /// A segment of text with uniform style
        pub const Segment = struct {
            text: []const u8,
            style: Style,
            start_byte: usize,
        };

        pub fn next(self: *SegmentIterator) ?Segment {
            if (self.byte_idx >= self.styled_text.text.len) return null;

            const start_byte = self.byte_idx;
            const start_style = self.styled_text.styleAt(self.byte_idx);

            // Find the end of this segment (where style changes)
            var end_byte = start_byte;
            while (end_byte < self.styled_text.text.len) {
                const len = std.unicode.utf8ByteSequenceLength(self.styled_text.text[end_byte]) catch 1;
                const next_byte = end_byte + len;

                // Check if style changes at next character
                if (next_byte < self.styled_text.text.len) {
                    const next_style = self.styled_text.styleAt(next_byte);
                    if (!stylesEqual(start_style, next_style)) {
                        end_byte = next_byte;
                        break;
                    }
                }

                end_byte = next_byte;
                if (end_byte >= self.styled_text.text.len) break;
            }

            self.byte_idx = end_byte;

            return .{
                .text = self.styled_text.text[start_byte..end_byte],
                .style = start_style,
                .start_byte = start_byte,
            };
        }
    };

    /// Get an iterator over styled segments
    pub fn segments(self: *const Self) SegmentIterator {
        return .{
            .styled_text = self,
            .byte_idx = 0,
        };
    }
};

/// Compare two styles for equality
fn stylesEqual(a: Style, b: Style) bool {
    return a.fg.eql(b.fg) and a.bg.eql(b.bg) and a.attrs.eql(b.attrs);
}

// ============================================================================
// Builder pattern for convenience
// ============================================================================

/// Builder for creating StyledText with spans
pub const StyledTextBuilder = struct {
    text: []const u8,
    spans: std.ArrayList(Span),
    default_style: Style,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, text: []const u8) Self {
        return .{
            .text = text,
            .spans = std.ArrayList(Span).init(allocator),
            .default_style = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.spans.deinit();
    }

    /// Add a styled span
    pub fn addSpan(self: *Self, start: usize, end: usize, style: Style) !*Self {
        try self.spans.append(.{
            .start = start,
            .end = end,
            .style = style,
        });
        return self;
    }

    /// Set the default style
    pub fn withDefaultStyle(self: *Self, style: Style) *Self {
        self.default_style = style;
        return self;
    }

    /// Build the StyledText (spans slice is owned by builder, valid until deinit)
    pub fn build(self: *const Self) StyledText {
        return .{
            .text = self.text,
            .spans = self.spans.items,
            .default_style = self.default_style,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "StyledText init" {
    const st = StyledText.init("Hello, world!");
    try std.testing.expectEqualStrings("Hello, world!", st.text);
    try std.testing.expectEqual(@as(usize, 0), st.spans.len);
}

test "StyledText displayWidth" {
    const st = StyledText.init("Hello");
    try std.testing.expectEqual(@as(usize, 5), st.displayWidth());

    const st_wide = StyledText.init("中文");
    try std.testing.expectEqual(@as(usize, 4), st_wide.displayWidth());
}

test "StyledText styleAt without spans" {
    const st = StyledText.init("Hello");
    const style = st.styleAt(0);
    try std.testing.expect(style.fg.eql(.default));
}

test "StyledText styleAt with spans" {
    const spans = [_]Span{
        .{ .start = 0, .end = 5, .style = .{ .attrs = .{ .bold = true } } },
        .{ .start = 7, .end = 12, .style = .{ .fg = Cell.Color.red } },
    };
    const st = StyledText.initWithSpans("Hello, world!", &spans);

    // Position 0-4: bold
    const style0 = st.styleAt(0);
    try std.testing.expect(style0.attrs.bold);

    // Position 6: default (comma and space)
    const style6 = st.styleAt(6);
    try std.testing.expect(!style6.attrs.bold);

    // Position 7-11: red
    const style7 = st.styleAt(7);
    try std.testing.expect(style7.fg.eql(Cell.Color.red));
}

test "StyledText overlapping spans" {
    const spans = [_]Span{
        .{ .start = 0, .end = 10, .style = .{ .attrs = .{ .bold = true } } },
        .{ .start = 5, .end = 8, .style = .{ .attrs = .{ .underline = true } } },
    };
    const st = StyledText.initWithSpans("Hello world", &spans);

    // Position 0-4: bold only
    const style0 = st.styleAt(0);
    try std.testing.expect(style0.attrs.bold);
    try std.testing.expect(!style0.attrs.underline);

    // Position 5-7: bold AND underline (merged)
    const style5 = st.styleAt(5);
    try std.testing.expect(style5.attrs.bold);
    try std.testing.expect(style5.attrs.underline);

    // Position 8-9: bold only
    const style8 = st.styleAt(8);
    try std.testing.expect(style8.attrs.bold);
    try std.testing.expect(!style8.attrs.underline);
}

test "StyledText renderToCells" {
    const spans = [_]Span{
        .{ .start = 0, .end = 2, .style = .{ .attrs = .{ .bold = true } } },
    };
    const st = StyledText.initWithSpans("Hi!", &spans);

    var cells: [10]Cell = undefined;
    for (&cells) |*c| c.* = Cell.default;

    const written = st.renderToCells(&cells, 10);
    try std.testing.expectEqual(@as(usize, 3), written);
    try std.testing.expectEqual(@as(u21, 'H'), cells[0].char);
    try std.testing.expect(cells[0].attrs.bold);
    try std.testing.expectEqual(@as(u21, 'i'), cells[1].char);
    try std.testing.expect(cells[1].attrs.bold);
    try std.testing.expectEqual(@as(u21, '!'), cells[2].char);
    try std.testing.expect(!cells[2].attrs.bold);
}

test "StyledText segments iterator" {
    const spans = [_]Span{
        .{ .start = 0, .end = 5, .style = .{ .attrs = .{ .bold = true } } },
    };
    const st = StyledText.initWithSpans("Hello World", &spans);

    var iter = st.segments();

    // First segment: "Hello" (bold)
    const seg1 = iter.next();
    try std.testing.expect(seg1 != null);
    try std.testing.expectEqualStrings("Hello", seg1.?.text);
    try std.testing.expect(seg1.?.style.attrs.bold);

    // Second segment: " World" (default)
    const seg2 = iter.next();
    try std.testing.expect(seg2 != null);
    try std.testing.expectEqualStrings(" World", seg2.?.text);
    try std.testing.expect(!seg2.?.style.attrs.bold);

    // No more segments
    try std.testing.expect(iter.next() == null);
}

test "StyledTextBuilder" {
    const allocator = std.testing.allocator;

    var builder = StyledTextBuilder.init(allocator, "Hello, world!");
    defer builder.deinit();

    _ = try builder.addSpan(0, 5, .{ .attrs = .{ .bold = true } });
    _ = try builder.addSpan(7, 12, .{ .fg = Cell.Color.red });

    const st = builder.build();
    try std.testing.expectEqual(@as(usize, 2), st.spans.len);

    const style0 = st.styleAt(0);
    try std.testing.expect(style0.attrs.bold);

    const style7 = st.styleAt(7);
    try std.testing.expect(style7.fg.eql(Cell.Color.red));
}

test "Span contains" {
    const span = Span{ .start = 5, .end = 10, .style = .{} };

    try std.testing.expect(!span.contains(4));
    try std.testing.expect(span.contains(5));
    try std.testing.expect(span.contains(7));
    try std.testing.expect(span.contains(9));
    try std.testing.expect(!span.contains(10));
}
