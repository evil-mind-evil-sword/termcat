//! Collapsible: Expandable/collapsible content section
//!
//! A container that shows a title and can expand/collapse its content.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const Event = @import("../Event.zig");

/// Collapsible widget
pub const Collapsible = struct {
    /// Title/header text
    title: []const u8,
    /// Child content widget
    child: Widget.Widget,
    /// Whether content is expanded
    expanded: bool = true,
    /// Title style
    title_style: Style = .{ .attrs = .{ .bold = true } },
    /// Expand/collapse indicator style
    indicator_style: Style = .{ .fg = .{ .index = 6 } },
    /// Widget state
    widget_state: Widget.WidgetState = .{},
    /// Change callback
    on_toggle: ?*const fn (ctx: ?*anyopaque, expanded: bool) void = null,
    /// Callback context
    callback_ctx: ?*anyopaque = null,

    /// Create a collapsible section
    pub fn init(title: []const u8, child: Widget.Widget) Collapsible {
        return .{ .title = title, .child = child };
    }

    // Builder methods

    /// Set expanded state
    pub fn withExpanded(self: *Collapsible, expanded: bool) *Collapsible {
        self.expanded = expanded;
        return self;
    }

    /// Set title style
    pub fn withTitleStyle(self: *Collapsible, style: Style) *Collapsible {
        self.title_style = style;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *Collapsible, state: Widget.WidgetState) *Collapsible {
        self.widget_state = state;
        return self;
    }

    /// Set toggle callback
    pub fn withOnToggle(self: *Collapsible, callback: *const fn (ctx: ?*anyopaque, expanded: bool) void, ctx: ?*anyopaque) *Collapsible {
        self.on_toggle = callback;
        self.callback_ctx = ctx;
        return self;
    }

    // Methods

    /// Toggle expanded state
    pub fn toggle(self: *Collapsible) void {
        self.expanded = !self.expanded;
        if (self.on_toggle) |callback| {
            callback(self.callback_ctx, self.expanded);
        }
    }

    /// Expand content
    pub fn expand(self: *Collapsible) void {
        if (!self.expanded) {
            self.expanded = true;
            if (self.on_toggle) |callback| {
                callback(self.callback_ctx, true);
            }
        }
    }

    /// Collapse content
    pub fn collapse(self: *Collapsible) void {
        if (self.expanded) {
            self.expanded = false;
            if (self.on_toggle) |callback| {
                callback(self.callback_ctx, false);
            }
        }
    }

    // Widget interface

    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Collapsible = @ptrCast(@alignCast(ptr));

        // Title line always visible
        const title_width: u16 = @intCast(@min(self.title.len + 2, std.math.maxInt(u16))); // +2 for indicator

        if (!self.expanded) {
            return .{
                .width = @min(title_width, constraint.max_width),
                .height = 1,
            };
        }

        // Measure child
        const child_constraint = Widget.SizeConstraint{
            .max_width = constraint.max_width,
            .max_height = constraint.max_height -| 1, // Reserve 1 for title
        };
        const child_size = self.child.measure(child_constraint);

        return .{
            .width = @max(title_width, child_size.width),
            .height = 1 + child_size.height,
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Collapsible = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0) return;

        // Draw indicator
        const indicator: u21 = if (self.expanded) '▼' else '▶';
        view.setCell(0, 0, .{
            .char = indicator,
            .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
            .fg = self.indicator_style.fg,
            .bg = self.indicator_style.bg,
            .attrs = self.indicator_style.attrs,
        });

        // Draw title
        const title_style = if (self.widget_state.focused)
            self.title_style.merge(.{ .attrs = .{ .underline = true } })
        else
            self.title_style;

        view.print(2, 0, self.title, title_style.fg, title_style.bg, title_style.attrs);

        // Draw child content if expanded
        if (self.expanded and size.height > 1) {
            var content_view = view.subView(.{
                .x = 0,
                .y = 1,
                .width = size.width,
                .height = size.height - 1,
            });
            self.child.render(&content_view);
        }
    }

    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *Collapsible = @ptrCast(@alignCast(ptr));

        if (self.widget_state.disabled) {
            return .ignored;
        }

        switch (event) {
            .key => |key| {
                // Enter or Space toggles
                if (key.special == .enter or (key.codepoint == ' ' and key.mods.eql(Event.Modifiers.none))) {
                    self.toggle();
                    return .consumed;
                }
                // Left/Right for collapse/expand
                if (key.special == .left) {
                    self.collapse();
                    return .consumed;
                }
                if (key.special == .right) {
                    self.expand();
                    return .consumed;
                }
            },
            .mouse => |mouse| {
                // Click on title row toggles
                if (mouse.button == .left and mouse.y == 0) {
                    self.toggle();
                    return .consumed;
                }
            },
            else => {},
        }

        // Forward events to child if expanded
        if (self.expanded) {
            return self.child.handleEvent(event);
        }

        return .ignored;
    }

    /// VTable for Widget interface
    pub const widget_vtable = Widget.VTable{
        .measureFn = measure,
        .renderFn = render,
        .handleEventFn = handleEvent,
    };
};

// ============================================================================
// Tests
// ============================================================================

const Plane = @import("../Plane.zig");
const Label = @import("Label.zig").Label;

test "Collapsible init" {
    var label = Label.init("Content");
    const child = Widget.Widget.init(Label, &label);

    const collapsible = Collapsible.init("Section", child);
    try std.testing.expectEqualStrings("Section", collapsible.title);
    try std.testing.expect(collapsible.expanded);
}

test "Collapsible toggle" {
    var label = Label.init("Content");
    const child = Widget.Widget.init(Label, &label);

    var collapsible = Collapsible.init("Section", child);
    try std.testing.expect(collapsible.expanded);

    collapsible.toggle();
    try std.testing.expect(!collapsible.expanded);

    collapsible.toggle();
    try std.testing.expect(collapsible.expanded);
}

test "Collapsible expand/collapse" {
    var label = Label.init("Content");
    const child = Widget.Widget.init(Label, &label);

    var collapsible = Collapsible.init("Section", child);
    _ = collapsible.withExpanded(false);

    collapsible.expand();
    try std.testing.expect(collapsible.expanded);

    collapsible.collapse();
    try std.testing.expect(!collapsible.expanded);
}

test "Collapsible measure collapsed" {
    var label = Label.init("Long content here");
    const child = Widget.Widget.init(Label, &label);

    var collapsible = Collapsible.init("Title", child);
    _ = collapsible.withExpanded(false);
    const widget = Widget.Widget.init(Collapsible, &collapsible);

    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));
    // Title + indicator = "Title" (5) + 2 = 7
    try std.testing.expectEqual(@as(u16, 7), measured.width);
    try std.testing.expectEqual(@as(u16, 1), measured.height);
}

test "Collapsible measure expanded" {
    var label = Label.init("Content");
    const child = Widget.Widget.init(Label, &label);

    var collapsible = Collapsible.init("Title", child);
    const widget = Widget.Widget.init(Collapsible, &collapsible);

    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));
    // Title row + content row
    try std.testing.expectEqual(@as(u16, 2), measured.height);
}

test "Collapsible render collapsed" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 5 });
    defer root.deinit();

    var label = Label.init("Hidden");
    const child = Widget.Widget.init(Label, &label);

    var collapsible = Collapsible.init("Section", child);
    _ = collapsible.withExpanded(false);
    const widget = Widget.Widget.init(Collapsible, &collapsible);

    var view = PlaneView.init(root);
    widget.render(&view);

    // Collapsed indicator
    try std.testing.expectEqual(@as(u21, '▶'), view.getCell(0, 0).?.char);
    // Title
    try std.testing.expectEqual(@as(u21, 'S'), view.getCell(2, 0).?.char);
}

test "Collapsible render expanded" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 5 });
    defer root.deinit();

    var label = Label.init("Content");
    const child = Widget.Widget.init(Label, &label);

    var collapsible = Collapsible.init("Section", child);
    const widget = Widget.Widget.init(Collapsible, &collapsible);

    var view = PlaneView.init(root);
    widget.render(&view);

    // Expanded indicator
    try std.testing.expectEqual(@as(u21, '▼'), view.getCell(0, 0).?.char);
    // Content should be visible on row 1
    try std.testing.expectEqual(@as(u21, 'C'), view.getCell(0, 1).?.char);
}

test "Collapsible callback" {
    var toggled_state: ?bool = null;

    const callback = struct {
        fn cb(ctx: ?*anyopaque, expanded: bool) void {
            const ptr: *?bool = @ptrCast(@alignCast(ctx.?));
            ptr.* = expanded;
        }
    }.cb;

    var label = Label.init("Content");
    const child = Widget.Widget.init(Label, &label);

    var collapsible = Collapsible.init("Section", child);
    _ = collapsible.withOnToggle(callback, &toggled_state);

    collapsible.toggle();
    try std.testing.expect(!toggled_state.?);
}
