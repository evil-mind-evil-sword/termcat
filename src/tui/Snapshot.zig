//! Snapshot Testing Framework for termcat widgets
//!
//! Enables visual regression testing by comparing widget renders against golden files.
//! Supports text-based snapshots (`.snap` files) that are easy to review in PRs.
//!
//! ## Usage (HeadlessBackend API - Recommended)
//!
//! ```zig
//! const std = @import("std");
//! const testing = std.testing;
//! const termcat = @import("termcat");
//! const HeadlessBackend = termcat.backend.headless.HeadlessBackend;
//! const Snapshot = termcat.tui.Snapshot;
//!
//! test "button renders correctly" {
//!     var backend = try HeadlessBackend.init(testing.allocator, .{ .width = 20, .height = 3 });
//!     defer backend.deinit();
//!
//!     // Render your widget to the backend buffer...
//!     var button = Button.init("Click me");
//!     button.widget_state = .{ .focused = true };
//!     const widget = Widget.init(Button, &button);
//!     var plane = PlaneView.init(backend.getBuffer());
//!     widget.render(&plane);
//!
//!     // Compare against snapshot
//!     try Snapshot.expectBackend(testing.allocator, &backend, "button_default", .{});
//! }
//! ```
//!
//! ## Usage (Widget Convenience API)
//!
//! For simpler cases where you just need to snapshot a single widget:
//!
//! ```zig
//! test "button widget snapshot" {
//!     var button = Button.init("Click me");
//!     try Snapshot.expectWidget(
//!         testing.allocator,
//!         Widget.init(Button, &button),
//!         .{ .width = 20, .height = 3 },
//!         "button_focused",
//!     );
//! }
//! ```
//!
//! ## Update Mode
//!
//! To regenerate snapshots, set the environment variable:
//! ```
//! TERMCAT_UPDATE_SNAPSHOTS=1 zig build test
//! ```
//!
//! ## Snapshot Files
//!
//! Snapshots are stored as `.snap` files in the configured directory (default: `snapshots/`).
//! The extension was chosen to be distinct from regular text files and consistent with
//! other snapshot testing frameworks (Jest, Insta, etc.).
//!
//! By default, snapshots are stored in `snapshots/` relative to the current working directory.
//! Use `Options.snapshot_path` to specify a custom absolute or relative path.

const std = @import("std");
const Plane = @import("../Plane.zig");
const Cell = @import("../Cell.zig");
const Buffer = @import("../Buffer.zig");
const Event = @import("../Event.zig");
const Widget = @import("Widget.zig").Widget;
const SizeConstraint = @import("Widget.zig").SizeConstraint;
const PlaneView = @import("PlaneView.zig").PlaneView;
const HeadlessBackend = @import("../backend/headless.zig").HeadlessBackend;

pub const Snapshot = @This();

/// Error types for snapshot testing
pub const SnapshotError = error{
    /// Snapshot file not found and update mode is disabled
    SnapshotNotFound,
    /// Rendered output differs from snapshot
    SnapshotMismatch,
    /// Failed to create snapshot directory
    DirectoryCreationFailed,
    /// Invalid snapshot file format
    InvalidSnapshotFormat,
} || std.mem.Allocator.Error || std.fs.File.OpenError || std.fs.File.WriteError || std.fs.File.ReadError;

/// Options for snapshot comparison
pub const Options = struct {
    /// Width of the render area (for widget API)
    width: u16 = 80,
    /// Height of the render area (for widget API)
    height: u16 = 24,
    /// Include cell attributes in snapshot (colors, bold, etc.)
    include_attributes: bool = false,
    /// Trim trailing whitespace from each line
    trim_trailing_whitespace: bool = true,
    /// Snapshot directory path (relative to cwd or absolute)
    snapshot_path: []const u8 = "snapshots",
    /// Number of context lines to show around differences in diff output
    context_lines: usize = 3,
};

/// Result of a snapshot comparison
pub const CompareResult = struct {
    matches: bool,
    expected: ?[]const u8,
    actual: []const u8,
    diff: ?[]const u8,

    pub fn deinit(self: *CompareResult, allocator: std.mem.Allocator) void {
        if (self.expected) |e| allocator.free(e);
        allocator.free(self.actual);
        if (self.diff) |d| allocator.free(d);
    }
};

/// Cached update mode state (computed once per process)
var update_mode_cached: ?bool = null;

// ============================================================================
// Core API - HeadlessBackend (matches issue specification)
// ============================================================================

/// Check if update mode is enabled via environment variable.
/// Result is cached after first call.
pub fn isUpdateMode(allocator: std.mem.Allocator) bool {
    if (update_mode_cached) |cached| return cached;

    const result = blk: {
        const env_result = std.process.getEnvVarOwned(allocator, "TERMCAT_UPDATE_SNAPSHOTS") catch break :blk false;
        defer allocator.free(env_result);
        break :blk std.mem.eql(u8, env_result, "1") or
            std.mem.eql(u8, env_result, "true") or
            std.mem.eql(u8, env_result, "yes");
    };

    update_mode_cached = result;
    return result;
}

/// Reset the cached update mode (for testing)
pub fn resetUpdateModeCache() void {
    update_mode_cached = null;
}

/// Expect a HeadlessBackend buffer to match a snapshot.
/// This is the primary API matching the issue specification.
///
/// In update mode, creates/updates the snapshot file.
/// In verify mode, compares against existing snapshot and fails on mismatch.
pub fn expectSnapshot(
    allocator: std.mem.Allocator,
    buffer: *Buffer,
    size: Event.Size,
    snapshot_name: []const u8,
    options: Options,
) SnapshotError!void {
    // Render the buffer to a string
    const rendered = try bufferToString(allocator, buffer, size, options);
    defer allocator.free(rendered);

    try expectContent(allocator, rendered, snapshot_name, options);
}

/// Expect a Buffer to match a snapshot.
/// Convenience overload that extracts size from the buffer.
pub fn expectBuffer(
    allocator: std.mem.Allocator,
    buffer: *Buffer,
    snapshot_name: []const u8,
    options: Options,
) SnapshotError!void {
    const size = Event.Size{ .width = buffer.width, .height = buffer.height };
    return expectSnapshot(allocator, buffer, size, snapshot_name, options);
}

/// Expect a HeadlessBackend's current state to match a snapshot.
/// This is the recommended API for snapshot testing, matching the issue specification.
///
/// Example:
/// ```zig
/// var backend = try HeadlessBackend.init(allocator, .{ .width = 80, .height = 24 });
/// defer backend.deinit();
/// // ... render to backend ...
/// try Snapshot.expectBackend(allocator, &backend, "my_test", .{});
/// ```
pub fn expectBackend(
    allocator: std.mem.Allocator,
    backend: *HeadlessBackend,
    snapshot_name: []const u8,
    options: Options,
) SnapshotError!void {
    return expectSnapshot(allocator, backend.getBuffer(), backend.size, snapshot_name, options);
}

// ============================================================================
// Convenience API - Widget-based
// ============================================================================

/// Expect a widget's render to match a snapshot.
/// This is a convenience API that creates a Plane internally.
///
/// In update mode, creates/updates the snapshot file.
/// In verify mode, compares against existing snapshot and fails on mismatch.
pub fn expectWidget(
    allocator: std.mem.Allocator,
    widget: Widget,
    options: Options,
    snapshot_name: []const u8,
) SnapshotError!void {
    // Render the widget to a string
    const rendered = try renderWidget(allocator, widget, options);
    defer allocator.free(rendered);

    try expectContent(allocator, rendered, snapshot_name, options);
}

/// Expect a raw string to match a snapshot (for testing non-widget renders)
pub fn expectString(
    allocator: std.mem.Allocator,
    actual: []const u8,
    snapshot_name: []const u8,
    options: Options,
) SnapshotError!void {
    try expectContent(allocator, actual, snapshot_name, options);
}

// ============================================================================
// Internal - Content comparison
// ============================================================================

fn expectContent(
    allocator: std.mem.Allocator,
    actual: []const u8,
    snapshot_name: []const u8,
    options: Options,
) SnapshotError!void {
    // Get the snapshot path
    const snapshot_path = try getSnapshotPath(allocator, options.snapshot_path, snapshot_name);
    defer allocator.free(snapshot_path);

    if (isUpdateMode(allocator)) {
        // Update mode: write the snapshot
        try writeSnapshot(snapshot_path, options.snapshot_path, actual);
        std.debug.print("Updated snapshot: {s}\n", .{snapshot_path});
    } else {
        // Verify mode: compare against existing snapshot
        const expected = readSnapshot(allocator, snapshot_path) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print(
                    \\
                    \\╔══════════════════════════════════════════════════════════════╗
                    \\║                    SNAPSHOT NOT FOUND                        ║
                    \\╠══════════════════════════════════════════════════════════════╣
                    \\║ Snapshot: {s}
                    \\║ Path: {s}
                    \\║                                                              ║
                    \\║ To create this snapshot, run:                                ║
                    \\║   TERMCAT_UPDATE_SNAPSHOTS=1 zig build test                  ║
                    \\╚══════════════════════════════════════════════════════════════╝
                    \\
                    \\Actual output:
                    \\{s}
                    \\
                , .{ snapshot_name, snapshot_path, actual });
                return error.SnapshotNotFound;
            },
            else => return err,
        };
        defer allocator.free(expected);

        if (!std.mem.eql(u8, expected, actual)) {
            const diff = try generateDiff(allocator, expected, actual, options.context_lines);
            defer allocator.free(diff);

            std.debug.print(
                \\
                \\╔══════════════════════════════════════════════════════════════╗
                \\║                    SNAPSHOT MISMATCH                         ║
                \\╠══════════════════════════════════════════════════════════════╣
                \\║ Snapshot: {s}
                \\║                                                              ║
                \\║ To update this snapshot, run:                                ║
                \\║   TERMCAT_UPDATE_SNAPSHOTS=1 zig build test                  ║
                \\╚══════════════════════════════════════════════════════════════╝
                \\
                \\{s}
                \\
            , .{ snapshot_name, diff });
            return error.SnapshotMismatch;
        }
    }
}

// ============================================================================
// Rendering
// ============================================================================

/// Convert a Buffer to a string representation
pub fn bufferToString(
    allocator: std.mem.Allocator,
    buffer: *Buffer,
    size: Event.Size,
    options: Options,
) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    const w = result.writer();

    for (0..size.height) |y| {
        var line_end: usize = size.width;

        // Find the last non-space character if trimming
        if (options.trim_trailing_whitespace) {
            while (line_end > 0) {
                const idx = y * @as(usize, size.width) + (line_end - 1);
                if (idx < buffer.cells.len) {
                    const cell = buffer.cells[idx];
                    if (cell.char != ' ' and cell.char != 0) break;
                }
                line_end -= 1;
            }
        }

        for (0..line_end) |x| {
            const idx = y * @as(usize, size.width) + x;
            if (idx >= buffer.cells.len) {
                try w.writeByte(' ');
                continue;
            }

            const cell = buffer.cells[idx];

            if (options.include_attributes) {
                try writeStyledChar(w, cell);
            } else {
                if (cell.char == 0) {
                    try w.writeByte(' ');
                } else {
                    var utf8_buf: [4]u8 = undefined;
                    const utf8_len = std.unicode.utf8Encode(cell.char, &utf8_buf) catch {
                        try w.writeByte('?');
                        continue;
                    };
                    try w.writeAll(utf8_buf[0..utf8_len]);
                }
            }
        }

        // Add newline (except for last line)
        if (y < size.height - 1) {
            try w.writeByte('\n');
        }
    }

    return result.toOwnedSlice();
}

/// Render a widget to a string representation
pub fn renderWidget(
    allocator: std.mem.Allocator,
    widget: Widget,
    options: Options,
) ![]const u8 {
    // Create a plane for rendering
    const plane = try Plane.initRoot(allocator, .{
        .width = options.width,
        .height = options.height,
    });
    defer plane.deinit();

    // Create a view and render the widget
    var view = PlaneView.init(plane);
    widget.render(&view);

    // Convert to string
    return try planeToString(allocator, plane, options);
}

/// Convert a plane to a string representation
pub fn planeToString(
    allocator: std.mem.Allocator,
    plane: *Plane,
    options: Options,
) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    const w = result.writer();

    for (0..plane.height) |y| {
        var line_end: usize = plane.width;

        // Find the last non-space character if trimming
        if (options.trim_trailing_whitespace) {
            while (line_end > 0) {
                const cell = plane.getCell(@intCast(line_end - 1), @intCast(y));
                if (cell.char != ' ' and cell.char != 0) break;
                line_end -= 1;
            }
        }

        for (0..line_end) |x| {
            const cell = plane.getCell(@intCast(x), @intCast(y));

            if (options.include_attributes) {
                try writeStyledChar(w, cell);
            } else {
                if (cell.char == 0) {
                    try w.writeByte(' ');
                } else {
                    var utf8_buf: [4]u8 = undefined;
                    const utf8_len = std.unicode.utf8Encode(cell.char, &utf8_buf) catch {
                        try w.writeByte('?');
                        continue;
                    };
                    try w.writeAll(utf8_buf[0..utf8_len]);
                }
            }
        }

        // Add newline (except for last line)
        if (y < plane.height - 1) {
            try w.writeByte('\n');
        }
    }

    return result.toOwnedSlice();
}

/// Write a cell with ANSI styling (for include_attributes mode)
fn writeStyledChar(writer: anytype, cell: Cell) !void {
    const has_style = !cell.fg.eql(.default) or !cell.bg.eql(.default) or
        cell.attrs.bold or cell.attrs.italic or cell.attrs.underline or
        cell.attrs.reverse or cell.attrs.dim or cell.attrs.strikethrough;

    if (has_style) {
        try writer.writeAll("\x1b[");
        var first = true;

        if (cell.attrs.bold) {
            if (!first) try writer.writeByte(';');
            try writer.writeAll("1");
            first = false;
        }
        if (cell.attrs.dim) {
            if (!first) try writer.writeByte(';');
            try writer.writeAll("2");
            first = false;
        }
        if (cell.attrs.italic) {
            if (!first) try writer.writeByte(';');
            try writer.writeAll("3");
            first = false;
        }
        if (cell.attrs.underline) {
            if (!first) try writer.writeByte(';');
            try writer.writeAll("4");
            first = false;
        }
        if (cell.attrs.reverse) {
            if (!first) try writer.writeByte(';');
            try writer.writeAll("7");
            first = false;
        }
        if (cell.attrs.strikethrough) {
            if (!first) try writer.writeByte(';');
            try writer.writeAll("9");
            first = false;
        }

        switch (cell.fg) {
            .default => {},
            .index => |idx| {
                if (!first) try writer.writeByte(';');
                if (idx < 8) {
                    try writer.print("3{d}", .{idx});
                } else if (idx < 16) {
                    try writer.print("9{d}", .{idx - 8});
                } else {
                    try writer.print("38;5;{d}", .{idx});
                }
                first = false;
            },
            .rgb => |c| {
                if (!first) try writer.writeByte(';');
                try writer.print("38;2;{d};{d};{d}", .{ c.r, c.g, c.b });
                first = false;
            },
        }

        switch (cell.bg) {
            .default => {},
            .index => |idx| {
                if (!first) try writer.writeByte(';');
                if (idx < 8) {
                    try writer.print("4{d}", .{idx});
                } else if (idx < 16) {
                    try writer.print("10{d}", .{idx - 8});
                } else {
                    try writer.print("48;5;{d}", .{idx});
                }
                first = false;
            },
            .rgb => |c| {
                if (!first) try writer.writeByte(';');
                try writer.print("48;2;{d};{d};{d}", .{ c.r, c.g, c.b });
                first = false;
            },
        }

        try writer.writeByte('m');
    }

    if (cell.char == 0) {
        try writer.writeByte(' ');
    } else {
        var utf8_buf: [4]u8 = undefined;
        const utf8_len = std.unicode.utf8Encode(cell.char, &utf8_buf) catch {
            try writer.writeByte('?');
            return;
        };
        try writer.writeAll(utf8_buf[0..utf8_len]);
    }

    if (has_style) {
        try writer.writeAll("\x1b[0m");
    }
}

// ============================================================================
// File I/O
// ============================================================================

/// Get the full path to a snapshot file
fn getSnapshotPath(
    allocator: std.mem.Allocator,
    snapshot_dir: []const u8,
    snapshot_name: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.snap", .{ snapshot_dir, snapshot_name });
}

/// Read a snapshot file
fn readSnapshot(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const content = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(content);

    const bytes_read = try file.readAll(content);
    if (bytes_read != stat.size) {
        return error.InvalidSnapshotFormat;
    }

    return content;
}

/// Write a snapshot file, creating the directory if needed
fn writeSnapshot(path: []const u8, snapshot_dir: []const u8, content: []const u8) !void {
    // Create the snapshots directory if it doesn't exist
    std.fs.cwd().makePath(snapshot_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.DirectoryCreationFailed,
    };

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    try file.writeAll(content);
}

// ============================================================================
// Diff Generation with Context
// ============================================================================

/// Generate a unified diff between expected and actual content
/// Shows context_lines around each difference (default: 3)
pub fn generateDiff(
    allocator: std.mem.Allocator,
    expected: []const u8,
    actual: []const u8,
    context_lines: usize,
) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    const w = result.writer();

    // Split into lines
    var expected_list = std.ArrayList([]const u8).init(allocator);
    defer expected_list.deinit();
    var actual_list = std.ArrayList([]const u8).init(allocator);
    defer actual_list.deinit();

    var exp_iter = std.mem.splitScalar(u8, expected, '\n');
    while (exp_iter.next()) |line| {
        try expected_list.append(line);
    }

    var act_iter = std.mem.splitScalar(u8, actual, '\n');
    while (act_iter.next()) |line| {
        try actual_list.append(line);
    }

    const exp_lines = expected_list.items;
    const act_lines = actual_list.items;

    try w.writeAll("--- Expected\n+++ Actual\n");

    // Find differences with context
    var i: usize = 0;
    var last_printed: usize = 0;
    var in_hunk = false;

    while (i < @max(exp_lines.len, act_lines.len)) {
        const exp_line = if (i < exp_lines.len) exp_lines[i] else null;
        const act_line = if (i < act_lines.len) act_lines[i] else null;

        const is_different = blk: {
            if (exp_line == null and act_line == null) break :blk false;
            if (exp_line == null or act_line == null) break :blk true;
            break :blk !std.mem.eql(u8, exp_line.?, act_line.?);
        };

        if (is_different) {
            // Print context lines before this difference
            const context_start = if (i > context_lines) i - context_lines else 0;
            if (context_start > last_printed) {
                if (in_hunk) {
                    try w.writeAll("...\n");
                }
                try w.print("@@ -{d},{d} +{d},{d} @@\n", .{
                    context_start + 1,
                    @min(exp_lines.len, i + context_lines + 1) - context_start,
                    context_start + 1,
                    @min(act_lines.len, i + context_lines + 1) - context_start,
                });
                in_hunk = true;

                // Print leading context
                var ctx = context_start;
                while (ctx < i and ctx < exp_lines.len) : (ctx += 1) {
                    if (ctx >= last_printed) {
                        try w.print(" {s}\n", .{exp_lines[ctx]});
                    }
                }
            }

            // Print the difference
            if (exp_line) |line| {
                try w.print("-{s}\n", .{line});
            }
            if (act_line) |line| {
                try w.print("+{s}\n", .{line});
            }

            last_printed = i + 1;

            // Look ahead to print trailing context
            const ctx_end = @min(i + context_lines + 1, @max(exp_lines.len, act_lines.len));
            var j = i + 1;
            while (j < ctx_end) : (j += 1) {
                const j_exp = if (j < exp_lines.len) exp_lines[j] else null;
                const j_act = if (j < act_lines.len) act_lines[j] else null;
                const j_diff = blk: {
                    if (j_exp == null and j_act == null) break :blk false;
                    if (j_exp == null or j_act == null) break :blk true;
                    break :blk !std.mem.eql(u8, j_exp.?, j_act.?);
                };
                if (j_diff) break; // Another diff coming, don't print context yet
                if (j_exp) |line| {
                    try w.print(" {s}\n", .{line});
                    last_printed = j + 1;
                }
            }
        }

        i += 1;
    }

    if (!in_hunk) {
        try w.writeAll("(no visible differences - check for trailing whitespace or encoding)\n");
    }

    return result.toOwnedSlice();
}

// ============================================================================
// Convenience Functions
// ============================================================================

/// Render a widget and return its string representation without comparison
pub fn capture(
    allocator: std.mem.Allocator,
    widget: Widget,
    options: Options,
) ![]const u8 {
    return renderWidget(allocator, widget, options);
}

/// Compare two rendered strings and return a detailed result
pub fn compare(
    allocator: std.mem.Allocator,
    expected: []const u8,
    actual: []const u8,
) !CompareResult {
    const matches = std.mem.eql(u8, expected, actual);
    const diff = if (!matches) try generateDiff(allocator, expected, actual, 3) else null;

    return .{
        .matches = matches,
        .expected = try allocator.dupe(u8, expected),
        .actual = try allocator.dupe(u8, actual),
        .diff = diff,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "renderWidget basic" {
    const allocator = std.testing.allocator;
    const Button = @import("Button.zig").Button;

    var button = Button.init("Test");
    const widget = Widget.init(Button, &button);

    const rendered = try renderWidget(allocator, widget, .{
        .width = 10,
        .height = 1,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.startsWith(u8, rendered, "Test"));
}

test "renderWidget focused button" {
    const allocator = std.testing.allocator;
    const Button = @import("Button.zig").Button;

    var button = Button.init("OK");
    button.widget_state = .{ .focused = true };
    const widget = Widget.init(Button, &button);

    const rendered = try renderWidget(allocator, widget, .{
        .width = 10,
        .height = 1,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.startsWith(u8, rendered, "[OK]"));
}

test "generateDiff shows differences with context" {
    const allocator = std.testing.allocator;

    const expected = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5";
    const actual = "Line 1\nLine 2\nChanged\nLine 4\nLine 5";

    const diff = try generateDiff(allocator, expected, actual, 1);
    defer allocator.free(diff);

    // Should contain diff markers
    try std.testing.expect(std.mem.indexOf(u8, diff, "---") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+++") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "-Line 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+Changed") != null);
}

test "generateDiff identical content" {
    const allocator = std.testing.allocator;

    const content = "Same\nContent";

    const diff = try generateDiff(allocator, content, content, 3);
    defer allocator.free(diff);

    try std.testing.expect(std.mem.indexOf(u8, diff, "no visible differences") != null);
}

test "planeToString trims whitespace" {
    const allocator = std.testing.allocator;

    const plane = try Plane.initRoot(allocator, .{ .width = 10, .height = 2 });
    defer plane.deinit();

    plane.setCell(0, 0, .{
        .char = 'H',
        .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    });
    plane.setCell(1, 0, .{
        .char = 'i',
        .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    });

    const result = try planeToString(allocator, plane, .{
        .width = 10,
        .height = 2,
        .trim_trailing_whitespace = true,
    });
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hi\n", result);
}

test "compare returns correct result" {
    const allocator = std.testing.allocator;

    // Matching case
    {
        var result = try compare(allocator, "test", "test");
        defer result.deinit(allocator);

        try std.testing.expect(result.matches);
        try std.testing.expect(result.diff == null);
    }

    // Non-matching case
    {
        var result = try compare(allocator, "expected", "actual");
        defer result.deinit(allocator);

        try std.testing.expect(!result.matches);
        try std.testing.expect(result.diff != null);
    }
}

test "isUpdateMode caches result" {
    // Reset cache for test isolation
    resetUpdateModeCache();

    // First call computes the value
    const first = isUpdateMode(std.testing.allocator);
    // Second call should return cached value
    const second = isUpdateMode(std.testing.allocator);

    try std.testing.expectEqual(first, second);

    // Reset for other tests
    resetUpdateModeCache();
}

test "bufferToString handles buffer correctly" {
    const allocator = std.testing.allocator;

    var buffer = try Buffer.init(allocator, .{ .width = 5, .height = 2 });
    defer buffer.deinit();

    // Set some cells
    buffer.cells[0] = .{
        .char = 'A',
        .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };
    buffer.cells[1] = .{
        .char = 'B',
        .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };

    const result = try bufferToString(allocator, &buffer, .{ .width = 5, .height = 2 }, .{
        .trim_trailing_whitespace = true,
    });
    defer allocator.free(result);

    try std.testing.expect(std.mem.startsWith(u8, result, "AB"));
}

test "getSnapshotPath builds correct path" {
    const allocator = std.testing.allocator;

    const path = try getSnapshotPath(allocator, "test/snapshots", "my_test");
    defer allocator.free(path);

    try std.testing.expectEqualStrings("test/snapshots/my_test.snap", path);
}

// ============================================================================
// File I/O Integration Tests
// ============================================================================

test "file I/O: write and read snapshot" {
    const allocator = std.testing.allocator;

    // Use a temp directory for test isolation
    const tmp_dir = "zig-cache/test_snapshots";
    const test_name = "io_test_write_read";

    // Clean up before test
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const content = "Test content\nLine 2";

    // Write snapshot
    const path = try getSnapshotPath(allocator, tmp_dir, test_name);
    defer allocator.free(path);

    try writeSnapshot(path, tmp_dir, content);

    // Read it back
    const read_content = try readSnapshot(allocator, path);
    defer allocator.free(read_content);

    try std.testing.expectEqualStrings(content, read_content);
}

test "file I/O: expectString creates snapshot in update mode" {
    const allocator = std.testing.allocator;

    // Use a temp directory for test isolation
    const tmp_dir = "zig-cache/test_snapshots_update";
    const test_name = "io_test_update";

    // Clean up before test
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    // Force update mode for this test
    update_mode_cached = true;
    defer resetUpdateModeCache();

    const content = "Snapshot content";

    // This should create the snapshot file
    try expectString(allocator, content, test_name, .{ .snapshot_path = tmp_dir });

    // Verify file was created
    const path = try getSnapshotPath(allocator, tmp_dir, test_name);
    defer allocator.free(path);

    const read_content = try readSnapshot(allocator, path);
    defer allocator.free(read_content);

    try std.testing.expectEqualStrings(content, read_content);
}

test "file I/O: expectString matches existing snapshot" {
    const allocator = std.testing.allocator;

    // Use a temp directory for test isolation
    const tmp_dir = "zig-cache/test_snapshots_match";
    const test_name = "io_test_match";

    // Clean up before test
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const content = "Matching content";

    // First, create the snapshot
    const path = try getSnapshotPath(allocator, tmp_dir, test_name);
    defer allocator.free(path);
    try writeSnapshot(path, tmp_dir, content);

    // Now verify it matches (not in update mode)
    resetUpdateModeCache();
    update_mode_cached = false;
    defer resetUpdateModeCache();

    // This should succeed because content matches
    try expectString(allocator, content, test_name, .{ .snapshot_path = tmp_dir });
}

test "file I/O: expectString fails on mismatch" {
    const allocator = std.testing.allocator;

    // Use a temp directory for test isolation
    const tmp_dir = "zig-cache/test_snapshots_mismatch";
    const test_name = "io_test_mismatch";

    // Clean up before test
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    // First, create the snapshot with one content
    const path = try getSnapshotPath(allocator, tmp_dir, test_name);
    defer allocator.free(path);
    try writeSnapshot(path, tmp_dir, "Original content");

    // Verify mode (not update)
    resetUpdateModeCache();
    update_mode_cached = false;
    defer resetUpdateModeCache();

    // This should fail because content doesn't match
    const result = expectString(allocator, "Different content", test_name, .{ .snapshot_path = tmp_dir });
    try std.testing.expectError(error.SnapshotMismatch, result);
}

test "file I/O: expectBackend with HeadlessBackend" {
    const allocator = std.testing.allocator;

    // Use a temp directory for test isolation
    const tmp_dir = "zig-cache/test_snapshots_backend";
    const test_name = "io_test_backend";

    // Clean up before test
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    // Create a HeadlessBackend and render something
    var backend = try HeadlessBackend.init(allocator, .{ .width = 10, .height = 2 });
    defer backend.deinit();

    // Set some cells
    backend.setCell(0, 0, .{
        .char = 'H',
        .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    });
    backend.setCell(1, 0, .{
        .char = 'i',
        .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    });

    // Force update mode to create snapshot
    update_mode_cached = true;
    defer resetUpdateModeCache();

    // This should create the snapshot
    try expectBackend(allocator, &backend, test_name, .{ .snapshot_path = tmp_dir });

    // Verify file was created with expected content
    const path = try getSnapshotPath(allocator, tmp_dir, test_name);
    defer allocator.free(path);

    const read_content = try readSnapshot(allocator, path);
    defer allocator.free(read_content);

    // Should start with "Hi" (the cells we set)
    try std.testing.expect(std.mem.startsWith(u8, read_content, "Hi"));
}
