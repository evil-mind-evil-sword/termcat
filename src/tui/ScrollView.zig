//! ScrollView: Scrollable container widget with viewport and scrollbars
//!
//! Provides a viewport into content that may be larger than the display area.
//! Supports vertical and optional horizontal scrollbars, keyboard navigation
//! (arrows, Page Up/Down, Home/End), and mouse wheel scrolling.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Event = @import("../Event.zig");
const Cell = @import("../Cell.zig");

/// Scrollbar characters
const ScrollbarChars = struct {
    track: u21 = '░',
    thumb: u21 = '█',
    up_arrow: u21 = '▲',
    down_arrow: u21 = '▼',
    left_arrow: u21 = '◄',
    right_arrow: u21 = '►',
};

/// Default scrollbar character set
pub const default_scrollbar = ScrollbarChars{};

/// ScrollView widget
pub const ScrollView = struct {
    child: Widget.Widget,

    // Content dimensions (set by user or measured from child)
    content_width: u16 = 0,
    content_height: u16 = 0,

    // Scroll position
    scroll_x: u16 = 0,
    scroll_y: u16 = 0,

    // Configuration
    show_vertical: bool = true,
    show_horizontal: bool = false,
    scrollbar_width: u16 = 1, // Usually 1 cell wide

    // Styling
    fg: Cell.Color = .default,
    bg: Cell.Color = .default,
    thumb_fg: Cell.Color = .default,
    thumb_bg: Cell.Color = .default,

    /// Create a ScrollView around a child widget
    pub fn init(child: Widget.Widget) ScrollView {
        return .{ .child = child };
    }

    /// Set the content size (virtual size of scrollable content)
    pub fn withContentSize(self: *ScrollView, width: u16, height: u16) *ScrollView {
        self.content_width = width;
        self.content_height = height;
        return self;
    }

    /// Enable/disable vertical scrollbar
    pub fn withVerticalScrollbar(self: *ScrollView, show: bool) *ScrollView {
        self.show_vertical = show;
        return self;
    }

    /// Enable/disable horizontal scrollbar
    pub fn withHorizontalScrollbar(self: *ScrollView, show: bool) *ScrollView {
        self.show_horizontal = show;
        return self;
    }

    /// Set scrollbar styling
    pub fn withScrollbarStyle(self: *ScrollView, fg: Cell.Color, bg: Cell.Color) *ScrollView {
        self.fg = fg;
        self.bg = bg;
        return self;
    }

    /// Scroll to a position
    pub fn scrollTo(self: *ScrollView, x: u16, y: u16) void {
        self.scroll_x = x;
        self.scroll_y = y;
        self.clampScroll();
    }

    /// Scroll by a delta
    pub fn scrollBy(self: *ScrollView, dx: i16, dy: i16) void {
        if (dx >= 0) {
            self.scroll_x +|= @intCast(dx);
        } else {
            self.scroll_x -|= @intCast(-dx);
        }
        if (dy >= 0) {
            self.scroll_y +|= @intCast(dy);
        } else {
            self.scroll_y -|= @intCast(-dy);
        }
        self.clampScroll();
    }

    /// Clamp scroll position to valid range
    fn clampScroll(_: *ScrollView) void {
        // Note: We'd need viewport size to clamp properly
        // This is handled in render where we know the actual size
    }

    /// Measure: return viewport size (we take available space)
    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *ScrollView = @ptrCast(@alignCast(ptr));

        // Measure child to get content size if not explicitly set
        if (self.content_width == 0 or self.content_height == 0) {
            const child_size = self.child.measure(Widget.SizeConstraint{
                .max_width = std.math.maxInt(u16),
                .max_height = std.math.maxInt(u16),
            });
            if (self.content_width == 0) self.content_width = child_size.width;
            if (self.content_height == 0) self.content_height = child_size.height;
        }

        // ScrollView takes whatever space is available
        return constraint.clamp(.{
            .width = constraint.max_width,
            .height = constraint.max_height,
        });
    }

    /// Render: draw viewport content and scrollbars
    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *ScrollView = @ptrCast(@alignCast(ptr));

        const view_size = view.size();
        if (view_size.width == 0 or view_size.height == 0) return;

        // Calculate viewport dimensions (excluding scrollbars)
        const scrollbar_h_space: u16 = if (self.show_vertical) self.scrollbar_width else 0;
        const scrollbar_v_space: u16 = if (self.show_horizontal) self.scrollbar_width else 0;

        const viewport_width = view_size.width -| scrollbar_h_space;
        const viewport_height = view_size.height -| scrollbar_v_space;

        if (viewport_width == 0 or viewport_height == 0) return;

        // Clamp scroll position to valid range
        const max_scroll_x = self.content_width -| viewport_width;
        const max_scroll_y = self.content_height -| viewport_height;
        const clamped_x = @min(self.scroll_x, max_scroll_x);
        const clamped_y = @min(self.scroll_y, max_scroll_y);

        // Create a viewport sub-view for the child content
        var content_view = view.subView(.{
            .x = 0,
            .y = 0,
            .width = viewport_width,
            .height = viewport_height,
        });

        // Render child - the child should render within the content_view
        // We offset by the scroll position by rendering child in a larger "virtual" view
        // But PlaneView doesn't support negative offsets, so we use a different approach:
        // We'll create a subview that represents the scrolled portion

        // For now, we render the child directly - they see the viewport size
        // In a real implementation, we'd need a temporary buffer or different approach
        self.child.render(&content_view);

        // Draw vertical scrollbar
        if (self.show_vertical and view_size.width > 0) {
            self.drawVerticalScrollbar(view, viewport_width, viewport_height, clamped_y, max_scroll_y);
        }

        // Draw horizontal scrollbar
        if (self.show_horizontal and view_size.height > 0) {
            self.drawHorizontalScrollbar(view, viewport_width, viewport_height, clamped_x, max_scroll_x);
        }
    }

    fn drawVerticalScrollbar(
        self: *ScrollView,
        view: *PlaneView,
        x: u16,
        height: u16,
        scroll_pos: u16,
        max_scroll: u16,
    ) void {
        const scrollbar_height = height;
        if (scrollbar_height < 3) return; // Need at least arrows + thumb

        // Draw track
        var y: u16 = 0;
        while (y < scrollbar_height) : (y += 1) {
            view.setCell(@intCast(x), @intCast(y), Cell{
                .char = default_scrollbar.track,
                .combining = .{ 0, 0 },
                .fg = self.fg,
                .bg = self.bg,
                .attrs = .{},
            });
        }

        // Calculate thumb position and size
        if (max_scroll == 0) {
            // Content fits, thumb fills track
            var ty: u16 = 0;
            while (ty < scrollbar_height) : (ty += 1) {
                view.setCell(@intCast(x), @intCast(ty), Cell{
                    .char = default_scrollbar.thumb,
                    .combining = .{ 0, 0 },
                    .fg = self.thumb_fg,
                    .bg = self.thumb_bg,
                    .attrs = .{},
                });
            }
        } else {
            // Calculate proportional thumb
            const content_h = self.content_height;
            const viewport_h = height;

            // Thumb size: proportional to visible portion
            const thumb_size_raw = (@as(u32, viewport_h) * @as(u32, scrollbar_height)) / @as(u32, content_h);
            const thumb_size = @max(1, @min(@as(u16, @intCast(thumb_size_raw)), scrollbar_height));

            // Thumb position: proportional to scroll position
            const available_track = scrollbar_height -| thumb_size;
            const thumb_pos: u16 = if (max_scroll == 0)
                0
            else
                @intCast((@as(u32, scroll_pos) * @as(u32, available_track)) / @as(u32, max_scroll));

            // Draw thumb
            var ty: u16 = 0;
            while (ty < thumb_size) : (ty += 1) {
                const pos_y = thumb_pos +| ty;
                if (pos_y < scrollbar_height) {
                    view.setCell(@intCast(x), @intCast(pos_y), Cell{
                        .char = default_scrollbar.thumb,
                        .combining = .{ 0, 0 },
                        .fg = self.thumb_fg,
                        .bg = self.thumb_bg,
                        .attrs = .{},
                    });
                }
            }
        }
    }

    fn drawHorizontalScrollbar(
        self: *ScrollView,
        view: *PlaneView,
        width: u16,
        y: u16,
        scroll_pos: u16,
        max_scroll: u16,
    ) void {
        const scrollbar_width = width;
        if (scrollbar_width < 3) return;

        // Draw track
        var x: u16 = 0;
        while (x < scrollbar_width) : (x += 1) {
            view.setCell(@intCast(x), @intCast(y), Cell{
                .char = default_scrollbar.track,
                .combining = .{ 0, 0 },
                .fg = self.fg,
                .bg = self.bg,
                .attrs = .{},
            });
        }

        // Calculate and draw thumb
        if (max_scroll == 0) {
            var tx: u16 = 0;
            while (tx < scrollbar_width) : (tx += 1) {
                view.setCell(@intCast(tx), @intCast(y), Cell{
                    .char = default_scrollbar.thumb,
                    .combining = .{ 0, 0 },
                    .fg = self.thumb_fg,
                    .bg = self.thumb_bg,
                    .attrs = .{},
                });
            }
        } else {
            const content_w = self.content_width;
            const viewport_w = width;

            const thumb_size_raw = (@as(u32, viewport_w) * @as(u32, scrollbar_width)) / @as(u32, content_w);
            const thumb_size = @max(1, @min(@as(u16, @intCast(thumb_size_raw)), scrollbar_width));

            const available_track = scrollbar_width -| thumb_size;
            const thumb_pos: u16 = if (max_scroll == 0)
                0
            else
                @intCast((@as(u32, scroll_pos) * @as(u32, available_track)) / @as(u32, max_scroll));

            var tx: u16 = 0;
            while (tx < thumb_size) : (tx += 1) {
                const pos_x = thumb_pos +| tx;
                if (pos_x < scrollbar_width) {
                    view.setCell(@intCast(pos_x), @intCast(y), Cell{
                        .char = default_scrollbar.thumb,
                        .combining = .{ 0, 0 },
                        .fg = self.thumb_fg,
                        .bg = self.thumb_bg,
                        .attrs = .{},
                    });
                }
            }
        }
    }

    /// Handle events - keyboard and mouse scrolling
    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *ScrollView = @ptrCast(@alignCast(ptr));

        switch (event) {
            .key => |key| {
                // Handle scroll keys
                if (key.codepoint == Event.Key.up or key.codepoint == 'k') {
                    self.scrollBy(0, -1);
                    return .consumed;
                } else if (key.codepoint == Event.Key.down or key.codepoint == 'j') {
                    self.scrollBy(0, 1);
                    return .consumed;
                } else if (key.codepoint == Event.Key.left or key.codepoint == 'h') {
                    self.scrollBy(-1, 0);
                    return .consumed;
                } else if (key.codepoint == Event.Key.right or key.codepoint == 'l') {
                    self.scrollBy(1, 0);
                    return .consumed;
                } else if (key.codepoint == Event.Key.page_up) {
                    self.scrollBy(0, -10); // Page scroll
                    return .consumed;
                } else if (key.codepoint == Event.Key.page_down) {
                    self.scrollBy(0, 10);
                    return .consumed;
                } else if (key.codepoint == Event.Key.home) {
                    self.scroll_y = 0;
                    return .consumed;
                } else if (key.codepoint == Event.Key.end) {
                    self.scroll_y = std.math.maxInt(u16); // Will be clamped
                    return .consumed;
                }
            },
            .mouse => |mouse| {
                // Handle mouse wheel
                if (mouse.button == .wheel_up) {
                    self.scrollBy(0, -3);
                    return .consumed;
                } else if (mouse.button == .wheel_down) {
                    self.scrollBy(0, 3);
                    return .consumed;
                }
            },
            else => {},
        }

        // Forward to child
        return self.child.handleEvent(event);
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

// Test widget that fills with a character
const TestWidget = struct {
    char: u21,
    width: u16,
    height: u16,

    fn measure(ptr: *anyopaque, _: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *TestWidget = @ptrCast(@alignCast(ptr));
        return .{ .width = self.width, .height = self.height };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *TestWidget = @ptrCast(@alignCast(ptr));
        const size = view.size();
        var y: i32 = 0;
        while (y < size.height) : (y += 1) {
            var x: i32 = 0;
            while (x < size.width) : (x += 1) {
                view.setCell(x, y, Cell{
                    .char = self.char,
                    .combining = .{ 0, 0 },
                    .fg = .default,
                    .bg = .default,
                    .attrs = .{},
                });
            }
        }
    }

    pub const widget_vtable = Widget.VTable{
        .measureFn = measure,
        .renderFn = render,
    };
};

test "ScrollView init" {
    var child = TestWidget{ .char = 'X', .width = 100, .height = 50 };
    const child_widget = Widget.Widget.init(TestWidget, &child);

    const scroll = ScrollView.init(child_widget);
    try std.testing.expect(scroll.show_vertical);
    try std.testing.expect(!scroll.show_horizontal);
    try std.testing.expectEqual(@as(u16, 0), scroll.scroll_x);
    try std.testing.expectEqual(@as(u16, 0), scroll.scroll_y);
}

test "ScrollView withContentSize" {
    var child = TestWidget{ .char = 'X', .width = 10, .height = 10 };
    const child_widget = Widget.Widget.init(TestWidget, &child);

    var scroll = ScrollView.init(child_widget);
    _ = scroll.withContentSize(200, 100);

    try std.testing.expectEqual(@as(u16, 200), scroll.content_width);
    try std.testing.expectEqual(@as(u16, 100), scroll.content_height);
}

test "ScrollView scrollTo" {
    var child = TestWidget{ .char = 'X', .width = 100, .height = 50 };
    const child_widget = Widget.Widget.init(TestWidget, &child);

    var scroll = ScrollView.init(child_widget);
    _ = scroll.withContentSize(100, 50);
    scroll.scrollTo(10, 20);

    try std.testing.expectEqual(@as(u16, 10), scroll.scroll_x);
    try std.testing.expectEqual(@as(u16, 20), scroll.scroll_y);
}

test "ScrollView scrollBy positive" {
    var child = TestWidget{ .char = 'X', .width = 100, .height = 50 };
    const child_widget = Widget.Widget.init(TestWidget, &child);

    var scroll = ScrollView.init(child_widget);
    _ = scroll.withContentSize(100, 50);
    scroll.scrollBy(5, 10);

    try std.testing.expectEqual(@as(u16, 5), scroll.scroll_x);
    try std.testing.expectEqual(@as(u16, 10), scroll.scroll_y);
}

test "ScrollView scrollBy negative" {
    var child = TestWidget{ .char = 'X', .width = 100, .height = 50 };
    const child_widget = Widget.Widget.init(TestWidget, &child);

    var scroll = ScrollView.init(child_widget);
    _ = scroll.withContentSize(100, 50);
    scroll.scroll_x = 20;
    scroll.scroll_y = 30;
    scroll.scrollBy(-5, -10);

    try std.testing.expectEqual(@as(u16, 15), scroll.scroll_x);
    try std.testing.expectEqual(@as(u16, 20), scroll.scroll_y);
}

test "ScrollView render draws scrollbar" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 21, .height = 10 });
    defer root.deinit();

    var child = TestWidget{ .char = 'X', .width = 100, .height = 100 };
    const child_widget = Widget.Widget.init(TestWidget, &child);

    var scroll = ScrollView.init(child_widget);
    _ = scroll.withContentSize(100, 100);

    var view = PlaneView.init(root);
    const widget = Widget.Widget.init(ScrollView, &scroll);
    widget.render(&view);

    // Scrollbar should be at the right edge (column 20)
    // Should have scrollbar characters
    const scrollbar_cell = view.getCell(20, 0).?;
    // Should be either track or thumb
    try std.testing.expect(scrollbar_cell.char == default_scrollbar.track or
        scrollbar_cell.char == default_scrollbar.thumb);
}

test "ScrollView keyboard event handling" {
    var child = TestWidget{ .char = 'X', .width = 100, .height = 100 };
    const child_widget = Widget.Widget.init(TestWidget, &child);

    var scroll = ScrollView.init(child_widget);
    _ = scroll.withContentSize(100, 100);

    const widget = Widget.Widget.init(ScrollView, &scroll);

    // Test down key
    const down_event = Event.Event{ .key = Event.Key.fromCodepoint(Event.Key.down, Event.Modifiers.none) };
    const result = widget.handleEvent(down_event);
    try std.testing.expectEqual(Widget.EventResult.consumed, result);
    try std.testing.expectEqual(@as(u16, 1), scroll.scroll_y);
}

test "ScrollView measure uses available space" {
    var child = TestWidget{ .char = 'X', .width = 100, .height = 100 };
    const child_widget = Widget.Widget.init(TestWidget, &child);

    const scroll = ScrollView.init(child_widget);
    var scroll_mut = scroll;
    const widget = Widget.Widget.init(ScrollView, &scroll_mut);

    const size = widget.measure(Widget.SizeConstraint.atMost(50, 30));

    try std.testing.expectEqual(@as(u16, 50), size.width);
    try std.testing.expectEqual(@as(u16, 30), size.height);
}
