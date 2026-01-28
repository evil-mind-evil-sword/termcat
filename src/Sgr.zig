//! Shared helpers for emitting ANSI SGR sequences.

const Cell = @import("Cell.zig");
const Color = Cell.Color;
const Attributes = Cell.Attributes;

pub const RESET_SEQ: []const u8 = "\x1b[0m";

/// Emit the minimal ANSI SGR codes needed to transition attributes.
/// Returns true if a reset (0m) was emitted.
pub fn emitAttributeDiff(
    writer: anytype,
    old_attrs: ?Attributes,
    new_attrs: Attributes,
    reset_on_null: bool,
) !bool {
    var reset_emitted = false;
    if (old_attrs == null and reset_on_null) {
        try writer.writeAll(RESET_SEQ);
        reset_emitted = true;
    }

    const old = old_attrs orelse Attributes{};

    if ((old.bold and !new_attrs.bold) or (old.dim and !new_attrs.dim)) {
        try writer.writeAll("\x1b[22m");
        if (new_attrs.bold) try writer.writeAll("\x1b[1m");
        if (new_attrs.dim) try writer.writeAll("\x1b[2m");
    } else {
        if (!old.bold and new_attrs.bold) try writer.writeAll("\x1b[1m");
        if (!old.dim and new_attrs.dim) try writer.writeAll("\x1b[2m");
    }

    if (old.italic and !new_attrs.italic) try writer.writeAll("\x1b[23m");
    if (!old.italic and new_attrs.italic) try writer.writeAll("\x1b[3m");

    if (old.underline and !new_attrs.underline) try writer.writeAll("\x1b[24m");
    if (!old.underline and new_attrs.underline) try writer.writeAll("\x1b[4m");

    if (old.blink and !new_attrs.blink) try writer.writeAll("\x1b[25m");
    if (!old.blink and new_attrs.blink) try writer.writeAll("\x1b[5m");

    if (old.reverse and !new_attrs.reverse) try writer.writeAll("\x1b[27m");
    if (!old.reverse and new_attrs.reverse) try writer.writeAll("\x1b[7m");

    if (old.strikethrough and !new_attrs.strikethrough) try writer.writeAll("\x1b[29m");
    if (!old.strikethrough and new_attrs.strikethrough) try writer.writeAll("\x1b[9m");

    return reset_emitted;
}

pub fn emitFgColor(writer: anytype, color: Color) !void {
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

pub fn emitBgColor(writer: anytype, color: Color) !void {
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
