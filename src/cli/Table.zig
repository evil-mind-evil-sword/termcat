//! Column-based table formatting for CLI output.
//!
//! Provides fixed-width table rendering with alignment, truncation,
//! and Unicode-aware width calculations.

const std = @import("std");
const unicode = @import("../root.zig").unicode;

/// Column definition for table layout.
pub const Column = struct {
    /// Header text.
    header: []const u8,
    /// Column width specification.
    width: Width,
    /// Text alignment within column.
    alignment: Alignment = .left,
    /// How to handle overflow.
    truncation: Truncation = .ellipsis,

    pub const Width = union(enum) {
        /// Fixed character width.
        fixed: u16,
        /// Minimum and maximum bounds.
        min_max: struct { min: u16, max: u16 },
        /// Flexible proportion of remaining space.
        flex: f32,
    };

    pub const Alignment = enum { left, center, right };

    pub const Truncation = enum {
        /// No truncation, overflow.
        none,
        /// Truncate with "..." suffix.
        ellipsis,
        /// Fade last characters.
        fade,
    };
};

/// Table formatter with fixed column definitions.
pub fn Table(comptime columns: []const Column) type {
    return struct {
        writer: std.io.AnyWriter,
        widths: [columns.len]u16,
        separator: []const u8 = "  ",

        const Self = @This();

        /// Initialize table with calculated widths.
        pub fn init(writer: std.io.AnyWriter, total_width: u16) Self {
            var self = Self{
                .writer = writer,
                .widths = undefined,
            };

            // Calculate widths
            var fixed_total: u16 = 0;
            var flex_total: f32 = 0;
            const sep_width = @as(u16, @intCast(self.separator.len * (columns.len - 1)));

            inline for (columns, 0..) |col, i| {
                switch (col.width) {
                    .fixed => |w| {
                        self.widths[i] = w;
                        fixed_total += w;
                    },
                    .min_max => |mm| {
                        self.widths[i] = mm.min;
                        fixed_total += mm.min;
                    },
                    .flex => |f| {
                        flex_total += f;
                        self.widths[i] = 0;
                    },
                }
            }

            // Distribute remaining space to flex columns
            const remaining = if (total_width > fixed_total + sep_width)
                total_width - fixed_total - sep_width
            else
                0;

            if (flex_total > 0) {
                inline for (columns, 0..) |col, i| {
                    if (col.width == .flex) {
                        const proportion = col.width.flex / flex_total;
                        self.widths[i] = @intFromFloat(@as(f32, @floatFromInt(remaining)) * proportion);
                    }
                }
            }

            return self;
        }

        /// Write table header row.
        pub fn header(self: *Self) !void {
            inline for (columns, 0..) |col, i| {
                if (i > 0) try self.writer.writeAll(self.separator);
                try self.writeCell(col.header, self.widths[i], col.alignment, .none);
            }
            try self.writer.writeByte('\n');
        }

        /// Write a data row.
        pub fn row(self: *Self, values: [columns.len][]const u8) !void {
            inline for (columns, 0..) |col, i| {
                if (i > 0) try self.writer.writeAll(self.separator);
                try self.writeCell(values[i], self.widths[i], col.alignment, col.truncation);
            }
            try self.writer.writeByte('\n');
        }

        /// Write a horizontal separator line.
        pub fn separator_line(self: *Self) !void {
            var first = true;
            inline for (0..columns.len) |i| {
                if (!first) try self.writer.writeAll(self.separator);
                first = false;
                var j: u16 = 0;
                while (j < self.widths[i]) : (j += 1) {
                    try self.writer.writeByte('-');
                }
            }
            try self.writer.writeByte('\n');
        }

        fn writeCell(
            self: *Self,
            text: []const u8,
            width: u16,
            alignment: Column.Alignment,
            truncation: Column.Truncation,
        ) !void {
            const text_width = unicode.stringWidth(text);
            const w = @as(usize, width);

            if (text_width <= w) {
                // Text fits, apply padding
                const padding = w - text_width;
                const left_pad = switch (alignment) {
                    .left => 0,
                    .center => padding / 2,
                    .right => padding,
                };
                const right_pad = padding - left_pad;

                try self.writer.writeByteNTimes(' ', left_pad);
                try self.writer.writeAll(text);
                try self.writer.writeByteNTimes(' ', right_pad);
            } else {
                // Text overflows, truncate
                switch (truncation) {
                    .none => try self.writer.writeAll(text),
                    .ellipsis => try self.writeEllipsis(text, w),
                    .fade => try self.writeFade(text, w),
                }
            }
        }

        fn writeEllipsis(self: *Self, text: []const u8, max_width: usize) !void {
            if (max_width <= 3) {
                try self.writer.writeByteNTimes('.', max_width);
                return;
            }

            const target_width = max_width - 3;
            var written: usize = 0;
            var byte_pos: usize = 0;

            while (byte_pos < text.len) {
                const cp_len = std.unicode.utf8ByteSequenceLength(text[byte_pos]) catch 1;
                const cp_slice = text[byte_pos..@min(byte_pos + cp_len, text.len)];
                const cp = std.unicode.utf8Decode(cp_slice) catch 0xFFFD;
                const cp_width = unicode.codePointWidth(cp);

                if (written + cp_width > target_width) break;

                try self.writer.writeAll(cp_slice);
                written += cp_width;
                byte_pos += cp_len;
            }

            // Pad if needed and add ellipsis
            while (written < target_width) : (written += 1) {
                try self.writer.writeByte(' ');
            }
            try self.writer.writeAll("...");
        }

        fn writeFade(self: *Self, text: []const u8, max_width: usize) !void {
            // Simple fade using progressively dimmer characters
            const fade_chars = "░▒▓";
            const fade_len: usize = 3;

            if (max_width <= fade_len) {
                try self.writeEllipsis(text, max_width);
                return;
            }

            const target_width = max_width - fade_len;
            var written: usize = 0;
            var byte_pos: usize = 0;

            while (byte_pos < text.len) {
                const cp_len = std.unicode.utf8ByteSequenceLength(text[byte_pos]) catch 1;
                const cp_slice = text[byte_pos..@min(byte_pos + cp_len, text.len)];
                const cp = std.unicode.utf8Decode(cp_slice) catch 0xFFFD;
                const cp_width = unicode.codePointWidth(cp);

                if (written + cp_width > target_width) break;

                try self.writer.writeAll(cp_slice);
                written += cp_width;
                byte_pos += cp_len;
            }

            while (written < target_width) : (written += 1) {
                try self.writer.writeByte(' ');
            }
            try self.writer.writeAll(fade_chars);
        }
    };
}

/// Simple table without comptime columns.
pub const DynamicTable = struct {
    writer: std.io.AnyWriter,
    columns: []const Column,
    widths: []u16,
    separator: []const u8 = "  ",
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, writer: std.io.AnyWriter, cols: []const Column, total_width: u16) !DynamicTable {
        const widths = try allocator.alloc(u16, cols.len);

        // First pass: calculate fixed widths and count flex columns
        var fixed_total: u16 = 0;
        var flex_count: u16 = 0;
        const separator_overhead: u16 = if (cols.len > 1) @as(u16, @intCast((cols.len - 1) * 2)) else 0;

        for (cols) |col| {
            switch (col.width) {
                .fixed => |w| fixed_total += w,
                .min_max => |mm| fixed_total += mm.min,
                .flex => flex_count += 1,
            }
        }

        // Calculate flex column width
        const available = if (total_width > fixed_total + separator_overhead)
            total_width - fixed_total - separator_overhead
        else
            0;
        const flex_width: u16 = if (flex_count > 0) @max(10, available / flex_count) else 0;

        // Second pass: assign widths
        for (cols, 0..) |col, i| {
            widths[i] = switch (col.width) {
                .fixed => |w| w,
                .min_max => |mm| mm.min,
                .flex => flex_width,
            };
        }

        return .{
            .writer = writer,
            .columns = cols,
            .widths = widths,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DynamicTable) void {
        self.allocator.free(self.widths);
    }

    pub fn header(self: *DynamicTable) !void {
        for (self.columns, 0..) |col, i| {
            if (i > 0) try self.writer.writeAll(self.separator);
            try writeCell(self.writer, col.header, self.widths[i], col.alignment, .none);
        }
        try self.writer.writeByte('\n');
    }

    pub fn row(self: *DynamicTable, values: []const []const u8) !void {
        for (self.columns, 0..) |col, i| {
            if (i > 0) try self.writer.writeAll(self.separator);
            const value = if (i < values.len) values[i] else "";
            try writeCell(self.writer, value, self.widths[i], col.alignment, col.truncation);
        }
        try self.writer.writeByte('\n');
    }
};

fn writeCell(
    writer: std.io.AnyWriter,
    text: []const u8,
    width: u16,
    alignment: Column.Alignment,
    truncation: Column.Truncation,
) !void {
    const text_width = unicode.stringWidth(text);
    const w = @as(usize, width);

    if (text_width <= w) {
        const padding = w - text_width;
        const left_pad = switch (alignment) {
            .left => 0,
            .center => padding / 2,
            .right => padding,
        };
        const right_pad = padding - left_pad;

        try writer.writeByteNTimes(' ', left_pad);
        try writer.writeAll(text);
        try writer.writeByteNTimes(' ', right_pad);
    } else {
        switch (truncation) {
            .none => try writer.writeAll(text),
            .ellipsis => {
                if (w <= 3) {
                    try writer.writeByteNTimes('.', w);
                } else {
                    // Truncate to width - 3, then add "..."
                    const target = w - 3;
                    var written: usize = 0;
                    var byte_pos: usize = 0;
                    while (byte_pos < text.len and written < target) {
                        const cp_len = std.unicode.utf8ByteSequenceLength(text[byte_pos]) catch 1;
                        const cp_slice = text[byte_pos..@min(byte_pos + cp_len, text.len)];
                        const cp = std.unicode.utf8Decode(cp_slice) catch 0xFFFD;
                        const cp_width = unicode.codePointWidth(cp);
                        if (written + cp_width > target) break;
                        try writer.writeAll(cp_slice);
                        written += cp_width;
                        byte_pos += cp_len;
                    }
                    while (written < target) : (written += 1) try writer.writeByte(' ');
                    try writer.writeAll("...");
                }
            },
            .fade => {
                // Simplified fade
                if (w <= 3) {
                    try writer.writeByteNTimes('.', w);
                } else {
                    const target = w - 3;
                    var written: usize = 0;
                    var byte_pos: usize = 0;
                    while (byte_pos < text.len and written < target) {
                        const cp_len = std.unicode.utf8ByteSequenceLength(text[byte_pos]) catch 1;
                        const cp_slice = text[byte_pos..@min(byte_pos + cp_len, text.len)];
                        const cp = std.unicode.utf8Decode(cp_slice) catch 0xFFFD;
                        const cp_width = unicode.codePointWidth(cp);
                        if (written + cp_width > target) break;
                        try writer.writeAll(cp_slice);
                        written += cp_width;
                        byte_pos += cp_len;
                    }
                    while (written < target) : (written += 1) try writer.writeByte(' ');
                    try writer.writeAll("...");
                }
            },
        }
    }
}

test "Table basic output" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const TestTable = Table(&.{
        .{ .header = "ID", .width = .{ .fixed = 8 } },
        .{ .header = "Name", .width = .{ .fixed = 12 } },
        .{ .header = "Status", .width = .{ .fixed = 10 }, .alignment = .right },
    });

    var table = TestTable.init(fbs.writer().any(), 80);
    try table.header();
    try table.row(.{ "abc123", "Test Item", "open" });

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "ID") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Test Item") != null);
}

test "Table truncation" {
    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const TestTable = Table(&.{
        .{ .header = "Name", .width = .{ .fixed = 10 }, .truncation = .ellipsis },
    });

    var table = TestTable.init(fbs.writer().any(), 80);
    try table.row(.{"This is a very long name that should be truncated"});

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "...") != null);
    try std.testing.expect(output.len <= 15); // 10 + newline + some buffer
}
