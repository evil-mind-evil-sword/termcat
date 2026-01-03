//! Rule: Visual separator widget
//!
//! A simple horizontal or vertical line for visually dividing content.
//! Similar to HTML's <hr> element.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const Layout = @import("../Layout.zig");

/// Direction of the rule
pub const Direction = enum {
    horizontal,
    vertical,
};

/// Rule line style
pub const LineStyle = enum {
    /// Single thin line: ─ or │
    light,
    /// Double line: ═ or ║
    double,
    /// Thick line: ━ or ┃
    heavy,
    /// Dashed line: ╌ or ╎
    dashed,
    /// Dotted line: ┄ or ┆
    dotted,
    /// ASCII: - or |
    ascii,

    /// Get the character for this style
    pub fn char(self: LineStyle, direction: Direction) u21 {
        return switch (self) {
            .light => switch (direction) {
                .horizontal => '─',
                .vertical => '│',
            },
            .double => switch (direction) {
                .horizontal => '═',
                .vertical => '║',
            },
            .heavy => switch (direction) {
                .horizontal => '━',
                .vertical => '┃',
            },
            .dashed => switch (direction) {
                .horizontal => '╌',
                .vertical => '╎',
            },
            .dotted => switch (direction) {
                .horizontal => '┄',
                .vertical => '┆',
            },
            .ascii => switch (direction) {
                .horizontal => '-',
                .vertical => '|',
            },
        };
    }
};

/// Rule separator widget
pub const Rule = struct {
    /// Direction of the rule
    direction: Direction = .horizontal,
    /// Line style
    line_style: LineStyle = .light,
    /// Style (colors and attributes)
    style: Style = .{},
    /// Optional title/label (horizontal only)
    title: ?[]const u8 = null,
    /// Title alignment
    title_align: Layout.Alignment = .center,
    /// Minimum size (thickness for perpendicular dimension)
    thickness: u16 = 1,

    /// Create a horizontal rule
    pub fn horizontal() Rule {
        return .{ .direction = .horizontal };
    }

    /// Create a vertical rule
    pub fn vertical() Rule {
        return .{ .direction = .vertical };
    }

    // Builder methods

    /// Set the line style
    pub fn withLineStyle(self: *Rule, line_style: LineStyle) *Rule {
        self.line_style = line_style;
        return self;
    }

    /// Set the style (colors/attributes)
    pub fn withStyle(self: *Rule, style: Style) *Rule {
        self.style = style;
        return self;
    }

    /// Set a title (horizontal rules only)
    pub fn withTitle(self: *Rule, title: []const u8) *Rule {
        self.title = title;
        return self;
    }

    /// Set title alignment
    pub fn withTitleAlign(self: *Rule, alignment: Layout.Alignment) *Rule {
        self.title_align = alignment;
        return self;
    }

    /// Set thickness
    pub fn withThickness(self: *Rule, thickness: u16) *Rule {
        self.thickness = thickness;
        return self;
    }

    // Widget interface

    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Rule = @ptrCast(@alignCast(ptr));
        return switch (self.direction) {
            .horizontal => .{
                .width = constraint.max_width,
                .height = self.thickness,
            },
            .vertical => .{
                .width = self.thickness,
                .height = constraint.max_height,
            },
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Rule = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0) return;

        const line_char = self.line_style.char(self.direction);
        const cell = Cell{
            .char = line_char,
            .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
            .fg = self.style.fg,
            .bg = self.style.bg,
            .attrs = self.style.attrs,
        };

        switch (self.direction) {
            .horizontal => {
                // Draw horizontal line
                var x: i32 = 0;
                while (x < size.width) : (x += 1) {
                    view.setCell(x, 0, cell);
                }

                // Draw title if present
                if (self.title) |title| {
                    const title_len: u16 = @intCast(@min(title.len, size.width -| 4));
                    if (title_len > 0 and size.width >= title_len + 4) {
                        const padding: u16 = 2; // Space on each side of title

                        const title_x: u16 = switch (self.title_align) {
                            .left => padding,
                            .center => (size.width -| title_len) / 2,
                            .right => size.width -| title_len -| padding,
                        };

                        // Draw space before title
                        const space_cell = Cell{
                            .char = ' ',
                            .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                            .fg = self.style.fg,
                            .bg = self.style.bg,
                            .attrs = .{},
                        };

                        if (title_x > 0) {
                            view.setCell(@intCast(title_x - 1), 0, space_cell);
                        }

                        // Draw title
                        view.print(@intCast(title_x), 0, title, self.style.fg, self.style.bg, self.style.attrs);

                        // Draw space after title
                        const after_x = title_x + title_len;
                        if (after_x < size.width) {
                            view.setCell(@intCast(after_x), 0, space_cell);
                        }
                    }
                }
            },
            .vertical => {
                // Draw vertical line
                var y: i32 = 0;
                while (y < size.height) : (y += 1) {
                    view.setCell(0, y, cell);
                }
            },
        }
    }

    /// VTable for Widget interface
    pub const widget_vtable = Widget.VTable{
        .measureFn = measure,
        .renderFn = render,
    };
};

// ============================================================================
// Tests
// ============================================================================

const Plane = @import("../Plane.zig");

test "Rule horizontal" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 3 });
    defer root.deinit();

    var rule = Rule.horizontal();
    const widget = Widget.Widget.init(Rule, &rule);

    var view = PlaneView.init(root);
    widget.render(&view);

    // Check horizontal line is drawn
    try std.testing.expectEqual(@as(u21, '─'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, '─'), view.getCell(10, 0).?.char);
    try std.testing.expectEqual(@as(u21, '─'), view.getCell(19, 0).?.char);
}

test "Rule vertical" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 3, .height = 10 });
    defer root.deinit();

    var rule = Rule.vertical();
    const widget = Widget.Widget.init(Rule, &rule);

    var view = PlaneView.init(root);
    widget.render(&view);

    // Check vertical line is drawn
    try std.testing.expectEqual(@as(u21, '│'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, '│'), view.getCell(0, 5).?.char);
    try std.testing.expectEqual(@as(u21, '│'), view.getCell(0, 9).?.char);
}

test "Rule with title" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 1 });
    defer root.deinit();

    var rule = Rule.horizontal();
    _ = rule.withTitle("Test");
    const widget = Widget.Widget.init(Rule, &rule);

    var view = PlaneView.init(root);
    widget.render(&view);

    // Title should be visible (centered)
    // Width 20, title "Test" (4 chars), centered at (20-4)/2 = 8
    try std.testing.expectEqual(@as(u21, 'T'), view.getCell(8, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'e'), view.getCell(9, 0).?.char);
}

test "Rule line styles" {
    var rule = Rule.horizontal();

    _ = rule.withLineStyle(.light);
    try std.testing.expectEqual(@as(u21, '─'), LineStyle.light.char(.horizontal));

    _ = rule.withLineStyle(.double);
    try std.testing.expectEqual(@as(u21, '═'), LineStyle.double.char(.horizontal));

    _ = rule.withLineStyle(.heavy);
    try std.testing.expectEqual(@as(u21, '━'), LineStyle.heavy.char(.horizontal));

    _ = rule.withLineStyle(.ascii);
    try std.testing.expectEqual(@as(u21, '-'), LineStyle.ascii.char(.horizontal));
}

test "Rule measure horizontal" {
    var rule = Rule.horizontal();
    const widget = Widget.Widget.init(Rule, &rule);

    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));
    try std.testing.expectEqual(@as(u16, 80), measured.width);
    try std.testing.expectEqual(@as(u16, 1), measured.height);
}

test "Rule measure vertical" {
    var rule = Rule.vertical();
    const widget = Widget.Widget.init(Rule, &rule);

    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));
    try std.testing.expectEqual(@as(u16, 1), measured.width);
    try std.testing.expectEqual(@as(u16, 24), measured.height);
}
