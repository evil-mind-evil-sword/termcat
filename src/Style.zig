//! Pure styled text rendering for line-mode terminal output.
//!
//! Provides a lipgloss-inspired API for rendering styled text without
//! stateful writers. Each render() call returns a complete styled string
//! with ANSI escape sequences, making it safe for interleaved output.
//!
//! Example:
//! ```zig
//! const style = Style{ .fg = Color.green, .attrs = .{ .bold = true } };
//! const styled = style.render("Success!", .true_color);
//! try writer.writeAll(styled);
//! ```

const std = @import("std");
const Cell = @import("Cell.zig");
const Color = Cell.Color;
const ColorDepth = Cell.ColorDepth;
const Attributes = Cell.Attributes;

/// Style combines foreground color, background color, and text attributes.
/// Styles are immutable value types - modifications create new instances.
pub const Style = @This();

/// Foreground color
fg: Color = .default,
/// Background color
bg: Color = .default,
/// Text attributes (bold, italic, underline, etc.)
attrs: Attributes = .{},

/// Maximum size of rendered output buffer.
/// Enough for: SGR intro (2) + attrs (14) + fg (19) + bg (19) + 'm' (1) + text + reset (4)
/// Plus generous margin for long text.
pub const MAX_SGR_PREFIX: usize = 64;
pub const RESET_SEQ: []const u8 = "\x1b[0m";

/// Render styled text to a caller-provided buffer.
/// Returns a slice of the buffer containing the styled text.
/// The result includes ANSI SGR prefix and reset suffix.
///
/// Parameters:
/// - text: The text to style
/// - depth: Color depth for automatic downgrade (use detectCapabilities().color_depth)
/// - buf: Output buffer (must be at least text.len + MAX_SGR_PREFIX + RESET_SEQ.len)
///
/// Returns: Slice of buf containing the styled text, or error if buffer too small.
pub fn render(self: Style, text: []const u8, depth: ColorDepth, buf: []u8) error{BufferTooSmall}![]const u8 {
    const min_size = text.len + MAX_SGR_PREFIX + RESET_SEQ.len;
    if (buf.len < min_size) return error.BufferTooSmall;

    var pos: usize = 0;

    // Write SGR sequence
    pos += writeSgr(buf[pos..], self, depth);

    // Write text
    @memcpy(buf[pos..][0..text.len], text);
    pos += text.len;

    // Write reset
    @memcpy(buf[pos..][0..RESET_SEQ.len], RESET_SEQ);
    pos += RESET_SEQ.len;

    return buf[0..pos];
}

/// Render styled text, allocating the result.
/// Caller owns the returned slice and must free it.
pub fn renderAlloc(self: Style, allocator: std.mem.Allocator, text: []const u8, depth: ColorDepth) ![]u8 {
    const max_size = text.len + MAX_SGR_PREFIX + RESET_SEQ.len;
    const buf = try allocator.alloc(u8, max_size);
    errdefer allocator.free(buf);

    const result = self.render(text, depth, buf) catch unreachable; // buf is always big enough

    // Shrink to actual size
    if (result.len < buf.len) {
        return allocator.realloc(buf, result.len) catch buf[0..result.len];
    }
    return buf;
}

/// Write just the SGR prefix (no text, no reset).
/// Useful for streaming output where you manage reset yourself.
/// Returns number of bytes written.
pub fn writeSgrPrefix(self: Style, buf: []u8, depth: ColorDepth) usize {
    return writeSgr(buf, self, depth);
}

// Internal: Write SGR sequence to buffer, returns bytes written
fn writeSgr(buf: []u8, style: Style, depth: ColorDepth) usize {
    var pos: usize = 0;

    // Start SGR sequence
    buf[pos] = '\x1b';
    pos += 1;
    buf[pos] = '[';
    pos += 1;
    buf[pos] = '0'; // Reset first
    pos += 1;

    // Attributes
    if (style.attrs.bold) {
        buf[pos] = ';';
        buf[pos + 1] = '1';
        pos += 2;
    }
    if (style.attrs.dim) {
        buf[pos] = ';';
        buf[pos + 1] = '2';
        pos += 2;
    }
    if (style.attrs.italic) {
        buf[pos] = ';';
        buf[pos + 1] = '3';
        pos += 2;
    }
    if (style.attrs.underline) {
        buf[pos] = ';';
        buf[pos + 1] = '4';
        pos += 2;
    }
    if (style.attrs.blink) {
        buf[pos] = ';';
        buf[pos + 1] = '5';
        pos += 2;
    }
    if (style.attrs.reverse) {
        buf[pos] = ';';
        buf[pos + 1] = '7';
        pos += 2;
    }
    if (style.attrs.strikethrough) {
        buf[pos] = ';';
        buf[pos + 1] = '9';
        pos += 2;
    }

    // Foreground color
    pos += writeColorSgr(buf[pos..], style.fg.downgrade(depth), false);

    // Background color
    pos += writeColorSgr(buf[pos..], style.bg.downgrade(depth), true);

    // End SGR sequence
    buf[pos] = 'm';
    pos += 1;

    return pos;
}

// Internal: Write color SGR codes, returns bytes written
fn writeColorSgr(buf: []u8, color: Color, is_bg: bool) usize {
    var pos: usize = 0;
    const base: u8 = if (is_bg) 40 else 30;

    switch (color) {
        .default => {}, // No code needed
        .index => |idx| {
            if (idx < 8) {
                // Standard colors 0-7: ;30-37 or ;40-47
                buf[pos] = ';';
                pos += 1;
                pos += writeU8(buf[pos..], base + idx);
            } else if (idx < 16) {
                // Bright colors 8-15: ;90-97 or ;100-107
                const bright_base: u8 = if (is_bg) 100 else 90;
                buf[pos] = ';';
                pos += 1;
                pos += writeU8(buf[pos..], bright_base + (idx - 8));
            } else {
                // 256-color: ;38;5;N or ;48;5;N
                const prefix: []const u8 = if (is_bg) ";48;5;" else ";38;5;";
                @memcpy(buf[pos..][0..prefix.len], prefix);
                pos += prefix.len;
                pos += writeU8(buf[pos..], idx);
            }
        },
        .rgb => |c| {
            // True color: ;38;2;R;G;B or ;48;2;R;G;B
            const prefix: []const u8 = if (is_bg) ";48;2;" else ";38;2;";
            @memcpy(buf[pos..][0..prefix.len], prefix);
            pos += prefix.len;
            pos += writeU8(buf[pos..], c.r);
            buf[pos] = ';';
            pos += 1;
            pos += writeU8(buf[pos..], c.g);
            buf[pos] = ';';
            pos += 1;
            pos += writeU8(buf[pos..], c.b);
        },
    }

    return pos;
}

// Internal: Write u8 as decimal string, returns bytes written
fn writeU8(buf: []u8, val: u8) usize {
    if (val >= 100) {
        buf[0] = '0' + val / 100;
        buf[1] = '0' + (val / 10) % 10;
        buf[2] = '0' + val % 10;
        return 3;
    } else if (val >= 10) {
        buf[0] = '0' + val / 10;
        buf[1] = '0' + val % 10;
        return 2;
    } else {
        buf[0] = '0' + val;
        return 1;
    }
}

// Convenience constructors
pub fn foreground(color: Color) Style {
    return .{ .fg = color };
}

pub fn background(color: Color) Style {
    return .{ .bg = color };
}

pub fn bold() Style {
    return .{ .attrs = .{ .bold = true } };
}

pub fn italic() Style {
    return .{ .attrs = .{ .italic = true } };
}

pub fn underline() Style {
    return .{ .attrs = .{ .underline = true } };
}

pub fn dim() Style {
    return .{ .attrs = .{ .dim = true } };
}

// Builder methods for chaining
pub fn withFg(self: Style, color: Color) Style {
    var s = self;
    s.fg = color;
    return s;
}

pub fn withBg(self: Style, color: Color) Style {
    var s = self;
    s.bg = color;
    return s;
}

pub fn withBold(self: Style) Style {
    var s = self;
    s.attrs.bold = true;
    return s;
}

pub fn withItalic(self: Style) Style {
    var s = self;
    s.attrs.italic = true;
    return s;
}

pub fn withUnderline(self: Style) Style {
    var s = self;
    s.attrs.underline = true;
    return s;
}

pub fn withDim(self: Style) Style {
    var s = self;
    s.attrs.dim = true;
    return s;
}

// Tests
test "render basic colors" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;

    // Green bold text
    const style = Style{ .fg = Color.green, .attrs = .{ .bold = true } };
    const result = try style.render("OK", .true_color, &buf);
    try testing.expectEqualStrings("\x1b[0;1;32mOK\x1b[0m", result);
}

test "render bright colors" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;

    const style = Style{ .fg = Color.bright_red };
    const result = try style.render("Error", .true_color, &buf);
    try testing.expectEqualStrings("\x1b[0;91mError\x1b[0m", result);
}

test "render 256 color" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;

    const style = Style{ .fg = .{ .index = 202 } }; // Orange
    const result = try style.render("!", .color_256, &buf);
    try testing.expectEqualStrings("\x1b[0;38;5;202m!\x1b[0m", result);
}

test "render true color" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;

    const style = Style{ .fg = Color.fromRgb(255, 128, 0) };
    const result = try style.render("RGB", .true_color, &buf);
    try testing.expectEqualStrings("\x1b[0;38;2;255;128;0mRGB\x1b[0m", result);
}

test "render with background" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;

    const style = Style{ .fg = Color.white, .bg = Color.blue };
    const result = try style.render("Hi", .true_color, &buf);
    try testing.expectEqualStrings("\x1b[0;37;44mHi\x1b[0m", result);
}

test "render all attributes" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;

    const style = Style{
        .attrs = .{
            .bold = true,
            .dim = true,
            .italic = true,
            .underline = true,
            .blink = true,
            .reverse = true,
            .strikethrough = true,
        },
    };
    const result = try style.render("X", .true_color, &buf);
    try testing.expectEqualStrings("\x1b[0;1;2;3;4;5;7;9mX\x1b[0m", result);
}

test "downgrade true color to basic" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;

    // RGB green (0,255,0) downgrades to bright green (index 10) due to high luminance
    const style = Style{ .fg = Color.fromRgb(0, 255, 0) };
    const result = try style.render("G", .basic, &buf);
    try testing.expectEqualStrings("\x1b[0;92mG\x1b[0m", result);
}

test "downgrade dark color to basic" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;

    // Dark red downgrades to basic red (index 1)
    const style = Style{ .fg = Color.fromRgb(128, 0, 0) };
    const result = try style.render("R", .basic, &buf);
    try testing.expectEqualStrings("\x1b[0;31mR\x1b[0m", result);
}

test "builder methods" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;

    const style = Style.foreground(Color.cyan).withBold().withUnderline();
    const result = try style.render("!", .true_color, &buf);
    try testing.expectEqualStrings("\x1b[0;1;4;36m!\x1b[0m", result);
}

test "combined fg bg bold underline" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;

    const style = Style{
        .fg = Color.red,
        .bg = Color.blue,
        .attrs = .{ .bold = true, .underline = true },
    };
    const result = try style.render("X", .true_color, &buf);
    try testing.expectEqualStrings("\x1b[0;1;4;31;44mX\x1b[0m", result);
}

test "default style" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;

    const style = Style{};
    const result = try style.render("plain", .true_color, &buf);
    try testing.expectEqualStrings("\x1b[0mplain\x1b[0m", result);
}
