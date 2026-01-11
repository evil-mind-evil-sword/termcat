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

/// Original termios saved for restoration (restored even in signal handler)
var global_orig_termios: posix.termios = undefined;
var global_termios_valid: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Reference count for signal handler installation
var signal_handler_refcount: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

/// Whether alternate screen is in use (affects cleanup sequence)
var global_uses_alt_screen: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

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

/// Call this during terminal init to enable crash-safe restore.
/// Set uses_alt_screen to true if the terminal enters alternate screen buffer.
pub fn install(tty_fd: posix.fd_t, orig_termios: posix.termios) void {
    installWithOptions(tty_fd, orig_termios, true);
}

/// Install with explicit alternate screen option.
/// InputReader should call this with uses_alt_screen=false.
pub fn installWithOptions(tty_fd: posix.fd_t, orig_termios: posix.termios, uses_alt_screen: bool) void {
    // Atomically increment refcount
    const prev_count = signal_handler_refcount.fetchAdd(1, .acq_rel);

    if (prev_count == 0) {
        // First install: save fd, termios, and set up all signal handlers
        global_tty_fd.store(tty_fd, .release);
        global_orig_termios = orig_termios;
        global_termios_valid.store(true, .release);
        global_uses_alt_screen.store(uses_alt_screen, .release);
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
    const fd = global_tty_fd.load(.acquire);
    if (fd >= 0) {
        // Write cleanup sequence appropriate for the mode:
        // - Disable synchronized output, focus events, bracketed paste
        // - Disable mouse tracking (any-event mode + SGR mode)
        // - Show cursor, reset attributes
        // - Exit alternate screen (only if we entered it)
        const uses_alt = global_uses_alt_screen.load(.acquire);
        if (uses_alt) {
            // Full cleanup including alternate screen exit
            const cleanup_seq = "\x1b[?2026l\x1b[?1004l\x1b[?2004l\x1b[?1003l\x1b[?1006l\x1b[?25h\x1b[0m\x1b[?1049l";
            _ = posix.write(fd, cleanup_seq) catch {};
        } else {
            // Minimal cleanup for InputReader (no alternate screen)
            const cleanup_seq = "\x1b[?25h\x1b[0m";
            _ = posix.write(fd, cleanup_seq) catch {};
        }

        // Attempt to restore termios (raw mode -> cooked mode)
        // Note: tcsetattr is not strictly async-signal-safe per POSIX,
        // but leaving terminal in raw mode is worse than the small
        // deadlock risk. Most implementations handle this fine.
        if (global_termios_valid.load(.acquire)) {
            posix.tcsetattr(fd, .FLUSH, global_orig_termios) catch {};
        }
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
        global_termios_valid.store(false, .release);
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
