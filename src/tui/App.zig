//! App: MVU (Model-View-Update) application interface
//!
//! The App interface provides a structured pattern for building TUI applications:
//! - init: Initialize the application state
//! - update: Handle messages and update state
//! - view: Render the current state to widgets
//!
//! This pattern ensures:
//! - Pure update logic (no side effects)
//! - Deterministic rendering
//! - Testable business logic
//! - Clear unidirectional data flow

const std = @import("std");
const Widget = @import("Widget.zig").Widget;

/// Command type - effects that produce messages
pub fn Cmd(comptime Msg: type) type {
    return union(enum) {
        /// No command
        cmd_none: void,
        /// Batch of commands to execute
        cmd_batch: []const Cmd(Msg),
        /// Synchronous task that produces a message
        cmd_perform: *const fn () Msg,
        /// Quit the application
        cmd_quit: void,

        const Self = @This();

        /// Create a "do nothing" command
        pub fn none() Self {
            return .{ .cmd_none = {} };
        }

        /// Batch multiple commands together
        pub fn batch(cmds: []const Cmd(Msg)) Self {
            return .{ .cmd_batch = cmds };
        }

        /// Create a command that performs a function and returns a message
        pub fn perform(f: *const fn () Msg) Self {
            return .{ .cmd_perform = f };
        }

        /// Create a quit command
        pub fn quit() Self {
            return .{ .cmd_quit = {} };
        }
    };
}

/// Timer subscription data
pub const Timer = struct {
    interval_ms: u32,
    toMsg: *const fn () anyopaque,
};

/// Subscription type - external event sources
pub fn Sub(comptime Msg: type) type {
    return union(enum) {
        /// No subscription
        sub_none: void,
        /// Batch of subscriptions
        sub_batch: []const Sub(Msg),
        /// Timer subscription (fires every N milliseconds)
        sub_every: struct {
            interval_ms: u32,
            toMsg: *const fn () Msg,
        },

        const Self = @This();

        pub fn none() Self {
            return .{ .sub_none = {} };
        }

        pub fn batch(subs: []const Sub(Msg)) Self {
            return .{ .sub_batch = subs };
        }

        pub fn every(interval_ms: u32, toMsg: *const fn () Msg) Self {
            return .{ .sub_every = .{ .interval_ms = interval_ms, .toMsg = toMsg } };
        }
    };
}

/// Result of init function
pub fn InitResult(comptime Model: type, comptime Msg: type) type {
    return struct {
        model: Model,
        cmd: Cmd(Msg),
    };
}

/// Result of update function
pub fn UpdateResult(comptime Msg: type) type {
    return struct {
        cmd: Cmd(Msg),
    };
}

/// App interface for MVU pattern
/// Model: The application state type
/// Msg: The message type for updates
pub fn App(comptime Model: type, comptime Msg: type) type {
    return struct {
        /// Initialize the application state and return initial command
        initFn: *const fn (allocator: std.mem.Allocator) InitResult(Model, Msg),

        /// Update state in response to a message (mutates model in place)
        updateFn: *const fn (model: *Model, msg: Msg) UpdateResult(Msg),

        /// Render the current state to a widget tree (pure, no side effects)
        viewFn: *const fn (model: *const Model) Widget,

        /// Optional: subscriptions to external events (timers, etc.)
        subscriptionsFn: ?*const fn (model: *const Model) Sub(Msg) = null,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Cmd.none" {
    const TestMsg = enum { tick, tock };
    const cmd = Cmd(TestMsg).none();
    try std.testing.expect(cmd == .cmd_none);
}

test "Cmd.quit" {
    const TestMsg = enum { tick, tock };
    const cmd = Cmd(TestMsg).quit();
    try std.testing.expect(cmd == .cmd_quit);
}

test "Cmd.perform" {
    const TestMsg = enum { tick, tock };

    const cmd = Cmd(TestMsg).perform(struct {
        fn f() TestMsg {
            return .tick;
        }
    }.f);

    try std.testing.expect(cmd == .cmd_perform);
    try std.testing.expectEqual(TestMsg.tick, cmd.cmd_perform());
}

test "Sub.none" {
    const TestMsg = enum { tick };
    const sub = Sub(TestMsg).none();
    try std.testing.expect(sub == .sub_none);
}

test "Sub.every" {
    const TestMsg = enum { tick };

    const sub = Sub(TestMsg).every(1000, struct {
        fn f() TestMsg {
            return .tick;
        }
    }.f);

    try std.testing.expect(sub == .sub_every);
    try std.testing.expectEqual(@as(u32, 1000), sub.sub_every.interval_ms);
}

test "App interface types" {
    const Model = struct {
        count: i32,
    };

    const Msg = enum {
        increment,
        decrement,
    };

    // Verify types compile
    const AppType = App(Model, Msg);
    const InitResultType = InitResult(Model, Msg);
    const UpdateResultType = UpdateResult(Msg);
    const CmdType = Cmd(Msg);
    const SubType = Sub(Msg);

    // Use types to avoid unused warnings
    _ = AppType;
    _ = InitResultType;
    _ = UpdateResultType;
    _ = CmdType;
    _ = SubType;
}
