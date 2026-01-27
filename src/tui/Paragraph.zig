//! Paragraph: Multi-line text display widget with optional wrapping.
//!
//! Renders text across multiple lines, respecting explicit newlines and
//! optionally wrapping long lines to the available width.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Theme = @import("Theme.zig").Theme;
const Style = @import("Theme.zig").Style;
const Label = @import("Label.zig");
const unicode = @import("../unicode/width.zig");

/// Paragraph widget for multi-line text rendering.
pub const Paragraph = struct {
    text: []const u8,
    style: Style = .{},
    alignment: Label.Alignment = .left,
    wrap: bool = true,
    widget_state: Widget.WidgetState = .{},

    /// Initialize a paragraph with text.
    pub fn init(text: []const u8) Paragraph {
        return .{ .text = text };
    }

    /// Set text style.
    pub fn withStyle(self: *Paragraph, style: Style) *Paragraph {
        self.style = style;
        return self;
    }

    /// Set alignment.
    pub fn withAlignment(self: *Paragraph, alignment: Label.Alignment) *Paragraph {
        self.alignment = alignment;
        return self;
    }

    /// Enable/disable wrapping.
    pub fn withWrap(self: *Paragraph, wrap: bool) *Paragraph {
        self.wrap = wrap;
        return self;
    }

    /// Set widget state (disabled, focused, etc.).
    pub fn withState(self: *Paragraph, state: Widget.WidgetState) *Paragraph {
        self.widget_state = state;
        return self;
    }

    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Paragraph = @ptrCast(@alignCast(ptr));

        if (constraint.max_width == 0 or constraint.max_height == 0) {
            return .{ .width = 0, .height = 0 };
        }

        const metrics = lineMetrics(self.text, constraint.max_width, self.wrap);
        const measured = Widget.MeasuredSize{
            .width = @min(metrics.max_width, constraint.max_width),
            .height = @min(metrics.lines, constraint.max_height),
        };
        return constraint.clamp(measured);
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Paragraph = @ptrCast(@alignCast(ptr));
        const size = view.size();
        if (size.width == 0 or size.height == 0) return;

        const theme = Theme.default;
        const style = theme.styleForState(self.style, self.widget_state);

        var row: u16 = 0;
        var line_start: usize = 0;
        var line_width: u16 = 0;

        var i: usize = 0;
        while (i < self.text.len and row < size.height) {
            const byte = self.text[i];
            if (byte == '\n') {
                renderLine(view, style, self.text[line_start..i], line_width, self.alignment, row, size.width);
                row += 1;
                line_start = i + 1;
                line_width = 0;
                i += 1;
                continue;
            }

            const cp_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
            if (i + cp_len > self.text.len) break;

            const cp = std.unicode.utf8Decode(self.text[i..][0..cp_len]) catch '?';
            const cp_width: u16 = @intCast(unicode.codePointWidth(cp));
            if (cp_width == 0) {
                i += cp_len;
                continue;
            }

            if (self.wrap and line_width > 0 and line_width + cp_width > size.width) {
                renderLine(view, style, self.text[line_start..i], line_width, self.alignment, row, size.width);
                row += 1;
                line_start = i;
                line_width = cp_width;
                i += cp_len;
                continue;
            }

            line_width +|= cp_width;
            i += cp_len;
        }

        if (row < size.height) {
            renderLine(view, style, self.text[line_start..self.text.len], line_width, self.alignment, row, size.width);
        }
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

const LineMetrics = struct {
    lines: u16,
    max_width: u16,
};

fn lineMetrics(text: []const u8, max_width: u16, wrap: bool) LineMetrics {
    if (text.len == 0) {
        return .{ .lines = 1, .max_width = 0 };
    }

    var lines: u16 = 1;
    var line_width: u16 = 0;
    var max_line_width: u16 = 0;

    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        if (byte == '\n') {
            if (line_width > max_line_width) max_line_width = line_width;
            lines +|= 1;
            line_width = 0;
            i += 1;
            continue;
        }

        const cp_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        if (i + cp_len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i..][0..cp_len]) catch '?';
        const cp_width: u16 = @intCast(unicode.codePointWidth(cp));
        if (cp_width == 0) {
            i += cp_len;
            continue;
        }

        if (wrap and line_width > 0 and line_width + cp_width > max_width) {
            if (line_width > max_line_width) max_line_width = line_width;
            lines +|= 1;
            line_width = cp_width;
            i += cp_len;
            continue;
        }

        line_width +|= cp_width;
        i += cp_len;
    }

    if (line_width > max_line_width) max_line_width = line_width;

    return .{
        .lines = lines,
        .max_width = @min(max_line_width, max_width),
    };
}

fn renderLine(
    view: *PlaneView,
    style: Style,
    text: []const u8,
    line_width: u16,
    alignment: Label.Alignment,
    row: u16,
    max_width: u16,
) void {
    const offset: i32 = switch (alignment) {
        .left => 0,
        .center => @intCast((max_width -| line_width) / 2),
        .right => @intCast(max_width -| line_width),
    };
    view.print(offset, @intCast(row), text, style.fg, style.bg, style.attrs);
}

// =============================================================================
// Tests
// =============================================================================

const Plane = @import("../Plane.zig");

test "Paragraph measure wraps text" {
    var para = Paragraph.init("abcdefghij");
    const widget = Widget.Widget.init(Paragraph, &para);
    const measured = widget.measure(Widget.SizeConstraint{ .max_width = 5, .max_height = 10 });
    try std.testing.expectEqual(@as(u16, 5), measured.width);
    try std.testing.expectEqual(@as(u16, 2), measured.height);
}

test "Paragraph render wraps lines" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 5, .height = 3 });
    defer root.deinit();

    var view = PlaneView.init(root);
    var para = Paragraph.init("abcdef");
    const widget = Widget.Widget.init(Paragraph, &para);
    widget.render(&view);

    try std.testing.expectEqual(@as(u21, 'a'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'e'), view.getCell(4, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'f'), view.getCell(0, 1).?.char);
}
