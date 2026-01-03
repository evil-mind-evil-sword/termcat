//! Markdown: Markdown text rendering widget
//!
//! A widget for displaying formatted markdown text with support for
//! headers, bold, italic, code blocks, lists, and links.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const Event = @import("../Event.zig");
const unicode = @import("../unicode/width.zig");

/// Markdown block type
pub const BlockType = enum {
    paragraph,
    heading1,
    heading2,
    heading3,
    heading4,
    code_block,
    bullet_list,
    numbered_list,
    blockquote,
    horizontal_rule,
};

/// A parsed markdown block
pub const Block = struct {
    block_type: BlockType = .paragraph,
    content: []const u8,
    /// Indentation level (for nested lists)
    indent: u8 = 0,
    /// List item number (for numbered lists)
    number: ?u16 = null,
    /// Code language (for code blocks)
    language: ?[]const u8 = null,
};

/// Markdown widget
pub const Markdown = struct {
    /// Parsed blocks
    blocks: []const Block,
    /// Scroll offset (in rendered lines)
    scroll_offset: usize = 0,
    /// Visible height
    visible_height: u16 = 20,
    /// Text width (for wrapping)
    text_width: u16 = 80,
    /// Show line numbers in code blocks
    show_code_line_numbers: bool = false,
    /// Heading 1 style
    h1_style: Style = .{ .attrs = .{ .bold = true, .underline = true } },
    /// Heading 2 style
    h2_style: Style = .{ .attrs = .{ .bold = true } },
    /// Heading 3 style
    h3_style: Style = .{ .attrs = .{ .bold = true }, .fg = .{ .index = 7 } },
    /// Heading 4 style
    h4_style: Style = .{ .fg = .{ .index = 7 } },
    /// Normal text style
    text_style: Style = .{},
    /// Bold style
    bold_style: Style = .{ .attrs = .{ .bold = true } },
    /// Italic style
    italic_style: Style = .{ .attrs = .{ .italic = true } },
    /// Code style (inline)
    code_style: Style = .{ .fg = .{ .index = 3 }, .bg = .{ .index = 0 } },
    /// Code block style
    code_block_style: Style = .{ .fg = .{ .index = 7 }, .bg = .{ .index = 0 } },
    /// Blockquote style
    blockquote_style: Style = .{ .fg = .{ .index = 8 } },
    /// Link style
    link_style: Style = .{ .fg = .{ .index = 4 }, .attrs = .{ .underline = true } },
    /// Bullet character
    bullet_char: u21 = '•',
    /// Widget state
    widget_state: Widget.WidgetState = .{},

    /// Create a markdown widget from pre-parsed blocks
    pub fn init(blocks: []const Block) Markdown {
        return .{ .blocks = blocks };
    }

    // Builder methods

    /// Set visible height
    pub fn withHeight(self: *Markdown, height: u16) *Markdown {
        self.visible_height = height;
        return self;
    }

    /// Set text width
    pub fn withWidth(self: *Markdown, width: u16) *Markdown {
        self.text_width = width;
        return self;
    }

    /// Set heading 1 style
    pub fn withH1Style(self: *Markdown, style: Style) *Markdown {
        self.h1_style = style;
        return self;
    }

    /// Set heading 2 style
    pub fn withH2Style(self: *Markdown, style: Style) *Markdown {
        self.h2_style = style;
        return self;
    }

    /// Set code block style
    pub fn withCodeBlockStyle(self: *Markdown, style: Style) *Markdown {
        self.code_block_style = style;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *Markdown, state: Widget.WidgetState) *Markdown {
        self.widget_state = state;
        return self;
    }

    // Navigation

    /// Scroll up
    pub fn scrollUp(self: *Markdown) void {
        if (self.scroll_offset > 0) {
            self.scroll_offset -= 1;
        }
    }

    /// Scroll down
    pub fn scrollDown(self: *Markdown) void {
        self.scroll_offset += 1;
    }

    /// Scroll to top
    pub fn scrollToTop(self: *Markdown) void {
        self.scroll_offset = 0;
    }

    /// Page up
    pub fn pageUp(self: *Markdown) void {
        if (self.scroll_offset >= self.visible_height) {
            self.scroll_offset -= self.visible_height;
        } else {
            self.scroll_offset = 0;
        }
    }

    /// Page down
    pub fn pageDown(self: *Markdown) void {
        self.scroll_offset += self.visible_height;
    }

    // Widget interface

    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Markdown = @ptrCast(@alignCast(ptr));
        return .{
            .width = @min(self.text_width, constraint.max_width),
            .height = @min(self.visible_height, constraint.max_height),
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Markdown = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0) return;

        var render_y: usize = 0; // Logical line being rendered
        var screen_y: i32 = 0; // Screen position

        for (self.blocks) |block| {
            if (screen_y >= size.height) break;

            const lines_to_render = countBlockLines(block, size.width);

            for (0..lines_to_render) |line_in_block| {
                if (render_y < self.scroll_offset) {
                    render_y += 1;
                    continue;
                }

                if (screen_y >= size.height) break;

                renderBlockLine(self, view, block, line_in_block, size.width, screen_y);
                screen_y += 1;
                render_y += 1;
            }

            // Add blank line after block (except for lists)
            if (block.block_type != .bullet_list and block.block_type != .numbered_list) {
                if (render_y >= self.scroll_offset and screen_y < size.height) {
                    clearLine(view, size.width, screen_y, self.text_style);
                    screen_y += 1;
                }
                render_y += 1;
            }
        }

        // Fill remaining lines
        while (screen_y < size.height) : (screen_y += 1) {
            clearLine(view, size.width, screen_y, self.text_style);
        }
    }

    fn countBlockLines(block: Block, width: u16) usize {
        if (block.block_type == .horizontal_rule) return 1;

        const effective_width = switch (block.block_type) {
            .bullet_list, .numbered_list => width -| (2 + block.indent * 2),
            .blockquote => width -| 2,
            else => width,
        };

        if (effective_width == 0) return 1;
        if (block.content.len == 0) return 1;

        // Count display width for proper line wrapping
        const display_width = countDisplayWidth(block.content);
        if (display_width == 0) return 1;

        return (display_width + effective_width - 1) / effective_width;
    }

    /// Count display width of text (terminal cells, not codepoints)
    fn countDisplayWidth(text: []const u8) usize {
        const view = std.unicode.Utf8View.init(text) catch return text.len;
        var iter = view.iterator();
        var width: usize = 0;
        while (iter.nextCodepoint()) |cp| {
            width += unicode.codePointWidth(cp);
        }
        return width;
    }

    /// Slice text by display width (returns byte slice that fits in max_width cells)
    fn sliceByDisplayWidth(text: []const u8, start_width: usize, max_width: usize) []const u8 {
        const view = std.unicode.Utf8View.init(text) catch return "";
        var iter = view.iterator();

        // Skip to start width
        var current_width: usize = 0;
        while (current_width < start_width) {
            const cp = iter.nextCodepoint() orelse return "";
            current_width += unicode.codePointWidth(cp);
        }

        const start_byte = iter.i;

        // Collect up to max_width cells
        var collected_width: usize = 0;
        while (collected_width < max_width) {
            const cp = iter.nextCodepoint() orelse break;
            const cp_width = unicode.codePointWidth(cp);
            if (collected_width + cp_width > max_width) break;
            collected_width += cp_width;
        }

        const end_byte = iter.i;
        return text[start_byte..end_byte];
    }

    fn renderBlockLine(self: *Markdown, view: *PlaneView, block: Block, line_in_block: usize, width: u16, y: i32) void {
        const style = switch (block.block_type) {
            .heading1 => self.h1_style,
            .heading2 => self.h2_style,
            .heading3 => self.h3_style,
            .heading4 => self.h4_style,
            .code_block => self.code_block_style,
            .blockquote => self.blockquote_style,
            else => self.text_style,
        };

        // Clear line first
        clearLine(view, width, y, style);

        var x: u16 = 0;

        // Handle special block prefixes
        switch (block.block_type) {
            .horizontal_rule => {
                // Draw horizontal line
                while (x < width) : (x += 1) {
                    view.setCell(@intCast(x), y, makeCell('─', style.fg, style.bg));
                }
                return;
            },
            .blockquote => {
                view.setCell(0, y, makeCell('│', self.blockquote_style.fg, style.bg));
                view.setCell(1, y, makeCell(' ', style.fg, style.bg));
                x = 2;
            },
            .bullet_list => {
                // Indent
                const indent_x = block.indent * 2;
                x = indent_x;
                if (line_in_block == 0 and x < width) {
                    view.setCell(@intCast(x), y, makeCell(self.bullet_char, style.fg, style.bg));
                    x += 1;
                    if (x < width) {
                        view.setCell(@intCast(x), y, makeCell(' ', style.fg, style.bg));
                        x += 1;
                    }
                } else {
                    x += 2; // Continuation indent
                }
            },
            .numbered_list => {
                const indent_x = block.indent * 2;
                x = indent_x;
                if (line_in_block == 0) {
                    if (block.number) |num| {
                        var buf: [8]u8 = undefined;
                        const num_str = std.fmt.bufPrint(&buf, "{d}.", .{num}) catch "?.";
                        const num_len: u16 = @intCast(@min(num_str.len, width -| x));
                        view.print(@intCast(x), y, num_str[0..num_len], style.fg, style.bg, style.attrs);
                        x += num_len;
                        if (x < width) {
                            view.setCell(@intCast(x), y, makeCell(' ', style.fg, style.bg));
                            x += 1;
                        }
                    }
                } else {
                    x += 3; // Continuation indent
                }
            },
            .heading1, .heading2, .heading3, .heading4 => {
                // Headers get rendered directly
            },
            else => {},
        }

        // Calculate content slice for this line (codepoint-aware)
        const effective_width = width -| x;
        if (effective_width == 0) return;

        const content = sliceByDisplayWidth(block.content, line_in_block * effective_width, effective_width);
        if (content.len == 0) return;

        // Render content with inline formatting
        renderInlineText(self, view, content, x, y, style, width);
    }

    fn renderInlineText(self: *Markdown, view: *PlaneView, text: []const u8, start_x: u16, y: i32, base_style: Style, width: u16) void {
        var x = start_x;
        var current_style = base_style;
        var in_bold = false;
        var in_italic = false;
        var in_code = false;

        // Use UTF-8 iterator for proper codepoint handling
        const utf8_view = std.unicode.Utf8View.init(text) catch {
            // Fallback: render as replacement characters for invalid UTF-8
            while (x < width and x - start_x < text.len) {
                view.setCell(@intCast(x), y, makeCell(0xFFFD, current_style.fg, current_style.bg));
                x += 1;
            }
            return;
        };
        var iter = utf8_view.iterator();

        while (x < width) {
            const codepoint = iter.nextCodepoint() orelse break;

            // Check for formatting markers (all ASCII single-byte)
            if (codepoint == '*' and !in_code) {
                // Peek next codepoint for bold check
                const saved_i = iter.i;
                const next = iter.nextCodepoint();
                if (next != null and next.? == '*') {
                    // Bold toggle
                    in_bold = !in_bold;
                    current_style = if (in_bold) self.bold_style else base_style;
                    if (in_italic) current_style.attrs.italic = true;
                    continue;
                } else {
                    // Italic toggle - restore iterator position
                    iter.i = saved_i;
                    in_italic = !in_italic;
                    current_style = if (in_italic) self.italic_style else base_style;
                    if (in_bold) current_style.attrs.bold = true;
                    continue;
                }
            } else if (codepoint == '`') {
                in_code = !in_code;
                current_style = if (in_code) self.code_style else base_style;
                continue;
            }

            // Render codepoint with proper width handling
            const char_width: u16 = @intCast(unicode.codePointWidth(codepoint));
            if (char_width == 0) continue; // Skip combining characters
            if (x + char_width > width) break; // No room for wide char
            view.setCell(@intCast(x), y, makeCell(codepoint, current_style.fg, current_style.bg));
            x += char_width;
        }
    }

    fn clearLine(view: *PlaneView, width: u16, y: i32, style: Style) void {
        for (0..width) |x| {
            view.setCell(@intCast(x), y, makeCell(' ', style.fg, style.bg));
        }
    }

    fn makeCell(char: u21, fg: Cell.Color, bg: Cell.Color) Cell {
        return .{
            .char = char,
            .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
            .fg = fg,
            .bg = bg,
            .attrs = .{},
        };
    }

    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *Markdown = @ptrCast(@alignCast(ptr));

        if (self.widget_state.disabled or !self.widget_state.focused) {
            return .ignored;
        }

        switch (event) {
            .key => |key| {
                if (key.special) |special| {
                    switch (special) {
                        .up => {
                            self.scrollUp();
                            return .consumed;
                        },
                        .down => {
                            self.scrollDown();
                            return .consumed;
                        },
                        .home => {
                            self.scrollToTop();
                            return .consumed;
                        },
                        .page_up => {
                            self.pageUp();
                            return .consumed;
                        },
                        .page_down => {
                            self.pageDown();
                            return .consumed;
                        },
                        else => {},
                    }
                }
                if (key.codepoint) |cp| {
                    switch (cp) {
                        'k' => {
                            self.scrollUp();
                            return .consumed;
                        },
                        'j' => {
                            self.scrollDown();
                            return .consumed;
                        },
                        'g' => {
                            self.scrollToTop();
                            return .consumed;
                        },
                        else => {},
                    }
                }
            },
            .mouse => |mouse| {
                if (mouse.button == .wheel_up) {
                    self.scrollUp();
                    return .consumed;
                } else if (mouse.button == .wheel_down) {
                    self.scrollDown();
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
// Simple markdown parser helper
// ============================================================================

/// Parse a line into a block type (simple heuristic parser)
pub fn parseBlockType(line: []const u8) struct { block_type: BlockType, content: []const u8, number: ?u16 } {
    const trimmed = std.mem.trimLeft(u8, line, " \t");

    if (trimmed.len == 0) {
        return .{ .block_type = .paragraph, .content = "", .number = null };
    }

    // Horizontal rule
    if (trimmed.len >= 3 and (std.mem.startsWith(u8, trimmed, "---") or std.mem.startsWith(u8, trimmed, "***") or std.mem.startsWith(u8, trimmed, "___"))) {
        var all_same = true;
        const first = trimmed[0];
        for (trimmed) |c| {
            if (c != first and c != ' ') {
                all_same = false;
                break;
            }
        }
        if (all_same) {
            return .{ .block_type = .horizontal_rule, .content = "", .number = null };
        }
    }

    // Headers
    if (std.mem.startsWith(u8, trimmed, "#### ")) {
        return .{ .block_type = .heading4, .content = trimmed[5..], .number = null };
    }
    if (std.mem.startsWith(u8, trimmed, "### ")) {
        return .{ .block_type = .heading3, .content = trimmed[4..], .number = null };
    }
    if (std.mem.startsWith(u8, trimmed, "## ")) {
        return .{ .block_type = .heading2, .content = trimmed[3..], .number = null };
    }
    if (std.mem.startsWith(u8, trimmed, "# ")) {
        return .{ .block_type = .heading1, .content = trimmed[2..], .number = null };
    }

    // Blockquote
    if (std.mem.startsWith(u8, trimmed, "> ")) {
        return .{ .block_type = .blockquote, .content = trimmed[2..], .number = null };
    }
    if (std.mem.startsWith(u8, trimmed, ">")) {
        return .{ .block_type = .blockquote, .content = trimmed[1..], .number = null };
    }

    // Bullet list
    if (trimmed.len >= 2 and (trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') and trimmed[1] == ' ') {
        return .{ .block_type = .bullet_list, .content = trimmed[2..], .number = null };
    }

    // Numbered list
    if (trimmed.len >= 3) {
        var num_end: usize = 0;
        while (num_end < trimmed.len and trimmed[num_end] >= '0' and trimmed[num_end] <= '9') {
            num_end += 1;
        }
        if (num_end > 0 and num_end < trimmed.len and trimmed[num_end] == '.' and num_end + 1 < trimmed.len and trimmed[num_end + 1] == ' ') {
            const num = std.fmt.parseInt(u16, trimmed[0..num_end], 10) catch 1;
            return .{ .block_type = .numbered_list, .content = trimmed[num_end + 2 ..], .number = num };
        }
    }

    // Code block (fence)
    if (std.mem.startsWith(u8, trimmed, "```")) {
        return .{ .block_type = .code_block, .content = trimmed[3..], .number = null };
    }

    return .{ .block_type = .paragraph, .content = trimmed, .number = null };
}

// ============================================================================
// Tests
// ============================================================================

const Plane = @import("../Plane.zig");

test "Markdown init" {
    const blocks = [_]Block{
        .{ .block_type = .heading1, .content = "Title" },
        .{ .block_type = .paragraph, .content = "Hello world" },
    };
    const md = Markdown.init(&blocks);
    try std.testing.expectEqual(@as(usize, 2), md.blocks.len);
}

test "Markdown navigation" {
    const blocks = [_]Block{};
    var md = Markdown.init(&blocks);

    try std.testing.expectEqual(@as(usize, 0), md.scroll_offset);

    md.scrollDown();
    try std.testing.expectEqual(@as(usize, 1), md.scroll_offset);

    md.scrollUp();
    try std.testing.expectEqual(@as(usize, 0), md.scroll_offset);

    md.scrollUp(); // Should stay at 0
    try std.testing.expectEqual(@as(usize, 0), md.scroll_offset);
}

test "Markdown measure" {
    const blocks = [_]Block{};
    var md = Markdown.init(&blocks);
    _ = md.withHeight(15).withWidth(60);

    const widget = Widget.Widget.init(Markdown, &md);
    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));

    try std.testing.expectEqual(@as(u16, 60), measured.width);
    try std.testing.expectEqual(@as(u16, 15), measured.height);
}

test "Markdown handleEvent down" {
    const blocks = [_]Block{};
    var md = Markdown.init(&blocks);
    _ = md.withState(.{ .focused = true });

    const widget = Widget.Widget.init(Markdown, &md);
    const event = Event.Event{ .key = Event.Key.fromSpecial(.down, .{}) };

    const result = widget.handleEvent(event);
    try std.testing.expectEqual(Widget.EventResult.consumed, result);
    try std.testing.expectEqual(@as(usize, 1), md.scroll_offset);
}

test "Markdown render" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 40, .height = 5 });
    defer root.deinit();

    const blocks = [_]Block{
        .{ .block_type = .heading1, .content = "Hello" },
    };
    var md = Markdown.init(&blocks);

    const widget = Widget.Widget.init(Markdown, &md);
    var view = PlaneView.init(root);
    widget.render(&view);

    // Heading should be visible
    try std.testing.expectEqual(@as(u21, 'H'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'e'), view.getCell(1, 0).?.char);
}

test "parseBlockType heading" {
    const h1 = parseBlockType("# Title");
    try std.testing.expectEqual(BlockType.heading1, h1.block_type);
    try std.testing.expectEqualStrings("Title", h1.content);

    const h2 = parseBlockType("## Subtitle");
    try std.testing.expectEqual(BlockType.heading2, h2.block_type);

    const h3 = parseBlockType("### Section");
    try std.testing.expectEqual(BlockType.heading3, h3.block_type);
}

test "parseBlockType bullet list" {
    const bullet = parseBlockType("- Item");
    try std.testing.expectEqual(BlockType.bullet_list, bullet.block_type);
    try std.testing.expectEqualStrings("Item", bullet.content);

    const star = parseBlockType("* Another");
    try std.testing.expectEqual(BlockType.bullet_list, star.block_type);
}

test "parseBlockType numbered list" {
    const num = parseBlockType("1. First");
    try std.testing.expectEqual(BlockType.numbered_list, num.block_type);
    try std.testing.expectEqualStrings("First", num.content);
    try std.testing.expectEqual(@as(?u16, 1), num.number);

    const num2 = parseBlockType("42. Item");
    try std.testing.expectEqual(@as(?u16, 42), num2.number);
}

test "parseBlockType blockquote" {
    const quote = parseBlockType("> Quote text");
    try std.testing.expectEqual(BlockType.blockquote, quote.block_type);
    try std.testing.expectEqualStrings("Quote text", quote.content);
}

test "parseBlockType horizontal rule" {
    const hr1 = parseBlockType("---");
    try std.testing.expectEqual(BlockType.horizontal_rule, hr1.block_type);

    const hr2 = parseBlockType("***");
    try std.testing.expectEqual(BlockType.horizontal_rule, hr2.block_type);
}

test "parseBlockType paragraph" {
    const para = parseBlockType("Normal text");
    try std.testing.expectEqual(BlockType.paragraph, para.block_type);
    try std.testing.expectEqualStrings("Normal text", para.content);
}

test "BlockType values" {
    try std.testing.expectEqual(BlockType.paragraph, BlockType.paragraph);
    try std.testing.expectEqual(BlockType.heading1, BlockType.heading1);
    try std.testing.expectEqual(BlockType.code_block, BlockType.code_block);
}
