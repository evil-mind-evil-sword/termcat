pub const StyleRegistry = @import("StyleRegistry.zig");
pub const SyntaxStyle = StyleRegistry.SyntaxStyle;
pub const StyleDefinition = StyleRegistry.StyleDefinition;
pub const Attr = StyleRegistry.Attr;

pub const Highlighter = @import("Highlighter.zig");
pub const Span = Highlighter.Span;
pub const SpanBuffer = Highlighter.SpanBuffer;
pub const HighlighterRegistry = Highlighter.HighlighterRegistry;

pub const SimpleZigHighlighter = @import("SimpleZig.zig").SimpleZigHighlighter;
