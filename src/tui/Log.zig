//! Log: Scrollable log output widget
//!
//! A widget for displaying streaming log output with auto-scroll,
//! line limits, and optional timestamps.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const Event = @import("../Event.zig");

/// Log level for styling
pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    pub fn style(self: LogLevel) Style {
        return switch (self) {
            .debug => .{ .fg = .{ .index = 8 } }, // Gray
            .info => .{ .fg = .default },
            .warn => .{ .fg = .{ .index = 3 } }, // Yellow
            .err => .{ .fg = .{ .index = 1 } }, // Red
        };
    }

    pub fn prefix(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "[DBG]",
            .info => "[INF]",
            .warn => "[WRN]",
            .err => "[ERR]",
        };
    }
};

/// A single log entry
pub const LogEntry = struct {
    text: []const u8,
    level: LogLevel = .info,
    owned: bool = false, // Whether we own the text memory
};

/// Log widget
pub const Log = struct {
    /// Log entries
    entries: std.ArrayList(LogEntry),
    /// Memory allocator
    allocator: std.mem.Allocator,
    /// Scroll offset (from bottom, 0 = at bottom)
    scroll_offset: usize = 0,
    /// Maximum entries to keep (0 = unlimited)
    max_entries: usize = 1000,
    /// Auto-scroll to bottom on new entries
    auto_scroll: bool = true,
    /// Show level prefix
    show_level: bool = true,
    /// Visible dimensions
    visible_width: u16 = 80,
    visible_height: u16 = 10,
    /// Default text style
    style: Style = .{},
    /// Widget state
    widget_state: Widget.WidgetState = .{},

    /// Create an empty log
    pub fn init(allocator: std.mem.Allocator) Log {
        return .{
            .entries = std.ArrayList(LogEntry).init(allocator),
            .allocator = allocator,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Log) void {
        for (self.entries.items) |entry| {
            if (entry.owned) {
                self.allocator.free(entry.text);
            }
        }
        self.entries.deinit();
    }

    // Builder methods

    /// Set visible dimensions
    pub fn withSize(self: *Log, width: u16, height: u16) *Log {
        self.visible_width = width;
        self.visible_height = height;
        return self;
    }

    /// Set max entries
    pub fn withMaxEntries(self: *Log, max: usize) *Log {
        self.max_entries = max;
        return self;
    }

    /// Set auto-scroll
    pub fn withAutoScroll(self: *Log, auto: bool) *Log {
        self.auto_scroll = auto;
        return self;
    }

    /// Set show level prefix
    pub fn withShowLevel(self: *Log, show: bool) *Log {
        self.show_level = show;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *Log, state: Widget.WidgetState) *Log {
        self.widget_state = state;
        return self;
    }

    // Content methods

    /// Append a log entry (does not own text)
    pub fn append(self: *Log, text: []const u8, level: LogLevel) !void {
        try self.entries.append(.{ .text = text, .level = level, .owned = false });
        self.pruneIfNeeded();
        if (self.auto_scroll) {
            self.scroll_offset = 0;
        }
    }

    /// Append a log entry (owns text, will free on clear/deinit)
    pub fn appendOwned(self: *Log, text: []const u8, level: LogLevel) !void {
        const owned_text = try self.allocator.dupe(u8, text);
        try self.entries.append(.{ .text = owned_text, .level = level, .owned = true });
        self.pruneIfNeeded();
        if (self.auto_scroll) {
            self.scroll_offset = 0;
        }
    }

    /// Append info level
    pub fn info(self: *Log, text: []const u8) !void {
        try self.appendOwned(text, .info);
    }

    /// Append warning level
    pub fn warn(self: *Log, text: []const u8) !void {
        try self.appendOwned(text, .warn);
    }

    /// Append error level
    pub fn err(self: *Log, text: []const u8) !void {
        try self.appendOwned(text, .err);
    }

    /// Append debug level
    pub fn debug(self: *Log, text: []const u8) !void {
        try self.appendOwned(text, .debug);
    }

    /// Clear all entries
    pub fn clear(self: *Log) void {
        for (self.entries.items) |entry| {
            if (entry.owned) {
                self.allocator.free(entry.text);
            }
        }
        self.entries.clearRetainingCapacity();
        self.scroll_offset = 0;
    }

    /// Get entry count
    pub fn count(self: *const Log) usize {
        return self.entries.items.len;
    }

    fn pruneIfNeeded(self: *Log) void {
        if (self.max_entries == 0) return;

        while (self.entries.items.len > self.max_entries) {
            const removed = self.entries.orderedRemove(0);
            if (removed.owned) {
                self.allocator.free(removed.text);
            }
        }
    }

    // Navigation

    /// Scroll up (towards older entries)
    pub fn scrollUp(self: *Log) void {
        const max_scroll = if (self.entries.items.len > self.visible_height)
            self.entries.items.len - self.visible_height
        else
            0;
        if (self.scroll_offset < max_scroll) {
            self.scroll_offset += 1;
        }
    }

    /// Scroll down (towards newer entries)
    pub fn scrollDown(self: *Log) void {
        if (self.scroll_offset > 0) {
            self.scroll_offset -= 1;
        }
    }

    /// Scroll to bottom (newest)
    pub fn scrollToBottom(self: *Log) void {
        self.scroll_offset = 0;
    }

    /// Scroll to top (oldest)
    pub fn scrollToTop(self: *Log) void {
        if (self.entries.items.len > self.visible_height) {
            self.scroll_offset = self.entries.items.len - self.visible_height;
        }
    }

    // Widget interface

    fn measure(ptr: *anyopaque, _: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Log = @ptrCast(@alignCast(ptr));
        return .{
            .width = self.visible_width,
            .height = self.visible_height,
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Log = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0) return;

        // Calculate which entries to show
        const total = self.entries.items.len;
        const end_idx = if (total > self.scroll_offset) total - self.scroll_offset else 0;
        const start_idx = if (end_idx > size.height) end_idx - size.height else 0;

        var y: u16 = 0;
        var idx = start_idx;
        while (y < size.height and idx < end_idx) : ({
            y += 1;
            idx += 1;
        }) {
            const entry = self.entries.items[idx];
            const entry_style = entry.level.style();

            // Clear line
            var x: i32 = 0;
            while (x < size.width) : (x += 1) {
                view.setCell(x, @intCast(y), .{
                    .char = ' ',
                    .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                    .fg = self.style.fg,
                    .bg = self.style.bg,
                    .attrs = .{},
                });
            }

            var text_x: u16 = 0;

            // Draw level prefix
            if (self.show_level) {
                const prefix = entry.level.prefix();
                view.print(0, @intCast(y), prefix, entry_style.fg, entry_style.bg, entry_style.attrs);
                text_x = @intCast(prefix.len + 1);
            }

            // Draw text
            const available_width = size.width -| text_x;
            const display_len = @min(entry.text.len, available_width);
            if (display_len > 0) {
                view.print(@intCast(text_x), @intCast(y), entry.text[0..display_len], entry_style.fg, entry_style.bg, entry_style.attrs);
            }
        }

        // Fill remaining lines
        while (y < size.height) : (y += 1) {
            var x: i32 = 0;
            while (x < size.width) : (x += 1) {
                view.setCell(x, @intCast(y), .{
                    .char = ' ',
                    .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                    .fg = self.style.fg,
                    .bg = self.style.bg,
                    .attrs = .{},
                });
            }
        }
    }

    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *Log = @ptrCast(@alignCast(ptr));

        if (self.widget_state.disabled) {
            return .ignored;
        }

        switch (event) {
            .key => |key| {
                if (key.special == .up or key.codepoint == 'k') {
                    self.scrollUp();
                    return .consumed;
                } else if (key.special == .down or key.codepoint == 'j') {
                    self.scrollDown();
                    return .consumed;
                } else if (key.special == .home or key.codepoint == 'g') {
                    self.scrollToTop();
                    return .consumed;
                } else if (key.special == .end or key.codepoint == 'G') {
                    self.scrollToBottom();
                    return .consumed;
                }
            },
            .mouse => |mouse| {
                if (mouse.button == .wheel_up) {
                    self.scrollUp();
                    return .consumed;
                } else if (mouse.button == .wheel_down) {
                    self.scrollDown();
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

test "Log init" {
    var log = Log.init(std.testing.allocator);
    defer log.deinit();

    try std.testing.expectEqual(@as(usize, 0), log.count());
}

test "Log append" {
    var log = Log.init(std.testing.allocator);
    defer log.deinit();

    try log.info("First message");
    try log.warn("Second message");

    try std.testing.expectEqual(@as(usize, 2), log.count());
}

test "Log clear" {
    var log = Log.init(std.testing.allocator);
    defer log.deinit();

    try log.info("Message");
    try std.testing.expectEqual(@as(usize, 1), log.count());

    log.clear();
    try std.testing.expectEqual(@as(usize, 0), log.count());
}

test "Log max entries" {
    var log = Log.init(std.testing.allocator);
    defer log.deinit();
    _ = log.withMaxEntries(3);

    try log.info("1");
    try log.info("2");
    try log.info("3");
    try log.info("4");

    try std.testing.expectEqual(@as(usize, 3), log.count());
}

test "Log scroll" {
    var log = Log.init(std.testing.allocator);
    defer log.deinit();
    _ = log.withSize(80, 2);

    try log.info("1");
    try log.info("2");
    try log.info("3");
    try log.info("4");

    // Should start at bottom (scroll_offset = 0)
    try std.testing.expectEqual(@as(usize, 0), log.scroll_offset);

    log.scrollUp();
    try std.testing.expectEqual(@as(usize, 1), log.scroll_offset);

    log.scrollDown();
    try std.testing.expectEqual(@as(usize, 0), log.scroll_offset);
}

test "Log measure" {
    var log = Log.init(std.testing.allocator);
    defer log.deinit();
    _ = log.withSize(60, 15);

    const widget = Widget.Widget.init(Log, &log);
    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));

    try std.testing.expectEqual(@as(u16, 60), measured.width);
    try std.testing.expectEqual(@as(u16, 15), measured.height);
}

test "Log render" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 30, .height = 3 });
    defer root.deinit();

    var log = Log.init(allocator);
    defer log.deinit();

    try log.info("Hello");

    const widget = Widget.Widget.init(Log, &log);

    var view = PlaneView.init(root);
    widget.render(&view);

    // Level prefix should be visible
    try std.testing.expectEqual(@as(u21, '['), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'I'), view.getCell(1, 0).?.char);
}

test "LogLevel styles" {
    try std.testing.expectEqual(Cell.Color{ .index = 8 }, LogLevel.debug.style().fg);
    try std.testing.expectEqual(Cell.Color.default, LogLevel.info.style().fg);
    try std.testing.expectEqual(Cell.Color{ .index = 3 }, LogLevel.warn.style().fg);
    try std.testing.expectEqual(Cell.Color{ .index = 1 }, LogLevel.err.style().fg);
}
