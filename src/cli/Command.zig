//! Comptime command definition and metadata extraction.
//!
//! Provides types for declaratively defining CLI commands as Zig structs,
//! with automatic derivation of parsing tables and help text.
//!
//! ## Variadic Positionals
//!
//! Use `VariadicSlice` for commands that accept multiple positional arguments:
//!
//! ```zig
//! const CopyCmd = struct {
//!     dest: []const u8,
//!     files: VariadicSlice,  // Captures all remaining positionals
//!
//!     pub const positional = .{ .dest, .files };
//! };
//!
//! // After parsing:
//! const file_args = result.files.items(args);  // Zero-copy slice
//! ```

const std = @import("std");

/// Zero-copy reference to variadic positional arguments.
///
/// Stores indices into the original args array, avoiding allocation.
/// The variadic field must be the last positional argument.
pub const VariadicSlice = struct {
    /// Start index in args array (inclusive).
    start: usize = 0,
    /// End index in args array (exclusive).
    end: usize = 0,

    /// Get the actual argument values from the original args array.
    pub fn items(self: @This(), args: []const []const u8) []const []const u8 {
        if (self.start >= args.len) return &.{};
        const safe_end = @min(self.end, args.len);
        return args[self.start..safe_end];
    }

    /// Returns true if no variadic arguments were captured.
    pub fn isEmpty(self: @This()) bool {
        return self.start >= self.end;
    }

    /// Returns the number of captured arguments.
    pub fn len(self: @This()) usize {
        if (self.start >= self.end) return 0;
        return self.end - self.start;
    }
};

/// Field metadata for argument configuration.
pub const FieldMeta = struct {
    /// Short option character (e.g., 'm' for -m).
    short: ?u8 = null,
    /// Description for help text.
    description: []const u8 = "",
    /// Environment variable fallback.
    env: ?[]const u8 = null,
    /// Whether this field is required.
    required: bool = false,
    /// Value placeholder for help (e.g., "<file>").
    value_name: ?[]const u8 = null,
    /// Hide from help output.
    hidden: bool = false,
};

/// Command metadata.
pub const CommandMeta = struct {
    /// Command name.
    name: []const u8,
    /// Alternate names (aliases).
    aliases: []const []const u8 = &.{},
    /// Short description for command list.
    description: []const u8 = "",
    /// Long description for detailed help.
    long_description: ?[]const u8 = null,
    /// Usage examples.
    examples: []const []const u8 = &.{},
    /// Hide from command list.
    hidden: bool = false,
};

/// Application metadata.
pub const AppMeta = struct {
    /// Application name (used in help/usage).
    name: []const u8,
    /// Version string.
    version: []const u8 = "0.0.0",
    /// Short description.
    description: []const u8 = "",
    /// Author information.
    author: ?[]const u8 = null,
};

/// Option specification derived from a struct field.
pub const OptionSpec = struct {
    /// Long option name.
    long: []const u8,
    /// Short option character.
    short: ?u8,
    /// Whether this option takes a value.
    takes_value: bool,
    /// Whether the option is required.
    required: bool,
    /// Type of value (for parsing).
    value_type: ValueType,
    /// Description for help.
    description: []const u8,
    /// Environment variable fallback.
    env: ?[]const u8,
    /// Value placeholder for help.
    value_name: []const u8,
    /// Hide from help.
    hidden: bool,

    pub const ValueType = enum {
        bool,
        string,
        optional_string,
        int,
        optional_int,
        @"enum",
        optional_enum,
    };
};

/// Positional argument specification.
pub const PositionalSpec = struct {
    /// Field name.
    name: []const u8,
    /// Whether required (non-optional type).
    required: bool,
    /// Description.
    description: []const u8,
    /// Value placeholder.
    value_name: []const u8,
    /// Whether this positional captures all remaining args.
    variadic: bool = false,
};

/// Get command metadata from a type.
pub fn getCommandMeta(comptime T: type) CommandMeta {
    if (@hasDecl(T, "meta")) {
        const m = T.meta;
        return .{
            .name = if (@hasField(@TypeOf(m), "name")) m.name else @typeName(T),
            .aliases = if (@hasField(@TypeOf(m), "aliases")) m.aliases else &.{},
            .description = if (@hasField(@TypeOf(m), "description")) m.description else "",
            .long_description = if (@hasField(@TypeOf(m), "long_description")) m.long_description else null,
            .examples = if (@hasField(@TypeOf(m), "examples")) m.examples else &.{},
            .hidden = if (@hasField(@TypeOf(m), "hidden")) m.hidden else false,
        };
    }
    return .{ .name = @typeName(T) };
}

/// Get application metadata from a type.
pub fn getAppMeta(comptime T: type) AppMeta {
    if (@hasDecl(T, "meta")) {
        const m = T.meta;
        return .{
            .name = if (@hasField(@TypeOf(m), "name")) m.name else @typeName(T),
            .version = if (@hasField(@TypeOf(m), "version")) m.version else "0.0.0",
            .description = if (@hasField(@TypeOf(m), "description")) m.description else "",
            .author = if (@hasField(@TypeOf(m), "author")) m.author else null,
        };
    }
    return .{ .name = @typeName(T) };
}

fn getValueType(comptime T: type) OptionSpec.ValueType {
    const type_info = @typeInfo(T);

    if (T == bool) return .bool;
    if (T == []const u8) return .string;
    if (type_info == .optional) {
        const child = type_info.optional.child;
        if (child == []const u8) return .optional_string;
        if (@typeInfo(child) == .int) return .optional_int;
        if (@typeInfo(child) == .@"enum") return .optional_enum;
        return .optional_string;
    }
    if (type_info == .int) return .int;
    if (type_info == .@"enum") return .@"enum";

    return .string;
}

fn getDefaultValueName(value_type: OptionSpec.ValueType) []const u8 {
    return switch (value_type) {
        .bool => "",
        .string, .optional_string => "<value>",
        .int, .optional_int => "<n>",
        .@"enum", .optional_enum => "<choice>",
    };
}

/// Get field metadata for a specific field.
pub fn getFieldMeta(comptime T: type, comptime field_name: []const u8) FieldMeta {
    if (@hasDecl(T, "fields")) {
        const field_meta = T.fields;
        if (@hasField(@TypeOf(field_meta), field_name)) {
            // Coerce anonymous struct literal to FieldMeta
            const anon = @field(field_meta, field_name);
            return .{
                .short = if (@hasField(@TypeOf(anon), "short")) anon.short else null,
                .description = if (@hasField(@TypeOf(anon), "description")) anon.description else "",
                .env = if (@hasField(@TypeOf(anon), "env")) anon.env else null,
                .required = if (@hasField(@TypeOf(anon), "required")) anon.required else false,
                .value_name = if (@hasField(@TypeOf(anon), "value_name")) anon.value_name else null,
                .hidden = if (@hasField(@TypeOf(anon), "hidden")) anon.hidden else false,
            };
        }
    }
    return .{};
}

/// Check if a field is marked as positional.
pub fn isPositional(comptime T: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(T, "positional")) return false;

    const positionals = T.positional;
    const pos_info = @typeInfo(@TypeOf(positionals));
    if (pos_info != .@"struct") return false;

    inline for (pos_info.@"struct".fields) |pos_field| {
        const pos_field_type = @typeInfo(pos_field.type);
        const pos_name: []const u8 = if (pos_field_type == .enum_literal)
            @tagName(@field(positionals, pos_field.name))
        else if (pos_field.type == []const u8)
            @field(positionals, pos_field.name)
        else
            continue;

        if (std.mem.eql(u8, pos_name, field_name)) return true;
    }
    return false;
}

/// Check if a field is a variadic positional (VariadicSlice type).
pub fn isVariadicField(comptime T: type, comptime field_name: []const u8) bool {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") return false;

    inline for (type_info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) {
            return field.type == VariadicSlice;
        }
    }
    return false;
}

/// Get option spec for a field.
pub fn getOptionSpec(comptime T: type, comptime field: std.builtin.Type.StructField) OptionSpec {
    const meta = getFieldMeta(T, field.name);
    const value_type = getValueType(field.type);
    const has_default = field.default_value_ptr != null;

    return .{
        .long = field.name,
        .short = meta.short,
        .takes_value = value_type != .bool,
        .required = meta.required and !has_default,
        .value_type = value_type,
        .description = meta.description,
        .env = meta.env,
        .value_name = meta.value_name orelse getDefaultValueName(value_type),
        .hidden = meta.hidden,
    };
}

/// Get positional spec for a field.
pub fn getPositionalSpec(comptime T: type, comptime field: std.builtin.Type.StructField) PositionalSpec {
    const meta = getFieldMeta(T, field.name);
    const is_optional = @typeInfo(field.type) == .optional;
    const is_variadic = field.type == VariadicSlice;

    return .{
        .name = field.name,
        // Variadic fields are not required (can be empty)
        .required = !is_optional and !is_variadic and field.default_value_ptr == null,
        .description = meta.description,
        .value_name = meta.value_name orelse ("<" ++ field.name ++ (if (is_variadic) ">..." else ">")),
        .variadic = is_variadic,
    };
}

/// Create a union type from command type definitions.
pub fn Commands(comptime cmd_defs: anytype) type {
    const defs_info = @typeInfo(@TypeOf(cmd_defs));
    if (defs_info != .@"struct") {
        @compileError("Commands expects a struct of command types");
    }

    const fields = defs_info.@"struct".fields;
    if (fields.len == 0) {
        @compileError("Commands requires at least one command type");
    }

    // Zig 0.16 split `@Type` into per-kind builtins. We build the tagged
    // union by handing @Union three parallel arrays (names, types,
    // attributes) plus a tag enum produced by @Enum from the same names.
    const TagInt = std.math.IntFittingRange(0, fields.len - 1);

    comptime var names: [fields.len][:0]const u8 = undefined;
    comptime var tag_values: [fields.len]TagInt = undefined;
    comptime var union_types: [fields.len]type = undefined;
    comptime var union_attrs: [fields.len]std.builtin.Type.UnionField.Attributes = undefined;

    inline for (fields, 0..) |field, i| {
        const CmdType = @field(cmd_defs, field.name);
        names[i] = field.name;
        tag_values[i] = @intCast(i);
        union_types[i] = CmdType;
        union_attrs[i] = .{};
    }

    const TagType = @Enum(TagInt, .exhaustive, &names, &tag_values);
    return @Union(.auto, TagType, &names, &union_types, &union_attrs);
}

/// Create a subcommand group with optional metadata.
///
/// Can be called two ways:
///
/// 1. Simple form (just subcommands):
/// ```zig
/// .bib = Subcommand(.{
///     .add = BibAddCmd,
///     .remove = BibRemoveCmd,
/// }),
/// ```
///
/// 2. With metadata:
/// ```zig
/// .bib = Subcommand(.{
///     .meta = .{
///         .name = "bib",
///         .description = "Manage bibliography entries",
///     },
///     .commands = .{
///         .add = BibAddCmd,
///         .remove = BibRemoveCmd,
///     },
/// }),
/// ```
pub fn Subcommand(comptime config: anytype) type {
    const ConfigType = @TypeOf(config);
    const has_commands_field = @hasField(ConfigType, "commands");

    // Extract commands and optional metadata
    const cmd_defs = if (has_commands_field) config.commands else config;
    const CmdUnion = Commands(cmd_defs);

    return struct {
        /// The inner commands union type.
        pub const commands = CmdUnion;

        /// Group metadata (name, description, etc.).
        pub const meta: CommandMeta = if (@hasField(ConfigType, "meta")) blk: {
            const m = config.meta;
            break :blk .{
                .name = if (@hasField(@TypeOf(m), "name")) m.name else "",
                .aliases = if (@hasField(@TypeOf(m), "aliases")) m.aliases else &.{},
                .description = if (@hasField(@TypeOf(m), "description")) m.description else "",
                .long_description = if (@hasField(@TypeOf(m), "long_description")) m.long_description else null,
                .examples = if (@hasField(@TypeOf(m), "examples")) m.examples else &.{},
                .hidden = if (@hasField(@TypeOf(m), "hidden")) m.hidden else false,
            };
        } else .{ .name = "" };

        /// Marker for subcommand group detection.
        pub const is_subcommand_group = true;

        /// The actual command value.
        value: CmdUnion,
    };
}

test "getCommandMeta" {
    const TestCmd = struct {
        pub const meta = .{
            .name = "test",
            .description = "A test command",
        };
    };

    const cmd_meta = getCommandMeta(TestCmd);
    try std.testing.expectEqualStrings("test", cmd_meta.name);
    try std.testing.expectEqualStrings("A test command", cmd_meta.description);
}

test "isPositional" {
    const TestCmd = struct {
        file: []const u8 = "",
        verbose: bool = false,

        pub const positional = .{.file};
    };

    try std.testing.expect(isPositional(TestCmd, "file"));
    try std.testing.expect(!isPositional(TestCmd, "verbose"));
}

test "Commands union" {
    const ListCmd = struct { all: bool = false };
    const ShowCmd = struct { id: []const u8 = "" };

    const Cmd = Commands(.{
        .list = ListCmd,
        .show = ShowCmd,
    });

    const list_cmd = Cmd{ .list = .{ .all = true } };
    try std.testing.expect(list_cmd == .list);
    try std.testing.expect(list_cmd.list.all);
}

test "VariadicSlice" {
    const args = &[_][]const u8{ "cmd", "file1.txt", "file2.txt", "file3.txt" };

    // Normal case
    const slice = VariadicSlice{ .start = 1, .end = 4 };
    const items = slice.items(args);
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("file1.txt", items[0]);
    try std.testing.expectEqualStrings("file3.txt", items[2]);
    try std.testing.expectEqual(@as(usize, 3), slice.len());
    try std.testing.expect(!slice.isEmpty());

    // Empty case
    const empty = VariadicSlice{ .start = 1, .end = 1 };
    try std.testing.expectEqual(@as(usize, 0), empty.items(args).len);
    try std.testing.expect(empty.isEmpty());

    // Bounds safety
    const beyond = VariadicSlice{ .start = 10, .end = 20 };
    try std.testing.expectEqual(@as(usize, 0), beyond.items(args).len);
}

test "isVariadicField" {
    const TestCmd = struct {
        dest: []const u8 = "",
        files: VariadicSlice = .{},
        verbose: bool = false,

        pub const positional = .{ .dest, .files };
    };

    try std.testing.expect(isVariadicField(TestCmd, "files"));
    try std.testing.expect(!isVariadicField(TestCmd, "dest"));
    try std.testing.expect(!isVariadicField(TestCmd, "verbose"));
}

test "getPositionalSpec variadic" {
    const TestCmd = struct {
        dest: []const u8,
        files: VariadicSlice = .{},

        pub const positional = .{ .dest, .files };
        pub const fields = .{
            .files = .{ .description = "Input files" },
        };
    };

    const type_info = @typeInfo(TestCmd);
    inline for (type_info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "files")) {
            const spec = getPositionalSpec(TestCmd, field);
            try std.testing.expect(spec.variadic);
            try std.testing.expect(!spec.required); // Variadic is never required
            try std.testing.expectEqualStrings("<files>...", spec.value_name);
        }
        if (std.mem.eql(u8, field.name, "dest")) {
            const spec = getPositionalSpec(TestCmd, field);
            try std.testing.expect(!spec.variadic);
            try std.testing.expect(spec.required);
        }
    }
}
