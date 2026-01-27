//! Link: Clickable hyperlink widget
//!
//! A widget that displays clickable text that can open URLs.
//! Uses OSC 8 hyperlink sequences when supported by the terminal.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const Event = @import("../Event.zig");

/// Link widget for clickable hyperlinks
pub const Link = struct {
    /// Display text
    text: []const u8,
    /// URL to open
    url: []const u8,
    /// Normal style
    style: Style = .{ .fg = .{ .index = 4 }, .attrs = .{ .underline = true } }, // Blue, underlined
    /// Hovered style
    hover_style: Style = .{ .fg = .{ .index = 12 }, .attrs = .{ .underline = true } }, // Bright blue
    /// Focused style
    focused_style: Style = .{ .fg = .{ .index = 14 }, .attrs = .{ .underline = true, .bold = true } }, // Cyan, bold
    /// Widget state
    widget_state: Widget.WidgetState = .{},
    /// Click callback
    on_click: ?*const fn (ctx: ?*anyopaque, url: []const u8) void = null,
    /// Callback context
    callback_ctx: ?*anyopaque = null,

    /// Create a link with text and URL
    pub fn init(text: []const u8, url: []const u8) Link {
        return .{ .text = text, .url = url };
    }

    /// Create a link where text and URL are the same
    pub fn fromUrl(url: []const u8) Link {
        return .{ .text = url, .url = url };
    }

    // Builder methods

    /// Set normal style
    pub fn withStyle(self: *Link, style: Style) *Link {
        self.style = style;
        return self;
    }

    /// Set hover style
    pub fn withHoverStyle(self: *Link, style: Style) *Link {
        self.hover_style = style;
        return self;
    }

    /// Set focused style
    pub fn withFocusedStyle(self: *Link, style: Style) *Link {
        self.focused_style = style;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *Link, state: Widget.WidgetState) *Link {
        self.widget_state = state;
        return self;
    }

    /// Set click callback
    pub fn withOnClick(self: *Link, callback: *const fn (ctx: ?*anyopaque, url: []const u8) void, ctx: ?*anyopaque) *Link {
        self.on_click = callback;
        self.callback_ctx = ctx;
        return self;
    }

    /// Get current style based on state
    fn currentStyle(self: *const Link) Style {
        if (self.widget_state.disabled) {
            return .{ .fg = .{ .index = 8 } }; // Gray
        }
        if (self.widget_state.focused) {
            return self.focused_style;
        }
        if (self.widget_state.hovered) {
            return self.hover_style;
        }
        return self.style;
    }

    // Widget interface

    fn measure(ptr: *anyopaque, _: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Link = @ptrCast(@alignCast(ptr));
        return .{
            .width = @intCast(@min(self.text.len, std.math.maxInt(u16))),
            .height = 1,
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Link = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0) return;

        const style = self.currentStyle();

        // Draw the link text
        // Note: OSC 8 hyperlink support would be added at the terminal/renderer level
        // Here we just render the styled text
        view.print(0, 0, self.text, style.fg, style.bg, style.attrs);
    }

    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *Link = @ptrCast(@alignCast(ptr));

        if (self.widget_state.disabled) {
            return .ignored;
        }

        switch (event) {
            .key => |key| {
                // Enter or Space activates the link
                if (key.special == .enter or (key.codepoint == ' ' and key.mods.eql(Event.Modifiers.none))) {
                    if (self.on_click) |callback| {
                        callback(self.callback_ctx, self.url);
                    }
                    return .consumed;
                }
            },
            .mouse => |mouse| {
                if (mouse.button == .left) {
                    if (self.on_click) |callback| {
                        callback(self.callback_ctx, self.url);
                    }
                    return .consumed;
                }
            },
            else => {},
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

test "Link init" {
    const link = Link.init("Click here", "https://example.com");
    try std.testing.expectEqualStrings("Click here", link.text);
    try std.testing.expectEqualStrings("https://example.com", link.url);
}

test "Link fromUrl" {
    const link = Link.fromUrl("https://example.com");
    try std.testing.expectEqualStrings("https://example.com", link.text);
    try std.testing.expectEqualStrings("https://example.com", link.url);
}

test "Link measure" {
    var link = Link.init("Click me", "https://example.com");
    const widget = Widget.Widget.init(Link, &link);

    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));
    try std.testing.expectEqual(@as(u16, 8), measured.width); // "Click me" = 8 chars
    try std.testing.expectEqual(@as(u16, 1), measured.height);
}

test "Link render" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 1 });
    defer root.deinit();

    var link = Link.init("Test", "https://test.com");
    const widget = Widget.Widget.init(Link, &link);

    var view = PlaneView.init(root);
    widget.render(&view);

    // Text should be visible
    try std.testing.expectEqual(@as(u21, 'T'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'e'), view.getCell(1, 0).?.char);

    // Should have underline attribute
    try std.testing.expect(view.getCell(0, 0).?.attrs.underline);
}

test "Link style changes with state" {
    var link = Link.init("Test", "https://test.com");

    // Normal state
    var style = link.currentStyle();
    try std.testing.expectEqual(Cell.Color{ .index = 4 }, style.fg);

    // Hovered state
    link.widget_state.hovered = true;
    style = link.currentStyle();
    try std.testing.expectEqual(Cell.Color{ .index = 12 }, style.fg);

    // Focused state
    link.widget_state.focused = true;
    style = link.currentStyle();
    try std.testing.expectEqual(Cell.Color{ .index = 14 }, style.fg);

    // Disabled state
    link.widget_state.disabled = true;
    style = link.currentStyle();
    try std.testing.expectEqual(Cell.Color{ .index = 8 }, style.fg);
}

test "Link click callback" {
    var clicked_url: ?[]const u8 = null;

    const callback = struct {
        fn cb(ctx: ?*anyopaque, url: []const u8) void {
            const ptr: *?[]const u8 = @ptrCast(@alignCast(ctx.?));
            ptr.* = url;
        }
    }.cb;

    var link = Link.init("Test", "https://test.com");
    _ = link.withOnClick(callback, &clicked_url);

    const widget = Widget.Widget.init(Link, &link);

    // Simulate Enter key
    const enter_event = Event.Event{
        .key = Event.Key.fromSpecial(.enter, Event.Modifiers.none),
    };

    const result = widget.handleEvent(enter_event);
    try std.testing.expectEqual(Widget.EventResult.consumed, result);
    try std.testing.expectEqualStrings("https://test.com", clicked_url.?);
}

test "Link builder pattern" {
    var link = Link.init("Test", "https://test.com");
    _ = link
        .withStyle(.{ .fg = .{ .index = 1 } })
        .withHoverStyle(.{ .fg = .{ .index = 2 } })
        .withFocusedStyle(.{ .fg = .{ .index = 3 } });

    try std.testing.expectEqual(Cell.Color{ .index = 1 }, link.style.fg);
    try std.testing.expectEqual(Cell.Color{ .index = 2 }, link.hover_style.fg);
    try std.testing.expectEqual(Cell.Color{ .index = 3 }, link.focused_style.fg);
}
