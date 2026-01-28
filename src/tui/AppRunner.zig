//! AppRunner: Event loop for MVU applications
//!
//! Provides the infrastructure to run an App with the standard MVU event loop:
//! 1. Initialize model and execute initial commands
//! 2. Render view
//! 3. Poll for events
//! 4. Dispatch messages through update
//! 5. Execute resulting commands
//! 6. Repeat until quit
//!
//! Features:
//! - Frame rate limiting
//! - Graceful shutdown
//! - Command execution

const std = @import("std");
const app_mod = @import("App.zig");
const Cmd = app_mod.Cmd;
const Sub = app_mod.Sub;
const ConsoleOverlay = @import("ConsoleOverlay.zig");

/// Runner configuration options
pub const Options = struct {
    /// Target frames per second (0 = unlimited)
    target_fps: u8 = 60,
    /// Optional console overlay configuration (null = disabled)
    console_overlay: ?ConsoleOverlay.Options = null,
};

/// Calculate frame time in milliseconds from target FPS
pub fn frameTimeMs(target_fps: u8) u32 {
    return if (target_fps > 0) 1000 / @as(u32, target_fps) else 0;
}

/// Execute a command and return whether to quit
pub fn executeCmd(comptime Msg: type, cmd: Cmd(Msg)) struct { should_quit: bool, msg: ?Msg } {
    switch (cmd) {
        .cmd_none => return .{ .should_quit = false, .msg = null },
        .cmd_quit => return .{ .should_quit = true, .msg = null },
        .cmd_perform => |f| return .{ .should_quit = false, .msg = f() },
        .cmd_batch => |cmds| {
            for (cmds) |c| {
                const result = executeCmd(Msg, c);
                if (result.should_quit) return result;
                // Note: batch messages are lost in this simple impl
            }
            return .{ .should_quit = false, .msg = null };
        },
    }
}

/// Check if a subscription has a timer that should fire
pub fn checkTimer(comptime Msg: type, sub: Sub(Msg), elapsed_ms: u32) ?Msg {
    switch (sub) {
        .sub_none => return null,
        .sub_every => |timer| {
            if (elapsed_ms >= timer.interval_ms) {
                return timer.toMsg();
            }
            return null;
        },
        .sub_batch => |subs| {
            for (subs) |s| {
                if (checkTimer(Msg, s, elapsed_ms)) |msg| {
                    return msg;
                }
            }
            return null;
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "frameTimeMs" {
    try std.testing.expectEqual(@as(u32, 16), frameTimeMs(60)); // ~60 FPS
    try std.testing.expectEqual(@as(u32, 33), frameTimeMs(30)); // ~30 FPS
    try std.testing.expectEqual(@as(u32, 0), frameTimeMs(0)); // unlimited
}

test "executeCmd none" {
    const Msg = enum { tick };
    const result = executeCmd(Msg, Cmd(Msg).none());
    try std.testing.expect(!result.should_quit);
    try std.testing.expect(result.msg == null);
}

test "executeCmd quit" {
    const Msg = enum { tick };
    const result = executeCmd(Msg, Cmd(Msg).quit());
    try std.testing.expect(result.should_quit);
}

test "executeCmd perform" {
    const Msg = enum { tick, tock };
    const cmd = Cmd(Msg).perform(struct {
        fn f() Msg {
            return .tock;
        }
    }.f);
    const result = executeCmd(Msg, cmd);
    try std.testing.expect(!result.should_quit);
    try std.testing.expect(result.msg != null);
    try std.testing.expectEqual(Msg.tock, result.msg.?);
}

test "checkTimer fires" {
    const Msg = enum { tick };
    const sub = Sub(Msg).every(100, struct {
        fn f() Msg {
            return .tick;
        }
    }.f);

    // Not enough time
    try std.testing.expect(checkTimer(Msg, sub, 50) == null);

    // Enough time
    const msg = checkTimer(Msg, sub, 100);
    try std.testing.expect(msg != null);
    try std.testing.expectEqual(Msg.tick, msg.?);
}
