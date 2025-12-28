//! FocusManager: Tab navigation and event routing
//!
//! Manages an ordered chain of focusable widgets:
//! - Tab cycles focus forward, Shift+Tab cycles backward
//! - Dispatches keyboard events to the focused widget
//! - Supports dynamic registration/unregistration of widgets
//! - Maintains exactly one focused widget at a time

const std = @import("std");
const Widget = @import("Widget.zig").Widget;
const Event = @import("../Event.zig");
const EventResult = @import("Widget.zig").EventResult;

/// Focus manager for widget navigation
pub const FocusManager = struct {
    /// Ordered list of focusable widgets
    focus_chain: std.ArrayList(Widget),
    /// Index of currently focused widget (null if none)
    focused_index: ?usize = null,
    /// Memory allocator
    allocator: std.mem.Allocator,

    /// Create a new FocusManager
    pub fn init(allocator: std.mem.Allocator) FocusManager {
        return .{
            .focus_chain = std.ArrayList(Widget).init(allocator),
            .focused_index = null,
            .allocator = allocator,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *FocusManager) void {
        self.focus_chain.deinit();
    }

    /// Register a widget to the end of the focus chain
    pub fn register(self: *FocusManager, widget: Widget) !void {
        try self.focus_chain.append(widget);
        // If this is the first widget, focus it
        if (self.focused_index == null and self.focus_chain.items.len > 0) {
            self.focused_index = 0;
        }
    }

    /// Unregister a widget from the focus chain (by pointer comparison)
    pub fn unregister(self: *FocusManager, widget: Widget) void {
        var i: usize = 0;
        while (i < self.focus_chain.items.len) {
            if (self.focus_chain.items[i].ptr == widget.ptr) {
                _ = self.focus_chain.orderedRemove(i);
                // Adjust focused_index if necessary
                if (self.focused_index) |idx| {
                    if (idx == i) {
                        // Removed widget was focused
                        if (self.focus_chain.items.len > 0) {
                            // Focus next widget (or wrap to 0)
                            self.focused_index = if (i < self.focus_chain.items.len) i else 0;
                        } else {
                            // No more widgets
                            self.focused_index = null;
                        }
                    } else if (idx > i) {
                        // Adjust index after removal
                        self.focused_index = idx - 1;
                    }
                }
                return;
            }
            i += 1;
        }
    }

    /// Move focus to the next widget (wraps around)
    pub fn focusNext(self: *FocusManager) void {
        if (self.focus_chain.items.len == 0) {
            self.focused_index = null;
            return;
        }

        if (self.focused_index) |idx| {
            self.focused_index = (idx + 1) % self.focus_chain.items.len;
        } else {
            self.focused_index = 0;
        }
    }

    /// Move focus to the previous widget (wraps around)
    pub fn focusPrev(self: *FocusManager) void {
        if (self.focus_chain.items.len == 0) {
            self.focused_index = null;
            return;
        }

        if (self.focused_index) |idx| {
            self.focused_index = if (idx > 0) idx - 1 else self.focus_chain.items.len - 1;
        } else {
            self.focused_index = self.focus_chain.items.len - 1;
        }
    }

    /// Get the currently focused widget
    pub fn getFocused(self: FocusManager) ?Widget {
        if (self.focused_index) |idx| {
            if (idx < self.focus_chain.items.len) {
                return self.focus_chain.items[idx];
            }
        }
        return null;
    }

    /// Route an event through the focus manager
    /// Handles Tab/Shift+Tab for navigation, or dispatches to focused widget
    pub fn routeEvent(self: *FocusManager, event: Event.Event) EventResult {
        // Handle Tab/Shift+Tab navigation
        if (event == .key) {
            const key = event.key;
            if (key.special == .tab) {
                if (key.mods.shift) {
                    // Shift+Tab: focus previous
                    self.focusPrev();
                } else {
                    // Tab: focus next
                    self.focusNext();
                }
                return .consumed;
            }
        }

        // Dispatch to focused widget
        if (self.getFocused()) |focused| {
            return focused.handleEvent(event);
        }

        return .ignored;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "FocusManager init and deinit" {
    var fm = FocusManager.init(std.testing.allocator);
    defer fm.deinit();

    try std.testing.expectEqual(@as(?usize, null), fm.focused_index);
    try std.testing.expectEqual(@as(usize, 0), fm.focus_chain.items.len);
}

test "FocusManager register single widget" {
    var fm = FocusManager.init(std.testing.allocator);
    defer fm.deinit();

    // Create a simple widget
    const TestWidget = struct {
        value: u32,

        pub const widget_vtable = @import("Widget.zig").VTable{
            .measureFn = struct {
                fn measure(_: *anyopaque, _: @import("Widget.zig").SizeConstraint) @import("Widget.zig").MeasuredSize {
                    return .{ .width = 10, .height = 5 };
                }
            }.measure,
            .renderFn = struct {
                fn render(_: *anyopaque, _: *@import("PlaneView.zig").PlaneView) void {}
            }.render,
        };
    };

    var widget1: TestWidget = .{ .value = 1 };
    try fm.register(Widget.init(TestWidget, &widget1));

    try std.testing.expectEqual(@as(usize, 1), fm.focus_chain.items.len);
    try std.testing.expectEqual(@as(?usize, 0), fm.focused_index);
    try std.testing.expect(fm.getFocused() != null);
}

test "FocusManager register multiple widgets" {
    var fm = FocusManager.init(std.testing.allocator);
    defer fm.deinit();

    const TestWidget = struct {
        value: u32,

        pub const widget_vtable = @import("Widget.zig").VTable{
            .measureFn = struct {
                fn measure(_: *anyopaque, _: @import("Widget.zig").SizeConstraint) @import("Widget.zig").MeasuredSize {
                    return .{ .width = 10, .height = 5 };
                }
            }.measure,
            .renderFn = struct {
                fn render(_: *anyopaque, _: *@import("PlaneView.zig").PlaneView) void {}
            }.render,
        };
    };

    var widget1: TestWidget = .{ .value = 1 };
    var widget2: TestWidget = .{ .value = 2 };
    var widget3: TestWidget = .{ .value = 3 };

    try fm.register(Widget.init(TestWidget, &widget1));
    try fm.register(Widget.init(TestWidget, &widget2));
    try fm.register(Widget.init(TestWidget, &widget3));

    try std.testing.expectEqual(@as(usize, 3), fm.focus_chain.items.len);
    try std.testing.expectEqual(@as(?usize, 0), fm.focused_index);
}

test "FocusManager focusNext wraps around" {
    var fm = FocusManager.init(std.testing.allocator);
    defer fm.deinit();

    const TestWidget = struct {
        value: u32,

        pub const widget_vtable = @import("Widget.zig").VTable{
            .measureFn = struct {
                fn measure(_: *anyopaque, _: @import("Widget.zig").SizeConstraint) @import("Widget.zig").MeasuredSize {
                    return .{ .width = 10, .height = 5 };
                }
            }.measure,
            .renderFn = struct {
                fn render(_: *anyopaque, _: *@import("PlaneView.zig").PlaneView) void {}
            }.render,
        };
    };

    var widget1: TestWidget = .{ .value = 1 };
    var widget2: TestWidget = .{ .value = 2 };
    var widget3: TestWidget = .{ .value = 3 };

    try fm.register(Widget.init(TestWidget, &widget1));
    try fm.register(Widget.init(TestWidget, &widget2));
    try fm.register(Widget.init(TestWidget, &widget3));

    // Start at widget 0
    try std.testing.expectEqual(@as(?usize, 0), fm.focused_index);

    // Move to next
    fm.focusNext();
    try std.testing.expectEqual(@as(?usize, 1), fm.focused_index);

    fm.focusNext();
    try std.testing.expectEqual(@as(?usize, 2), fm.focused_index);

    // Wrap around
    fm.focusNext();
    try std.testing.expectEqual(@as(?usize, 0), fm.focused_index);
}

test "FocusManager focusPrev wraps around" {
    var fm = FocusManager.init(std.testing.allocator);
    defer fm.deinit();

    const TestWidget = struct {
        value: u32,

        pub const widget_vtable = @import("Widget.zig").VTable{
            .measureFn = struct {
                fn measure(_: *anyopaque, _: @import("Widget.zig").SizeConstraint) @import("Widget.zig").MeasuredSize {
                    return .{ .width = 10, .height = 5 };
                }
            }.measure,
            .renderFn = struct {
                fn render(_: *anyopaque, _: *@import("PlaneView.zig").PlaneView) void {}
            }.render,
        };
    };

    var widget1: TestWidget = .{ .value = 1 };
    var widget2: TestWidget = .{ .value = 2 };
    var widget3: TestWidget = .{ .value = 3 };

    try fm.register(Widget.init(TestWidget, &widget1));
    try fm.register(Widget.init(TestWidget, &widget2));
    try fm.register(Widget.init(TestWidget, &widget3));

    // Start at widget 0
    fm.focusPrev();
    // Should wrap to last widget
    try std.testing.expectEqual(@as(?usize, 2), fm.focused_index);

    fm.focusPrev();
    try std.testing.expectEqual(@as(?usize, 1), fm.focused_index);

    fm.focusPrev();
    try std.testing.expectEqual(@as(?usize, 0), fm.focused_index);
}

test "FocusManager unregister widget" {
    var fm = FocusManager.init(std.testing.allocator);
    defer fm.deinit();

    const TestWidget = struct {
        value: u32,

        pub const widget_vtable = @import("Widget.zig").VTable{
            .measureFn = struct {
                fn measure(_: *anyopaque, _: @import("Widget.zig").SizeConstraint) @import("Widget.zig").MeasuredSize {
                    return .{ .width = 10, .height = 5 };
                }
            }.measure,
            .renderFn = struct {
                fn render(_: *anyopaque, _: *@import("PlaneView.zig").PlaneView) void {}
            }.render,
        };
    };

    var widget1: TestWidget = .{ .value = 1 };
    var widget2: TestWidget = .{ .value = 2 };
    var widget3: TestWidget = .{ .value = 3 };

    try fm.register(Widget.init(TestWidget, &widget1));
    try fm.register(Widget.init(TestWidget, &widget2));
    try fm.register(Widget.init(TestWidget, &widget3));

    try std.testing.expectEqual(@as(usize, 3), fm.focus_chain.items.len);

    // Unregister widget2
    fm.unregister(Widget.init(TestWidget, &widget2));

    try std.testing.expectEqual(@as(usize, 2), fm.focus_chain.items.len);
}

test "FocusManager routeEvent Tab navigation" {
    var fm = FocusManager.init(std.testing.allocator);
    defer fm.deinit();

    const TestWidget = struct {
        value: u32,

        pub const widget_vtable = @import("Widget.zig").VTable{
            .measureFn = struct {
                fn measure(_: *anyopaque, _: @import("Widget.zig").SizeConstraint) @import("Widget.zig").MeasuredSize {
                    return .{ .width = 10, .height = 5 };
                }
            }.measure,
            .renderFn = struct {
                fn render(_: *anyopaque, _: *@import("PlaneView.zig").PlaneView) void {}
            }.render,
        };
    };

    var widget1: TestWidget = .{ .value = 1 };
    var widget2: TestWidget = .{ .value = 2 };

    try fm.register(Widget.init(TestWidget, &widget1));
    try fm.register(Widget.init(TestWidget, &widget2));

    try std.testing.expectEqual(@as(?usize, 0), fm.focused_index);

    // Send Tab event
    const tab_event = Event.Event{
        .key = Event.Key.fromSpecial(.tab, Event.Modifiers.none),
    };

    const result = fm.routeEvent(tab_event);
    try std.testing.expectEqual(EventResult.consumed, result);
    try std.testing.expectEqual(@as(?usize, 1), fm.focused_index);
}

test "FocusManager routeEvent Shift+Tab navigation" {
    var fm = FocusManager.init(std.testing.allocator);
    defer fm.deinit();

    const TestWidget = struct {
        value: u32,

        pub const widget_vtable = @import("Widget.zig").VTable{
            .measureFn = struct {
                fn measure(_: *anyopaque, _: @import("Widget.zig").SizeConstraint) @import("Widget.zig").MeasuredSize {
                    return .{ .width = 10, .height = 5 };
                }
            }.measure,
            .renderFn = struct {
                fn render(_: *anyopaque, _: *@import("PlaneView.zig").PlaneView) void {}
            }.render,
        };
    };

    var widget1: TestWidget = .{ .value = 1 };
    var widget2: TestWidget = .{ .value = 2 };

    try fm.register(Widget.init(TestWidget, &widget1));
    try fm.register(Widget.init(TestWidget, &widget2));

    // Move to widget 2
    fm.focusNext();
    try std.testing.expectEqual(@as(?usize, 1), fm.focused_index);

    // Send Shift+Tab event
    const shift_tab_event = Event.Event{
        .key = Event.Key.fromSpecial(.tab, Event.Modifiers{ .shift = true }),
    };

    const result = fm.routeEvent(shift_tab_event);
    try std.testing.expectEqual(EventResult.consumed, result);
    try std.testing.expectEqual(@as(?usize, 0), fm.focused_index);
}

test "FocusManager routeEvent to widget with handler" {
    var fm = FocusManager.init(std.testing.allocator);
    defer fm.deinit();

    var event_received = false;

    const TestWidget = struct {
        value: u32,
        event_ptr: *bool,

        const ThisType = @This();

        pub const widget_vtable = @import("Widget.zig").VTable{
            .measureFn = struct {
                fn measure(_: *anyopaque, _: @import("Widget.zig").SizeConstraint) @import("Widget.zig").MeasuredSize {
                    return .{ .width = 10, .height = 5 };
                }
            }.measure,
            .renderFn = struct {
                fn render(_: *anyopaque, _: *@import("PlaneView.zig").PlaneView) void {}
            }.render,
            .handleEventFn = struct {
                fn handleEvent(ptr: *anyopaque, _: Event.Event) EventResult {
                    const self: *ThisType = @ptrCast(@alignCast(ptr));
                    self.event_ptr.* = true;
                    return .consumed;
                }
            }.handleEvent,
        };
    };

    var widget1: TestWidget = .{ .value = 1, .event_ptr = &event_received };

    try fm.register(Widget.init(TestWidget, &widget1));

    // Send a key event that's not Tab
    const key_event = Event.Event{
        .key = Event.Key.fromCodepoint('a', Event.Modifiers.none),
    };

    const result = fm.routeEvent(key_event);
    try std.testing.expectEqual(EventResult.consumed, result);
    try std.testing.expect(event_received);
}
