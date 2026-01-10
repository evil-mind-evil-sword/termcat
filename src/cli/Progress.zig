//! Progress indicators for CLI applications.
//!
//! Provides non-TUI spinners and progress bars that work in
//! standard terminal output (no alternate screen).

const std = @import("std");
const Output = @import("Output.zig").Output;
const Mode = @import("Output.zig").Mode;

/// Spinner animation styles.
pub const SpinnerStyle = enum {
    /// Unicode dots: ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏
    dots,
    /// ASCII: |/-\
    ascii,
    /// Block characters: ▖▘▝▗
    blocks,
    /// Simple arrow: ←↖↑↗→↘↓↙
    arrows,

    pub fn frames(self: SpinnerStyle) []const []const u8 {
        return switch (self) {
            .dots => &.{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
            .ascii => &.{ "|", "/", "-", "\\" },
            .blocks => &.{ "▖", "▘", "▝", "▗" },
            .arrows => &.{ "←", "↖", "↑", "↗", "→", "↘", "↓", "↙" },
        };
    }
};

/// Animated spinner for indeterminate progress.
pub const Spinner = struct {
    output: *Output,
    message: []const u8,
    style: SpinnerStyle,
    frame: usize,
    started: bool,

    const Self = @This();

    pub fn init(output: *Output, message: []const u8) Self {
        return .{
            .output = output,
            .message = message,
            .style = .dots,
            .frame = 0,
            .started = false,
        };
    }

    pub fn withStyle(self: Self, style: SpinnerStyle) Self {
        var copy = self;
        copy.style = style;
        return copy;
    }

    /// Update spinner animation.
    pub fn tick(self: *Self) !void {
        // Only show spinner in human mode
        if (self.output.mode != .human) return;

        const frames_slice = self.style.frames();

        // Clear line and redraw
        if (self.started) {
            try self.output.file.writeAll("\r\x1b[K");
        }
        self.started = true;

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s} {s}", .{
            frames_slice[self.frame % frames_slice.len],
            self.message,
        }) catch return;
        try self.output.file.writeAll(msg);

        self.frame +%= 1;
    }

    /// Complete spinner with success message.
    pub fn done(self: *Self, result: []const u8) !void {
        if (self.output.mode != .human) return;

        if (self.started) {
            try self.output.file.writeAll("\r\x1b[K");
        }
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "✓ {s}\n", .{result}) catch return;
        try self.output.file.writeAll(msg);
    }

    /// Complete spinner with failure message.
    pub fn fail(self: *Self, error_msg: []const u8) !void {
        if (self.output.mode != .human) return;

        if (self.started) {
            try self.output.file.writeAll("\r\x1b[K");
        }
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "✗ {s}\n", .{error_msg}) catch return;
        try self.output.file.writeAll(msg);
    }

    /// Clear spinner without completion message.
    pub fn clear(self: *Self) !void {
        if (self.output.mode != .human) return;

        if (self.started) {
            try self.output.file.writeAll("\r\x1b[K");
            self.started = false;
        }
    }
};

/// Progress bar for determinate progress.
pub const ProgressBar = struct {
    output: *Output,
    total: u64,
    current: u64,
    message: []const u8,
    width: u16,
    style: BarStyle,
    started: bool,

    pub const BarStyle = struct {
        filled: u8 = '#',
        empty: u8 = ' ',
        left_cap: []const u8 = "[",
        right_cap: []const u8 = "]",
    };

    const Self = @This();

    pub fn init(output: *Output, total: u64, message: []const u8) Self {
        return .{
            .output = output,
            .total = total,
            .current = 0,
            .message = message,
            .width = 40,
            .style = .{},
            .started = false,
        };
    }

    pub fn withWidth(self: Self, width: u16) Self {
        var copy = self;
        copy.width = width;
        return copy;
    }

    pub fn withStyle(self: Self, style: BarStyle) Self {
        var copy = self;
        copy.style = style;
        return copy;
    }

    /// Update progress bar to new value.
    pub fn update(self: *Self, current: u64) !void {
        if (self.output.mode != .human) return;

        self.current = @min(current, self.total);

        // Clear line
        if (self.started) {
            try self.output.file.writeAll("\r\x1b[K");
        }
        self.started = true;

        // Calculate fill
        const percent: f64 = if (self.total > 0)
            @as(f64, @floatFromInt(self.current)) / @as(f64, @floatFromInt(self.total))
        else
            0;

        const filled = @as(u16, @intFromFloat(percent * @as(f64, @floatFromInt(self.width))));

        // Build output in buffer
        var buf: [256]u8 = undefined;
        var pos: usize = 0;

        // Left cap
        const left = self.style.left_cap;
        @memcpy(buf[pos .. pos + left.len], left);
        pos += left.len;

        // Bar contents
        var i: u16 = 0;
        while (i < self.width) : (i += 1) {
            if (pos < buf.len) {
                buf[pos] = if (i < filled) self.style.filled else self.style.empty;
                pos += 1;
            }
        }

        // Right cap
        const right = self.style.right_cap;
        if (pos + right.len <= buf.len) {
            @memcpy(buf[pos .. pos + right.len], right);
            pos += right.len;
        }

        // Percentage and message
        const suffix = std.fmt.bufPrint(buf[pos..], " {d:>3}% {s}", .{
            @as(u8, @intFromFloat(percent * 100)),
            self.message,
        }) catch "";
        pos += suffix.len;

        try self.output.file.writeAll(buf[0..pos]);
    }

    /// Increment progress by amount.
    pub fn increment(self: *Self, amount: u64) !void {
        try self.update(self.current + amount);
    }

    /// Complete progress bar.
    pub fn finish(self: *Self) !void {
        try self.update(self.total);
        if (self.output.mode == .human) {
            try self.output.file.writeAll("\n");
        }
    }

    /// Clear progress bar.
    pub fn clear(self: *Self) !void {
        if (self.output.mode != .human) return;

        if (self.started) {
            try self.output.file.writeAll("\r\x1b[K");
            self.started = false;
        }
    }
};

/// Simple status line that updates in place.
pub const StatusLine = struct {
    output: *Output,
    started: bool,

    pub fn init(output: *Output) StatusLine {
        return .{ .output = output, .started = false };
    }

    /// Update status message.
    pub fn update(self: *StatusLine, comptime fmt: []const u8, args: anytype) !void {
        if (self.output.mode != .human) return;

        if (self.started) {
            try self.output.file.writeAll("\r\x1b[K");
        }
        self.started = true;

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        try self.output.file.writeAll(msg);
    }

    /// Finalize with newline.
    pub fn finish(self: *StatusLine) !void {
        if (self.output.mode != .human) return;
        if (self.started) {
            try self.output.file.writeAll("\n");
            self.started = false;
        }
    }

    /// Clear without newline.
    pub fn clear(self: *StatusLine) !void {
        if (self.output.mode != .human) return;
        if (self.started) {
            try self.output.file.writeAll("\r\x1b[K");
            self.started = false;
        }
    }
};

test "Spinner styles" {
    try std.testing.expect(SpinnerStyle.dots.frames().len == 10);
    try std.testing.expect(SpinnerStyle.ascii.frames().len == 4);
}

test "ProgressBar calculation" {
    // Create a temporary file for testing
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_file = tmp_dir.dir.createFile("test_progress", .{ .read = true }) catch unreachable;
    defer tmp_file.close();

    var output = Output.initWithFile(tmp_file, std.testing.allocator);
    output.mode = .human;

    var bar = ProgressBar.init(&output, 100, "Loading");
    try bar.update(50);

    // Read back what was written
    try tmp_file.seekTo(0);
    var buf: [256]u8 = undefined;
    const bytes_read = try tmp_file.readAll(&buf);
    const result = buf[0..bytes_read];
    try std.testing.expect(std.mem.indexOf(u8, result, "50%") != null);
}
