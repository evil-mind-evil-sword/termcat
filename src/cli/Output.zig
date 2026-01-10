//! Mode-aware output formatting for CLI applications.
//!
//! Provides a unified interface for outputting data in different formats
//! (human-readable, JSON, quiet mode) based on flags and TTY detection.

const std = @import("std");
const CliError = @import("Error.zig").CliError;
const writeJsonEscaped = @import("Error.zig").writeJsonEscaped;

/// Output mode determines formatting strategy.
pub const Mode = enum {
    /// Human-readable output with formatting.
    human,
    /// Minified JSON output.
    json,
    /// Pretty-printed JSON with indentation.
    json_pretty,
    /// Minimal output (IDs only) for scripting.
    quiet,
    /// Condensed output with truncation.
    summary,
};

/// Color output mode.
pub const ColorMode = enum {
    /// Detect from TTY and environment.
    auto,
    /// Always use colors.
    always,
    /// Never use colors.
    never,

    pub fn shouldColor(self: ColorMode, is_tty: bool) bool {
        return switch (self) {
            .auto => is_tty,
            .always => true,
            .never => false,
        };
    }
};

/// Output context for CLI applications.
///
/// Wraps a writer with mode and formatting state.
pub const Output = struct {
    /// The underlying file for output.
    file: std.fs.File,
    mode: Mode,
    color: ColorMode,
    width: u16,
    is_tty: bool,
    /// Allocator for JSON serialization.
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize output context with stdout and default settings.
    /// Note: Uses page_allocator by default; for frequent JSON output,
    /// use initWithAllocator() with an arena or general purpose allocator.
    pub fn init() Self {
        const stdout = std.fs.File.stdout();
        return .{
            .file = stdout,
            .mode = .human,
            .color = .auto,
            .width = 80, // Default width; use termcat.tui for actual terminal size
            .is_tty = stdout.isTty(),
            .allocator = std.heap.page_allocator,
        };
    }

    /// Initialize output context with stdout and custom allocator.
    /// Prefer this for frequent JSON output to avoid per-allocation syscalls.
    pub fn initWithAllocator(allocator: std.mem.Allocator) Self {
        const stdout = std.fs.File.stdout();
        return .{
            .file = stdout,
            .mode = .human,
            .color = .auto,
            .width = 80,
            .is_tty = stdout.isTty(),
            .allocator = allocator,
        };
    }

    /// Initialize with explicit file and allocator (for testing).
    pub fn initWithFile(file: std.fs.File, allocator: std.mem.Allocator) Self {
        return .{
            .file = file,
            .mode = .human,
            .color = .never,
            .width = 80,
            .is_tty = false,
            .allocator = allocator,
        };
    }

    /// Set output mode.
    pub fn setMode(self: *Self, mode: Mode) void {
        self.mode = mode;
    }

    /// Set mode from common CLI flags.
    pub fn setModeFromFlags(self: *Self, json: bool, quiet: bool, summary: bool, pretty: bool) void {
        if (quiet) {
            self.mode = .quiet;
        } else if (json) {
            self.mode = if (pretty) .json_pretty else .json;
        } else if (summary) {
            self.mode = .summary;
        } else {
            self.mode = .human;
        }
    }

    /// Output a single record, dispatching based on mode.
    pub fn record(self: *Self, value: anytype) !void {
        switch (self.mode) {
            .json, .json_pretty => try self.writeJson(value),
            .quiet => try self.writeQuiet(value),
            .human, .summary => try self.writeHuman(value),
        }
    }

    /// Output a list of records.
    pub fn list(self: *Self, comptime T: type, values: []const T) !void {
        switch (self.mode) {
            .json, .json_pretty => {
                const options: std.json.Stringify.Options = if (self.mode == .json_pretty)
                    .{ .whitespace = .indent_2 }
                else
                    .{};
                const json_str = std.json.Stringify.valueAlloc(self.allocator, values, options) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                };
                defer self.allocator.free(json_str);
                try self.file.writeAll(json_str);
                try self.file.writeAll("\n");
            },
            .quiet => {
                for (values) |v| {
                    try self.writeQuiet(v);
                }
            },
            .human, .summary => {
                for (values) |v| {
                    try self.writeHuman(v);
                }
            },
        }
    }

    /// Write JSON output.
    fn writeJson(self: *Self, value: anytype) !void {
        const options: std.json.Stringify.Options = if (self.mode == .json_pretty)
            .{ .whitespace = .indent_2 }
        else
            .{};
        const json_str = std.json.Stringify.valueAlloc(self.allocator, value, options) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer self.allocator.free(json_str);
        try self.file.writeAll(json_str);
        try self.file.writeAll("\n");
    }

    /// Write quiet output (ID field only).
    fn writeQuiet(self: *Self, value: anytype) !void {
        const T = @TypeOf(value);
        const type_info = @typeInfo(T);

        if (type_info == .@"struct") {
            // Look for common ID field names
            inline for (type_info.@"struct".fields) |field| {
                if (std.mem.eql(u8, field.name, "id") or
                    std.mem.eql(u8, field.name, "ID") or
                    std.mem.eql(u8, field.name, "Id"))
                {
                    const id_value = @field(value, field.name);
                    const IdType = @TypeOf(id_value);
                    var buf: [256]u8 = undefined;
                    // Use {s} for string types, {} for integers
                    const msg = if (IdType == []const u8 or IdType == []u8)
                        std.fmt.bufPrint(&buf, "{s}\n", .{id_value}) catch return error.FormatError
                    else if (@typeInfo(IdType) == .int)
                        std.fmt.bufPrint(&buf, "{d}\n", .{id_value}) catch return error.FormatError
                    else
                        std.fmt.bufPrint(&buf, "{any}\n", .{id_value}) catch return error.FormatError;
                    try self.file.writeAll(msg);
                    return;
                }
            }
        }

        // Fallback to JSON if no ID field
        try self.writeJson(value);
    }

    /// Write human-readable output.
    fn writeHuman(self: *Self, value: anytype) !void {
        const T = @TypeOf(value);
        const type_info = @typeInfo(T);

        var buf: [4096]u8 = undefined;
        var pos: usize = 0;

        if (type_info == .@"struct") {
            // Simple key: value format
            inline for (type_info.@"struct".fields, 0..) |field, i| {
                if (i > 0) {
                    if (pos + 2 <= buf.len) {
                        buf[pos] = ' ';
                        buf[pos + 1] = ' ';
                        pos += 2;
                    }
                }
                const field_value = @field(value, field.name);
                const FieldType = @TypeOf(field_value);
                // Use {s} for string types, {d} for integers, {any} fallback
                const slice = if (FieldType == []const u8 or FieldType == []u8)
                    std.fmt.bufPrint(buf[pos..], "{s}: {s}", .{ field.name, field_value }) catch break
                else if (@typeInfo(FieldType) == .int)
                    std.fmt.bufPrint(buf[pos..], "{s}: {d}", .{ field.name, field_value }) catch break
                else
                    std.fmt.bufPrint(buf[pos..], "{s}: {any}", .{ field.name, field_value }) catch break;
                pos += slice.len;
            }
            if (pos < buf.len) {
                buf[pos] = '\n';
                pos += 1;
            }
            try self.file.writeAll(buf[0..pos]);
        } else if (T == []const u8 or T == []u8) {
            const slice = std.fmt.bufPrint(&buf, "{s}\n", .{value}) catch return error.FormatError;
            try self.file.writeAll(slice);
        } else if (type_info == .int) {
            const slice = std.fmt.bufPrint(&buf, "{d}\n", .{value}) catch return error.FormatError;
            try self.file.writeAll(slice);
        } else {
            const slice = std.fmt.bufPrint(&buf, "{any}\n", .{value}) catch return error.FormatError;
            try self.file.writeAll(slice);
        }
    }

    /// Print a success message (suppressed in JSON/quiet mode).
    pub fn success(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        if (self.mode == .json or self.mode == .json_pretty or self.mode == .quiet) return;
        var buf: [4096]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return error.FormatError;
        try self.file.writeAll(slice);
    }

    /// Print an info message (suppressed in JSON/quiet mode).
    pub fn info(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        if (self.mode == .json or self.mode == .json_pretty or self.mode == .quiet) return;
        var buf: [4096]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return error.FormatError;
        try self.file.writeAll(slice);
    }

    /// Print an error.
    pub fn err(self: *Self, error_val: CliError) !void {
        const stderr_file = std.fs.File.stderr();
        var buf: [4096]u8 = undefined;
        var escape_buf: [1024]u8 = undefined;

        switch (self.mode) {
            .json, .json_pretty => {
                // Format JSON error with proper escaping
                var pos: usize = 0;
                const escaped_msg = writeJsonEscaped(&escape_buf, error_val.message);
                const header = std.fmt.bufPrint(buf[pos..], "{{\"error\":\"{s}\",\"code\":{d}", .{
                    escaped_msg,
                    @intFromEnum(error_val.code),
                }) catch return error.FormatError;
                pos += header.len;

                if (error_val.context) |ctx| {
                    const escaped_ctx = writeJsonEscaped(&escape_buf, ctx);
                    const ctx_part = std.fmt.bufPrint(buf[pos..], ",\"context\":\"{s}\"", .{escaped_ctx}) catch return error.FormatError;
                    pos += ctx_part.len;
                }
                if (error_val.suggestion) |sug| {
                    const escaped_sug = writeJsonEscaped(&escape_buf, sug);
                    const sug_part = std.fmt.bufPrint(buf[pos..], ",\"suggestion\":\"{s}\"", .{escaped_sug}) catch return error.FormatError;
                    pos += sug_part.len;
                }
                if (pos + 2 <= buf.len) {
                    buf[pos] = '}';
                    buf[pos + 1] = '\n';
                    pos += 2;
                }
                try stderr_file.writeAll(buf[0..pos]);
            },
            else => {
                var pos: usize = 0;
                const err_msg = std.fmt.bufPrint(buf[pos..], "error: {s}\n", .{error_val.message}) catch return error.FormatError;
                pos += err_msg.len;

                if (error_val.context) |ctx| {
                    const ctx_part = std.fmt.bufPrint(buf[pos..], "       {s}\n", .{ctx}) catch return error.FormatError;
                    pos += ctx_part.len;
                }
                if (error_val.suggestion) |sug| {
                    const sug_part = std.fmt.bufPrint(buf[pos..], "\nhint: {s}\n", .{sug}) catch return error.FormatError;
                    pos += sug_part.len;
                }
                try stderr_file.writeAll(buf[0..pos]);
            },
        }
    }

    /// Raw write for custom formatting.
    pub fn write(self: *Self, bytes: []const u8) !void {
        try self.file.writeAll(bytes);
    }

    /// Raw print for custom formatting.
    pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        var buf: [4096]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, fmt, args) catch return error.FormatError;
        try self.file.writeAll(slice);
    }
};

test "Output mode selection" {
    // Create a temporary file for testing
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_file = tmp_dir.dir.createFile("test_output", .{ .read = true }) catch unreachable;
    defer tmp_file.close();

    var output = Output.initWithFile(tmp_file, std.testing.allocator);

    // Test flag combinations
    output.setModeFromFlags(true, false, false, false);
    try std.testing.expectEqual(Mode.json, output.mode);

    output.setModeFromFlags(false, true, false, false);
    try std.testing.expectEqual(Mode.quiet, output.mode);

    output.setModeFromFlags(true, false, false, true);
    try std.testing.expectEqual(Mode.json_pretty, output.mode);

    // quiet takes precedence
    output.setModeFromFlags(true, true, false, false);
    try std.testing.expectEqual(Mode.quiet, output.mode);
}

test "Output record formatting" {
    // Create a temporary file for testing
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_file = tmp_dir.dir.createFile("test_output", .{ .read = true }) catch unreachable;
    defer tmp_file.close();

    var output = Output.initWithFile(tmp_file, std.testing.allocator);

    const TestRecord = struct {
        id: []const u8,
        name: []const u8,
    };

    const rec = TestRecord{ .id = "abc123", .name = "test" };

    // JSON mode
    output.mode = .json;
    try output.record(rec);

    // Seek back to read what was written
    try tmp_file.seekTo(0);
    var read_buf: [1024]u8 = undefined;
    const bytes_read = try tmp_file.readAll(&read_buf);
    const json_output = read_buf[0..bytes_read];
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"id\":\"abc123\"") != null);

    // Quiet mode - create new file
    const tmp_file2 = tmp_dir.dir.createFile("test_output2", .{ .read = true }) catch unreachable;
    defer tmp_file2.close();
    output.file = tmp_file2;
    output.mode = .quiet;
    try output.record(rec);

    try tmp_file2.seekTo(0);
    const bytes_read2 = try tmp_file2.readAll(&read_buf);
    const quiet_output = read_buf[0..bytes_read2];
    try std.testing.expectEqualStrings("abc123\n", quiet_output);
}
