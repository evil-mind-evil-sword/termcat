//! StyledWriter: line-mode styled output without full TUI initialization.
//!
//! This writer wraps any std.io.Writer and emits ANSI SGR sequences for styles.
//! It tracks the current style state to avoid redundant escape codes.
//!
//! Example:
//! ```zig
//! const termcat = @import("termcat");
//! var sw = termcat.StyledWriter.init(std.io.getStdOut().writer().any(), .{});
//! try sw.setStyle(.{ .fg = termcat.Color.green, .attrs = .{ .bold = true } });
//! try sw.writeAll("Success!");
//! try sw.reset();
//! ```

const std = @import("std");
const builtin = @import("builtin");
const Cell = @import("Cell.zig");
const Style = @import("Style.zig");
const detectCapabilities = if (builtin.os.tag == .windows)
    @import("backend/windows.zig").detectCapabilities
else
    @import("backend/posix.zig").detectCapabilities;

const Color = Cell.Color;
const ColorDepth = Cell.ColorDepth;
const Attributes = Cell.Attributes;

pub const StyledWriter = struct {
    writer: std.io.AnyWriter,
    color_depth: ColorDepth,
    state: StyleState = .{},

    pub const Options = struct {
        /// Terminal color depth (defaults to detectCapabilities().color_depth).
        color_depth: ?ColorDepth = null,
    };

    /// Initialize a StyledWriter around any std.io.Writer.
    pub fn init(writer: std.io.AnyWriter, options: Options) StyledWriter {
        const depth = options.color_depth orelse detectCapabilities().color_depth;
        return .{
            .writer = writer,
            .color_depth = depth,
            .state = .{},
        };
    }

    /// Write raw bytes to the underlying writer.
    pub fn writeAll(self: *StyledWriter, bytes: []const u8) !void {
        try self.writer.writeAll(bytes);
    }

    /// Apply a style, emitting only the minimal escape sequences needed.
    pub fn setStyle(self: *StyledWriter, style: Style) !void {
        try self.state.apply(self.writer, style, self.color_depth);
    }

    /// Write text using the provided style (style remains active afterward).
    pub fn writeStyled(self: *StyledWriter, style: Style, text: []const u8) !void {
        try self.setStyle(style);
        try self.writer.writeAll(text);
    }

    /// Reset terminal styling to defaults and clear tracked state.
    pub fn reset(self: *StyledWriter) !void {
        try self.writer.writeAll(Style.RESET_SEQ);
        self.state.setDefault();
    }
};

const StyleState = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    attrs: ?Attributes = null,

    fn setDefault(self: *StyleState) void {
        self.fg = .default;
        self.bg = .default;
        self.attrs = Attributes{};
    }

    fn apply(self: *StyleState, writer: std.io.AnyWriter, style: Style, depth: ColorDepth) !void {
        const effective = Style{
            .fg = style.fg.downgrade(depth),
            .bg = style.bg.downgrade(depth),
            .attrs = style.attrs,
        };

        const need_fg_change = self.fg == null or !self.fg.?.eql(effective.fg);
        const need_bg_change = self.bg == null or !self.bg.?.eql(effective.bg);
        const need_attr_change = self.attrs == null or !self.attrs.?.eql(effective.attrs);

        if (!need_fg_change and !need_bg_change and !need_attr_change) return;

        var reset_emitted = false;
        if (need_attr_change) {
            if (self.attrs == null) {
                try writer.writeAll(Style.RESET_SEQ);
                reset_emitted = true;
            }

            const old_attrs = self.attrs orelse Attributes{};
            const new_attrs = effective.attrs;

            if ((old_attrs.bold and !new_attrs.bold) or (old_attrs.dim and !new_attrs.dim)) {
                try writer.writeAll("\x1b[22m");
                if (new_attrs.bold) try writer.writeAll("\x1b[1m");
                if (new_attrs.dim) try writer.writeAll("\x1b[2m");
            } else {
                if (!old_attrs.bold and new_attrs.bold) try writer.writeAll("\x1b[1m");
                if (!old_attrs.dim and new_attrs.dim) try writer.writeAll("\x1b[2m");
            }

            if (old_attrs.italic and !new_attrs.italic) try writer.writeAll("\x1b[23m");
            if (!old_attrs.italic and new_attrs.italic) try writer.writeAll("\x1b[3m");

            if (old_attrs.underline and !new_attrs.underline) try writer.writeAll("\x1b[24m");
            if (!old_attrs.underline and new_attrs.underline) try writer.writeAll("\x1b[4m");

            if (old_attrs.blink and !new_attrs.blink) try writer.writeAll("\x1b[25m");
            if (!old_attrs.blink and new_attrs.blink) try writer.writeAll("\x1b[5m");

            if (old_attrs.reverse and !new_attrs.reverse) try writer.writeAll("\x1b[27m");
            if (!old_attrs.reverse and new_attrs.reverse) try writer.writeAll("\x1b[7m");

            if (old_attrs.strikethrough and !new_attrs.strikethrough) try writer.writeAll("\x1b[29m");
            if (!old_attrs.strikethrough and new_attrs.strikethrough) try writer.writeAll("\x1b[9m");
        }

        if (need_fg_change and !(reset_emitted and effective.fg.eql(.default))) {
            try emitFgColor(writer, effective.fg);
        }

        if (need_bg_change and !(reset_emitted and effective.bg.eql(.default))) {
            try emitBgColor(writer, effective.bg);
        }

        self.fg = effective.fg;
        self.bg = effective.bg;
        self.attrs = effective.attrs;
    }
};

fn emitFgColor(writer: std.io.AnyWriter, color: Color) !void {
    switch (color) {
        .default => try writer.writeAll("\x1b[39m"),
        .index => |idx| {
            if (idx < 8) {
                try writer.print("\x1b[{d}m", .{30 + idx});
            } else if (idx < 16) {
                try writer.print("\x1b[{d}m", .{90 + idx - 8});
            } else {
                try writer.print("\x1b[38;5;{d}m", .{idx});
            }
        },
        .rgb => |c| {
            try writer.print("\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
        },
        .rgba => |c| {
            try writer.print("\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
        },
    }
}

fn emitBgColor(writer: std.io.AnyWriter, color: Color) !void {
    switch (color) {
        .default => try writer.writeAll("\x1b[49m"),
        .index => |idx| {
            if (idx < 8) {
                try writer.print("\x1b[{d}m", .{40 + idx});
            } else if (idx < 16) {
                try writer.print("\x1b[{d}m", .{100 + idx - 8});
            } else {
                try writer.print("\x1b[48;5;{d}m", .{idx});
            }
        },
        .rgb => |c| {
            try writer.print("\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
        },
        .rgba => |c| {
            try writer.print("\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
        },
    }
}

test "StyledWriter avoids redundant style sequences" {
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var writer = StyledWriter.init(stream.writer().any(), .{ .color_depth = .basic });

    try writer.setStyle(.{ .fg = Color.red });
    try writer.writeAll("A");
    try writer.setStyle(.{ .fg = Color.red });
    try writer.writeAll("B");

    try std.testing.expectEqualStrings("\x1b[0m\x1b[31mAB", stream.getWritten());
}

test "StyledWriter downgrades true color to 256-color" {
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var writer = StyledWriter.init(stream.writer().any(), .{ .color_depth = .color_256 });

    try writer.setStyle(.{ .fg = Color.fromRgb(255, 0, 0) });
    try writer.writeAll("X");

    const out = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "38;5;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "38;2;") == null);
}

test "StyledWriter downgrades true color to basic palette" {
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var writer = StyledWriter.init(stream.writer().any(), .{ .color_depth = .basic });

    try writer.setStyle(.{ .fg = Color.fromRgb(255, 0, 0) });
    try writer.writeAll("X");

    const out = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[91m") != null);
}

test "StyledWriter toggles all attributes on and off" {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var writer = StyledWriter.init(stream.writer().any(), .{ .color_depth = .basic });

    try writer.setStyle(.{ .attrs = .{
        .bold = true,
        .dim = true,
        .italic = true,
        .underline = true,
        .blink = true,
        .reverse = true,
        .strikethrough = true,
    } });
    try writer.writeAll("X");
    try writer.setStyle(.{});
    try writer.writeAll("Y");

    const out = stream.getWritten();
    const required_on = [_][]const u8{ "\x1b[1m", "\x1b[2m", "\x1b[3m", "\x1b[4m", "\x1b[5m", "\x1b[7m", "\x1b[9m" };
    const required_off = [_][]const u8{ "\x1b[22m", "\x1b[23m", "\x1b[24m", "\x1b[25m", "\x1b[27m", "\x1b[29m" };

    for (required_on) |seq| {
        try std.testing.expect(std.mem.indexOf(u8, out, seq) != null);
    }
    for (required_off) |seq| {
        try std.testing.expect(std.mem.indexOf(u8, out, seq) != null);
    }
}
