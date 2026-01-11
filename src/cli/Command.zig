//! Comptime command definition and metadata extraction.
//!
//! Provides types for declaratively defining CLI commands as Zig structs,
//! with automatic derivation of parsing tables and help text.

const std = @import("std");

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

    return .{
        .name = field.name,
        .required = !is_optional and field.default_value_ptr == null,
        .description = meta.description,
        .value_name = meta.value_name orelse ("<" ++ field.name ++ ">"),
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

    comptime var union_fields: [fields.len]std.builtin.Type.UnionField = undefined;

    inline for (fields, 0..) |field, i| {
        const CmdType = @field(cmd_defs, field.name);
        union_fields[i] = .{
            .name = field.name,
            .type = CmdType,
            .alignment = @alignOf(CmdType),
        };
    }

    return @Type(.{
        .@"union" = .{
            .layout = .auto,
            .tag_type = blk: {
                comptime var tag_fields: [fields.len]std.builtin.Type.EnumField = undefined;
                inline for (fields, 0..) |field, i| {
                    tag_fields[i] = .{
                        .name = field.name,
                        .value = i,
                    };
                }
                break :blk @Type(.{
                    .@"enum" = .{
                        .tag_type = std.math.IntFittingRange(0, fields.len - 1),
                        .fields = &tag_fields,
                        .decls = &.{},
                        .is_exhaustive = true,
                    },
                });
            },
            .fields = &union_fields,
            .decls = &.{},
        },
    });
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
