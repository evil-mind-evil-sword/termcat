//! Structured error handling for CLI applications.
//!
//! Provides consistent error formatting across output modes (human, JSON)
//! with support for contextual hints and suggestions.

const std = @import("std");

/// Write a JSON-escaped string value (without surrounding quotes).
pub fn writeJsonEscaped(buf: []u8, s: []const u8) []const u8 {
    var pos: usize = 0;
    for (s) |c| {
        const escaped: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => null,
        };
        if (escaped) |esc| {
            if (pos + esc.len <= buf.len) {
                @memcpy(buf[pos .. pos + esc.len], esc);
                pos += esc.len;
            }
        } else if (c < 0x20) {
            // Control character - skip or use \uXXXX
            continue;
        } else {
            if (pos < buf.len) {
                buf[pos] = c;
                pos += 1;
            }
        }
    }
    return buf[0..pos];
}

/// Exit codes for CLI applications.
pub const ExitCode = enum(u8) {
    success = 0,
    runtime_error = 1,
    usage_error = 2,

    pub fn exit(self: ExitCode) noreturn {
        std.process.exit(@intFromEnum(self));
    }
};

/// Structured CLI error with context and suggestions.
pub const CliError = struct {
    code: ExitCode,
    message: []const u8,
    context: ?[]const u8 = null,
    suggestion: ?[]const u8 = null,

    pub fn usageError(message: []const u8) CliError {
        return .{ .code = .usage_error, .message = message };
    }

    pub fn runtimeError(message: []const u8) CliError {
        return .{ .code = .runtime_error, .message = message };
    }

    pub fn withContext(self: CliError, context: []const u8) CliError {
        var copy = self;
        copy.context = context;
        return copy;
    }

    pub fn withSuggestion(self: CliError, suggestion: []const u8) CliError {
        var copy = self;
        copy.suggestion = suggestion;
        return copy;
    }

    /// Format error for human-readable output.
    pub fn formatHuman(self: CliError, writer: anytype) !void {
        try writer.print("error: {s}\n", .{self.message});
        if (self.context) |ctx| {
            try writer.print("       {s}\n", .{ctx});
        }
        if (self.suggestion) |sug| {
            try writer.print("\nhint: {s}\n", .{sug});
        }
    }

    /// Format error as JSON.
    pub fn formatJson(self: CliError, writer: anytype) !void {
        var escape_buf: [1024]u8 = undefined;
        const escaped_msg = writeJsonEscaped(&escape_buf, self.message);
        try writer.print("{{\"error\":\"{s}\",\"code\":{d}", .{
            escaped_msg,
            @intFromEnum(self.code),
        });
        if (self.context) |ctx| {
            const escaped_ctx = writeJsonEscaped(&escape_buf, ctx);
            try writer.print(",\"context\":\"{s}\"", .{escaped_ctx});
        }
        if (self.suggestion) |sug| {
            const escaped_sug = writeJsonEscaped(&escape_buf, sug);
            try writer.print(",\"suggestion\":\"{s}\"", .{escaped_sug});
        }
        try writer.writeAll("}\n");
    }
};

/// Parse error kinds for argument parsing failures.
pub const ParseErrorKind = enum {
    unknown_command,
    unknown_option,
    missing_value,
    invalid_value,
    missing_required,
    too_many_positionals,
    ambiguous_option,
};

/// Parse error with argument context.
pub const ParseError = struct {
    kind: ParseErrorKind,
    arg: ?[]const u8 = null,
    expected: ?[]const u8 = null,
    field: ?[]const u8 = null,

    pub fn toCliError(self: ParseError) CliError {
        const message = switch (self.kind) {
            .unknown_command => "unknown command",
            .unknown_option => "unknown option",
            .missing_value => "missing value for option",
            .invalid_value => "invalid value",
            .missing_required => "missing required argument",
            .too_many_positionals => "too many positional arguments",
            .ambiguous_option => "ambiguous option prefix",
        };

        var err = CliError.usageError(message);

        if (self.arg) |arg| {
            err.context = arg;
        }

        return err;
    }
};

/// Common error mappings for store-based applications (jwz, tissue pattern).
pub fn mapStoreError(err: anyerror) CliError {
    return switch (err) {
        error.StoreNotFound => CliError.runtimeError("store not found")
            .withSuggestion("create a store with 'init' or set the store path"),
        error.NotFound => CliError.runtimeError("not found"),
        error.AlreadyExists => CliError.runtimeError("already exists"),
        error.DatabaseBusy => CliError.runtimeError("database is busy")
            .withSuggestion("another process may be using the store"),
        error.PermissionDenied => CliError.runtimeError("permission denied"),
        else => CliError.runtimeError(@errorName(err)),
    };
}

test "CliError formatting" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const err = CliError.usageError("missing argument")
        .withContext("--message")
        .withSuggestion("provide a value with -m <text>");

    try err.formatHuman(writer);
    const output = fbs.getWritten();

    try testing.expect(std.mem.indexOf(u8, output, "error: missing argument") != null);
    try testing.expect(std.mem.indexOf(u8, output, "--message") != null);
    try testing.expect(std.mem.indexOf(u8, output, "hint:") != null);
}

test "ParseError to CliError" {
    const parse_err = ParseError{
        .kind = .unknown_option,
        .arg = "--foo",
    };

    const cli_err = parse_err.toCliError();
    try std.testing.expectEqual(ExitCode.usage_error, cli_err.code);
    try std.testing.expectEqualStrings("unknown option", cli_err.message);
}
