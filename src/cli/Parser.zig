//! Argument parsing engine for CLI applications.
//!
//! Parses command-line arguments into typed command structs using
//! comptime-derived metadata from Command.zig.

const std = @import("std");
const CommandMod = @import("Command.zig");
const Error = @import("Error.zig");
const CliError = Error.CliError;
const ExitCode = Error.ExitCode;

/// Check if a CLI option name matches a field name.
/// Handles hyphen-to-underscore normalization: "--min-year" matches field "min_year".
fn optionMatchesField(opt_name: []const u8, comptime field_name: []const u8) bool {
    if (opt_name.len != field_name.len) return false;
    for (opt_name, field_name) |opt_c, field_c| {
        const normalized = if (opt_c == '-') '_' else opt_c;
        if (normalized != field_c) return false;
    }
    return true;
}

/// Convert a comptime field name to CLI format (underscores to hyphens) with "--" prefix.
/// Returns a comptime-known string for use in error messages and string concatenation.
fn toCliOption(comptime field_name: []const u8) *const [2 + field_name.len]u8 {
    const S = struct {
        const buf = blk: {
            var b: [2 + field_name.len]u8 = undefined;
            b[0] = '-';
            b[1] = '-';
            for (field_name, 0..) |c, i| {
                b[2 + i] = if (c == '_') '-' else c;
            }
            break :blk b;
        };
    };
    return &S.buf;
}

/// Result of parsing arguments.
pub fn ParseResult(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: CliError,
        help,
        version,
    };
}

/// Parse arguments into a command struct.
/// Returns parsed struct, or signals help/version/error.
pub fn parse(comptime T: type, args: []const []const u8) ParseResult(T) {
    // Skip environment fallbacks when called without explicit env
    return parseWithEnv(T, args, null);
}

/// Result of parseWithHelp - either parsed value or "handled" meaning help/version was printed.
pub fn ParseWithHelpResult(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: CliError,
        handled: void, // Help or version was printed
    };
}

/// Parse arguments and handle help/version automatically.
///
/// This is a convenience wrapper for standalone command parsing that prints
/// help and version information automatically, avoiding the need for
/// parseApp() when you just have global options or a single command.
///
/// Example:
/// ```zig
/// const Options = struct {
///     verbose: bool = false,
///     file: []const u8,
///     pub const positional = .{.file};
///     pub const meta = .{ .name = "mytool", .version = "1.0.0" };
/// };
///
/// const result = parseWithHelp(Options, args, std.io.getStdErr().writer());
/// switch (result) {
///     .ok => |opts| runWithOptions(opts),
///     .err => |err| { printError(err); return 1; },
///     .handled => return 0, // Help/version was printed
/// }
/// ```
pub fn parseWithHelp(
    comptime T: type,
    args: []const []const u8,
    writer: anytype,
) ParseWithHelpResult(T) {
    const Help = @import("Help.zig");

    const result = parse(T, args);
    switch (result) {
        .ok => |v| return .{ .ok = v },
        .err => |e| return .{ .err = e },
        .help => {
            const help_text = Help.generateHelp(T);
            writer.writeAll(help_text) catch {};
            return .handled;
        },
        .version => {
            // Try to get version from meta declaration
            if (@hasDecl(T, "meta")) {
                const meta = T.meta;
                if (@hasField(@TypeOf(meta), "version")) {
                    const name = if (@hasField(@TypeOf(meta), "name")) meta.name else @typeName(T);
                    writer.print("{s} {s}\n", .{ name, meta.version }) catch {};
                }
            }
            return .handled;
        },
    }
}

/// Parse arguments with explicit environment.
pub fn parseWithEnv(comptime T: type, args: []const []const u8, env: anytype) ParseResult(T) {
    var result: T = undefined;
    const type_info = @typeInfo(T);

    if (type_info != .@"struct") {
        @compileError("parse() requires a struct type");
    }

    // Track which required fields have been set
    const required_fields = comptime getRequiredFields(T);
    var fields_set: [required_fields.len]bool = [_]bool{false} ** required_fields.len;

    // Initialize all fields with defaults or safe values
    inline for (type_info.@"struct".fields) |field| {
        if (field.defaultValue()) |default| {
            @field(result, field.name) = default;
            // Mark as set if it has a default, UNLESS meta.required is true
            // (meta.required means user must explicitly provide, even if there's a default)
            const meta = CommandMod.getFieldMeta(T, field.name);
            if (!meta.required) {
                inline for (required_fields, 0..) |req_field, idx| {
                    if (std.mem.eql(u8, req_field, field.name)) {
                        fields_set[idx] = true;
                    }
                }
            }
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
        } else if (field.type == []const u8) {
            // Initialize strings to empty to avoid undefined behavior
            @field(result, field.name) = "";
        } else if (field.type == bool) {
            @field(result, field.name) = false;
        } else if (@typeInfo(field.type) == .int) {
            @field(result, field.name) = 0;
        } else if (field.type == CommandMod.VariadicSlice) {
            // Initialize variadic slices to empty
            @field(result, field.name) = .{ .start = 0, .end = 0 };
        }
        // Other types left undefined - they must be set during parsing
    }

    // Count positional args for this type
    var positional_index: usize = 0;
    const positional_fields = comptime getPositionalFields(T);

    // Parse arguments
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // Check for help
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return .help;
        }

        // Check for version
        if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            return .version;
        }

        // End-of-options marker: treat all remaining args as positional
        // Must check BEFORE long option parsing since "--" matches startsWith("--")
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            // Process remaining args as positionals - after --, don't stop at option-like strings
            while (i < args.len) : (i += 1) {
                if (positional_index < positional_fields.len) {
                    // Special handling: after --, variadic consumes ALL remaining args
                    const handled = handlePositionalArgAfterSeparator(T, positional_fields, &result, &positional_index, required_fields, &fields_set, i, args);
                    if (handled.is_error) {
                        return .{ .err = handled.err.? };
                    }
                    if (handled.consumed_rest) break;
                } else {
                    return .{ .err = CliError.usageError("unexpected argument").withContext(args[i]) };
                }
            }
            break; // Done processing after --
        }

        // Long option with =
        if (std.mem.startsWith(u8, arg, "--") and std.mem.indexOf(u8, arg, "=") != null) {
            const eq_pos = std.mem.indexOf(u8, arg, "=").?;
            const opt_name = arg[2..eq_pos];
            const opt_value = arg[eq_pos + 1 ..];

            if (setFieldByName(T, &result, opt_name, opt_value)) |err| {
                return .{ .err = err };
            }
            markFieldSet(required_fields, &fields_set, opt_name);
            continue;
        }

        // Long option
        if (std.mem.startsWith(u8, arg, "--")) {
            const opt_name = arg[2..];

            // Check if it's a bool flag
            if (isBoolField(T, opt_name)) {
                if (setBoolField(T, &result, opt_name, true)) |err| {
                    return .{ .err = err };
                }
                markFieldSet(required_fields, &fields_set, opt_name);
            } else {
                // Needs a value
                if (i + 1 >= args.len) {
                    return .{ .err = CliError.usageError("missing value for option").withContext(arg) };
                }
                i += 1;
                if (setFieldByName(T, &result, opt_name, args[i])) |err| {
                    return .{ .err = err };
                }
                markFieldSet(required_fields, &fields_set, opt_name);
            }
            continue;
        }

        // Short option
        if (arg.len == 2 and arg[0] == '-' and arg[1] != '-') {
            const short = arg[1];

            // Handle short options at comptime by checking each field
            var found_short = false;
            inline for (type_info.@"struct".fields) |field| {
                const meta = CommandMod.getFieldMeta(T, field.name);
                if (meta.short) |s| {
                    if (s == short) {
                        found_short = true;
                        markFieldSet(required_fields, &fields_set, field.name);
                        if (field.type == bool) {
                            @field(result, field.name) = true;
                        } else {
                            // Needs a value
                            if (i + 1 >= args.len) {
                                return .{ .err = CliError.usageError("missing value for option").withContext(arg) };
                            }
                            i += 1;
                            if (parseValue(field.type, args[i])) |parsed| {
                                @field(result, field.name) = parsed;
                            } else |_| {
                                return .{ .err = CliError.usageError("invalid value").withContext(args[i]) };
                            }
                        }
                    }
                }
            }
            if (!found_short) {
                return .{ .err = CliError.usageError("unknown option").withContext(arg) };
            }
            continue;
        }

        // Combined short options (e.g., -abc) or short option with inline value (e.g., -uhttp://x)
        // are not supported - give a clear error
        // Exception: negative numbers like -100 should be treated as positional arguments
        if (arg.len > 2 and arg[0] == '-' and arg[1] != '-' and !std.ascii.isDigit(arg[1])) {
            return .{ .err = CliError.usageError("combined short options (-abc) and inline values (-uVALUE) not supported; use -a -b -c or -u VALUE").withContext(arg) };
        }

        // Positional argument
        if (positional_index < positional_fields.len) {
            const handled = handlePositionalArg(T, positional_fields, &result, &positional_index, required_fields, &fields_set, i, args);
            if (handled.is_error) {
                return .{ .err = handled.err.? };
            }
            if (handled.consumed_rest) {
                break; // Variadic consumed remaining args
            }
            // Update i if variadic consumed multiple args
            if (handled.new_index) |new_i| {
                i = new_i;
            }
        } else {
            return .{ .err = CliError.usageError("unexpected argument").withContext(arg) };
        }
    }

    // Apply environment variable fallbacks (only if env is provided)
    if (@TypeOf(env) != @TypeOf(null)) {
        inline for (type_info.@"struct".fields) |field| {
            const meta = CommandMod.getFieldMeta(T, field.name);
            if (meta.env) |env_var| {
                // Only apply if field is still at default/null
                if (shouldApplyEnvFallback(T, &result, field.name)) {
                    if (getEnvValue(env, env_var)) |env_value| {
                        if (setFieldByName(T, &result, field.name, env_value)) |err| {
                            return .{ .err = err };
                        }
                        markFieldSet(required_fields, &fields_set, field.name);
                    }
                }
            }
        }
    }

    // Check required fields were provided
    inline for (required_fields, 0..) |req_field, idx| {
        if (!fields_set[idx]) {
            return .{ .err = CliError.usageError("missing required argument").withContext(toCliOption(req_field)) };
        }
    }

    return .{ .ok = result };
}

fn getPositionalFields(comptime T: type) []const []const u8 {
    const type_info = @typeInfo(T);
    comptime var fields: []const []const u8 = &.{};

    inline for (type_info.@"struct".fields) |field| {
        if (CommandMod.isPositional(T, field.name)) {
            fields = fields ++ &[_][]const u8{field.name};
        }
    }

    return fields;
}

/// Result of handling a positional argument.
const PositionalHandleResult = struct {
    is_error: bool = false,
    err: ?CliError = null,
    consumed_rest: bool = false,
    new_index: ?usize = null,
};

/// Handle a single positional argument, checking each positional field at comptime.
fn handlePositionalArg(
    comptime T: type,
    comptime positional_fields: []const []const u8,
    result: *T,
    positional_index: *usize,
    comptime required_fields: []const []const u8,
    fields_set: *[required_fields.len]bool,
    current_idx: usize,
    args: []const []const u8,
) PositionalHandleResult {
    // Check each positional field at comptime
    inline for (positional_fields, 0..) |field_name, field_idx| {
        if (positional_index.* == field_idx) {
            markFieldSet(required_fields, fields_set, field_name);

            // Check at comptime if this specific field is variadic
            if (comptime CommandMod.isVariadicField(T, field_name)) {
                // Find where positional args end
                var end_idx = current_idx;
                while (end_idx < args.len) : (end_idx += 1) {
                    const next_arg = args[end_idx];
                    // Stop at options (but not --, negative numbers, or single -)
                    if (next_arg.len > 1 and next_arg[0] == '-' and next_arg[1] != '-' and !std.ascii.isDigit(next_arg[1])) {
                        break;
                    }
                    if (next_arg.len > 2 and std.mem.startsWith(u8, next_arg, "--")) {
                        break;
                    }
                }
                if (setVariadicField(T, result, field_name, current_idx, end_idx)) |err| {
                    return .{ .is_error = true, .err = err };
                }
                positional_index.* += 1;
                return .{ .consumed_rest = (end_idx >= args.len), .new_index = end_idx - 1 };
            } else {
                // Regular positional
                if (setFieldByName(T, result, field_name, args[current_idx])) |err| {
                    return .{ .is_error = true, .err = err };
                }
                positional_index.* += 1;
                return .{};
            }
        }
    }
    return .{};
}

/// Handle positional argument after -- separator (variadic consumes ALL remaining).
fn handlePositionalArgAfterSeparator(
    comptime T: type,
    comptime positional_fields: []const []const u8,
    result: *T,
    positional_index: *usize,
    comptime required_fields: []const []const u8,
    fields_set: *[required_fields.len]bool,
    current_idx: usize,
    args: []const []const u8,
) PositionalHandleResult {
    inline for (positional_fields, 0..) |field_name, field_idx| {
        if (positional_index.* == field_idx) {
            markFieldSet(required_fields, fields_set, field_name);

            if (comptime CommandMod.isVariadicField(T, field_name)) {
                // After --, variadic consumes ALL remaining args (no option checking)
                if (setVariadicField(T, result, field_name, current_idx, args.len)) |err| {
                    return .{ .is_error = true, .err = err };
                }
                positional_index.* += 1;
                return .{ .consumed_rest = true };
            } else {
                // Regular positional
                if (setFieldByName(T, result, field_name, args[current_idx])) |err| {
                    return .{ .is_error = true, .err = err };
                }
                positional_index.* += 1;
                return .{};
            }
        }
    }
    return .{};
}

/// Set a variadic field's slice indices.
fn setVariadicField(comptime T: type, result: *T, comptime field_name: []const u8, start: usize, end: usize) ?CliError {
    const type_info = @typeInfo(T);
    inline for (type_info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) {
            if (field.type == CommandMod.VariadicSlice) {
                @field(result, field.name) = .{ .start = start, .end = end };
                return null;
            } else {
                return CliError.usageError("internal error: setVariadicField on non-variadic field").withContext(field_name);
            }
        }
    }
    return CliError.usageError("unknown field").withContext(field_name);
}

/// Get list of required fields (marked required or non-optional without default).
/// Works for both command structs and global option structs.
fn getRequiredFields(comptime T: type) []const []const u8 {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") return &.{};

    comptime var fields: []const []const u8 = &.{};

    inline for (type_info.@"struct".fields) |field| {
        const meta = CommandMod.getFieldMeta(T, field.name);
        // A field is required if:
        // 1. Explicitly marked required in metadata, OR
        // 2. Non-optional type without a default value
        const is_optional = @typeInfo(field.type) == .optional;
        const has_default = field.default_value_ptr != null;
        if (meta.required or (!is_optional and !has_default)) {
            fields = fields ++ &[_][]const u8{field.name};
        }
    }

    return fields;
}

/// Mark a field as set in the tracking array.
fn markFieldSet(comptime required_fields: []const []const u8, fields_set: *[required_fields.len]bool, name: []const u8) void {
    inline for (required_fields, 0..) |req_field, idx| {
        if (optionMatchesField(name, req_field)) {
            fields_set[idx] = true;
        }
    }
}

fn isBoolField(comptime T: type, name: []const u8) bool {
    const type_info = @typeInfo(T);
    inline for (type_info.@"struct".fields) |field| {
        if (optionMatchesField(name, field.name)) {
            return field.type == bool;
        }
    }
    return false;
}

fn isBoolFieldByName(comptime T: type, comptime name: []const u8) bool {
    const type_info = @typeInfo(T);
    inline for (type_info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return field.type == bool;
        }
    }
    return false;
}

fn getFieldNameByShort(comptime T: type, short: u8) ?[]const u8 {
    const type_info = @typeInfo(T);
    inline for (type_info.@"struct".fields) |field| {
        const meta = CommandMod.getFieldMeta(T, field.name);
        if (meta.short) |s| {
            if (s == short) return field.name;
        }
    }
    return null;
}

fn setFieldByName(comptime T: type, result: *T, name: []const u8, value: []const u8) ?CliError {
    const type_info = @typeInfo(T);
    inline for (type_info.@"struct".fields) |field| {
        if (optionMatchesField(name, field.name)) {
            if (parseValue(field.type, value)) |parsed| {
                @field(result, field.name) = parsed;
                return null;
            } else |_| {
                return CliError.usageError("Invalid value for " ++ toCliOption(field.name)).withContext(value);
            }
        }
    }
    return CliError.usageError("Unknown option").withContext(name);
}

fn setBoolField(comptime T: type, result: *T, name: []const u8, value: bool) ?CliError {
    const type_info = @typeInfo(T);
    inline for (type_info.@"struct".fields) |field| {
        if (optionMatchesField(name, field.name) and field.type == bool) {
            @field(result, field.name) = value;
            return null;
        }
    }
    return CliError.usageError("Unknown flag").withContext(name);
}

fn setBoolFieldByName(comptime T: type, result: *T, comptime name: []const u8, value: bool) ?CliError {
    @field(result, name) = value;
    return null;
}

fn parseValue(comptime FieldType: type, value: []const u8) !FieldType {
    const field_info = @typeInfo(FieldType);

    if (FieldType == []const u8) {
        return value;
    }

    if (FieldType == bool) {
        if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1")) {
            return true;
        }
        if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0")) {
            return false;
        }
        return error.InvalidValue;
    }

    if (field_info == .optional) {
        const child = field_info.optional.child;
        if (child == []const u8) {
            return value;
        }
        if (@typeInfo(child) == .int) {
            return std.fmt.parseInt(child, value, 10) catch return error.InvalidValue;
        }
        return value;
    }

    if (field_info == .int) {
        return std.fmt.parseInt(FieldType, value, 10) catch return error.InvalidValue;
    }

    // Fallback for other types
    return error.InvalidValue;
}

fn shouldApplyEnvFallback(comptime T: type, result: *T, comptime field_name: []const u8) bool {
    const type_info = @typeInfo(T);
    inline for (type_info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) {
            if (@typeInfo(field.type) == .optional) {
                return @field(result, field_name) == null;
            }
            // For non-optional with defaults, check if still at default
            if (field.default_value_ptr != null) {
                // Can't easily compare, so skip env fallback for non-optional with defaults
                return false;
            }
            return true;
        }
    }
    return false;
}

fn getEnvValue(env: anytype, name: []const u8) ?[]const u8 {
    const EnvType = @TypeOf(env);
    if (EnvType == [*:null]const ?[*:0]const u8) {
        // POSIX environ format
        var i: usize = 0;
        while (env[i]) |entry| : (i += 1) {
            const entry_slice = std.mem.span(entry);
            if (std.mem.indexOf(u8, entry_slice, "=")) |eq_pos| {
                if (std.mem.eql(u8, entry_slice[0..eq_pos], name)) {
                    return entry_slice[eq_pos + 1 ..];
                }
            }
        }
    }
    return null;
}

test "parse simple struct" {
    const TestCmd = struct {
        file: []const u8 = "",
        verbose: bool = false,

        pub const positional = .{.file};
        pub const fields = .{
            .verbose = .{ .short = 'v', .description = "Enable verbose output" },
        };
    };

    const result = parse(TestCmd, &.{ "myfile.txt", "-v" });
    switch (result) {
        .ok => |cmd| {
            try std.testing.expectEqualStrings("myfile.txt", cmd.file);
            try std.testing.expect(cmd.verbose);
        },
        else => try std.testing.expect(false),
    }
}

test "parse long options" {
    const TestCmd = struct {
        output: []const u8 = "",
        json: bool = false,
    };

    const result = parse(TestCmd, &.{ "--output", "out.txt", "--json" });
    switch (result) {
        .ok => |cmd| {
            try std.testing.expectEqualStrings("out.txt", cmd.output);
            try std.testing.expect(cmd.json);
        },
        else => try std.testing.expect(false),
    }
}

test "parse help flag" {
    const TestCmd = struct {
        verbose: bool = false,
    };

    const result = parse(TestCmd, &.{"--help"});
    try std.testing.expect(result == .help);
}

test "missing required field returns error" {
    const TestCmd = struct {
        // Required field - no default, non-optional
        message: []const u8,
        verbose: bool = false,

        pub const fields = .{
            .message = .{ .short = 'm', .description = "Message body", .required = true },
        };
    };

    // Missing --message should return error
    const result = parse(TestCmd, &.{"--verbose"});
    switch (result) {
        .err => |err| {
            try std.testing.expectEqualStrings("missing required argument", err.message);
        },
        else => try std.testing.expect(false),
    }
}

test "required field provided succeeds" {
    const TestCmd = struct {
        message: []const u8,
        verbose: bool = false,

        pub const fields = .{
            .message = .{ .short = 'm', .description = "Message body" },
        };
    };

    const result = parse(TestCmd, &.{ "-m", "hello" });
    switch (result) {
        .ok => |cmd| {
            try std.testing.expectEqualStrings("hello", cmd.message);
        },
        else => try std.testing.expect(false),
    }
}

test "variadic positional parsing" {
    const CopyCmd = struct {
        dest: []const u8,
        files: CommandMod.VariadicSlice = .{},
        verbose: bool = false,

        pub const positional = .{ .dest, .files };
        pub const fields = .{
            .verbose = .{ .short = 'v' },
        };
    };

    const args = &[_][]const u8{ "output.txt", "file1.txt", "file2.txt", "file3.txt" };
    const result = parse(CopyCmd, args);
    switch (result) {
        .ok => |cmd| {
            try std.testing.expectEqualStrings("output.txt", cmd.dest);
            const files = cmd.files.items(args);
            try std.testing.expectEqual(@as(usize, 3), files.len);
            try std.testing.expectEqualStrings("file1.txt", files[0]);
            try std.testing.expectEqualStrings("file3.txt", files[2]);
        },
        else => try std.testing.expect(false),
    }
}

test "variadic with options interspersed" {
    const RunCmd = struct {
        files: CommandMod.VariadicSlice = .{},
        verbose: bool = false,

        pub const positional = .{.files};
        pub const fields = .{
            .verbose = .{ .short = 'v' },
        };
    };

    // Files followed by option - variadic stops at option
    const args = &[_][]const u8{ "a.txt", "b.txt", "-v" };
    const result = parse(RunCmd, args);
    switch (result) {
        .ok => |cmd| {
            const files = cmd.files.items(args);
            try std.testing.expectEqual(@as(usize, 2), files.len);
            try std.testing.expect(cmd.verbose);
        },
        else => try std.testing.expect(false),
    }
}

test "end-of-options marker with variadic" {
    const RunCmd = struct {
        files: CommandMod.VariadicSlice = .{},

        pub const positional = .{.files};
    };

    // Everything after -- is a file, even if it looks like an option
    const args = &[_][]const u8{ "--", "-weird-file.txt", "--another.txt" };
    const result = parse(RunCmd, args);
    switch (result) {
        .ok => |cmd| {
            const files = cmd.files.items(args);
            try std.testing.expectEqual(@as(usize, 2), files.len);
            try std.testing.expectEqualStrings("-weird-file.txt", files[0]);
            try std.testing.expectEqualStrings("--another.txt", files[1]);
        },
        else => try std.testing.expect(false),
    }
}

// =============================================================================
// App-level parsing with subcommands
// =============================================================================

/// Result of parsing app arguments with subcommands.
pub fn AppParseResult(comptime App: type) type {
    const GlobalOptions = if (@hasDecl(App, "GlobalOptions")) App.GlobalOptions else struct {};
    const CommandUnion = if (@hasDecl(App, "Command")) App.Command else void;

    return union(enum) {
        ok: struct {
            global: GlobalOptions,
            command: CommandUnion,
            /// The args slice passed to the command parser.
            /// Use this for VariadicSlice.items() to get correct indices.
            cmd_args: []const []const u8,
        },
        err: CliError,
        help,
        version,
        /// Help requested for a specific command
        command_help: []const u8,
    };
}

/// Helper to dispatch to a named command by name.
/// Used for default command dispatch and to reduce code duplication.
fn dispatchToCommand(
    comptime App: type,
    comptime CommandUnion: type,
    comptime union_info: std.builtin.Type,
    comptime cmd_name: []const u8,
    cmd_args: []const []const u8,
    global: anytype,
    comptime required_globals: []const []const u8,
    globals_set: *[required_globals.len]bool,
) AppParseResult(App) {
    inline for (union_info.@"union".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, cmd_name)) {
            // Check if this is a subcommand group
            if (@hasDecl(field.type, "is_subcommand_group") and field.type.is_subcommand_group) {
                const sub_result = parseSubcommandGroup(field.type.commands, field.name, cmd_args);
                switch (sub_result) {
                    .ok => |sub| {
                        inline for (required_globals, 0..) |req_field, idx| {
                            if (!globals_set[idx]) {
                                return .{ .err = CliError.usageError("missing required global option").withContext(toCliOption(req_field)) };
                            }
                        }
                        var wrapper: field.type = undefined;
                        wrapper.value = sub.command;
                        return .{ .ok = .{
                            .global = global,
                            .command = @unionInit(CommandUnion, field.name, wrapper),
                            .cmd_args = sub.cmd_args,
                        } };
                    },
                    .err => |err| {
                        inline for (required_globals, 0..) |req_field, idx| {
                            if (!globals_set[idx]) {
                                return .{ .err = CliError.usageError("missing required global option").withContext(toCliOption(req_field)) };
                            }
                        }
                        return .{ .err = err };
                    },
                    .help => return .{ .command_help = field.name },
                    .command_help => |sub_cmd| return .{ .command_help = sub_cmd },
                    .version => return .version,
                }
            } else {
                // Regular command
                const cmd_result = parse(field.type, cmd_args);
                switch (cmd_result) {
                    .ok => |cmd| {
                        inline for (required_globals, 0..) |req_field, idx| {
                            if (!globals_set[idx]) {
                                return .{ .err = CliError.usageError("missing required global option").withContext(toCliOption(req_field)) };
                            }
                        }
                        return .{ .ok = .{
                            .global = global,
                            .command = @unionInit(CommandUnion, field.name, cmd),
                            .cmd_args = cmd_args,
                        } };
                    },
                    .err => |err| {
                        inline for (required_globals, 0..) |req_field, idx| {
                            if (!globals_set[idx]) {
                                return .{ .err = CliError.usageError("missing required global option").withContext(toCliOption(req_field)) };
                            }
                        }
                        return .{ .err = err };
                    },
                    .help => return .{ .command_help = field.name },
                    .version => return .version,
                }
            }
        }
    }
    // Command not found in union - this is a compile-time error if default_command is invalid
    @compileError("default_command '" ++ cmd_name ++ "' not found in Command union");
}

/// Parse app arguments with global options and subcommands.
///
/// Pattern: `app [global-opts] command [command-opts]`
///
/// Global options are ONLY parsed before the command name. This prevents
/// global options from consuming subcommand tokens.
///
/// Example:
/// ```zig
/// const App = struct {
///     pub const GlobalOptions = struct {
///         url: ?[]const u8 = null,
///     };
///     pub const Command = Commands(.{
///         .health = HealthCmd,
///         .search = SearchCmd,
///     });
/// };
/// const result = parseApp(App, args);
/// ```
pub fn parseApp(comptime App: type, args: []const []const u8) AppParseResult(App) {
    const GlobalOptions = if (@hasDecl(App, "GlobalOptions")) App.GlobalOptions else struct {};
    const CommandUnion = if (@hasDecl(App, "Command")) App.Command else @compileError("App must have a Command type");

    var global: GlobalOptions = undefined;
    const global_type_info = @typeInfo(GlobalOptions);

    // Track required global options (reuse getRequiredFields for consistency)
    const required_globals = comptime getRequiredFields(GlobalOptions);
    var globals_set: [required_globals.len]bool = [_]bool{false} ** required_globals.len;

    // Initialize global options with defaults
    if (global_type_info == .@"struct") {
        inline for (global_type_info.@"struct".fields) |field| {
            if (field.defaultValue()) |default| {
                @field(global, field.name) = default;
                // Mark as set if it has a default, UNLESS meta.required is true
                // (meta.required means user must explicitly provide, even if there's a default)
                const meta = CommandMod.getFieldMeta(GlobalOptions, field.name);
                if (!meta.required) {
                    inline for (required_globals, 0..) |req_field, idx| {
                        if (std.mem.eql(u8, req_field, field.name)) {
                            globals_set[idx] = true;
                        }
                    }
                }
            } else if (@typeInfo(field.type) == .optional) {
                @field(global, field.name) = null;
            } else if (field.type == []const u8) {
                @field(global, field.name) = "";
            } else if (field.type == bool) {
                @field(global, field.name) = false;
            } else if (@typeInfo(field.type) == .int) {
                @field(global, field.name) = 0;
            }
        }
    }

    // Phase 1: Parse global options until we hit command name
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // Check for help (app-level)
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return .help;
        }

        // Check for version
        if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            return .version;
        }

        // End of options marker
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }

        // Long option with =
        if (std.mem.startsWith(u8, arg, "--") and std.mem.indexOf(u8, arg, "=") != null) {
            const eq_pos = std.mem.indexOf(u8, arg, "=").?;
            const opt_name = arg[2..eq_pos];
            const opt_value = arg[eq_pos + 1 ..];

            if (setGlobalField(GlobalOptions, &global, opt_name, opt_value)) |err| {
                return .{ .err = err };
            }
            markFieldSet(required_globals, &globals_set, opt_name);
            continue;
        }

        // Long option
        if (std.mem.startsWith(u8, arg, "--")) {
            const opt_name = arg[2..];

            if (isGlobalBoolField(GlobalOptions, opt_name)) {
                if (setGlobalBoolField(GlobalOptions, &global, opt_name, true)) |err| {
                    return .{ .err = err };
                }
                markFieldSet(required_globals, &globals_set, opt_name);
            } else if (isGlobalField(GlobalOptions, opt_name)) {
                // Needs a value
                if (i + 1 >= args.len) {
                    return .{ .err = CliError.usageError("missing value for option").withContext(arg) };
                }
                i += 1;
                if (setGlobalField(GlobalOptions, &global, opt_name, args[i])) |err| {
                    return .{ .err = err };
                }
                markFieldSet(required_globals, &globals_set, opt_name);
            } else {
                // Unknown global option - error (don't let it fall through to command)
                return .{ .err = CliError.usageError("unknown global option").withContext(arg) };
            }
            continue;
        }

        // Short option (single character only, e.g., -v)
        if (arg.len == 2 and arg[0] == '-' and arg[1] != '-') {
            const short = arg[1];
            var found = false;

            if (global_type_info == .@"struct") {
                inline for (global_type_info.@"struct".fields) |field| {
                    const meta = CommandMod.getFieldMeta(GlobalOptions, field.name);
                    if (meta.short) |s| {
                        if (s == short) {
                            found = true;
                            markFieldSet(required_globals, &globals_set, field.name);
                            if (field.type == bool) {
                                @field(global, field.name) = true;
                            } else {
                                if (i + 1 >= args.len) {
                                    return .{ .err = CliError.usageError("missing value for option").withContext(arg) };
                                }
                                i += 1;
                                if (parseValue(field.type, args[i])) |parsed| {
                                    @field(global, field.name) = parsed;
                                } else |_| {
                                    return .{ .err = CliError.usageError("invalid value").withContext(args[i]) };
                                }
                            }
                        }
                    }
                }
            }

            if (!found) {
                return .{ .err = CliError.usageError("unknown global option").withContext(arg) };
            }
            continue;
        }

        // Combined short options (e.g., -abc) or short option with inline value (e.g., -uhttp://x)
        // are not supported - give a clear error
        // Exception: negative numbers like -100 should fall through as command names
        if (arg.len > 2 and arg[0] == '-' and arg[1] != '-' and !std.ascii.isDigit(arg[1])) {
            return .{ .err = CliError.usageError("combined short options (-abc) and inline values (-uVALUE) not supported; use -a -b -c or -u VALUE").withContext(arg) };
        }

        // Non-option argument - this is the command name
        break;
    }

    // Phase 2: Identify and dispatch to command
    const union_info = @typeInfo(CommandUnion);
    if (union_info != .@"union") {
        @compileError("App.Command must be a union type (use Commands())");
    }

    // Check if we have a default command
    const has_default = @hasDecl(App, "default_command");

    if (i >= args.len) {
        // No command provided
        if (has_default) {
            // Dispatch to default command with empty args
            return dispatchToCommand(App, CommandUnion, union_info, App.default_command, &.{}, global, required_globals, &globals_set);
        }
        return .{ .err = CliError.usageError("missing command") };
    }

    const first_arg = args[i];
    const cmd_args = args[i + 1 ..];

    // Try to match against explicit command names first (subcommand takes precedence)
    inline for (union_info.@"union".fields) |field| {
        if (std.mem.eql(u8, field.name, first_arg)) {
            // Check if this is a subcommand group (has is_subcommand_group marker)
            if (@hasDecl(field.type, "is_subcommand_group") and field.type.is_subcommand_group) {
                // For subcommand groups, parse first to discover nested help requests
                const sub_result = parseSubcommandGroup(field.type.commands, field.name, cmd_args);
                switch (sub_result) {
                    .ok => |sub| {
                        // Validate required globals for successful parse
                        inline for (required_globals, 0..) |req_field, idx| {
                            if (!globals_set[idx]) {
                                return .{ .err = CliError.usageError("missing required global option").withContext(toCliOption(req_field)) };
                            }
                        }
                        // Wrap in the Subcommand struct
                        var wrapper: field.type = undefined;
                        wrapper.value = sub.command;
                        return .{ .ok = .{
                            .global = global,
                            .command = @unionInit(CommandUnion, field.name, wrapper),
                            .cmd_args = sub.cmd_args,
                        } };
                    },
                    .err => |err| {
                        // Validate globals for error cases too
                        inline for (required_globals, 0..) |req_field, idx| {
                            if (!globals_set[idx]) {
                                return .{ .err = CliError.usageError("missing required global option").withContext(toCliOption(req_field)) };
                            }
                        }
                        return .{ .err = err };
                    },
                    // Help and command_help bypass globals validation
                    .help => return .{ .command_help = field.name },
                    .command_help => |sub_cmd| return .{ .command_help = sub_cmd },
                    .version => return .version,
                }
            } else {
                // Regular command - parse first to discover help/version anywhere in args
                const cmd_result = parse(field.type, cmd_args);
                switch (cmd_result) {
                    .ok => |cmd| {
                        // Validate required globals only for successful parse
                        inline for (required_globals, 0..) |req_field, idx| {
                            if (!globals_set[idx]) {
                                return .{ .err = CliError.usageError("missing required global option").withContext(toCliOption(req_field)) };
                            }
                        }
                        return .{ .ok = .{
                            .global = global,
                            .command = @unionInit(CommandUnion, field.name, cmd),
                            .cmd_args = cmd_args,
                        } };
                    },
                    .err => |err| {
                        // Validate globals for error cases too
                        inline for (required_globals, 0..) |req_field, idx| {
                            if (!globals_set[idx]) {
                                return .{ .err = CliError.usageError("missing required global option").withContext(toCliOption(req_field)) };
                            }
                        }
                        return .{ .err = err };
                    },
                    .help => return .{ .command_help = field.name },
                    .version => return .version,
                }
            }
        }

        // Check aliases (only for regular command types, not subcommand groups)
        if (!@hasDecl(field.type, "is_subcommand_group")) {
            const cmd_meta = CommandMod.getCommandMeta(field.type);
            for (cmd_meta.aliases) |alias| {
                if (std.mem.eql(u8, alias, first_arg)) {
                    // Parse first to discover help/version
                    const cmd_result = parse(field.type, cmd_args);
                    switch (cmd_result) {
                        .ok => |cmd| {
                            // Validate required globals only for successful parse
                            inline for (required_globals, 0..) |req_field, idx| {
                                if (!globals_set[idx]) {
                                    return .{ .err = CliError.usageError("missing required global option").withContext(toCliOption(req_field)) };
                                }
                            }
                            return .{ .ok = .{
                                .global = global,
                                .command = @unionInit(CommandUnion, field.name, cmd),
                                .cmd_args = cmd_args,
                            } };
                        },
                        .err => |err| {
                            // Validate globals for error cases too
                            inline for (required_globals, 0..) |req_field, idx| {
                                if (!globals_set[idx]) {
                                    return .{ .err = CliError.usageError("missing required global option").withContext(toCliOption(req_field)) };
                                }
                            }
                            return .{ .err = err };
                        },
                        .help => return .{ .command_help = field.name },
                        .version => return .version,
                    }
                }
            }
        }
    }

    // No command matched - check for default command
    if (has_default) {
        // Dispatch to default command with ALL remaining args (including first_arg)
        return dispatchToCommand(App, CommandUnion, union_info, App.default_command, args[i..], global, required_globals, &globals_set);
    }

    return .{ .err = CliError.usageError("unknown command").withContext(first_arg) };
}

/// Result of parsing a subcommand group.
fn SubcommandGroupResult(comptime SubCommands: type) type {
    return union(enum) {
        ok: struct {
            command: SubCommands,
            /// Args slice passed to parse() - use for VariadicSlice.items()
            cmd_args: []const []const u8,
        },
        err: CliError,
        help,
        version,
        command_help: []const u8,
    };
}

/// Parse a subcommand group (e.g., "bib add" where "bib" is the group).
/// SubCommands is the union type created by Commands() or Subcommand().
fn parseSubcommandGroup(
    comptime SubCommands: type,
    parent_name: []const u8,
    args: []const []const u8,
) SubcommandGroupResult(SubCommands) {
    const sub_union_info = @typeInfo(SubCommands);

    if (sub_union_info != .@"union") {
        @compileError("Subcommand group must be a Commands union");
    }

    // Check for help on the group itself
    if (args.len > 0 and (std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help"))) {
        return .help;
    }

    // Need at least one arg for the subcommand name
    if (args.len == 0) {
        return .{ .err = CliError.usageError("missing subcommand").withContext(parent_name) };
    }

    const sub_cmd_name = args[0];
    const sub_cmd_args = args[1..];

    // Check if this is a help request for a subcommand
    const is_help_request = sub_cmd_args.len > 0 and
        (std.mem.eql(u8, sub_cmd_args[0], "-h") or std.mem.eql(u8, sub_cmd_args[0], "--help"));

    // Match subcommand name (validates it exists before returning help)
    inline for (sub_union_info.@"union".fields) |field| {
        if (std.mem.eql(u8, field.name, sub_cmd_name)) {
            // Return help for valid subcommand
            if (is_help_request) {
                return .{ .command_help = field.name };
            }

            const cmd_result = parse(field.type, sub_cmd_args);
            switch (cmd_result) {
                .ok => |cmd| {
                    return .{ .ok = .{
                        .command = @unionInit(SubCommands, field.name, cmd),
                        .cmd_args = sub_cmd_args,
                    } };
                },
                .err => |err| return .{ .err = err },
                .help => return .{ .command_help = field.name },
                .version => return .version,
            }
        }

        // Check aliases
        const cmd_meta = CommandMod.getCommandMeta(field.type);
        for (cmd_meta.aliases) |alias| {
            if (std.mem.eql(u8, alias, sub_cmd_name)) {
                // Return help for valid subcommand (via alias)
                if (is_help_request) {
                    return .{ .command_help = field.name };
                }

                const cmd_result = parse(field.type, sub_cmd_args);
                switch (cmd_result) {
                    .ok => |cmd| {
                        return .{ .ok = .{
                            .command = @unionInit(SubCommands, field.name, cmd),
                            .cmd_args = sub_cmd_args,
                        } };
                    },
                    .err => |err| return .{ .err = err },
                    .help => return .{ .command_help = field.name },
                    .version => return .version,
                }
            }
        }
    }

    return .{ .err = CliError.usageError("unknown subcommand").withContext(sub_cmd_name) };
}

// Helper functions for global option parsing

fn isGlobalField(comptime GlobalOptions: type, name: []const u8) bool {
    const type_info = @typeInfo(GlobalOptions);
    if (type_info != .@"struct") return false;

    inline for (type_info.@"struct".fields) |field| {
        if (optionMatchesField(name, field.name)) {
            return true;
        }
    }
    return false;
}

fn isGlobalBoolField(comptime GlobalOptions: type, name: []const u8) bool {
    const type_info = @typeInfo(GlobalOptions);
    if (type_info != .@"struct") return false;

    inline for (type_info.@"struct".fields) |field| {
        if (optionMatchesField(name, field.name) and field.type == bool) {
            return true;
        }
    }
    return false;
}

fn setGlobalField(comptime GlobalOptions: type, global: *GlobalOptions, name: []const u8, value: []const u8) ?CliError {
    const type_info = @typeInfo(GlobalOptions);
    if (type_info != .@"struct") return CliError.usageError("invalid global options type");

    inline for (type_info.@"struct".fields) |field| {
        if (optionMatchesField(name, field.name)) {
            if (parseValue(field.type, value)) |parsed| {
                @field(global, field.name) = parsed;
                return null;
            } else |_| {
                return CliError.usageError("invalid value for option").withContext(value);
            }
        }
    }
    return CliError.usageError("unknown global option").withContext(name);
}

fn setGlobalBoolField(comptime GlobalOptions: type, global: *GlobalOptions, name: []const u8, value: bool) ?CliError {
    const type_info = @typeInfo(GlobalOptions);
    if (type_info != .@"struct") return CliError.usageError("invalid global options type");

    inline for (type_info.@"struct".fields) |field| {
        if (optionMatchesField(name, field.name) and field.type == bool) {
            @field(global, field.name) = value;
            return null;
        }
    }
    return CliError.usageError("unknown global flag").withContext(name);
}

test "parseApp basic" {
    const HealthCmd = struct {
        verbose: bool = false,
        pub const meta = .{ .name = "health", .description = "Check health" };
    };

    const SearchCmd = struct {
        query: []const u8 = "",
        limit: u32 = 10,
        pub const positional = .{.query};
        pub const meta = .{ .name = "search", .description = "Search items" };
    };

    const TestApp = struct {
        pub const GlobalOptions = struct {
            url: ?[]const u8 = null,
            verbose: bool = false,
            pub const fields = .{
                .url = .{ .description = "Server URL" },
                .verbose = .{ .short = 'v', .description = "Verbose output" },
            };
        };

        pub const Command = CommandMod.Commands(.{
            .health = HealthCmd,
            .search = SearchCmd,
        });
    };

    // Test: global option before command
    const result1 = parseApp(TestApp, &.{ "--url", "http://localhost", "health" });
    switch (result1) {
        .ok => |r| {
            try std.testing.expectEqualStrings("http://localhost", r.global.url.?);
            try std.testing.expect(r.command == .health);
        },
        else => try std.testing.expect(false),
    }

    // Test: command with its own args
    const result2 = parseApp(TestApp, &.{ "search", "foo", "--limit", "5" });
    switch (result2) {
        .ok => |r| {
            try std.testing.expect(r.command == .search);
            try std.testing.expectEqualStrings("foo", r.command.search.query);
            try std.testing.expectEqual(@as(u32, 5), r.command.search.limit);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp rejects global option after command" {
    const HealthCmd = struct {
        verbose: bool = false,
    };

    const TestApp = struct {
        pub const GlobalOptions = struct {
            url: ?[]const u8 = null,
        };

        pub const Command = CommandMod.Commands(.{
            .health = HealthCmd,
        });
    };

    // --url after command should fail (unknown option for health command)
    const result = parseApp(TestApp, &.{ "health", "--url", "http://x" });
    switch (result) {
        .err => |err| {
            // health command doesn't know --url, so it fails
            try std.testing.expect(std.mem.indexOf(u8, err.message, "unknown") != null or
                std.mem.indexOf(u8, err.message, "Unknown") != null);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp unknown command" {
    const HealthCmd = struct {};

    const TestApp = struct {
        pub const GlobalOptions = struct {};
        pub const Command = CommandMod.Commands(.{
            .health = HealthCmd,
        });
    };

    const result = parseApp(TestApp, &.{"unknown"});
    switch (result) {
        .err => |err| {
            try std.testing.expectEqualStrings("unknown command", err.message);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp missing command" {
    const HealthCmd = struct {};

    const TestApp = struct {
        pub const GlobalOptions = struct {};
        pub const Command = CommandMod.Commands(.{
            .health = HealthCmd,
        });
    };

    const result = parseApp(TestApp, &.{});
    switch (result) {
        .err => |err| {
            try std.testing.expectEqualStrings("missing command", err.message);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp default command - no args" {
    const RunCmd = struct {
        files: CommandMod.VariadicSlice = .{},
    };
    const ConfigCmd = struct {};

    const TestApp = struct {
        pub const meta = .{ .name = "myapp" };
        pub const GlobalOptions = struct {
            verbose: bool = false,
        };
        pub const default_command = "run";
        pub const Command = CommandMod.Commands(.{
            .run = RunCmd,
            .config = ConfigCmd,
        });
    };

    // No args -> default command with empty args
    const result = parseApp(TestApp, &.{});
    switch (result) {
        .ok => |r| {
            try std.testing.expect(r.command == .run);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp default command - with positional args" {
    const RunCmd = struct {
        files: CommandMod.VariadicSlice = .{},
        pub const positional = .{.files};
    };
    const ConfigCmd = struct {};

    const TestApp = struct {
        pub const meta = .{ .name = "myapp" };
        pub const GlobalOptions = struct {};
        pub const default_command = "run";
        pub const Command = CommandMod.Commands(.{
            .run = RunCmd,
            .config = ConfigCmd,
        });
    };

    // Args that don't match a command -> default command
    const args = &[_][]const u8{ "file1.txt", "file2.txt" };
    const result = parseApp(TestApp, args);
    switch (result) {
        .ok => |r| {
            try std.testing.expect(r.command == .run);
            // Use cmd_args for correct VariadicSlice indexing
            const files = r.command.run.files.items(r.cmd_args);
            try std.testing.expectEqual(@as(usize, 2), files.len);
            try std.testing.expectEqualStrings("file1.txt", files[0]);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp default command with global options - variadic indexing" {
    const RunCmd = struct {
        files: CommandMod.VariadicSlice = .{},
        pub const positional = .{.files};
    };
    const ConfigCmd = struct {};

    const TestApp = struct {
        pub const GlobalOptions = struct {
            verbose: bool = false,
            pub const fields = .{ .verbose = .{ .short = 'v' } };
        };
        pub const default_command = "run";
        pub const Command = CommandMod.Commands(.{
            .run = RunCmd,
            .config = ConfigCmd,
        });
    };

    // Global option before positional args - tests that cmd_args is correct
    const args = &[_][]const u8{ "-v", "file1.txt", "file2.txt" };
    const result = parseApp(TestApp, args);
    switch (result) {
        .ok => |r| {
            try std.testing.expect(r.global.verbose);
            try std.testing.expect(r.command == .run);
            // Must use cmd_args, not original args
            const files = r.command.run.files.items(r.cmd_args);
            try std.testing.expectEqual(@as(usize, 2), files.len);
            try std.testing.expectEqualStrings("file1.txt", files[0]);
            try std.testing.expectEqualStrings("file2.txt", files[1]);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp default command - explicit subcommand takes precedence" {
    const RunCmd = struct {};
    const ConfigCmd = struct {};

    const TestApp = struct {
        pub const GlobalOptions = struct {};
        pub const default_command = "run";
        pub const Command = CommandMod.Commands(.{
            .run = RunCmd,
            .config = ConfigCmd,
        });
    };

    // Explicit 'config' command -> config, not default
    const result = parseApp(TestApp, &.{"config"});
    switch (result) {
        .ok => |r| {
            try std.testing.expect(r.command == .config);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp --option=value format" {
    const HealthCmd = struct {};

    const TestApp = struct {
        pub const GlobalOptions = struct {
            url: ?[]const u8 = null,
        };
        pub const Command = CommandMod.Commands(.{
            .health = HealthCmd,
        });
    };

    // Test --url=value format
    const result = parseApp(TestApp, &.{ "--url=http://localhost:8080", "health" });
    switch (result) {
        .ok => |r| {
            try std.testing.expectEqualStrings("http://localhost:8080", r.global.url.?);
            try std.testing.expect(r.command == .health);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp required global option" {
    const HealthCmd = struct {};

    const TestApp = struct {
        pub const GlobalOptions = struct {
            // Required - no default, non-optional
            url: []const u8,
            pub const fields = .{
                .url = .{ .description = "Server URL", .required = true },
            };
        };
        pub const Command = CommandMod.Commands(.{
            .health = HealthCmd,
        });
    };

    // Missing required --url should fail
    const result = parseApp(TestApp, &.{"health"});
    switch (result) {
        .err => |err| {
            try std.testing.expectEqualStrings("missing required global option", err.message);
        },
        else => try std.testing.expect(false),
    }

    // Providing --url should succeed
    const result2 = parseApp(TestApp, &.{ "--url", "http://x", "health" });
    switch (result2) {
        .ok => |r| {
            try std.testing.expectEqualStrings("http://x", r.global.url);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp combined short options error" {
    const HealthCmd = struct {};

    const TestApp = struct {
        pub const GlobalOptions = struct {
            verbose: bool = false,
            debug: bool = false,
            pub const fields = .{
                .verbose = .{ .short = 'v' },
                .debug = .{ .short = 'd' },
            };
        };
        pub const Command = CommandMod.Commands(.{
            .health = HealthCmd,
        });
    };

    // Combined short options should give clear error
    const result = parseApp(TestApp, &.{ "-vd", "health" });
    switch (result) {
        .err => |err| {
            try std.testing.expect(std.mem.indexOf(u8, err.message, "combined short options") != null);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp command help bypasses required globals" {
    const HealthCmd = struct {
        verbose: bool = false,
    };

    const TestApp = struct {
        pub const GlobalOptions = struct {
            // Required - no default, non-optional
            url: []const u8,
            pub const fields = .{
                .url = .{ .description = "Server URL" },
            };
        };
        pub const Command = CommandMod.Commands(.{
            .health = HealthCmd,
        });
    };

    // `app health --help` should work without providing required --url
    const result = parseApp(TestApp, &.{ "health", "--help" });
    switch (result) {
        .command_help => |cmd_name| {
            try std.testing.expectEqualStrings("health", cmd_name);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp metadata-required optional field" {
    const HealthCmd = struct {};

    const TestApp = struct {
        pub const GlobalOptions = struct {
            // Optional type with null default, but marked required via metadata
            // This tests the meta.required path, not the type-based path
            token: ?[]const u8 = null,
            pub const fields = .{
                .token = .{ .description = "Auth token", .required = true },
            };
        };
        pub const Command = CommandMod.Commands(.{
            .health = HealthCmd,
        });
    };

    // Missing --token (marked required via metadata) should fail
    const result = parseApp(TestApp, &.{"health"});
    switch (result) {
        .err => |err| {
            try std.testing.expectEqualStrings("missing required global option", err.message);
        },
        else => try std.testing.expect(false),
    }

    // Providing --token should succeed
    const result2 = parseApp(TestApp, &.{ "--token", "secret", "health" });
    switch (result2) {
        .ok => |r| {
            try std.testing.expectEqualStrings("secret", r.global.token.?);
        },
        else => try std.testing.expect(false),
    }
}

test "parse combined short options error" {
    const TestCmd = struct {
        verbose: bool = false,
        debug: bool = false,
        pub const fields = .{
            .verbose = .{ .short = 'v' },
            .debug = .{ .short = 'd' },
        };
    };

    // Combined short options should give clear error
    const result = parse(TestCmd, &.{"-vd"});
    switch (result) {
        .err => |err| {
            try std.testing.expect(std.mem.indexOf(u8, err.message, "combined short options") != null);
        },
        else => try std.testing.expect(false),
    }
}

test "parse negative number as positional" {
    const TestCmd = struct {
        value: i32 = 0,
        pub const positional = .{.value};
    };

    // Negative numbers should be treated as positional arguments, not combined short options
    const result = parse(TestCmd, &.{"-100"});
    switch (result) {
        .ok => |cmd| {
            try std.testing.expectEqual(@as(i32, -100), cmd.value);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp nested subcommand group" {
    const BibAddCmd = struct {
        file: []const u8 = "",
        pub const positional = .{.file};
        pub const meta = .{ .name = "add", .description = "Add bibliography entry" };
    };

    const BibRemoveCmd = struct {
        key: []const u8 = "",
        pub const positional = .{.key};
        pub const meta = .{ .name = "remove", .description = "Remove bibliography entry" };
    };

    const HealthCmd = struct {
        verbose: bool = false,
    };

    const TestApp = struct {
        pub const GlobalOptions = struct {};
        pub const Command = CommandMod.Commands(.{
            .health = HealthCmd,
            .bib = CommandMod.Subcommand(.{
                .add = BibAddCmd,
                .remove = BibRemoveCmd,
            }),
        });
    };

    // Test: "app bib add file.bib"
    const result1 = parseApp(TestApp, &.{ "bib", "add", "refs.bib" });
    switch (result1) {
        .ok => |r| {
            try std.testing.expect(r.command == .bib);
            try std.testing.expect(r.command.bib.value == .add);
            try std.testing.expectEqualStrings("refs.bib", r.command.bib.value.add.file);
        },
        else => try std.testing.expect(false),
    }

    // Test: "app bib remove key123"
    const result2 = parseApp(TestApp, &.{ "bib", "remove", "key123" });
    switch (result2) {
        .ok => |r| {
            try std.testing.expect(r.command == .bib);
            try std.testing.expect(r.command.bib.value == .remove);
            try std.testing.expectEqualStrings("key123", r.command.bib.value.remove.key);
        },
        else => try std.testing.expect(false),
    }

    // Test: regular command still works
    const result3 = parseApp(TestApp, &.{ "health", "--verbose" });
    switch (result3) {
        .ok => |r| {
            try std.testing.expect(r.command == .health);
            try std.testing.expect(r.command.health.verbose);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp nested subcommand missing subcommand" {
    const BibAddCmd = struct {};

    const TestApp = struct {
        pub const GlobalOptions = struct {};
        pub const Command = CommandMod.Commands(.{
            .bib = CommandMod.Subcommand(.{
                .add = BibAddCmd,
            }),
        });
    };

    // "app bib" without subcommand should error
    const result = parseApp(TestApp, &.{"bib"});
    switch (result) {
        .err => |err| {
            try std.testing.expectEqualStrings("missing subcommand", err.message);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp nested subcommand unknown subcommand" {
    const BibAddCmd = struct {};

    const TestApp = struct {
        pub const GlobalOptions = struct {};
        pub const Command = CommandMod.Commands(.{
            .bib = CommandMod.Subcommand(.{
                .add = BibAddCmd,
            }),
        });
    };

    // "app bib unknown" should error
    const result = parseApp(TestApp, &.{ "bib", "unknown" });
    switch (result) {
        .err => |err| {
            try std.testing.expectEqualStrings("unknown subcommand", err.message);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp nested subcommand help" {
    const BibAddCmd = struct {};

    const TestApp = struct {
        pub const GlobalOptions = struct {};
        pub const Command = CommandMod.Commands(.{
            .bib = CommandMod.Subcommand(.{
                .add = BibAddCmd,
            }),
        });
    };

    // "app bib --help" should return help for bib group
    const result1 = parseApp(TestApp, &.{ "bib", "--help" });
    switch (result1) {
        .command_help => |cmd_name| {
            try std.testing.expectEqualStrings("bib", cmd_name);
        },
        else => try std.testing.expect(false),
    }

    // "app bib add --help" should return help for add subcommand
    const result2 = parseApp(TestApp, &.{ "bib", "add", "--help" });
    switch (result2) {
        .command_help => |cmd_name| {
            try std.testing.expectEqualStrings("add", cmd_name);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp subcommand group with metadata" {
    const BibAddCmd = struct {
        file: []const u8 = "",
        pub const positional = .{.file};
    };

    const TestApp = struct {
        pub const GlobalOptions = struct {};
        pub const Command = CommandMod.Commands(.{
            .bib = CommandMod.Subcommand(.{
                .meta = .{
                    .name = "bib",
                    .description = "Manage bibliography entries",
                },
                .commands = .{
                    .add = BibAddCmd,
                },
            }),
        });
    };

    // Test parsing still works with metadata form
    const result = parseApp(TestApp, &.{ "bib", "add", "refs.bib" });
    switch (result) {
        .ok => |r| {
            try std.testing.expect(r.command == .bib);
            try std.testing.expect(r.command.bib.value == .add);
            try std.testing.expectEqualStrings("refs.bib", r.command.bib.value.add.file);
        },
        else => try std.testing.expect(false),
    }

    // Verify metadata is accessible at comptime
    const BibSubgroup = @TypeOf(@as(TestApp.Command, undefined).bib);
    try std.testing.expectEqualStrings("bib", BibSubgroup.meta.name);
    try std.testing.expectEqualStrings("Manage bibliography entries", BibSubgroup.meta.description);
}

test "parse hyphen-to-underscore normalization" {
    const TestCmd = struct {
        min_year: ?i32 = null,
        max_results: u32 = 10,
        local_only: bool = false,
    };

    // Hyphens should work (standard CLI convention)
    const result1 = parse(TestCmd, &.{ "--min-year", "2020", "--max-results", "5", "--local-only" });
    switch (result1) {
        .ok => |cmd| {
            try std.testing.expectEqual(@as(?i32, 2020), cmd.min_year);
            try std.testing.expectEqual(@as(u32, 5), cmd.max_results);
            try std.testing.expect(cmd.local_only);
        },
        else => try std.testing.expect(false),
    }

    // Underscores should also work (for compatibility)
    const result2 = parse(TestCmd, &.{ "--min_year", "2021" });
    switch (result2) {
        .ok => |cmd| {
            try std.testing.expectEqual(@as(?i32, 2021), cmd.min_year);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp hyphen-to-underscore for global options" {
    const HealthCmd = struct {};

    const TestApp = struct {
        pub const GlobalOptions = struct {
            base_url: ?[]const u8 = null,
            dry_run: bool = false,
        };
        pub const Command = CommandMod.Commands(.{
            .health = HealthCmd,
        });
    };

    // Hyphens should work for global options
    const result = parseApp(TestApp, &.{ "--base-url", "http://localhost", "--dry-run", "health" });
    switch (result) {
        .ok => |r| {
            try std.testing.expectEqualStrings("http://localhost", r.global.base_url.?);
            try std.testing.expect(r.global.dry_run);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp unknown command help returns error" {
    const HealthCmd = struct {};

    const TestApp = struct {
        pub const GlobalOptions = struct {};
        pub const Command = CommandMod.Commands(.{
            .health = HealthCmd,
        });
    };

    // Unknown command with --help should return error, not help
    const result = parseApp(TestApp, &.{ "unknown", "--help" });
    switch (result) {
        .err => |err| {
            try std.testing.expectEqualStrings("unknown command", err.message);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp alias help returns canonical name" {
    const ListCmd = struct {
        pub const meta = .{
            .name = "list",
            .description = "List items",
            .aliases = &[_][]const u8{"ls"},
        };
    };

    const TestApp = struct {
        pub const GlobalOptions = struct {};
        pub const Command = CommandMod.Commands(.{
            .list = ListCmd,
        });
    };

    // Using alias with --help should return canonical field name
    const result = parseApp(TestApp, &.{ "ls", "--help" });
    switch (result) {
        .command_help => |cmd_name| {
            try std.testing.expectEqualStrings("list", cmd_name);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp nested subcommand help returns validated name" {
    const BibAddCmd = struct {
        pub const meta = .{ .name = "add", .description = "Add entry" };
    };

    const TestApp = struct {
        pub const GlobalOptions = struct {};
        pub const Command = CommandMod.Commands(.{
            .bib = CommandMod.Subcommand(.{
                .meta = .{ .name = "bib", .description = "Bibliography" },
                .commands = .{ .add = BibAddCmd },
            }),
        });
    };

    // Nested subcommand help should return subcommand name (validated)
    const result = parseApp(TestApp, &.{ "bib", "add", "--help" });
    switch (result) {
        .command_help => |cmd_name| {
            try std.testing.expectEqualStrings("add", cmd_name);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp unknown subcommand help returns error" {
    const BibAddCmd = struct {};

    const TestApp = struct {
        pub const GlobalOptions = struct {};
        pub const Command = CommandMod.Commands(.{
            .bib = CommandMod.Subcommand(.{
                .add = BibAddCmd,
            }),
        });
    };

    // Unknown subcommand with --help should return error
    const result = parseApp(TestApp, &.{ "bib", "unknown", "--help" });
    switch (result) {
        .err => |err| {
            try std.testing.expectEqualStrings("unknown subcommand", err.message);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp nested help bypasses required globals" {
    const BibAddCmd = struct {
        pub const meta = .{ .name = "add", .description = "Add entry" };
    };

    const TestApp = struct {
        pub const GlobalOptions = struct {
            api_key: []const u8, // Required global option
        };
        pub const Command = CommandMod.Commands(.{
            .bib = CommandMod.Subcommand(.{
                .meta = .{ .name = "bib", .description = "Bibliography" },
                .commands = .{ .add = BibAddCmd },
            }),
        });
    };

    // Nested help should work without providing required globals
    const result = parseApp(TestApp, &.{ "bib", "add", "--help" });
    switch (result) {
        .command_help => |cmd_name| {
            try std.testing.expectEqualStrings("add", cmd_name);
        },
        else => try std.testing.expect(false),
    }

    // Group help should also work without required globals
    const result2 = parseApp(TestApp, &.{ "bib", "--help" });
    switch (result2) {
        .command_help => |cmd_name| {
            try std.testing.expectEqualStrings("bib", cmd_name);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp help anywhere in args bypasses globals" {
    const ListCmd = struct {
        filter: ?[]const u8 = null,
        pub const meta = .{ .name = "list", .description = "List items" };
    };

    const TestApp = struct {
        pub const GlobalOptions = struct {
            api_key: []const u8, // Required global option
        };
        pub const Command = CommandMod.Commands(.{
            .list = ListCmd,
        });
    };

    // Help at the end of args should work without required globals
    const result = parseApp(TestApp, &.{ "list", "--filter", "test", "--help" });
    switch (result) {
        .command_help => |cmd_name| {
            try std.testing.expectEqualStrings("list", cmd_name);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp error messages show hyphens not underscores" {
    const ListCmd = struct {
        pub const meta = .{ .name = "list", .description = "List items" };
    };

    const TestApp = struct {
        pub const GlobalOptions = struct {
            api_key: []const u8, // Required - has underscore
        };
        pub const Command = CommandMod.Commands(.{
            .list = ListCmd,
        });
    };

    // Missing required global should show hyphenated option name
    const result = parseApp(TestApp, &.{"list"});
    switch (result) {
        .err => |err| {
            try std.testing.expectEqualStrings("missing required global option", err.message);
            // Context should show "--api-key" not "--api_key"
            try std.testing.expectEqualStrings("--api-key", err.context.?);
        },
        else => try std.testing.expect(false),
    }
}

test "parseApp subcommand group with variadic positionals" {
    const BibAddCmd = struct {
        output: []const u8 = "",
        files: CommandMod.VariadicSlice = .{},

        pub const positional = .{ .output, .files };
        pub const fields = .{
            .files = .{ .variadic = true },
        };
        pub const meta = .{ .name = "add", .description = "Add bibliography entries" };
    };

    const TestApp = struct {
        pub const GlobalOptions = struct {};
        pub const Command = CommandMod.Commands(.{
            .bib = CommandMod.Subcommand(.{
                .add = BibAddCmd,
            }),
        });
    };

    // Test: "app bib add out.bib file1.bib file2.bib file3.bib"
    // The cmd_args should be relative to the args passed to parse()
    // which is args[1..] inside parseSubcommandGroup (i.e., ["add", "out.bib", ...])
    // But the inner parse() gets sub_cmd_args which is args[1..] again
    // So cmd_args should be ["out.bib", "file1.bib", "file2.bib", "file3.bib"]
    const args = &[_][]const u8{ "bib", "add", "out.bib", "file1.bib", "file2.bib", "file3.bib" };
    const result = parseApp(TestApp, args);
    switch (result) {
        .ok => |r| {
            try std.testing.expect(r.command == .bib);
            try std.testing.expect(r.command.bib.value == .add);
            const add_cmd = r.command.bib.value.add;
            try std.testing.expectEqualStrings("out.bib", add_cmd.output);

            // The critical test: VariadicSlice.items() should work with cmd_args
            const files = add_cmd.files.items(r.cmd_args);
            try std.testing.expectEqual(@as(usize, 3), files.len);
            try std.testing.expectEqualStrings("file1.bib", files[0]);
            try std.testing.expectEqualStrings("file2.bib", files[1]);
            try std.testing.expectEqualStrings("file3.bib", files[2]);
        },
        else => try std.testing.expect(false),
    }
}
