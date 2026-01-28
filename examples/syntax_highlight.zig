const std = @import("std");
const termcat = @import("termcat");

const SyntaxStyle = termcat.syntax.SyntaxStyle;
const HighlighterRegistry = termcat.syntax.HighlighterRegistry;
const SimpleZigHighlighter = termcat.syntax.SimpleZigHighlighter;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var styles = try SyntaxStyle.init(allocator);
    defer styles.deinit();

    _ = try styles.registerStyle("keyword", termcat.Color{ .index = 4 }, null, termcat.syntax.Attr.bold);
    _ = try styles.registerStyle("string", termcat.Color{ .index = 2 }, null, 0);
    _ = try styles.registerStyle("comment", termcat.Color{ .index = 8 }, null, termcat.syntax.Attr.italic);

    var registry = try HighlighterRegistry.init(allocator);
    defer registry.deinit();

    var zig = try SimpleZigHighlighter.init(styles);
    try registry.register("zig", zig.toHighlighter());

    const sample =
        "pub fn main() void {\n" ++
        "    const value = \"hi\" // greeting\n" ++
        "}\n";

    var spans = termcat.syntax.SpanBuffer.init(allocator);
    defer spans.deinit();

    try registry.highlight("zig", sample, &spans, styles);

    var stdout = std.io.getStdOut().writer();
    try renderStyled(stdout, styles, sample, spans.spans.items);
}

fn renderStyled(writer: anytype, styles: *SyntaxStyle, text: []const u8, spans: []const termcat.syntax.Span) !void {
    var cursor: usize = 0;
    const base = termcat.Style{};

    for (spans) |span| {
        if (span.start > cursor) {
            try writer.writeAll(text[cursor..span.start]);
        }
        if (styles.resolveById(span.style_id)) |def| {
            const styled = SyntaxStyle.applyDefinition(def, base);
            const rendered = try styled.renderAlloc(std.heap.page_allocator, text[span.start..span.end], .true_color);
            defer std.heap.page_allocator.free(rendered);
            try writer.writeAll(rendered);
        } else {
            try writer.writeAll(text[span.start..span.end]);
        }
        cursor = span.end;
    }

    if (cursor < text.len) {
        try writer.writeAll(text[cursor..]);
    }
}
