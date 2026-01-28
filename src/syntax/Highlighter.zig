const std = @import("std");
const Allocator = std.mem.Allocator;
const StyleRegistry = @import("StyleRegistry.zig");

pub const SyntaxStyle = StyleRegistry.SyntaxStyle;

pub const Span = struct {
    start: usize,
    end: usize,
    style_id: u32,
};

pub const SpanBuffer = struct {
    spans: std.ArrayListUnmanaged(Span) = .empty,
    allocator: Allocator,

    pub fn init(allocator: Allocator) SpanBuffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SpanBuffer) void {
        self.spans.deinit(self.allocator);
    }

    pub fn clear(self: *SpanBuffer) void {
        self.spans.clearRetainingCapacity();
    }

    pub fn append(self: *SpanBuffer, span: Span) !void {
        try self.spans.append(self.allocator, span);
    }
};

pub const HighlightError = error{
    OutOfMemory,
    LanguageNotFound,
    HighlightFailed,
};

pub const HighlightFn = *const fn (ctx: *anyopaque, text: []const u8, spans: *SpanBuffer, styles: *SyntaxStyle) HighlightError!void;

pub const Highlighter = struct {
    ctx: *anyopaque,
    highlightFn: HighlightFn,

    pub fn highlight(self: Highlighter, text: []const u8, spans: *SpanBuffer, styles: *SyntaxStyle) HighlightError!void {
        return self.highlightFn(self.ctx, text, spans, styles);
    }
};

pub const HighlighterRegistry = struct {
    allocator: Allocator,
    global_allocator: Allocator,
    arena: *std.heap.ArenaAllocator,
    name_to_highlighter: std.StringHashMapUnmanaged(Highlighter),

    pub fn init(global_allocator: Allocator) HighlightError!*HighlighterRegistry {
        const self = global_allocator.create(HighlighterRegistry) catch return HighlightError.OutOfMemory;
        errdefer global_allocator.destroy(self);

        const internal_arena = global_allocator.create(std.heap.ArenaAllocator) catch return HighlightError.OutOfMemory;
        errdefer global_allocator.destroy(internal_arena);
        internal_arena.* = std.heap.ArenaAllocator.init(global_allocator);

        const internal_allocator = internal_arena.allocator();

        self.* = .{
            .allocator = internal_allocator,
            .global_allocator = global_allocator,
            .arena = internal_arena,
            .name_to_highlighter = .{},
        };

        return self;
    }

    pub fn deinit(self: *HighlighterRegistry) void {
        self.name_to_highlighter.deinit(self.allocator);
        self.arena.deinit();
        self.global_allocator.destroy(self.arena);
        self.global_allocator.destroy(self);
    }

    pub fn register(self: *HighlighterRegistry, language: []const u8, highlighter: Highlighter) HighlightError!void {
        const owned = self.allocator.dupe(u8, language) catch return HighlightError.OutOfMemory;
        try self.name_to_highlighter.put(self.allocator, owned, highlighter);
    }

    pub fn highlight(self: *HighlighterRegistry, language: []const u8, text: []const u8, spans: *SpanBuffer, styles: *SyntaxStyle) HighlightError!void {
        const highlighter = self.name_to_highlighter.get(language) orelse return HighlightError.LanguageNotFound;
        spans.clear();
        return highlighter.highlight(text, spans, styles);
    }

    pub fn highlightOrEmpty(self: *HighlighterRegistry, language: []const u8, text: []const u8, spans: *SpanBuffer, styles: *SyntaxStyle) bool {
        self.highlight(language, text, spans, styles) catch |err| {
            switch (err) {
                error.LanguageNotFound, error.HighlightFailed, error.OutOfMemory => {},
            }
            spans.clear();
            return false;
        };
        return true;
    }
};
