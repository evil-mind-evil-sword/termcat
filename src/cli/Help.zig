//! Auto-generated help text for CLI applications.
//!
//! Generates formatted help output from command metadata defined
//! using the declarative struct pattern.

const std = @import("std");
const CommandMod = @import("Command.zig");

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
            if (pos_spec.required) {
                try writer.print(" <{s}>", .{field.name});
            } else {
                try writer.print(" [{s}]", .{field.name});
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
                var buf: [64]u8 = undefined;
                var pos: usize = 0;

                // Short option
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
                    buf[pos] = ' ';
                    pos += 1;
                    buf[pos] = ' ';
                    pos += 1;
                    buf[pos] = ' ';
                    pos += 1;
                    buf[pos] = ' ';
                    pos += 1;
                }

                // Long option
                buf[pos] = '-';
                pos += 1;
                buf[pos] = '-';
                pos += 1;
                @memcpy(buf[pos .. pos + opt.long.len], opt.long);
                pos += opt.long.len;

                // Value placeholder
                if (opt.takes_value) {
                    buf[pos] = ' ';
                    pos += 1;
                    @memcpy(buf[pos .. pos + opt.value_name.len], opt.value_name);
                    pos += opt.value_name.len;
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

    // Usage
    try writer.print("\nUsage: {s} <command> [options]\n", .{meta.name});

    // Commands
    if (@hasDecl(App, "Command")) {
        try writer.writeAll("\nCommands:\n");

        const CmdUnion = App.Command;
        const union_info = @typeInfo(CmdUnion);

        if (union_info == .@"union") {
            inline for (union_info.@"union".fields) |field| {
                const cmd_meta = CommandMod.getCommandMeta(field.type);
                if (!cmd_meta.hidden) {
                    try writer.print("  {s:<16}  {s}\n", .{ field.name, cmd_meta.description });
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
                    var buf: [64]u8 = undefined;
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

                    buf[pos] = '-';
                    pos += 1;
                    buf[pos] = '-';
                    pos += 1;
                    @memcpy(buf[pos .. pos + opt.long.len], opt.long);
                    pos += opt.long.len;

                    if (opt.takes_value) {
                        buf[pos] = ' ';
                        pos += 1;
                        @memcpy(buf[pos .. pos + opt.value_name.len], opt.value_name);
                        pos += opt.value_name.len;
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
