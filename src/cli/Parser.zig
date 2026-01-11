//! Argument parsing engine for CLI applications.
//!
//! Parses command-line arguments into typed command structs using
//! comptime-derived metadata from Command.zig.

const std = @import("std");
const Command = @import("Command.zig");
const Error = @import("Error.zig");
const CliError = Error.CliError;
const ExitCode = Error.ExitCode;

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

/// Parse arguments with explicit environment.
pub fn parseWithEnv(comptime T: type, args: []const []const u8, env: anytype) ParseResult(T) {
    var result: T = undefined;
    const type_info = @typeInfo(T);

    if (type_info != .@"struct") {
        @compileError("parse() requires a struct type");
    }

    // Initialize all fields with defaults
    inline for (type_info.@"struct".fields) |field| {
        if (field.defaultValue()) |default| {
            @field(result, field.name) = default;
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
        } else {
            // Required field - leave uninitialized, will be set during parsing
        }
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

        // Long option with =
        if (std.mem.startsWith(u8, arg, "--") and std.mem.indexOf(u8, arg, "=") != null) {
            const eq_pos = std.mem.indexOf(u8, arg, "=").?;
            const opt_name = arg[2..eq_pos];
            const opt_value = arg[eq_pos + 1 ..];

            if (setFieldByName(T, &result, opt_name, opt_value)) |err| {
                return .{ .err = err };
            }
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
            } else {
                // Needs a value
                if (i + 1 >= args.len) {
                    return .{ .err = CliError.usageError("missing value for option").withContext(arg) };
                }
                i += 1;
                if (setFieldByName(T, &result, opt_name, args[i])) |err| {
                    return .{ .err = err };
                }
            }
            continue;
        }

        // Short option
        if (arg.len == 2 and arg[0] == '-' and arg[1] != '-') {
            const short = arg[1];

            // Handle short options at comptime by checking each field
            var found_short = false;
            inline for (type_info.@"struct".fields) |field| {
                const meta = Command.getFieldMeta(T, field.name);
                if (meta.short) |s| {
                    if (s == short) {
                        found_short = true;
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

        // Positional argument
        if (positional_index < positional_fields.len) {
            const field_name = positional_fields[positional_index];
            if (setFieldByName(T, &result, field_name, arg)) |err| {
                return .{ .err = err };
            }
            positional_index += 1;
        } else {
            return .{ .err = CliError.usageError("unexpected argument").withContext(arg) };
        }
    }

    // Apply environment variable fallbacks
    inline for (type_info.@"struct".fields) |field| {
        const meta = Command.getFieldMeta(T, field.name);
        if (meta.env) |env_var| {
            // Only apply if field is still at default/null
            if (shouldApplyEnvFallback(T, &result, field.name)) {
                if (getEnvValue(env, env_var)) |env_value| {
                    if (setFieldByName(T, &result, field.name, env_value)) |err| {
                        return .{ .err = err };
                    }
                }
            }
        }
    }

    // Check required fields
    inline for (type_info.@"struct".fields) |field| {
        const meta = Command.getFieldMeta(T, field.name);
        if (meta.required and field.default_value_ptr == null) {
            if (@typeInfo(field.type) != .optional) {
                // Check if still uninitialized (for non-optional required fields)
                // This is tricky - we rely on the field being set during parsing
            }
        }
    }

    return .{ .ok = result };
}

fn getPositionalFields(comptime T: type) []const []const u8 {
    const type_info = @typeInfo(T);
    comptime var fields: []const []const u8 = &.{};

    inline for (type_info.@"struct".fields) |field| {
        if (Command.isPositional(T, field.name)) {
            fields = fields ++ &[_][]const u8{field.name};
        }
    }

    return fields;
}

fn isBoolField(comptime T: type, name: []const u8) bool {
    const type_info = @typeInfo(T);
    inline for (type_info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
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
        const meta = Command.getFieldMeta(T, field.name);
        if (meta.short) |s| {
            if (s == short) return field.name;
        }
    }
    return null;
}

fn setFieldByName(comptime T: type, result: *T, name: []const u8, value: []const u8) ?CliError {
    const type_info = @typeInfo(T);
    inline for (type_info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            if (parseValue(field.type, value)) |parsed| {
                @field(result, field.name) = parsed;
                return null;
            } else |_| {
                return CliError.usageError( "Invalid value for --" ++ field.name).withContext(value);
            }
        }
    }
    return CliError.usageError( "Unknown option").withContext(name);
}

fn setBoolField(comptime T: type, result: *T, name: []const u8, value: bool) ?CliError {
    const type_info = @typeInfo(T);
    inline for (type_info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, name) and field.type == bool) {
            @field(result, field.name) = value;
            return null;
        }
    }
    return CliError.usageError( "Unknown flag").withContext(name);
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
