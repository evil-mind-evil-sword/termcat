//! Standalone input reader for key/mouse/resize events.
//!
//! This module provides a lightweight input handler that can be used without
//! initializing the full Terminal with alternate screen buffer and cell-based
//! rendering. It's suitable for:
//! - Line-based REPLs with key shortcuts
//! - CLI tools with interactive key input
//! - Applications that manage their own output
//!
//! Example usage:
//! ```zig
//! var reader = try termcat.InputReader.init(allocator, .{});
//! defer reader.deinit();
//!
//! while (try reader.pollEvent(100)) |event| {
//!     switch (event) {
//!         .key => |k| {
//!             if (k.codepoint == 'q') break;
//!         },
//!         .resize => |sz| {
//!             // Handle terminal resize
//!         },
//!         else => {},
//!     }
//! }
//! ```

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const Event = @import("../Event.zig");
const Input = @import("Input.zig");
const signal = @import("../signal.zig");
const resize = @import("../resize.zig");

pub const InputReader = @This();

/// Configuration options for InputReader
pub const Options = struct {
    /// File descriptor to read from. If null, opens /dev/tty or falls back to stdin.
    fd: ?posix.fd_t = null,
    /// Leave ISIG enabled so Ctrl+C/Ctrl+Z are handled by the terminal driver.
    /// Default true for REPL-style applications where users expect Ctrl+C to work.
    enable_signals: bool = true,
    /// Install SIGWINCH handler for resize detection.
    install_sigwinch: bool = true,
    /// Use blocking reads instead of poll/select. Simpler and more compatible,
    /// but readEvent() will block until input is available.
    blocking: bool = false,
};

/// File descriptor for the terminal
tty_fd: posix.fd_t,
/// File descriptor for input (may differ from tty_fd)
input_fd: posix.fd_t,
/// Whether we own the fd (and should close it on deinit)
owns_fd: bool,
/// Original terminal attributes (for restoration)
orig_termios: posix.termios,
/// Whether terminal is currently in raw mode
in_raw_mode: bool,
/// Whether using blocking reads
blocking: bool,
/// Input handler for decoding terminal input
input_handler: Input,
/// Self-pipe for resize notifications (read end, write end)
resize_pipe: ?[2]posix.fd_t,
/// Slot index in the global resize registry
resize_slot: ?usize,
/// Allocator
allocator: std.mem.Allocator,
/// Current terminal size
size: Event.Size,

/// Initialize the input reader.
///
/// This sets up raw mode for input (disables echo and line buffering) but does
/// NOT enter alternate screen buffer or modify terminal output in any way.
pub fn init(allocator: std.mem.Allocator, options: Options) !InputReader {
    // Determine the fd to use
    const tty_fd, const owns_fd = if (options.fd) |fd|
        .{ fd, false }
    else blk: {
        // Try to open /dev/tty first for direct terminal access
        const fd = posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch |err| switch (err) {
            error.FileNotFound, error.NoDevice => {
                // Fall back to stdin if /dev/tty not available
                if (posix.isatty(posix.STDIN_FILENO)) {
                    break :blk .{ posix.STDIN_FILENO, false };
                }
                return error.NotATerminal;
            },
            else => return err,
        };
        break :blk .{ fd, true };
    };
    errdefer if (owns_fd) posix.close(tty_fd);

    // Get original terminal attributes
    const orig_termios = try posix.tcgetattr(tty_fd);

    // Get initial terminal size
    const size = getTerminalSize(tty_fd) catch Event.Size{ .width = 80, .height = 24 };

    // Create self-pipe for resize notifications if requested
    var resize_pipe: ?[2]posix.fd_t = null;
    var resize_slot: ?usize = null;
    if (options.install_sigwinch) {
        const pipe_fds = try posix.pipe();
        const O_NONBLOCK: usize = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));

        const read_flags = posix.fcntl(pipe_fds[0], posix.F.GETFL, 0) catch {
            posix.close(pipe_fds[0]);
            posix.close(pipe_fds[1]);
            return error.PipeSetupFailed;
        };
        _ = posix.fcntl(pipe_fds[0], posix.F.SETFL, read_flags | O_NONBLOCK) catch {
            posix.close(pipe_fds[0]);
            posix.close(pipe_fds[1]);
            return error.PipeSetupFailed;
        };
        _ = posix.fcntl(pipe_fds[0], posix.F.SETFD, @as(usize, posix.FD_CLOEXEC)) catch {
            posix.close(pipe_fds[0]);
            posix.close(pipe_fds[1]);
            return error.PipeSetupFailed;
        };

        const write_flags = posix.fcntl(pipe_fds[1], posix.F.GETFL, 0) catch {
            posix.close(pipe_fds[0]);
            posix.close(pipe_fds[1]);
            return error.PipeSetupFailed;
        };
        _ = posix.fcntl(pipe_fds[1], posix.F.SETFL, write_flags | O_NONBLOCK) catch {
            posix.close(pipe_fds[0]);
            posix.close(pipe_fds[1]);
            return error.PipeSetupFailed;
        };
        _ = posix.fcntl(pipe_fds[1], posix.F.SETFD, @as(usize, posix.FD_CLOEXEC)) catch {
            posix.close(pipe_fds[0]);
            posix.close(pipe_fds[1]);
            return error.PipeSetupFailed;
        };

        resize_slot = resize.registry.register(pipe_fds[1]);
        if (resize_slot == null) {
            posix.close(pipe_fds[0]);
            posix.close(pipe_fds[1]);
            return error.TooManyInputReaders;
        }
        resize_pipe = pipe_fds;
    }
    errdefer if (resize_pipe) |p| {
        if (resize_slot) |slot| resize.registry.unregister(slot);
        posix.close(p[0]);
        posix.close(p[1]);
    };

    // Use stdin for input when it's a TTY (avoids poll() quirks on /dev/tty on macOS)
    const input_fd: posix.fd_t = if (posix.isatty(posix.STDIN_FILENO)) posix.STDIN_FILENO else tty_fd;

    var self = InputReader{
        .tty_fd = tty_fd,
        .input_fd = input_fd,
        .owns_fd = owns_fd,
        .orig_termios = orig_termios,
        .in_raw_mode = false,
        .blocking = options.blocking,
        .input_handler = Input.init(allocator, input_fd),
        .resize_pipe = resize_pipe,
        .resize_slot = resize_slot,
        .allocator = allocator,
        .size = size,
    };
    errdefer self.input_handler.deinit();

    // Enter raw mode
    try self.enterRawMode(options.enable_signals);
    errdefer self.exitRawMode() catch {};

    // Install crash-safe signal handler for terminal restore
    // InputReader doesn't use alternate screen, so pass false
    signal.installWithOptions(tty_fd, orig_termios, false);
    errdefer signal.uninstall();

    // Install SIGWINCH handler if requested
    if (options.install_sigwinch) {
        resize.installHandler();
    }

    return self;
}

/// Clean up and restore terminal state.
pub fn deinit(self: *InputReader) void {
    // Uninstall crash-safe signal handler
    signal.uninstall();

    // Restore SIGWINCH handler if we installed one
    if (self.resize_pipe != null) {
        resize.uninstallHandler();
    }

    // Unregister and close resize pipe (unregister atomically before close to prevent fd-reuse race)
    if (self.resize_slot) |slot| {
        resize.registry.unregister(slot);
    }
    if (self.resize_pipe) |p| {
        posix.close(p[0]);
        posix.close(p[1]);
    }

    // Exit raw mode
    self.exitRawMode() catch {};

    // Free input handler
    self.input_handler.deinit();

    // Close fd if we own it
    if (self.owns_fd) {
        posix.close(self.tty_fd);
    }

    self.* = undefined;
}

/// Enter raw mode for input.
///
/// This disables echo and canonical mode but does NOT:
/// - Enter alternate screen buffer
/// - Enable mouse tracking
/// - Enable bracketed paste
/// - Hide the cursor
fn enterRawMode(self: *InputReader, enable_signals: bool) !void {
    if (self.in_raw_mode) return;

    var raw = self.orig_termios;

    // Input flags: disable CR-to-NL, flow control
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;

    // Local flags: disable echo, canonical mode, extended input
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = enable_signals;

    if (self.blocking) {
        // Blocking mode: VMIN=1 makes read() block until at least 1 byte available
        // VTIME=0 returns immediately when VMIN is satisfied (no inter-byte delay)
        // Escape sequence disambiguation is handled by the decoder's timeout logic
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0; // No timeout - return immediately on input
    } else {
        // Non-blocking mode: use poll/select to wait for data
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    }

    try posix.tcsetattr(self.tty_fd, .FLUSH, raw);
    self.in_raw_mode = true;
}

/// Exit raw mode and restore terminal.
fn exitRawMode(self: *InputReader) !void {
    if (!self.in_raw_mode) return;

    try posix.tcsetattr(self.tty_fd, .FLUSH, self.orig_termios);
    self.in_raw_mode = false;
}

/// Poll for an event with optional timeout (in milliseconds).
/// Returns null on timeout.
pub fn pollEvent(self: *InputReader, timeout_ms: ?u32) !?Event.Event {
    // Check for pending resize first
    if (self.checkResizePending()) {
        self.size = getTerminalSize(self.tty_fd) catch self.size;
        return .{ .resize = self.size };
    }

    if (self.resize_pipe) |pipe| {
        const result = try self.input_handler.pollEventWithExtraFd(timeout_ms, pipe[0]);
        if (result) |outcome| {
            switch (outcome) {
                .event => |event| return event,
                .extra_ready => {
                    if (self.checkResizePending()) {
                        self.size = getTerminalSize(self.tty_fd) catch self.size;
                        return .{ .resize = self.size };
                    }
                    return null;
                },
            }
        }
        return null;
    }

    return self.input_handler.pollEvent(timeout_ms);
}

/// Poll for an event, but also return if an extra fd becomes readable.
/// Returns .extra_ready when the extra fd is readable.
/// This enables efficient wakeup from background threads.
pub fn pollEventWithExtraFd(self: *InputReader, timeout_ms: ?u32, extra_fd: posix.fd_t) !?Input.PollResult {
    // Check for pending resize first
    if (self.checkResizePending()) {
        self.size = getTerminalSize(self.tty_fd) catch self.size;
        return .{ .event = .{ .resize = self.size } };
    }

    return self.input_handler.pollEventWithExtraFd(timeout_ms, extra_fd);
}

/// Non-blocking event check (equivalent to pollEvent(0)).
pub fn peekEvent(self: *InputReader) !?Event.Event {
    return self.pollEvent(0);
}

/// Blocking read for an event. Blocks until input is available.
/// Requires InputReader to be initialized with blocking=true.
/// This is simpler and more compatible than poll-based input.
/// Check for resize events after each call by comparing getSize().
pub fn readEvent(self: *InputReader) !?Event.Event {
    // Check for pending resize first
    if (self.checkResizePending()) {
        self.size = getTerminalSize(self.tty_fd) catch self.size;
        return .{ .resize = self.size };
    }

    // Use blocking read - bypasses poll/select entirely
    // With VMIN=1, VTIME=1 in termios, read() blocks until data or 100ms timeout
    return self.input_handler.blockingRead();
}

/// Get the current terminal size.
pub fn getSize(self: *const InputReader) Event.Size {
    return self.size;
}

/// Set the escape sequence timeout in milliseconds.
pub fn setEscapeTimeout(self: *InputReader, timeout_ms: u32) void {
    self.input_handler.setEscapeTimeout(timeout_ms);
}

/// Reset the input handler state.
pub fn reset(self: *InputReader) void {
    self.input_handler.reset();
}

fn checkResizePending(self: *InputReader) bool {
    const pipe = self.resize_pipe orelse return false;
    var buf: [64]u8 = undefined;
    var had_data = false;
    while (true) {
        const n = posix.read(pipe[0], &buf) catch break;
        if (n == 0) break;
        had_data = true;
    }
    return had_data;
}

fn getTerminalSize(fd: posix.fd_t) !Event.Size {
    var ws: posix.winsize = undefined;
    if (posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws)) != 0) {
        return error.IoctlFailed;
    }
    if (ws.col == 0 or ws.row == 0) {
        return Event.Size{ .width = 80, .height = 24 };
    }
    return Event.Size{ .width = ws.col, .height = ws.row };
}

// ============================================================================
// Tests
// ============================================================================

test "InputReader struct size" {
    try std.testing.expect(@sizeOf(InputReader) > 0);
}

test "InputReader init with explicit fd" {
    // Create a pipe to use as a fake tty
    const pipe_fds = try posix.pipe();
    defer {
        posix.close(pipe_fds[0]);
        posix.close(pipe_fds[1]);
    }

    // This will fail because pipe is not a tty, but we can at least verify
    // the code path that handles explicit fd
    const result = InputReader.init(std.testing.allocator, .{
        .fd = pipe_fds[0],
        .install_sigwinch = false,
    });

    // Expected to fail with ENOTTY since pipe isn't a terminal
    try std.testing.expectError(error.NotATerminal, result);
}
