//! termcat.cli - Command-line interface framework
//!
//! Provides types and utilities for building CLI applications.
//! Core features:
//! - Output formatting (JSON, table, human-readable)
//! - Error handling with structured messages
//! - Progress indicators (spinner, progress bar)
//! - Command/option type definitions
//!
//! Note: The full comptime argument parsing is still in development.
//! For now, use the output and error utilities alongside manual parsing.

const std = @import("std");

// Core command types
pub const Command = @import("Command.zig");
pub const Commands = Command.Commands;
pub const Subcommand = Command.Subcommand;
pub const FieldMeta = Command.FieldMeta;
pub const CommandMeta = Command.CommandMeta;
pub const AppMeta = Command.AppMeta;
pub const OptionSpec = Command.OptionSpec;
pub const PositionalSpec = Command.PositionalSpec;
pub const getCommandMeta = Command.getCommandMeta;
pub const getAppMeta = Command.getAppMeta;
pub const isPositional = Command.isPositional;
pub const getFieldMeta = Command.getFieldMeta;
pub const getOptionSpec = Command.getOptionSpec;
pub const getPositionalSpec = Command.getPositionalSpec;

// Output
pub const Output = @import("Output.zig").Output;
pub const OutputMode = @import("Output.zig").Mode;
pub const ColorMode = @import("Output.zig").ColorMode;

// Table formatting
pub const Table = @import("Table.zig").Table;
pub const DynamicTable = @import("Table.zig").DynamicTable;
pub const Column = @import("Table.zig").Column;

// Error handling
pub const Error = @import("Error.zig");
pub const CliError = Error.CliError;
pub const ParseError = Error.ParseError;
pub const ParseErrorKind = Error.ParseErrorKind;
pub const ExitCode = Error.ExitCode;
pub const mapStoreError = Error.mapStoreError;

// Progress indicators
pub const Progress = @import("Progress.zig");
pub const Spinner = Progress.Spinner;
pub const SpinnerStyle = Progress.SpinnerStyle;
pub const ProgressBar = Progress.ProgressBar;
pub const StatusLine = Progress.StatusLine;

// Argument parsing
pub const Parser = @import("Parser.zig");
pub const parse = Parser.parse;
pub const parseWithEnv = Parser.parseWithEnv;
pub const ParseResult = Parser.ParseResult;
pub const parseApp = Parser.parseApp;
pub const AppParseResult = Parser.AppParseResult;

// Help generation
pub const Help = @import("Help.zig");
pub const generateHelp = Help.generateHelp;
pub const generateAppHelp = Help.generateAppHelp;
pub const printHelp = Help.printHelp;
pub const printAppHelp = Help.printAppHelp;

/// Extract common output flags from a command struct.
/// Convenience for commands that follow the jwz/tissue pattern.
pub fn getOutputFlags(cmd: anytype) struct { json: bool, quiet: bool, summary: bool, pretty: bool } {
    const T = @TypeOf(cmd);
    return .{
        .json = if (@hasField(T, "json")) cmd.json else false,
        .quiet = if (@hasField(T, "quiet")) cmd.quiet else false,
        .summary = if (@hasField(T, "summary")) cmd.summary else false,
        .pretty = if (@hasField(T, "pretty")) cmd.pretty else false,
    };
}

/// Simple argument helper - get next value from args.
/// Returns null if no more args or next arg is an option.
pub fn nextValue(args: []const []const u8, i: *usize) ?[]const u8 {
    if (i.* + 1 >= args.len) return null;
    const next = args[i.* + 1];
    if (next.len > 0 and next[0] == '-') return null;
    i.* += 1;
    return next;
}

/// Check if arg matches a flag (short or long form).
pub fn matchesFlag(arg: []const u8, short: ?u8, long: []const u8) bool {
    if (std.mem.eql(u8, arg, long)) return true;
    if (arg.len == 2 and arg[0] == '-') {
        if (short) |s| {
            if (arg[1] == s) return true;
        }
    }
    if (arg.len > 2 and std.mem.startsWith(u8, arg, "--")) {
        if (std.mem.eql(u8, arg[2..], long)) return true;
    }
    return false;
}

/// File-based writer type for stderr.
const FileWriter = std.io.GenericWriter(std.fs.File, std.fs.File.WriteError, struct {
    fn write(file: std.fs.File, bytes: []const u8) std.fs.File.WriteError!usize {
        return file.write(bytes);
    }
}.write);

/// Die with error message (for CLI error handling).
pub fn die(comptime fmt: []const u8, args: anytype) noreturn {
    const stderr = std.fs.File.stderr();
    const writer = (FileWriter{ .context = stderr }).any();
    writer.print("error: " ++ fmt ++ "\n", args) catch {};
    std.process.exit(1);
}

test {
    std.testing.refAllDecls(@This());
}
