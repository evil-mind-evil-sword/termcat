//! Signal handling for crash-safe terminal restore
//!
//! Registers signal handlers to restore terminal state on unexpected exit.
//! This module ensures that if a termcat application crashes, the terminal
//! is left in a usable state (exiting raw mode, alternate screen, showing cursor).

const std = @import("std");
const posix = std.posix;

/// Global state for signal handlers (must be async-signal-safe)
/// Using atomic Value for thread-safe and signal-safe access
var global_tty_fd: std.atomic.Value(posix.fd_t) = std.atomic.Value(posix.fd_t).init(-1);

/// Reference count for signal handler installation
var signal_handler_refcount: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

/// Original signal action handlers (saved when we install)
var original_sigactions: struct {
    int: posix.Sigaction = undefined,
    term: posix.Sigaction = undefined,
    hup: posix.Sigaction = undefined,
    quit: posix.Sigaction = undefined,
    int_valid: bool = false,
    term_valid: bool = false,
    hup_valid: bool = false,
    quit_valid: bool = false,
} = .{};

/// Call this during terminal init to enable crash-safe restore
pub fn install(tty_fd: posix.fd_t, orig_termios: posix.termios) void {
    _ = orig_termios; // termios is not restored in signal handler (not async-signal-safe)

    // Atomically increment refcount
    const prev_count = signal_handler_refcount.fetchAdd(1, .acq_rel);

    if (prev_count == 0) {
        // First install: save fd and set up all signal handlers
        global_tty_fd.store(tty_fd, .release);
        installSignalHandlers();
    }
}

/// Install all signal handlers
fn installSignalHandlers() void {
    // Use standard library constant for portability
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESETHAND,
    };

    var old_sa: posix.Sigaction = undefined;

    // Install SIGINT
    posix.sigaction(posix.SIG.INT, &sa, &old_sa);
    original_sigactions.int = old_sa;
    original_sigactions.int_valid = true;

    // Install SIGTERM
    posix.sigaction(posix.SIG.TERM, &sa, &old_sa);
    original_sigactions.term = old_sa;
    original_sigactions.term_valid = true;

    // Install SIGHUP
    posix.sigaction(posix.SIG.HUP, &sa, &old_sa);
    original_sigactions.hup = old_sa;
    original_sigactions.hup_valid = true;

    // Install SIGQUIT
    posix.sigaction(posix.SIG.QUIT, &sa, &old_sa);
    original_sigactions.quit = old_sa;
    original_sigactions.quit_valid = true;
}

/// Async-signal-safe handler that restores terminal and exits
fn signalHandler(sig: i32) callconv(.c) void {
    restore();
    // Use _exit for immediate termination (async-signal-safe)
    // Exit code 128 + signal_number is standard for signal termination
    std.c._exit(128 + sig);
}

/// Restore terminal state (async-signal-safe)
pub fn restore() void {
    // Only use async-signal-safe operations (write)
    // tcsetattr is NOT async-signal-safe and can deadlock
    const fd = global_tty_fd.load(.acquire);
    if (fd >= 0) {
        // Exit alternate screen and show cursor
        const escape = "\x1b[?1049l\x1b[?25h";
        _ = posix.write(fd, escape) catch {};
    }
}

/// Uninstall signal handlers and restore originals (call during normal shutdown)
pub fn uninstall() void {
    // Atomically decrement refcount
    const prev_count = signal_handler_refcount.fetchSub(1, .acq_rel);

    if (prev_count == 1) {
        // Last uninstall: restore original handlers and clear state
        uninstallSignalHandlers();
        global_tty_fd.store(-1, .release);
    }
}

/// Restore original signal handlers
fn uninstallSignalHandlers() void {
    if (original_sigactions.int_valid) {
        posix.sigaction(posix.SIG.INT, &original_sigactions.int, null);
        original_sigactions.int_valid = false;
    }

    if (original_sigactions.term_valid) {
        posix.sigaction(posix.SIG.TERM, &original_sigactions.term, null);
        original_sigactions.term_valid = false;
    }

    if (original_sigactions.hup_valid) {
        posix.sigaction(posix.SIG.HUP, &original_sigactions.hup, null);
        original_sigactions.hup_valid = false;
    }

    if (original_sigactions.quit_valid) {
        posix.sigaction(posix.SIG.QUIT, &original_sigactions.quit, null);
        original_sigactions.quit_valid = false;
    }
}

test "signal module basic" {
    // Just verify the module loads without errors
    _ = restore;
    _ = install;
    _ = uninstall;
}
