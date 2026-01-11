//! Auto-generated help text for CLI applications.
//!
//! Generates formatted help output from command metadata defined
//! using the declarative struct pattern.

const std = @import("std");
const CommandMod = @import("Command.zig");

/// Copy a string while converting underscores to hyphens (for CLI option display).
fn copyWithHyphens(dest: []u8, src: []const u8) void {
    for (src, 0..) |c, i| {
        dest[i] = if (c == '_') '-' else c;
    }
}

/// Generate help text for a command type.
pub fn generateHelp(comptime T: type, writer: anytype) !void {
    const meta = CommandMod.getCommandMeta(T);
    const type_info = @typeInfo(T);

    // Usage line
    try writer.print("Usage: {s}", .{meta.name});

    // Add positional args to usage
    inline for (type_info.@"struct".fields) |field| {
        if (CommandMod.isPositional(T, field.name)) {
            const pos_spec = CommandMod.getPositionalSpec(T, field);
            const suffix = if (pos_spec.variadic) "..." else "";
            if (pos_spec.required) {
                try writer.print(" <{s}>{s}", .{ field.name, suffix });
            } else {
                try writer.print(" [{s}]{s}", .{ field.name, suffix });
            }
        }
    }

    try writer.writeAll(" [OPTIONS]\n");

    // Description
    if (meta.description.len > 0) {
        try writer.print("\n{s}\n", .{meta.description});
    }

    if (meta.long_description) |long| {
        try writer.print("\n{s}\n", .{long});
    }

    // Arguments section (positionals)
    var has_positionals = false;
    inline for (type_info.@"struct".fields) |field| {
        if (CommandMod.isPositional(T, field.name)) {
            if (!has_positionals) {
                try writer.writeAll("\nArguments:\n");
                has_positionals = true;
            }
            const pos_spec = CommandMod.getPositionalSpec(T, field);
            // value_name already includes "..." suffix for variadic fields
            try writer.print("  {s:<20}  {s}\n", .{ pos_spec.value_name, pos_spec.description });
        }
    }

    // Options section
    var has_options = false;
    inline for (type_info.@"struct".fields) |field| {
        if (!CommandMod.isPositional(T, field.name)) {
            const opt = CommandMod.getOptionSpec(T, field);
            if (!opt.hidden) {
                if (!has_options) {
                    try writer.writeAll("\nOptions:\n");
                    has_options = true;
                }

                // Format: "  -s, --long <value>  Description"
                // Use a buffer with safe bounds checking
                var buf: [256]u8 = undefined;
                var pos: usize = 0;

                // Short option (4 bytes max)
                if (opt.short) |s| {
                    buf[pos] = '-';
                    pos += 1;
                    buf[pos] = s;
                    pos += 1;
                    buf[pos] = ',';
                    pos += 1;
                    buf[pos] = ' ';
                    pos += 1;
                } else {
                    // Padding to align
                    @memset(buf[0..4], ' ');
                    pos = 4;
                }

                // Long option (convert underscores to hyphens for CLI convention)
                // Cap at available buffer space
                const long_len = @min(opt.long.len, buf.len - pos - 3); // Reserve space for "--" prefix and null
                buf[pos] = '-';
                pos += 1;
                buf[pos] = '-';
                pos += 1;
                copyWithHyphens(buf[pos .. pos + long_len], opt.long[0..long_len]);
                pos += long_len;

                // Value placeholder
                if (opt.takes_value) {
                    const val_len = @min(opt.value_name.len, buf.len - pos - 1);
                    if (val_len > 0) {
                        buf[pos] = ' ';
                        pos += 1;
                        @memcpy(buf[pos .. pos + val_len], opt.value_name[0..val_len]);
                        pos += val_len;
                    }
                }

                try writer.print("  {s:<24}  {s}\n", .{ buf[0..pos], opt.description });
            }
        }
    }

    // Always add help and version
    try writer.writeAll("  -h, --help                  Show this help message\n");
    try writer.writeAll("  -V, --version               Show version\n");

    // Examples
    if (meta.examples.len > 0) {
        try writer.writeAll("\nExamples:\n");
        for (meta.examples) |example| {
            try writer.print("  {s}\n", .{example});
        }
    }
}

/// Generate help text for an application with subcommands.
pub fn generateAppHelp(comptime App: type, writer: anytype) !void {
    const meta = CommandMod.getAppMeta(App);

    // Header
    try writer.print("{s}", .{meta.name});
    if (meta.version.len > 0) {
        try writer.print(" {s}", .{meta.version});
    }
    try writer.writeAll("\n");

    if (meta.description.len > 0) {
        try writer.print("{s}\n", .{meta.description});
    }

    // Usage - show default command pattern if defined
    if (@hasDecl(App, "default_command")) {
        // Show both default mode and explicit command mode
        try writer.print("\nUsage: {s} [OPTIONS] [ARGS...]  (default: {s})\n", .{ meta.name, App.default_command });
        try writer.print("       {s} <command> [OPTIONS]\n", .{meta.name});
    } else {
        try writer.print("\nUsage: {s} <command> [OPTIONS]\n", .{meta.name});
    }

    // Commands
    if (@hasDecl(App, "Command")) {
        try writer.writeAll("\nCommands:\n");

        const CmdUnion = App.Command;
        const union_info = @typeInfo(CmdUnion);
        const default_cmd = if (@hasDecl(App, "default_command")) App.default_command else "";

        if (union_info == .@"union") {
            inline for (union_info.@"union".fields) |field| {
                const cmd_meta = CommandMod.getCommandMeta(field.type);
                if (!cmd_meta.hidden) {
                    // Mark default command
                    const is_default = std.mem.eql(u8, field.name, default_cmd);
                    const suffix = if (is_default) " (default)" else "";
                    try writer.print("  {s:<16}  {s}{s}\n", .{ field.name, cmd_meta.description, suffix });
                }
            }
        }
    }

    // Global options (if defined)
    if (@hasDecl(App, "GlobalOptions")) {
        const GlobalOpts = App.GlobalOptions;
        const opts_info = @typeInfo(GlobalOpts);

        if (opts_info == .@"struct" and opts_info.@"struct".fields.len > 0) {
            try writer.writeAll("\nGlobal Options:\n");

            inline for (opts_info.@"struct".fields) |field| {
                const opt = CommandMod.getOptionSpec(GlobalOpts, field);
                if (!opt.hidden) {
                    // Use a buffer with safe bounds checking
                    var buf: [256]u8 = undefined;
                    var pos: usize = 0;

                    if (opt.short) |s| {
                        buf[pos] = '-';
                        pos += 1;
                        buf[pos] = s;
                        pos += 1;
                        buf[pos] = ',';
                        pos += 1;
                        buf[pos] = ' ';
                        pos += 1;
                    } else {
                        @memset(buf[0..4], ' ');
                        pos = 4;
                    }

                    // Cap at available buffer space
                    const long_len = @min(opt.long.len, buf.len - pos - 3);
                    buf[pos] = '-';
                    pos += 1;
                    buf[pos] = '-';
                    pos += 1;
                    copyWithHyphens(buf[pos .. pos + long_len], opt.long[0..long_len]);
                    pos += long_len;

                    if (opt.takes_value) {
                        const val_len = @min(opt.value_name.len, buf.len - pos - 1);
                        if (val_len > 0) {
                            buf[pos] = ' ';
                            pos += 1;
                            @memcpy(buf[pos .. pos + val_len], opt.value_name[0..val_len]);
                            pos += val_len;
                        }
                    }

                    try writer.print("  {s:<24}  {s}\n", .{ buf[0..pos], opt.description });
                }
            }
        }
    }

    try writer.writeAll("\n  -h, --help                  Show this help message\n");
    try writer.writeAll("  -V, --version               Show version\n");

    // Footer
    if (meta.author) |author| {
        try writer.print("\nAuthor: {s}\n", .{author});
    }
}

/// Generate help for a specific command within an application.
/// This handles both regular commands and subcommand groups.
/// For nested subcommands (e.g., "add" within "bib"), also searches subcommand groups.
pub fn generateCommandHelp(comptime App: type, cmd_name: []const u8, writer: anytype) !void {
    const CommandUnion = if (@hasDecl(App, "Command")) App.Command else return error.NoCommands;
    const union_info = @typeInfo(CommandUnion);

    if (union_info != .@"union") return error.InvalidCommand;

    // First, check top-level commands
    inline for (union_info.@"union".fields) |field| {
        if (std.mem.eql(u8, field.name, cmd_name)) {
            // Check if this is a subcommand group
            if (@hasDecl(field.type, "is_subcommand_group") and field.type.is_subcommand_group) {
                try generateSubcommandGroupHelp(field.type, field.name, writer);
            } else {
                // Regular command - generate its help
                try generateHelp(field.type, writer);
            }
            return;
        }

        // Also check aliases for regular commands
        if (!@hasDecl(field.type, "is_subcommand_group")) {
            const cmd_meta = CommandMod.getCommandMeta(field.type);
            for (cmd_meta.aliases) |alias| {
                if (std.mem.eql(u8, alias, cmd_name)) {
                    try generateHelp(field.type, writer);
                    return;
                }
            }
        }
    }

    // Second, search within subcommand groups for nested commands
    inline for (union_info.@"union".fields) |field| {
        if (@hasDecl(field.type, "is_subcommand_group") and field.type.is_subcommand_group) {
            const SubCommands = field.type.commands;
            const sub_union_info = @typeInfo(SubCommands);
            if (sub_union_info == .@"union") {
                inline for (sub_union_info.@"union".fields) |sub_field| {
                    if (std.mem.eql(u8, sub_field.name, cmd_name)) {
                        try generateHelp(sub_field.type, writer);
                        return;
                    }
                    // Check aliases
                    const sub_meta = CommandMod.getCommandMeta(sub_field.type);
                    for (sub_meta.aliases) |alias| {
                        if (std.mem.eql(u8, alias, cmd_name)) {
                            try generateHelp(sub_field.type, writer);
                            return;
                        }
                    }
                }
            }
        }
    }

    // Command not found
    try writer.print("Unknown command: {s}\n", .{cmd_name});
}

/// Generate help for a subcommand group, listing its available subcommands.
fn generateSubcommandGroupHelp(comptime SubgroupType: type, group_name: []const u8, writer: anytype) !void {
    const meta = SubgroupType.meta;
    const SubCommands = SubgroupType.commands;
    const sub_union_info = @typeInfo(SubCommands);

    // Header
    if (meta.name.len > 0) {
        try writer.print("{s}\n", .{meta.name});
    } else {
        try writer.print("{s}\n", .{group_name});
    }

    if (meta.description.len > 0) {
        try writer.print("{s}\n", .{meta.description});
    }

    // Usage
    const display_name = if (meta.name.len > 0) meta.name else group_name;
    try writer.print("\nUsage: {s} <subcommand> [options]\n", .{display_name});

    // Subcommands
    try writer.writeAll("\nSubcommands:\n");

    if (sub_union_info == .@"union") {
        inline for (sub_union_info.@"union".fields) |field| {
            const cmd_meta = CommandMod.getCommandMeta(field.type);
            if (!cmd_meta.hidden) {
                try writer.print("  {s:<16}  {s}\n", .{ field.name, cmd_meta.description });
            }
        }
    }

    try writer.writeAll("\n  -h, --help                  Show this help message\n");
}

/// Generate short usage string.
pub fn generateUsage(comptime T: type, writer: anytype) !void {
    const meta = CommandMod.getCommandMeta(T);
    const type_info = @typeInfo(T);

    try writer.print("Usage: {s}", .{meta.name});

    inline for (type_info.@"struct".fields) |field| {
        if (CommandMod.isPositional(T, field.name)) {
            const pos_spec = CommandMod.getPositionalSpec(T, field);
            if (pos_spec.required) {
                try writer.print(" <{s}>", .{field.name});
            } else {
                try writer.print(" [{s}]", .{field.name});
            }
        }
    }

    try writer.writeAll(" [OPTIONS]\n");
}

/// Print help to a file.
pub fn printHelp(comptime T: type, file: std.fs.File) void {
    var file_writer = file.writer(&.{});
    generateHelp(T, &file_writer.interface) catch {};
}

/// Print app help to a file.
pub fn printAppHelp(comptime App: type, file: std.fs.File) void {
    var file_writer = file.writer(&.{});
    generateAppHelp(App, &file_writer.interface) catch {};
}

test "generateHelp basic" {
    const TestCmd = struct {
        file: []const u8 = "",
        output: ?[]const u8 = null,
        verbose: bool = false,

        pub const meta = .{
            .name = "test",
            .description = "A test command",
        };

        pub const positional = .{.file};

        pub const fields = .{
            .file = .{ .description = "Input file" },
            .output = .{ .short = 'o', .description = "Output file", .value_name = "<file>" },
            .verbose = .{ .short = 'v', .description = "Enable verbose output" },
        };
    };

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    try generateHelp(TestCmd, stream.writer());

    const result = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, result, "test") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "A test command") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--verbose") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "-v") != null);
}

test "generateAppHelp" {
    const ListCmd = struct {
        all: bool = false,
        pub const meta = .{ .name = "list", .description = "List items" };
    };

    const ShowCmd = struct {
        id: []const u8 = "",
        pub const meta = .{ .name = "show", .description = "Show an item" };
    };

    const TestApp = struct {
        pub const meta = .{
            .name = "myapp",
            .version = "1.0.0",
            .description = "My test application",
        };

        pub const Command = CommandMod.Commands(.{
            .list = ListCmd,
            .show = ShowCmd,
        });
    };

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    try generateAppHelp(TestApp, stream.writer());

    const result = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, result, "myapp 1.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "list") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "show") != null);
}

test "generateCommandHelp for regular command" {
    const ListCmd = struct {
        all: bool = false,
        pub const meta = .{ .name = "list", .description = "List all items" };
        pub const fields = .{
            .all = .{ .short = 'a', .description = "Show all items" },
        };
    };

    const TestApp = struct {
        pub const meta = .{ .name = "myapp" };
        pub const Command = CommandMod.Commands(.{
            .list = ListCmd,
        });
    };

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    try generateCommandHelp(TestApp, "list", stream.writer());

    const result = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, result, "list") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "List all items") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--all") != null);
}

test "generateCommandHelp for subcommand group" {
    const BibAddCmd = struct {
        pub const meta = .{ .name = "add", .description = "Add a bibliography entry" };
    };
    const BibRemoveCmd = struct {
        pub const meta = .{ .name = "remove", .description = "Remove an entry" };
    };

    const TestApp = struct {
        pub const meta = .{ .name = "myapp" };
        pub const Command = CommandMod.Commands(.{
            .bib = CommandMod.Subcommand(.{
                .meta = .{ .name = "bib", .description = "Manage bibliography" },
                .commands = .{
                    .add = BibAddCmd,
                    .remove = BibRemoveCmd,
                },
            }),
        });
    };

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    try generateCommandHelp(TestApp, "bib", stream.writer());

    const result = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, result, "bib") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Manage bibliography") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Subcommands:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "add") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "remove") != null);
}

test "generateAppHelp shows subcommand group descriptions" {
    const BibAddCmd = struct {
        pub const meta = .{ .name = "add", .description = "Add entry" };
    };

    const HealthCmd = struct {
        pub const meta = .{ .name = "health", .description = "Check health" };
    };

    const TestApp = struct {
        pub const meta = .{
            .name = "myapp",
            .version = "1.0",
            .description = "Test app",
        };
        pub const Command = CommandMod.Commands(.{
            .health = HealthCmd,
            .bib = CommandMod.Subcommand(.{
                .meta = .{ .name = "bib", .description = "Manage bibliography entries" },
                .commands = .{ .add = BibAddCmd },
            }),
        });
    };

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    try generateAppHelp(TestApp, stream.writer());

    const result = stream.getWritten();
    // Verify subcommand group description is shown
    try std.testing.expect(std.mem.indexOf(u8, result, "bib") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Manage bibliography entries") != null);
    // Verify regular command is also shown
    try std.testing.expect(std.mem.indexOf(u8, result, "health") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Check health") != null);
}

test "generateHelp shows hyphenated option names" {
    const TestCmd = struct {
        min_year: ?i32 = null,
        max_results: u32 = 10,

        pub const meta = .{ .name = "test", .description = "Test command" };
        pub const fields = .{
            .min_year = .{ .description = "Minimum year filter" },
            .max_results = .{ .description = "Max results to return" },
        };
    };

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    try generateHelp(TestCmd, stream.writer());

    const result = stream.getWritten();
    // Should show hyphens, not underscores
    try std.testing.expect(std.mem.indexOf(u8, result, "--min-year") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--max-results") != null);
    // Should NOT show underscores
    try std.testing.expect(std.mem.indexOf(u8, result, "--min_year") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--max_results") == null);
}

test "generateCommandHelp resolves alias" {
    const ListCmd = struct {
        all: bool = false,
        pub const meta = .{
            .name = "list",
            .description = "List all items",
            .aliases = &[_][]const u8{"ls"},
        };
    };

    const TestApp = struct {
        pub const meta = .{ .name = "myapp" };
        pub const Command = CommandMod.Commands(.{
            .list = ListCmd,
        });
    };

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    // Looking up by alias should work
    try generateCommandHelp(TestApp, "ls", stream.writer());

    const result = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, result, "list") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "List all items") != null);
}

test "generateCommandHelp finds nested subcommand" {
    const BibAddCmd = struct {
        file: []const u8 = "",
        pub const meta = .{ .name = "add", .description = "Add bibliography entry" };
        pub const positional = .{.file};
    };

    const TestApp = struct {
        pub const meta = .{ .name = "myapp" };
        pub const Command = CommandMod.Commands(.{
            .bib = CommandMod.Subcommand(.{
                .meta = .{ .name = "bib", .description = "Bibliography commands" },
                .commands = .{ .add = BibAddCmd },
            }),
        });
    };

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    // Looking up nested subcommand by name should work
    try generateCommandHelp(TestApp, "add", stream.writer());

    const result = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, result, "add") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Add bibliography entry") != null);
}
