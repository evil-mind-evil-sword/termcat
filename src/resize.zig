//! Unified SIGWINCH handling for terminal resize detection.
//!
//! This module provides a shared resize notification system used by both
//! Terminal (PosixBackend) and InputReader. It ensures that only one SIGWINCH
//! handler is installed regardless of how many components need resize events.
//!
//! The design uses a pipe-based notification pattern that is async-signal-safe:
//! 1. Components register a pipe write fd
//! 2. SIGWINCH handler writes a byte to all registered pipes
//! 3. Components poll their pipe read fd to detect resize

const std = @import("std");
const posix = std.posix;

/// Maximum number of concurrent components that can receive resize notifications.
/// This is a compile-time constant to avoid dynamic allocation in signal handlers.
const max_resize_pipes = 16;

/// Global registry of resize notification pipes.
/// The signal handler writes to all registered pipes to notify each component.
/// This must be lock-free and async-signal-safe.
pub const ResizePipeRegistry = struct {
    /// Write ends of pipes for each registered component.
    /// -1 indicates an unused slot.
    pipes: [max_resize_pipes]std.atomic.Value(posix.fd_t),

    pub fn init() ResizePipeRegistry {
        var self: ResizePipeRegistry = undefined;
        for (&self.pipes) |*p| {
            p.* = std.atomic.Value(posix.fd_t).init(-1);
        }
        return self;
    }

    /// Register a pipe write fd. Returns the slot index, or null if full.
    pub fn register(self: *ResizePipeRegistry, write_fd: posix.fd_t) ?usize {
        for (&self.pipes, 0..) |*slot, i| {
            // Try to claim an empty slot (-1 -> write_fd)
            if (slot.cmpxchgStrong(-1, write_fd, .acq_rel, .acquire)) |_| {
                // Slot was not -1, try next
                continue;
            } else {
                // Successfully claimed slot
                return i;
            }
        }
        return null; // Registry full
    }

    /// Unregister a pipe by slot index.
    /// Uses atomic swap to avoid fd-reuse race: the fd is atomically invalidated
    /// before the caller closes it, preventing notifyAll from writing to a
    /// potentially reused fd number.
    pub fn unregister(self: *ResizePipeRegistry, slot: usize) void {
        if (slot < max_resize_pipes) {
            // Atomically swap to -1, ensuring no writes occur after this point
            _ = self.pipes[slot].swap(-1, .acq_rel);
        }
    }

    /// Signal handler: write a byte to all registered pipes.
    /// This is async-signal-safe (only uses write()).
    pub fn notifyAll(self: *ResizePipeRegistry) void {
        const byte = [_]u8{1};
        for (&self.pipes) |*slot| {
            const fd = slot.load(.acquire);
            if (fd >= 0) {
                // write() is async-signal-safe. Ignore errors (pipe full, closed, etc.)
                _ = posix.write(fd, &byte) catch {};
            }
        }
    }
};

/// Global resize pipe registry (initialized at comptime).
pub var registry: ResizePipeRegistry = ResizePipeRegistry.init();

/// Reference count for SIGWINCH handler installation.
/// The handler is installed when count goes 0->1 and restored when count goes 1->0.
var sigwinch_refcount: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

/// Stored original SIGWINCH handler (saved when first component installs handler).
var original_sigaction: posix.Sigaction = undefined;
var original_sigaction_valid: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Install SIGWINCH handler with reference counting.
/// Only installs the handler when refcount goes from 0 to 1.
/// Thread-safe: multiple components can call this concurrently.
pub fn installHandler() void {
    const prev_count = sigwinch_refcount.fetchAdd(1, .acq_rel);

    if (prev_count == 0) {
        // First component: install the signal handler and save original
        var sa: posix.Sigaction = .{
            .handler = .{ .handler = sigwinchHandler },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESTART,
        };

        var old_sa: posix.Sigaction = .{
            .handler = .{ .handler = null },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };

        posix.sigaction(posix.SIG.WINCH, &sa, &old_sa);
        original_sigaction = old_sa;
        original_sigaction_valid.store(true, .release);
    }
}

/// Restore previous SIGWINCH handler with reference counting.
/// Only restores when refcount goes from 1 to 0.
/// Thread-safe: multiple components can call this concurrently.
pub fn uninstallHandler() void {
    const prev_count = sigwinch_refcount.fetchSub(1, .acq_rel);

    if (prev_count == 1 and original_sigaction_valid.load(.acquire)) {
        // Last component: restore the original signal handler
        var sa = original_sigaction;
        posix.sigaction(posix.SIG.WINCH, &sa, null);
        original_sigaction_valid.store(false, .release);
    }
}

/// SIGWINCH signal handler - writes to all registered pipes
fn sigwinchHandler(_: c_int) callconv(.c) void {
    registry.notifyAll();
}

// ============================================================================
// Tests
// ============================================================================

test "ResizePipeRegistry basic operations" {
    var test_registry = ResizePipeRegistry.init();

    const pipe1 = try posix.pipe();
    defer posix.close(pipe1[0]);
    defer posix.close(pipe1[1]);

    const slot = test_registry.register(pipe1[1]);
    try std.testing.expect(slot != null);

    test_registry.notifyAll();

    var buf: [16]u8 = undefined;
    const n = try posix.read(pipe1[0], &buf);
    try std.testing.expect(n > 0);

    test_registry.unregister(slot.?);
}

test "ResizePipeRegistry multiple pipes" {
    var test_registry = ResizePipeRegistry.init();

    const pipe1 = try posix.pipe();
    defer posix.close(pipe1[0]);
    defer posix.close(pipe1[1]);

    const pipe2 = try posix.pipe();
    defer posix.close(pipe2[0]);
    defer posix.close(pipe2[1]);

    const slot1 = test_registry.register(pipe1[1]);
    try std.testing.expect(slot1 != null);

    const slot2 = test_registry.register(pipe2[1]);
    try std.testing.expect(slot2 != null);

    test_registry.notifyAll();

    var buf: [16]u8 = undefined;
    const n1 = try posix.read(pipe1[0], &buf);
    try std.testing.expect(n1 > 0);

    const n2 = try posix.read(pipe2[0], &buf);
    try std.testing.expect(n2 > 0);

    // Unregister pipe1, notify again
    test_registry.unregister(slot1.?);
    test_registry.notifyAll();

    // Only pipe2 should receive
    const n3 = try posix.read(pipe2[0], &buf);
    try std.testing.expect(n3 > 0);

    test_registry.unregister(slot2.?);
}

test "handler refcount" {
    // Just verify the functions are callable
    installHandler();
    installHandler(); // Second install should be no-op for handler
    uninstallHandler();
    uninstallHandler(); // Should restore original
}
