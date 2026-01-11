//! Argument parsing engine for CLI applications.
//!
//! Parses command-line arguments into typed command structs using
//! comptime-derived metadata from Command.zig.

const std = @import("std");
const CommandMod = @import("Command.zig");
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

    // Track which required fields have been set
    const required_fields = comptime getRequiredFields(T);
    var fields_set: [required_fields.len]bool = [_]bool{false} ** required_fields.len;

    // Initialize all fields with defaults or safe values
    inline for (type_info.@"struct".fields) |field| {
        if (field.defaultValue()) |default| {
            @field(result, field.name) = default;
            // Mark as set if it has a default
            inline for (required_fields, 0..) |req_field, idx| {
                if (std.mem.eql(u8, req_field, field.name)) {
                    fields_set[idx] = true;
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

        // Positional argument
        if (positional_index < positional_fields.len) {
            const field_name = positional_fields[positional_index];
            markFieldSet(required_fields, &fields_set, field_name);
            if (setFieldByName(T, &result, field_name, arg)) |err| {
                return .{ .err = err };
            }
            positional_index += 1;
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
            return .{ .err = CliError.usageError("missing required argument").withContext(req_field) };
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

/// Get list of required fields (marked required or non-optional without default).
fn getRequiredFields(comptime T: type) []const []const u8 {
    const type_info = @typeInfo(T);
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
        if (std.mem.eql(u8, req_field, name)) {
            fields_set[idx] = true;
        }
    }
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
        },
        err: CliError,
        help,
        version,
        /// Help requested for a specific command
        command_help: []const u8,
    };
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

    // Track required global options
    const required_globals = comptime getRequiredGlobalFields(GlobalOptions);
    var globals_set: [required_globals.len]bool = [_]bool{false} ** required_globals.len;

    // Initialize global options with defaults
    if (global_type_info == .@"struct") {
        inline for (global_type_info.@"struct".fields) |field| {
            if (field.defaultValue()) |default| {
                @field(global, field.name) = default;
                // Mark as set if it has a default
                inline for (required_globals, 0..) |req_field, idx| {
                    if (std.mem.eql(u8, req_field, field.name)) {
                        globals_set[idx] = true;
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
            markGlobalFieldSet(required_globals, &globals_set, opt_name);
            continue;
        }

        // Long option
        if (std.mem.startsWith(u8, arg, "--")) {
            const opt_name = arg[2..];

            if (isGlobalBoolField(GlobalOptions, opt_name)) {
                if (setGlobalBoolField(GlobalOptions, &global, opt_name, true)) |err| {
                    return .{ .err = err };
                }
                markGlobalFieldSet(required_globals, &globals_set, opt_name);
            } else if (isGlobalField(GlobalOptions, opt_name)) {
                // Needs a value
                if (i + 1 >= args.len) {
                    return .{ .err = CliError.usageError("missing value for option").withContext(arg) };
                }
                i += 1;
                if (setGlobalField(GlobalOptions, &global, opt_name, args[i])) |err| {
                    return .{ .err = err };
                }
                markGlobalFieldSet(required_globals, &globals_set, opt_name);
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
                            markGlobalFieldSet(required_globals, &globals_set, field.name);
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

        // Combined short options (e.g., -abc) or short option with value (e.g., -uhttp://x)
        // are not supported - give a clear error
        if (arg.len > 2 and arg[0] == '-' and arg[1] != '-') {
            return .{ .err = CliError.usageError("combined short options not supported; use separate flags").withContext(arg) };
        }

        // Non-option argument - this is the command name
        break;
    }

    // Validate required global options were provided
    inline for (required_globals, 0..) |req_field, idx| {
        if (!globals_set[idx]) {
            return .{ .err = CliError.usageError("missing required global option").withContext(req_field) };
        }
    }

    // Phase 2: Identify and dispatch to command
    if (i >= args.len) {
        return .{ .err = CliError.usageError("missing command") };
    }

    const cmd_name = args[i];
    const cmd_args = args[i + 1 ..];

    // Check for command-specific help
    if (cmd_args.len > 0 and (std.mem.eql(u8, cmd_args[0], "-h") or std.mem.eql(u8, cmd_args[0], "--help"))) {
        return .{ .command_help = cmd_name };
    }

    // Match command name against union fields
    const union_info = @typeInfo(CommandUnion);
    if (union_info != .@"union") {
        @compileError("App.Command must be a union type (use Commands())");
    }

    inline for (union_info.@"union".fields) |field| {
        if (std.mem.eql(u8, field.name, cmd_name)) {
            // Parse command-specific arguments
            const cmd_result = parse(field.type, cmd_args);
            switch (cmd_result) {
                .ok => |cmd| {
                    return .{ .ok = .{
                        .global = global,
                        .command = @unionInit(CommandUnion, field.name, cmd),
                    } };
                },
                .err => |err| return .{ .err = err },
                .help => return .{ .command_help = cmd_name },
                .version => return .version,
            }
        }

        // Check aliases
        const cmd_meta = CommandMod.getCommandMeta(field.type);
        for (cmd_meta.aliases) |alias| {
            if (std.mem.eql(u8, alias, cmd_name)) {
                const cmd_result = parse(field.type, cmd_args);
                switch (cmd_result) {
                    .ok => |cmd| {
                        return .{ .ok = .{
                            .global = global,
                            .command = @unionInit(CommandUnion, field.name, cmd),
                        } };
                    },
                    .err => |err| return .{ .err = err },
                    .help => return .{ .command_help = field.name },
                    .version => return .version,
                }
            }
        }
    }

    return .{ .err = CliError.usageError("unknown command").withContext(cmd_name) };
}

// Helper functions for global option parsing

fn isGlobalField(comptime GlobalOptions: type, name: []const u8) bool {
    const type_info = @typeInfo(GlobalOptions);
    if (type_info != .@"struct") return false;

    inline for (type_info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return true;
        }
    }
    return false;
}

fn isGlobalBoolField(comptime GlobalOptions: type, name: []const u8) bool {
    const type_info = @typeInfo(GlobalOptions);
    if (type_info != .@"struct") return false;

    inline for (type_info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, name) and field.type == bool) {
            return true;
        }
    }
    return false;
}

fn setGlobalField(comptime GlobalOptions: type, global: *GlobalOptions, name: []const u8, value: []const u8) ?CliError {
    const type_info = @typeInfo(GlobalOptions);
    if (type_info != .@"struct") return CliError.usageError("invalid global options type");

    inline for (type_info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
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
        if (std.mem.eql(u8, field.name, name) and field.type == bool) {
            @field(global, field.name) = value;
            return null;
        }
    }
    return CliError.usageError("unknown global flag").withContext(name);
}

/// Get list of required global option fields.
fn getRequiredGlobalFields(comptime GlobalOptions: type) []const []const u8 {
    const type_info = @typeInfo(GlobalOptions);
    if (type_info != .@"struct") return &.{};

    comptime var fields: []const []const u8 = &.{};

    inline for (type_info.@"struct".fields) |field| {
        const meta = CommandMod.getFieldMeta(GlobalOptions, field.name);
        const is_optional = @typeInfo(field.type) == .optional;
        const has_default = field.default_value_ptr != null;
        if (meta.required or (!is_optional and !has_default)) {
            fields = fields ++ &[_][]const u8{field.name};
        }
    }

    return fields;
}

/// Mark a global field as set in the tracking array.
fn markGlobalFieldSet(comptime required_globals: []const []const u8, globals_set: *[required_globals.len]bool, name: []const u8) void {
    inline for (required_globals, 0..) |req_field, idx| {
        if (std.mem.eql(u8, req_field, name)) {
            globals_set[idx] = true;
        }
    }
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
