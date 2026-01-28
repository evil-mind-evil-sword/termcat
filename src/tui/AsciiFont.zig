//! AsciiFont: ASCII art font widget
//!
//! Renders ASCII art text using embedded font assets with color support.

const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Theme = @import("Theme.zig").Theme;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const ascii_font = @import("ascii_font.zig");

pub const FontName = ascii_font.FontName;

pub const AsciiFont = struct {
    text: []const u8,
    font: FontName = .tiny,
    style: Style = .{},
    colors: []const Cell.Color = &.{},
    widget_state: Widget.WidgetState = .{},

    pub fn init(text: []const u8) AsciiFont {
        return .{ .text = text };
    }

    pub fn withFont(self: *AsciiFont, font: FontName) *AsciiFont {
        self.font = font;
        return self;
    }

    pub fn withStyle(self: *AsciiFont, style: Style) *AsciiFont {
        self.style = style;
        return self;
    }

    pub fn withColors(self: *AsciiFont, colors: []const Cell.Color) *AsciiFont {
        self.colors = colors;
        return self;
    }

    pub fn withState(self: *AsciiFont, state: Widget.WidgetState) *AsciiFont {
        self.widget_state = state;
        return self;
    }

    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *AsciiFont = @ptrCast(@alignCast(ptr));
        const size = ascii_font.measureText(self.text, self.font);
        return constraint.clamp(.{ .width = size.width, .height = size.height });
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *AsciiFont = @ptrCast(@alignCast(ptr));

        const view_size = view.size();
        if (view_size.width == 0 or view_size.height == 0) return;

        const theme = Theme.default;
        const final_style = theme.styleForState(self.style, self.widget_state);

        _ = ascii_font.renderFont(view, 0, 0, self.text, self.font, final_style, self.colors);
    }

    fn handleEvent(_: *anyopaque, _: @import("../Event.zig").Event) Widget.EventResult {
        return .ignored;
    }

    pub const widget_vtable = Widget.VTable{
        .measureFn = measure,
        .renderFn = render,
        .handleEventFn = handleEvent,
    };
};

// ============================================================================
// Tests
// ============================================================================

const std = @import("std");

test "AsciiFont measure" {
    var font = AsciiFont.init("AB");
    const widget = Widget.Widget.init(AsciiFont, &font);
    const measured = widget.measure(Widget.SizeConstraint.atMost(100, 100));
    try std.testing.expectEqual(@as(u16, 7), measured.width);
    try std.testing.expectEqual(@as(u16, 2), measured.height);
}
