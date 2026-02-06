//! Line-mode input/output helpers for REPL-style applications.
//!
//! This module provides:
//! - LineMode: raw input decoding without alternate screen
//! - LineOutput: stdout writer with optional CRLF normalization
//!
//! Intended for REPLs that want termcat key decoding while letting stdout
//! scroll normally.

const std = @import("std");
const builtin = @import("builtin");
const Event = @import("Event.zig");
const Input = @import("input/Input.zig");
const InputReader = @import("input/InputReader.zig");

pub const LineOutput = struct {
    file: std.fs.File,
    translate_newlines: bool,
    prev_cr: bool,

    pub const Options = struct {
        file: std.fs.File = std.fs.File.stdout(),
        /// If null, defaults to true on Windows, false elsewhere.
        translate_newlines: ?bool = null,
    };

    pub const Writer = std.io.Writer(*LineOutput, std.fs.File.WriteError, write);

    pub fn init(options: Options) LineOutput {
        return .{
            .file = options.file,
            .translate_newlines = options.translate_newlines orelse (builtin.os.tag == .windows),
            .prev_cr = false,
        };
    }

    pub fn writeAll(self: *LineOutput, bytes: []const u8) std.fs.File.WriteError!void {
        if (!self.translate_newlines) {
            try self.file.writeAll(bytes);
            if (bytes.len > 0) {
                self.prev_cr = bytes[bytes.len - 1] == '\r';
            }
            return;
        }

        var start: usize = 0;
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            const b = bytes[i];
            if (b == '\n' and !self.prev_cr) {
                if (i > start) {
                    try self.file.writeAll(bytes[start..i]);
                }
                try self.file.writeAll("\r\n");
                start = i + 1;
                self.prev_cr = false;
                continue;
            }
            self.prev_cr = b == '\r';
        }

        if (start < bytes.len) {
            try self.file.writeAll(bytes[start..]);
        }
    }

    fn write(self: *LineOutput, bytes: []const u8) std.fs.File.WriteError!usize {
        try self.writeAll(bytes);
        return bytes.len;
    }

    pub fn writer(self: *LineOutput) Writer {
        return .{ .context = self };
    }

    pub fn resetNewlineState(self: *LineOutput) void {
        self.prev_cr = false;
    }
};

pub const LineMode = struct {
    input: InputReader,
    output: LineOutput,

    pub const Options = struct {
        input: InputReader.Options = .{},
        output: LineOutput.Options = .{},
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !LineMode {
        var input = try InputReader.init(allocator, options.input);
        errdefer input.deinit();

        return .{
            .input = input,
            .output = LineOutput.init(options.output),
        };
    }

    pub fn deinit(self: *LineMode) void {
        self.input.deinit();
        self.* = undefined;
    }

    pub fn pollEvent(self: *LineMode, timeout_ms: ?u32) !?Event.Event {
        return self.input.pollEvent(timeout_ms);
    }

    pub fn pollEventWithExtraFd(
        self: *LineMode,
        timeout_ms: ?u32,
        extra_fd: std.posix.fd_t,
    ) !?Input.PollResult {
        return self.input.pollEventWithExtraFd(timeout_ms, extra_fd);
    }

    pub fn peekEvent(self: *LineMode) !?Event.Event {
        return self.input.peekEvent();
    }

    pub fn readEvent(self: *LineMode) !?Event.Event {
        return self.input.readEvent();
    }

    pub fn getSize(self: *const LineMode) Event.Size {
        return self.input.getSize();
    }

    pub fn setEscapeTimeout(self: *LineMode, timeout_ms: u32) void {
        self.input.setEscapeTimeout(timeout_ms);
    }

    pub fn resetInput(self: *LineMode) void {
        self.input.reset();
    }

    pub fn writeAll(self: *LineMode, bytes: []const u8) std.fs.File.WriteError!void {
        try self.output.writeAll(bytes);
    }

    pub fn writer(self: *LineMode) LineOutput.Writer {
        return self.output.writer();
    }
};

test "LineOutput translates newlines" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_file = tmp_dir.dir.createFile("line_output", .{ .read = true }) catch unreachable;
    defer tmp_file.close();

    var out = LineOutput.init(.{
        .file = tmp_file,
        .translate_newlines = true,
    });

    try out.writeAll("hello\nworld");

    try tmp_file.seekTo(0);
    var buf: [64]u8 = undefined;
    const n = try tmp_file.readAll(&buf);
    try std.testing.expectEqualStrings("hello\r\nworld", buf[0..n]);
}

test "LineOutput preserves CRLF across writes" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_file = tmp_dir.dir.createFile("line_output_crlf", .{ .read = true }) catch unreachable;
    defer tmp_file.close();

    var out = LineOutput.init(.{
        .file = tmp_file,
        .translate_newlines = true,
    });

    try out.writeAll("hello\r");
    try out.writeAll("\nworld");

    try tmp_file.seekTo(0);
    var buf: [64]u8 = undefined;
    const n = try tmp_file.readAll(&buf);
    try std.testing.expectEqualStrings("hello\r\nworld", buf[0..n]);
}

test "LineOutput raw mode passthrough" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_file = tmp_dir.dir.createFile("line_output_raw", .{ .read = true }) catch unreachable;
    defer tmp_file.close();

    var out = LineOutput.init(.{
        .file = tmp_file,
        .translate_newlines = false,
    });

    try out.writeAll("hello\nworld");

    try tmp_file.seekTo(0);
    var buf: [64]u8 = undefined;
    const n = try tmp_file.readAll(&buf);
    try std.testing.expectEqualStrings("hello\nworld", buf[0..n]);
}

test "LineMode struct size" {
    try std.testing.expect(@sizeOf(LineMode) > 0);
}
