//! Widget: Core types for the widget system
//!
//! Provides vtable-based Widget interface with two-phase layout (measure/render).
//! Widgets are stateless renderables; persistent state is managed separately
//! via StateStore (to be implemented).

const std = @import("std");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Event = @import("../Event.zig");
const Cell = @import("../Cell.zig");

pub const Size = Event.Size;
pub const Rect = Event.Rect;
pub const Position = Event.Position;

/// Size constraint passed to measure()
pub const SizeConstraint = struct {
    min_width: u16 = 0,
    min_height: u16 = 0,
    max_width: u16 = std.math.maxInt(u16),
    max_height: u16 = std.math.maxInt(u16),

    /// Create an exact size constraint
    pub fn exact(width: u16, height: u16) SizeConstraint {
        return .{
            .min_width = width,
            .max_width = width,
            .min_height = height,
            .max_height = height,
        };
    }

    /// Create a constraint with maximum bounds
    pub fn atMost(width: u16, height: u16) SizeConstraint {
        return .{ .max_width = width, .max_height = height };
    }

    /// Create a constraint with minimum bounds
    pub fn atLeast(width: u16, height: u16) SizeConstraint {
        return .{ .min_width = width, .min_height = height };
    }

    /// Clamp a size to this constraint
    pub fn clamp(self: SizeConstraint, size: MeasuredSize) MeasuredSize {
        return .{
            .width = @max(self.min_width, @min(self.max_width, size.width)),
            .height = @max(self.min_height, @min(self.max_height, size.height)),
        };
    }
};

/// Size returned by measure()
pub const MeasuredSize = struct {
    width: u16,
    height: u16,

    pub fn zero() MeasuredSize {
        return .{ .width = 0, .height = 0 };
    }
};

/// Widget state for styling
pub const WidgetState = struct {
    focused: bool = false,
    hovered: bool = false,
    pressed: bool = false,
    disabled: bool = false,

    pub fn normal() WidgetState {
        return .{};
    }
};

/// Event result from handleEvent
pub const EventResult = enum {
    ignored, // Event not handled, continue propagation
    consumed, // Event handled, stop propagation
};

/// VTable for widget interface
pub const VTable = struct {
    /// Measure the widget's preferred size given constraints
    measureFn: *const fn (ptr: *anyopaque, constraint: SizeConstraint) MeasuredSize,

    /// Render the widget to the provided view
    renderFn: *const fn (ptr: *anyopaque, view: *PlaneView) void,

    /// Handle an input event (optional)
    handleEventFn: ?*const fn (ptr: *anyopaque, event: Event.Event) EventResult = null,
};

/// Type-erased Widget handle
///
/// Widgets are created by calling Widget.init() with a pointer to a concrete
/// widget type that has a `widget_vtable` declaration.
pub const Widget = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Measure the widget's preferred size
    pub fn measure(self: Widget, constraint: SizeConstraint) MeasuredSize {
        return self.vtable.measureFn(self.ptr, constraint);
    }

    /// Render the widget to the view
    pub fn render(self: Widget, view: *PlaneView) void {
        self.vtable.renderFn(self.ptr, view);
    }

    /// Handle an event, returns whether it was consumed
    pub fn handleEvent(self: Widget, event: Event.Event) EventResult {
        if (self.vtable.handleEventFn) |handler| {
            return handler(self.ptr, event);
        }
        return .ignored;
    }

    /// Create a Widget from a concrete type
    ///
    /// The type T must have a `widget_vtable` declaration of type VTable.
    pub fn init(comptime T: type, ptr: *T) Widget {
        comptime {
            if (!@hasDecl(T, "widget_vtable")) {
                @compileError("Type " ++ @typeName(T) ++ " must have widget_vtable declaration");
            }
        }
        return .{
            .ptr = ptr,
            .vtable = &T.widget_vtable,
        };
    }
};

/// Check if a type implements the Widget interface at comptime
pub fn isWidget(comptime T: type) bool {
    if (!@hasDecl(T, "widget_vtable")) return false;
    const vtable_type = @TypeOf(@field(T, "widget_vtable"));
    return vtable_type == VTable;
}

// ============================================================================
// Tests
// ============================================================================

test "SizeConstraint exact" {
    const c = SizeConstraint.exact(10, 5);
    try std.testing.expectEqual(@as(u16, 10), c.min_width);
    try std.testing.expectEqual(@as(u16, 10), c.max_width);
    try std.testing.expectEqual(@as(u16, 5), c.min_height);
    try std.testing.expectEqual(@as(u16, 5), c.max_height);
}

test "SizeConstraint atMost" {
    const c = SizeConstraint.atMost(100, 50);
    try std.testing.expectEqual(@as(u16, 0), c.min_width);
    try std.testing.expectEqual(@as(u16, 100), c.max_width);
    try std.testing.expectEqual(@as(u16, 0), c.min_height);
    try std.testing.expectEqual(@as(u16, 50), c.max_height);
}

test "SizeConstraint clamp" {
    const c = SizeConstraint{ .min_width = 10, .max_width = 50, .min_height = 5, .max_height = 20 };

    // Clamp within bounds
    const s1 = c.clamp(.{ .width = 30, .height = 10 });
    try std.testing.expectEqual(@as(u16, 30), s1.width);
    try std.testing.expectEqual(@as(u16, 10), s1.height);

    // Clamp below min
    const s2 = c.clamp(.{ .width = 5, .height = 2 });
    try std.testing.expectEqual(@as(u16, 10), s2.width);
    try std.testing.expectEqual(@as(u16, 5), s2.height);

    // Clamp above max
    const s3 = c.clamp(.{ .width = 100, .height = 50 });
    try std.testing.expectEqual(@as(u16, 50), s3.width);
    try std.testing.expectEqual(@as(u16, 20), s3.height);
}

test "isWidget" {
    const ValidWidget = struct {
        value: u32,

        pub const widget_vtable = VTable{
            .measureFn = struct {
                fn measure(_: *anyopaque, _: SizeConstraint) MeasuredSize {
                    return .{ .width = 10, .height = 5 };
                }
            }.measure,
            .renderFn = struct {
                fn render(_: *anyopaque, _: *PlaneView) void {}
            }.render,
        };
    };

    const InvalidWidget = struct {
        value: u32,
    };

    try std.testing.expect(isWidget(ValidWidget));
    try std.testing.expect(!isWidget(InvalidWidget));
}
