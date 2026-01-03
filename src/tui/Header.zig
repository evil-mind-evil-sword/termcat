//! Header and Footer: Application chrome widgets
//!
//! Standard header and footer widgets for consistent application layout:
//! - Header: App title, subtitle, optional icon
//! - Footer: Key binding hints, status information

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const Layout = @import("../Layout.zig");

/// Header widget for application title bar
pub const Header = struct {
    /// Main title
    title: []const u8,
    /// Optional subtitle
    subtitle: ?[]const u8 = null,
    /// Optional icon/prefix character
    icon: ?u21 = null,
    /// Title style
    title_style: Style = .{ .attrs = .{ .bold = true } },
    /// Subtitle style
    subtitle_style: Style = .{ .fg = .{ .index = 8 } },
    /// Background style (fills entire width)
    bg_style: Style = .{ .bg = .{ .index = 4 }, .fg = .{ .index = 15 } }, // Blue bg, white fg
    /// Height (1 or 2 lines)
    tall: bool = false,

    /// Create a header with title
    pub fn init(title: []const u8) Header {
        return .{ .title = title };
    }

    // Builder methods

    /// Set subtitle
    pub fn withSubtitle(self: *Header, subtitle: []const u8) *Header {
        self.subtitle = subtitle;
        return self;
    }

    /// Set icon
    pub fn withIcon(self: *Header, icon: u21) *Header {
        self.icon = icon;
        return self;
    }

    /// Set title style
    pub fn withTitleStyle(self: *Header, style: Style) *Header {
        self.title_style = style;
        return self;
    }

    /// Set background style
    pub fn withBgStyle(self: *Header, style: Style) *Header {
        self.bg_style = style;
        return self;
    }

    /// Set tall mode (2 lines)
    pub fn withTall(self: *Header, tall: bool) *Header {
        self.tall = tall;
        return self;
    }

    // Widget interface

    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Header = @ptrCast(@alignCast(ptr));
        return .{
            .width = constraint.max_width,
            .height = if (self.tall) 2 else 1,
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Header = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0) return;

        // Fill background
        const bg_cell = Cell{
            .char = ' ',
            .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
            .fg = self.bg_style.fg,
            .bg = self.bg_style.bg,
            .attrs = .{},
        };

        var y: i32 = 0;
        while (y < size.height) : (y += 1) {
            var x: i32 = 0;
            while (x < size.width) : (x += 1) {
                view.setCell(x, y, bg_cell);
            }
        }

        // Merge styles for title
        const title_fg = if (self.title_style.fg != .default) self.title_style.fg else self.bg_style.fg;
        const title_bg = if (self.title_style.bg != .default) self.title_style.bg else self.bg_style.bg;

        var x_offset: u16 = 1; // Left padding

        // Draw icon if present
        if (self.icon) |icon| {
            const icon_cell = Cell{
                .char = icon,
                .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                .fg = title_fg,
                .bg = title_bg,
                .attrs = self.title_style.attrs,
            };
            view.setCell(@intCast(x_offset), 0, icon_cell);
            x_offset += 2; // Icon + space
        }

        // Draw title
        view.print(@intCast(x_offset), 0, self.title, title_fg, title_bg, self.title_style.attrs);

        // Draw subtitle
        if (self.subtitle) |subtitle| {
            const sub_fg = if (self.subtitle_style.fg != .default) self.subtitle_style.fg else self.bg_style.fg;
            const sub_bg = if (self.subtitle_style.bg != .default) self.subtitle_style.bg else self.bg_style.bg;

            if (self.tall and size.height >= 2) {
                // Subtitle on second line
                view.print(1, 1, subtitle, sub_fg, sub_bg, self.subtitle_style.attrs);
            } else {
                // Subtitle after title with separator
                const title_len: u16 = @intCast(@min(self.title.len, size.width));
                const sep_x = x_offset + title_len + 1;
                if (sep_x + 3 < size.width) {
                    view.print(@intCast(sep_x), 0, " - ", sub_fg, sub_bg, .{});
                    view.print(@intCast(sep_x + 3), 0, subtitle, sub_fg, sub_bg, self.subtitle_style.attrs);
                }
            }
        }
    }

    /// VTable for Widget interface
    pub const widget_vtable = Widget.VTable{
        .measureFn = measure,
        .renderFn = render,
    };
};

/// Key binding hint for footer
pub const KeyHint = struct {
    /// Key name (e.g., "Ctrl+Q", "Enter", "?")
    key: []const u8,
    /// Action description
    action: []const u8,
};

/// Footer widget for key binding hints
pub const Footer = struct {
    /// Key binding hints
    hints: []const KeyHint = &.{},
    /// Key style
    key_style: Style = .{ .attrs = .{ .bold = true } },
    /// Action style
    action_style: Style = .{ .fg = .{ .index = 8 } },
    /// Background style
    bg_style: Style = .{ .bg = .{ .index = 0 } },
    /// Separator between hints
    separator: []const u8 = "  │  ",
    /// Left status text
    left_status: ?[]const u8 = null,
    /// Right status text
    right_status: ?[]const u8 = null,

    /// Create an empty footer
    pub fn init() Footer {
        return .{};
    }

    /// Create a footer with hints
    pub fn withHints(hints: []const KeyHint) Footer {
        return .{ .hints = hints };
    }

    // Builder methods

    /// Set hints
    pub fn setHints(self: *Footer, hints: []const KeyHint) *Footer {
        self.hints = hints;
        return self;
    }

    /// Set key style
    pub fn setKeyStyle(self: *Footer, style: Style) *Footer {
        self.key_style = style;
        return self;
    }

    /// Set background style
    pub fn setBgStyle(self: *Footer, style: Style) *Footer {
        self.bg_style = style;
        return self;
    }

    /// Set separator
    pub fn setSeparator(self: *Footer, separator: []const u8) *Footer {
        self.separator = separator;
        return self;
    }

    /// Set left status
    pub fn setLeftStatus(self: *Footer, status: []const u8) *Footer {
        self.left_status = status;
        return self;
    }

    /// Set right status
    pub fn setRightStatus(self: *Footer, status: []const u8) *Footer {
        self.right_status = status;
        return self;
    }

    // Widget interface

    fn measure(_: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        return .{
            .width = constraint.max_width,
            .height = 1,
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Footer = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0) return;

        // Fill background
        const bg_cell = Cell{
            .char = ' ',
            .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
            .fg = self.bg_style.fg,
            .bg = self.bg_style.bg,
            .attrs = .{},
        };

        var x: i32 = 0;
        while (x < size.width) : (x += 1) {
            view.setCell(x, 0, bg_cell);
        }

        // Draw left status if present
        var x_offset: u16 = 1;
        if (self.left_status) |status| {
            view.print(@intCast(x_offset), 0, status, self.bg_style.fg, self.bg_style.bg, .{});
            x_offset += @intCast(@min(status.len + 2, size.width));
        }

        // Merge styles
        const key_fg = if (self.key_style.fg != .default) self.key_style.fg else self.bg_style.fg;
        const key_bg = if (self.key_style.bg != .default) self.key_style.bg else self.bg_style.bg;
        const action_fg = if (self.action_style.fg != .default) self.action_style.fg else self.bg_style.fg;
        const action_bg = if (self.action_style.bg != .default) self.action_style.bg else self.bg_style.bg;

        // Draw hints
        for (self.hints, 0..) |hint, i| {
            if (x_offset >= size.width) break;

            // Separator before hint (except first)
            if (i > 0) {
                view.print(@intCast(x_offset), 0, self.separator, self.bg_style.fg, self.bg_style.bg, .{});
                x_offset += @intCast(@min(self.separator.len, size.width -| x_offset));
            }

            // Key
            view.print(@intCast(x_offset), 0, hint.key, key_fg, key_bg, self.key_style.attrs);
            x_offset += @intCast(@min(hint.key.len, size.width -| x_offset));

            // Space
            if (x_offset < size.width) {
                x_offset += 1;
            }

            // Action
            view.print(@intCast(x_offset), 0, hint.action, action_fg, action_bg, self.action_style.attrs);
            x_offset += @intCast(@min(hint.action.len, size.width -| x_offset));
        }

        // Draw right status (right-aligned)
        if (self.right_status) |status| {
            const status_len: u16 = @intCast(@min(status.len, size.width -| 1));
            const right_x = size.width -| status_len -| 1;
            if (right_x > x_offset) {
                view.print(@intCast(right_x), 0, status, self.bg_style.fg, self.bg_style.bg, .{});
            }
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

test "Header init" {
    const header = Header.init("My App");
    try std.testing.expectEqualStrings("My App", header.title);
}

test "Header with subtitle" {
    var header = Header.init("My App");
    _ = header.withSubtitle("v1.0");
    try std.testing.expectEqualStrings("v1.0", header.subtitle.?);
}

test "Header measure" {
    var header = Header.init("Test");
    const widget = Widget.Widget.init(Header, &header);

    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));
    try std.testing.expectEqual(@as(u16, 80), measured.width);
    try std.testing.expectEqual(@as(u16, 1), measured.height);
}

test "Header measure tall" {
    var header = Header.init("Test");
    _ = header.withTall(true);
    const widget = Widget.Widget.init(Header, &header);

    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));
    try std.testing.expectEqual(@as(u16, 2), measured.height);
}

test "Header render" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 40, .height = 1 });
    defer root.deinit();

    var header = Header.init("Test App");
    const widget = Widget.Widget.init(Header, &header);

    var view = PlaneView.init(root);
    widget.render(&view);

    // Title should be visible at position 1 (after left padding)
    try std.testing.expectEqual(@as(u21, 'T'), view.getCell(1, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'e'), view.getCell(2, 0).?.char);
}

test "Footer init" {
    const footer = Footer.init();
    try std.testing.expectEqual(@as(usize, 0), footer.hints.len);
}

test "Footer with hints" {
    const hints = [_]KeyHint{
        .{ .key = "q", .action = "Quit" },
        .{ .key = "?", .action = "Help" },
    };
    const footer = Footer.withHints(&hints);
    try std.testing.expectEqual(@as(usize, 2), footer.hints.len);
}

test "Footer measure" {
    var footer = Footer.init();
    const widget = Widget.Widget.init(Footer, &footer);

    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));
    try std.testing.expectEqual(@as(u16, 80), measured.width);
    try std.testing.expectEqual(@as(u16, 1), measured.height);
}

test "Footer render with hints" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 40, .height = 1 });
    defer root.deinit();

    const hints = [_]KeyHint{
        .{ .key = "q", .action = "Quit" },
    };
    var footer = Footer.withHints(&hints);
    const widget = Widget.Widget.init(Footer, &footer);

    var view = PlaneView.init(root);
    widget.render(&view);

    // Key "q" should be visible
    try std.testing.expectEqual(@as(u21, 'q'), view.getCell(1, 0).?.char);
}

test "Footer with status" {
    var footer = Footer.init();
    _ = footer.setLeftStatus("Ready").setRightStatus("Line 1");

    try std.testing.expectEqualStrings("Ready", footer.left_status.?);
    try std.testing.expectEqualStrings("Line 1", footer.right_status.?);
}
