//! Label: Simple text display widget
//!
//! A lightweight widget for displaying static or dynamic text with alignment and styling.
//! Measures to text width x 1 height, and renders using Layout.printAligned().

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Theme = @import("Theme.zig").Theme;
const Style = @import("Theme.zig").Style;
const unicode = @import("../unicode/width.zig");

/// Text alignment options
pub const Alignment = enum {
    left,
    center,
    right,
};

/// Label widget for displaying text
pub const Label = struct {
    text: []const u8,
    alignment: Alignment = .left,
    style: Style = .{},
    widget_state: Widget.WidgetState = .{},

    /// Initialize a Label widget
    pub fn init(text: []const u8) Label {
        return .{
            .text = text,
            .alignment = .left,
            .style = .{},
            .widget_state = .{},
        };
    }

    /// Set the text alignment
    pub fn withAlignment(self: *Label, alignment: Alignment) *Label {
        self.alignment = alignment;
        return self;
    }

    /// Set the text style
    pub fn withStyle(self: *Label, style: Style) *Label {
        self.style = style;
        return self;
    }

    /// Set the widget state (disabled, focused, etc.)
    pub fn withState(self: *Label, state: Widget.WidgetState) *Label {
        self.widget_state = state;
        return self;
    }

    /// Measure the label's preferred size
    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Label = @ptrCast(@alignCast(ptr));

        // Get the display width of the text
        const text_width: u16 = @intCast(@min(unicode.stringWidth(self.text), std.math.maxInt(u16)));

        // Clamp to constraint bounds
        const constrained = constraint.clamp(.{
            .width = text_width,
            .height = 1,
        });

        return constrained;
    }

    /// Render the label to the provided view
    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Label = @ptrCast(@alignCast(ptr));

        const view_size = view.size();
        if (view_size.height == 0 or view_size.width == 0) return;

        // Get the theme to apply disabled state
        const theme = Theme.default;
        const final_style = theme.styleForState(self.style, self.widget_state);

        // Calculate text width for alignment
        const text_width: u16 = @intCast(@min(unicode.stringWidth(self.text), std.math.maxInt(u16)));

        // Calculate starting x position based on alignment
        const offset: i32 = switch (self.alignment) {
            .left => 0,
            .center => @intCast((view_size.width -| text_width) / 2),
            .right => @intCast(view_size.width -| text_width),
        };

        // Write the text to the view at the calculated position
        // PlaneView.print handles clipping automatically
        view.print(
            offset,
            0,
            self.text,
            final_style.fg,
            final_style.bg,
            final_style.attrs,
        );
    }

    /// Handle events - labels don't handle events
    fn handleEvent(_: *anyopaque, _: @import("../Event.zig").Event) Widget.EventResult {
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

const Cell = @import("../Cell.zig");
const Plane = @import("../Plane.zig");

test "Label init with default alignment" {
    const label = Label.init("Hello");
    try std.testing.expectEqualStrings("Hello", label.text);
    try std.testing.expectEqual(Alignment.left, label.alignment);
    try std.testing.expect(!label.widget_state.disabled);
    try std.testing.expect(!label.widget_state.focused);
}

test "Label measure basic text" {
    var label = Label.init("Hello");
    const widget = Widget.Widget.init(Label, &label);
    const measured = widget.measure(Widget.SizeConstraint{});

    try std.testing.expectEqual(@as(u16, 5), measured.width);
    try std.testing.expectEqual(@as(u16, 1), measured.height);
}

test "Label measure empty text" {
    var label = Label.init("");
    const widget = Widget.Widget.init(Label, &label);
    const measured = widget.measure(Widget.SizeConstraint{});

    try std.testing.expectEqual(@as(u16, 0), measured.width);
    try std.testing.expectEqual(@as(u16, 1), measured.height);
}

test "Label measure respects constraint" {
    var label = Label.init("Hello World");
    const widget = Widget.Widget.init(Label, &label);
    const constraint = Widget.SizeConstraint.atMost(5, 1);
    const measured = widget.measure(constraint);

    try std.testing.expectEqual(@as(u16, 5), measured.width);
    try std.testing.expectEqual(@as(u16, 1), measured.height);
}

test "Label measure with wide characters" {
    var label = Label.init("中文");
    const widget = Widget.Widget.init(Label, &label);
    const measured = widget.measure(Widget.SizeConstraint{});

    // "中文" = 2 + 2 = 4 display width
    try std.testing.expectEqual(@as(u16, 4), measured.width);
    try std.testing.expectEqual(@as(u16, 1), measured.height);
}

test "Label render left aligned" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 5 });
    defer root.deinit();

    var view = PlaneView.init(root);
    var label = Label.init("Hi");
    label.alignment = .left;
    const widget = Widget.Widget.init(Label, &label);

    widget.render(&view);

    try std.testing.expectEqual(@as(u21, 'H'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'i'), view.getCell(1, 0).?.char);
}

test "Label render center aligned" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 5 });
    defer root.deinit();

    var view = PlaneView.init(root);
    var label = Label.init("Hi");
    label.alignment = .center;
    const widget = Widget.Widget.init(Label, &label);

    widget.render(&view);

    // With 20 width and 2 char text, should be centered at position 9
    try std.testing.expectEqual(@as(u21, 'H'), view.getCell(9, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'i'), view.getCell(10, 0).?.char);
}

test "Label render right aligned" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 5 });
    defer root.deinit();

    var view = PlaneView.init(root);
    var label = Label.init("Hi");
    label.alignment = .right;
    const widget = Widget.Widget.init(Label, &label);

    widget.render(&view);

    // With 20 width and 2 char text, should be at right edge (positions 18-19)
    try std.testing.expectEqual(@as(u21, 'H'), view.getCell(18, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'i'), view.getCell(19, 0).?.char);
}

test "Label render with disabled state" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 5 });
    defer root.deinit();

    var view = PlaneView.init(root);
    var label = Label.init("Text");
    label.widget_state.disabled = true;
    const widget = Widget.Widget.init(Label, &label);

    widget.render(&view);

    // Should still render the text (disabled state is visual only)
    try std.testing.expectEqual(@as(u21, 'T'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'e'), view.getCell(1, 0).?.char);
}

test "Label as Widget" {
    var label = Label.init("Test");
    const widget = Widget.Widget.init(Label, &label);

    const measured = widget.measure(Widget.SizeConstraint{});
    try std.testing.expectEqual(@as(u16, 4), measured.width);
    try std.testing.expectEqual(@as(u16, 1), measured.height);

    // Events should be ignored - use a valid event
    const Event = @import("../Event.zig");
    const key_event = Event.Event{ .key = Event.Key.fromCodepoint('a', Event.Modifiers.none) };
    const result = widget.handleEvent(key_event);
    try std.testing.expectEqual(Widget.EventResult.ignored, result);
}

test "Label builder pattern" {
    var label = Label.init("Hello");
    _ = label.withAlignment(.center).withState(.{ .disabled = true });

    try std.testing.expectEqual(Alignment.center, label.alignment);
    try std.testing.expect(label.widget_state.disabled);
}
