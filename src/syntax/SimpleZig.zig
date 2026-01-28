const std = @import("std");
const StyleRegistry = @import("StyleRegistry.zig");
const HighlighterMod = @import("Highlighter.zig");

const SyntaxStyle = StyleRegistry.SyntaxStyle;
const Attr = StyleRegistry.Attr;
const SpanBuffer = HighlighterMod.SpanBuffer;
const Highlighter = HighlighterMod.Highlighter;
const HighlightError = HighlighterMod.HighlightError;

pub const SimpleZigHighlighter = struct {
    keyword_id: u32,
    string_id: u32,
    comment_id: u32,

    pub fn init(styles: *SyntaxStyle) !SimpleZigHighlighter {
        const keyword_id = try styles.registerStyle("keyword", null, null, Attr.bold);
        const string_id = try styles.registerStyle("string", null, null, 0);
        const comment_id = try styles.registerStyle("comment", null, null, Attr.italic);
        return .{
            .keyword_id = keyword_id,
            .string_id = string_id,
            .comment_id = comment_id,
        };
    }

    pub fn toHighlighter(self: *SimpleZigHighlighter) Highlighter {
        return .{
            .ctx = self,
            .highlightFn = highlight,
        };
    }

    fn highlight(ctx: *anyopaque, text: []const u8, spans: *SpanBuffer, _: *SyntaxStyle) HighlightError!void {
        const self: *SimpleZigHighlighter = @ptrCast(@alignCast(ctx));
        spans.clear();

        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (c == '/' and i + 1 < text.len) {
                if (text[i + 1] == '/') {
                    const start = i;
                    i += 2;
                    while (i < text.len and text[i] != '\n') : (i += 1) {}
                    try spans.append(.{ .start = start, .end = i, .style_id = self.comment_id });
                    continue;
                } else if (text[i + 1] == '*') {
                    const start = i;
                    i += 2;
                    while (i + 1 < text.len) : (i += 1) {
                        if (text[i] == '*' and text[i + 1] == '/') {
                            i += 2;
                            break;
                        }
                    }
                    try spans.append(.{ .start = start, .end = i, .style_id = self.comment_id });
                    continue;
                }
            }

            if (c == '"') {
                const start = i;
                i += 1;
                while (i < text.len) : (i += 1) {
                    if (text[i] == '\\') {
                        if (i + 1 < text.len) i += 1;
                        continue;
                    }
                    if (text[i] == '"') {
                        i += 1;
                        break;
                    }
                }
                try spans.append(.{ .start = start, .end = i, .style_id = self.string_id });
                continue;
            }

            if (isIdentStart(c)) {
                const start = i;
                i += 1;
                while (i < text.len and isIdentContinue(text[i])) : (i += 1) {}
                const token = text[start..i];
                if (isKeyword(token)) {
                    try spans.append(.{ .start = start, .end = i, .style_id = self.keyword_id });
                }
                continue;
            }

            i += 1;
        }
    }

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }

    fn isIdentContinue(c: u8) bool {
        return isIdentStart(c) or (c >= '0' and c <= '9');
    }

    fn isKeyword(token: []const u8) bool {
        return std.mem.eql(u8, token, "const") or
            std.mem.eql(u8, token, "var") or
            std.mem.eql(u8, token, "fn") or
            std.mem.eql(u8, token, "pub") or
            std.mem.eql(u8, token, "struct") or
            std.mem.eql(u8, token, "enum") or
            std.mem.eql(u8, token, "return") or
            std.mem.eql(u8, token, "if") or
            std.mem.eql(u8, token, "else") or
            std.mem.eql(u8, token, "while") or
            std.mem.eql(u8, token, "for") or
            std.mem.eql(u8, token, "switch") or
            std.mem.eql(u8, token, "break") or
            std.mem.eql(u8, token, "continue") or
            std.mem.eql(u8, token, "try") or
            std.mem.eql(u8, token, "catch") or
            std.mem.eql(u8, token, "defer") or
            std.mem.eql(u8, token, "errdefer");
    }
};

// =============================================================================
// Tests
// =============================================================================

test "SimpleZigHighlighter produces spans" {
    var styles = try SyntaxStyle.init(std.testing.allocator);
    defer styles.deinit();

    var zig = try SimpleZigHighlighter.init(styles);
    var spans = SpanBuffer.init(std.testing.allocator);
    defer spans.deinit();

    try zig.toHighlighter().highlight("const value = \"hi\" // comment", &spans, styles);

    try std.testing.expectEqual(@as(usize, 3), spans.spans.items.len);
    try std.testing.expectEqual(@as(usize, 0), spans.spans.items[0].start);
    try std.testing.expectEqual(@as(usize, 5), spans.spans.items[0].end);
    try std.testing.expectEqual(@as(usize, 14), spans.spans.items[1].start);
    try std.testing.expectEqual(@as(usize, 18), spans.spans.items[1].end);
    try std.testing.expectEqual(@as(usize, 19), spans.spans.items[2].start);
}
