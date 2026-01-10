//! CLI Demo - demonstrates termcat.cli utilities
//!
//! Run with:
//!   zig build cli_demo && ./zig-out/bin/cli_demo --help
//!   ./zig-out/bin/cli_demo greet Alice
//!   ./zig-out/bin/cli_demo list --json
//!   ./zig-out/bin/cli_demo count 10

const std = @import("std");
const termcat = @import("termcat");
const cli = termcat.cli;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), args);

    var output = cli.Output.init();

    // Skip program name
    const cmd_args = if (args.len > 0) args[1..] else args;

    if (cmd_args.len == 0 or std.mem.eql(u8, cmd_args[0], "--help") or std.mem.eql(u8, cmd_args[0], "-h")) {
        printHelp(&output);
        return;
    }

    const cmd = cmd_args[0];
    const rest = if (cmd_args.len > 1) cmd_args[1..] else &[_][]const u8{};

    if (std.mem.eql(u8, cmd, "greet")) {
        try cmdGreet(&output, rest);
    } else if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "ls")) {
        try cmdList(&output, rest);
    } else if (std.mem.eql(u8, cmd, "count")) {
        try cmdCount(&output, rest);
    } else {
        try output.err(cli.CliError.usageError("unknown command")
            .withContext(cmd)
            .withSuggestion("run with --help to see available commands"));
        cli.ExitCode.usage_error.exit();
    }
}

fn printHelp(output: *cli.Output) void {
    output.print(
        \\cli_demo 0.1.0
        \\Demo CLI application using termcat.cli
        \\
        \\Usage: cli_demo <command> [options]
        \\
        \\Commands:
        \\  greet <name>     Greet someone
        \\  list             List demo items
        \\  count <n>        Count to a number with progress
        \\
        \\Options:
        \\  -h, --help       Show this help message
        \\
        \\Examples:
        \\  cli_demo greet Alice
        \\  cli_demo greet Bob --shout
        \\  cli_demo list --json
        \\  cli_demo count 10
        \\
    , .{}) catch {};
}

fn cmdGreet(output: *cli.Output, args: []const []const u8) !void {
    var name: []const u8 = "World";
    var shout = false;
    var times: u32 = 1;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (cli.matchesFlag(arg, 's', "shout")) {
            shout = true;
        } else if (cli.matchesFlag(arg, 'n', "times")) {
            if (cli.nextValue(args, &i)) |val| {
                times = std.fmt.parseInt(u32, val, 10) catch {
                    cli.die("invalid value for --times: {s}", .{val});
                };
            } else {
                cli.die("--times requires a value", .{});
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            name = arg;
        }
    }

    var j: u32 = 0;
    while (j < times) : (j += 1) {
        if (shout) {
            try output.success("HELLO, {s}!", .{name});
        } else {
            try output.success("Hello, {s}!", .{name});
        }
    }
}

fn cmdList(output: *cli.Output, args: []const []const u8) !void {
    var json = false;
    var quiet = false;

    for (args) |arg| {
        if (cli.matchesFlag(arg, null, "json")) {
            json = true;
        } else if (cli.matchesFlag(arg, 'q', "quiet")) {
            quiet = true;
        }
    }

    output.setModeFromFlags(json, quiet, false, false);

    const Item = struct {
        id: []const u8,
        name: []const u8,
        status: []const u8,
    };

    const items = [_]Item{
        .{ .id = "item-001", .name = "First Item", .status = "active" },
        .{ .id = "item-002", .name = "Second Item", .status = "pending" },
        .{ .id = "item-003", .name = "Third Item", .status = "completed" },
    };

    try output.list(Item, &items);
}

fn cmdCount(output: *cli.Output, args: []const []const u8) !void {
    var target: u32 = 10;
    var delay: u32 = 100;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (cli.matchesFlag(arg, 'd', "delay")) {
            if (cli.nextValue(args, &i)) |val| {
                delay = std.fmt.parseInt(u32, val, 10) catch {
                    cli.die("invalid value for --delay: {s}", .{val});
                };
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            target = std.fmt.parseInt(u32, arg, 10) catch {
                cli.die("invalid target: {s}", .{arg});
            };
        }
    }

    var bar = cli.ProgressBar.init(output, target, "Counting...");

    var count: u32 = 0;
    while (count <= target) : (count += 1) {
        try bar.update(count);
        std.Thread.sleep(delay * std.time.ns_per_ms);
    }

    try bar.finish();
    try output.success("Counted to {d}!", .{target});
}
