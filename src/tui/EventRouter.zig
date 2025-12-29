//! EventRouter: Capture and bubble event routing
//!
//! Like DOM events, allows widgets to intercept events in two phases:
//! - Capture: walk from root toward target, each widget can intercept
//! - Bubble: walk from target back to root
//!
//! Use cases:
//! - Modal dialogs capture all clicks outside themselves
//! - Keyboard shortcuts at app level
//! - Scroll containers capturing scroll events

const std = @import("std");
const Event = @import("../Event.zig");
const Id = @import("Id.zig").Id;

/// Result of event handling
pub const EventResult = enum {
    /// Event not handled, continue propagation
    ignored,
    /// Event handled, stop propagation
    consumed,
};

/// Event handler callbacks for a widget
pub const EventHandler = struct {
    /// Widget identity
    id: Id,
    /// Called during capture phase (root to target)
    on_capture: ?*const fn (ctx: *anyopaque, event: Event.Event) EventResult = null,
    /// Called during bubble phase (target to root)
    on_bubble: ?*const fn (ctx: *anyopaque, event: Event.Event) EventResult = null,
    /// Context pointer passed to callbacks
    context: *anyopaque,
};

/// Routes events through a widget hierarchy
pub const EventRouter = struct {
    /// Handlers in tree order (root first)
    handlers: std.ArrayList(EventHandler),
    /// Allocator
    allocator: std.mem.Allocator,

    /// Create a new EventRouter
    pub fn init(allocator: std.mem.Allocator) EventRouter {
        return .{
            .handlers = std.ArrayList(EventHandler).init(allocator),
            .allocator = allocator,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *EventRouter) void {
        self.handlers.deinit();
    }

    /// Clear all handlers (call at start of each frame for immediate mode)
    pub fn beginFrame(self: *EventRouter) void {
        self.handlers.clearRetainingCapacity();
    }

    /// Register an event handler
    pub fn register(self: *EventRouter, handler: EventHandler) !void {
        try self.handlers.append(handler);
    }

    /// Route an event to a specific target widget
    /// Returns true if the event was consumed
    pub fn routeToTarget(self: *EventRouter, target_id: Id, event: Event.Event) bool {
        // Find target index
        var target_index: ?usize = null;
        for (self.handlers.items, 0..) |handler, i| {
            if (handler.id.eql(target_id)) {
                target_index = i;
                break;
            }
        }

        if (target_index == null) return false;

        // Capture phase: walk from root (0) to target
        for (self.handlers.items[0 .. target_index.? + 1]) |handler| {
            if (handler.on_capture) |capture_fn| {
                if (capture_fn(handler.context, event) == .consumed) {
                    return true;
                }
            }
        }

        // Bubble phase: walk from target back to root
        var i = target_index.? + 1;
        while (i > 0) {
            i -= 1;
            const handler = self.handlers.items[i];
            if (handler.on_bubble) |bubble_fn| {
                if (bubble_fn(handler.context, event) == .consumed) {
                    return true;
                }
            }
        }

        return false;
    }

    /// Route an event through all handlers (for global events like key shortcuts)
    /// Returns true if the event was consumed
    pub fn routeGlobal(self: *EventRouter, event: Event.Event) bool {
        // For global events, just do capture phase through all handlers
        for (self.handlers.items) |handler| {
            if (handler.on_capture) |capture_fn| {
                if (capture_fn(handler.context, event) == .consumed) {
                    return true;
                }
            }
        }
        return false;
    }

    /// Get the handler for a widget ID
    pub fn getHandler(self: *const EventRouter, id: Id) ?EventHandler {
        for (self.handlers.items) |handler| {
            if (handler.id.eql(id)) {
                return handler;
            }
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "EventRouter init and deinit" {
    var router = EventRouter.init(std.testing.allocator);
    defer router.deinit();

    try std.testing.expectEqual(@as(usize, 0), router.handlers.items.len);
}

test "EventRouter capture phase stops propagation" {
    var router = EventRouter.init(std.testing.allocator);
    defer router.deinit();

    // Track which handlers were called
    const Context = struct {
        capture_called: bool = false,
        bubble_called: bool = false,
    };

    var ctx1 = Context{};
    var ctx2 = Context{};

    // First handler consumes in capture
    try router.register(.{
        .id = Id.init("root"),
        .on_capture = struct {
            fn handler(ctx: *anyopaque, _: Event.Event) EventResult {
                const c: *Context = @ptrCast(@alignCast(ctx));
                c.capture_called = true;
                return .consumed;
            }
        }.handler,
        .context = @ptrCast(&ctx1),
    });

    // Second handler should not be called
    try router.register(.{
        .id = Id.init("child"),
        .on_capture = struct {
            fn handler(ctx: *anyopaque, _: Event.Event) EventResult {
                const c: *Context = @ptrCast(@alignCast(ctx));
                c.capture_called = true;
                return .ignored;
            }
        }.handler,
        .context = @ptrCast(&ctx2),
    });

    const consumed = router.routeToTarget(Id.init("child"), .{ .focus = true });

    try std.testing.expect(consumed);
    try std.testing.expect(ctx1.capture_called);
    try std.testing.expect(!ctx2.capture_called); // Stopped by first handler
}

test "EventRouter bubble phase" {
    var router = EventRouter.init(std.testing.allocator);
    defer router.deinit();

    var call_order = std.ArrayList([]const u8).init(std.testing.allocator);
    defer call_order.deinit();

    const Ctx = struct {
        name: []const u8,
        order: *std.ArrayList([]const u8),
    };

    var ctx_root = Ctx{ .name = "root", .order = &call_order };
    var ctx_child = Ctx{ .name = "child", .order = &call_order };

    try router.register(.{
        .id = Id.init("root"),
        .on_bubble = struct {
            fn handler(ctx: *anyopaque, _: Event.Event) EventResult {
                const c: *Ctx = @ptrCast(@alignCast(ctx));
                c.order.append(c.name) catch {};
                return .ignored;
            }
        }.handler,
        .context = @ptrCast(&ctx_root),
    });

    try router.register(.{
        .id = Id.init("child"),
        .on_bubble = struct {
            fn handler(ctx: *anyopaque, _: Event.Event) EventResult {
                const c: *Ctx = @ptrCast(@alignCast(ctx));
                c.order.append(c.name) catch {};
                return .ignored;
            }
        }.handler,
        .context = @ptrCast(&ctx_child),
    });

    _ = router.routeToTarget(Id.init("child"), .{ .focus = true });

    // Bubble should go child -> root
    try std.testing.expectEqual(@as(usize, 2), call_order.items.len);
    try std.testing.expectEqualStrings("child", call_order.items[0]);
    try std.testing.expectEqualStrings("root", call_order.items[1]);
}

test "EventRouter routeGlobal" {
    var router = EventRouter.init(std.testing.allocator);
    defer router.deinit();

    var called = false;

    try router.register(.{
        .id = Id.init("app"),
        .on_capture = struct {
            fn handler(ctx: *anyopaque, _: Event.Event) EventResult {
                const c: *bool = @ptrCast(@alignCast(ctx));
                c.* = true;
                return .consumed;
            }
        }.handler,
        .context = @ptrCast(&called),
    });

    const consumed = router.routeGlobal(.{ .focus = true });

    try std.testing.expect(consumed);
    try std.testing.expect(called);
}

test "EventRouter beginFrame clears handlers" {
    var router = EventRouter.init(std.testing.allocator);
    defer router.deinit();

    var dummy: u8 = 0;
    try router.register(.{
        .id = Id.init("widget"),
        .context = @ptrCast(&dummy),
    });

    try std.testing.expectEqual(@as(usize, 1), router.handlers.items.len);

    router.beginFrame();
    try std.testing.expectEqual(@as(usize, 0), router.handlers.items.len);
}
