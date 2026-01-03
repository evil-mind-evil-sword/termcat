//! Terminal: Embedded terminal emulator widget
//!
//! A widget for displaying terminal output with ANSI support,
//! scrollback buffer, and input handling. This provides the display
//! layer; PTY management is done at the application level.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const Event = @import("../Event.zig");

/// A line in the terminal buffer
pub const TermLine = struct {
    /// Line cells
    cells: []Cell,
    /// Whether line is dirty (needs redraw)
    dirty: bool = true,
};

/// Terminal widget
pub const Terminal = struct {
    /// Screen buffer (main display area)
    screen: [][]Cell,
    /// Scrollback buffer
    scrollback: std.ArrayList([]Cell),
    /// Memory allocator
    allocator: std.mem.Allocator,
    /// Cursor position (column)
    cursor_x: u16 = 0,
    /// Cursor position (row)
    cursor_y: u16 = 0,
    /// Terminal width
    width: u16,
    /// Terminal height
    height: u16,
    /// Scroll offset (into scrollback, 0 = at bottom)
    scroll_offset: usize = 0,
    /// Maximum scrollback lines
    max_scrollback: usize = 1000,
    /// Current text attributes
    current_style: Style = .{},
    /// Show cursor
    show_cursor: bool = true,
    /// Cursor style
    cursor_style: Style = .{ .attrs = .{ .reverse = true } },
    /// Alternate screen buffer (for vim, etc.)
    alt_screen: ?[][]Cell = null,
    /// Whether using alternate screen
    using_alt_screen: bool = false,
    /// Widget state
    widget_state: Widget.WidgetState = .{},
    /// Callback context
    callback_ctx: ?*anyopaque = null,
    /// Called when input is received
    on_input: ?*const fn (ctx: ?*anyopaque, data: []const u8) void = null,

    /// Create a terminal widget
    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Terminal {
        const screen = try allocator.alloc([]Cell, height);
        errdefer allocator.free(screen);

        for (screen) |*row| {
            row.* = try allocator.alloc(Cell, width);
            for (row.*) |*cell| {
                cell.* = emptyCell();
            }
        }

        return .{
            .screen = screen,
            .scrollback = std.ArrayList([]Cell).init(allocator),
            .allocator = allocator,
            .width = width,
            .height = height,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Terminal) void {
        for (self.screen) |row| {
            self.allocator.free(row);
        }
        self.allocator.free(self.screen);

        for (self.scrollback.items) |row| {
            self.allocator.free(row);
        }
        self.scrollback.deinit();

        if (self.alt_screen) |alt| {
            for (alt) |row| {
                self.allocator.free(row);
            }
            self.allocator.free(alt);
        }
    }

    // Builder methods

    /// Set max scrollback
    pub fn withMaxScrollback(self: *Terminal, max: usize) *Terminal {
        self.max_scrollback = max;
        return self;
    }

    /// Set show cursor
    pub fn withCursor(self: *Terminal, show: bool) *Terminal {
        self.show_cursor = show;
        return self;
    }

    /// Set input callback
    pub fn withOnInput(self: *Terminal, callback: *const fn (ctx: ?*anyopaque, data: []const u8) void, ctx: ?*anyopaque) *Terminal {
        self.on_input = callback;
        self.callback_ctx = ctx;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *Terminal, state: Widget.WidgetState) *Terminal {
        self.widget_state = state;
        return self;
    }

    // Output methods

    /// Write raw text to terminal (handles basic escape sequences)
    pub fn write(self: *Terminal, data: []const u8) void {
        var i: usize = 0;
        while (i < data.len) {
            const c = data[i];

            if (c == 0x1B and i + 1 < data.len) {
                // Escape sequence
                const seq_len = self.parseEscapeSequence(data[i..]);
                if (seq_len > 0) {
                    i += seq_len;
                    continue;
                }
            }

            switch (c) {
                '\n' => self.newline(),
                '\r' => self.cursor_x = 0,
                '\t' => self.tab(),
                '\x08' => { // Backspace
                    if (self.cursor_x > 0) self.cursor_x -= 1;
                },
                '\x07' => {}, // Bell - ignore
                else => {
                    if (c >= 32) {
                        self.putChar(c);
                    }
                },
            }

            i += 1;
        }
    }

    /// Write a string and newline
    pub fn writeLine(self: *Terminal, line: []const u8) void {
        self.write(line);
        self.newline();
    }

    /// Clear the terminal
    pub fn clear(self: *Terminal) void {
        for (self.screen) |row| {
            for (row) |*cell| {
                cell.* = emptyCell();
            }
        }
        self.cursor_x = 0;
        self.cursor_y = 0;
    }

    /// Clear from cursor to end of screen
    pub fn clearToEnd(self: *Terminal) void {
        // Clear rest of current line
        var x = self.cursor_x;
        while (x < self.width) : (x += 1) {
            self.screen[self.cursor_y][x] = emptyCell();
        }
        // Clear remaining lines
        var y = self.cursor_y + 1;
        while (y < self.height) : (y += 1) {
            for (self.screen[y]) |*cell| {
                cell.* = emptyCell();
            }
        }
    }

    /// Clear current line
    pub fn clearLine(self: *Terminal) void {
        for (self.screen[self.cursor_y]) |*cell| {
            cell.* = emptyCell();
        }
        self.cursor_x = 0;
    }

    /// Set cursor position
    pub fn setCursor(self: *Terminal, x: u16, y: u16) void {
        self.cursor_x = @min(x, self.width -| 1);
        self.cursor_y = @min(y, self.height -| 1);
    }

    /// Get cursor position
    pub fn getCursor(self: *const Terminal) struct { x: u16, y: u16 } {
        return .{ .x = self.cursor_x, .y = self.cursor_y };
    }

    // Navigation

    /// Scroll up (view older content)
    pub fn scrollUp(self: *Terminal) void {
        if (self.scroll_offset < self.scrollback.items.len) {
            self.scroll_offset += 1;
        }
    }

    /// Scroll down (view newer content)
    pub fn scrollDown(self: *Terminal) void {
        if (self.scroll_offset > 0) {
            self.scroll_offset -= 1;
        }
    }

    /// Scroll to bottom (current)
    pub fn scrollToBottom(self: *Terminal) void {
        self.scroll_offset = 0;
    }

    /// Scroll to top
    pub fn scrollToTop(self: *Terminal) void {
        self.scroll_offset = self.scrollback.items.len;
    }

    /// Get scrollback length
    pub fn scrollbackLength(self: *const Terminal) usize {
        return self.scrollback.items.len;
    }

    fn putChar(self: *Terminal, c: u8) void {
        if (self.cursor_x >= self.width) {
            self.newline();
        }

        self.screen[self.cursor_y][self.cursor_x] = .{
            .char = c,
            .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
            .fg = self.current_style.fg,
            .bg = self.current_style.bg,
            .attrs = self.current_style.attrs,
        };
        self.cursor_x += 1;
    }

    fn newline(self: *Terminal) void {
        self.cursor_x = 0;
        if (self.cursor_y + 1 >= self.height) {
            self.scrollScreenUp();
        } else {
            self.cursor_y += 1;
        }
    }

    fn tab(self: *Terminal) void {
        const tab_stop = 8;
        const next_tab = ((self.cursor_x / tab_stop) + 1) * tab_stop;
        self.cursor_x = @min(next_tab, self.width -| 1);
    }

    fn scrollScreenUp(self: *Terminal) void {
        // Save top line to scrollback
        if (self.scrollback.items.len >= self.max_scrollback) {
            // Remove oldest scrollback line
            const old = self.scrollback.orderedRemove(0);
            self.allocator.free(old);
        }

        // Clone top line
        const top_line = self.allocator.dupe(Cell, self.screen[0]) catch return;
        self.scrollback.append(top_line) catch {
            self.allocator.free(top_line);
            return;
        };

        // Shift lines up
        for (0..self.height - 1) |y| {
            @memcpy(self.screen[y], self.screen[y + 1]);
        }

        // Clear bottom line
        for (self.screen[self.height - 1]) |*cell| {
            cell.* = emptyCell();
        }
    }

    fn parseEscapeSequence(self: *Terminal, data: []const u8) usize {
        if (data.len < 2) return 0;
        if (data[0] != 0x1B) return 0;

        // CSI sequence
        if (data[1] == '[') {
            return self.parseCSI(data);
        }

        // Simple sequences
        switch (data[1]) {
            'c' => { // Reset
                self.current_style = .{};
                return 2;
            },
            else => return 0,
        }
    }

    fn parseCSI(self: *Terminal, data: []const u8) usize {
        if (data.len < 3) return 0;

        // Find the final byte (letter)
        var end: usize = 2;
        while (end < data.len and end < 32) {
            const c = data[end];
            if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) {
                break;
            }
            end += 1;
        }

        if (end >= data.len) return 0;

        const final_byte = data[end];
        const params = data[2..end];

        switch (final_byte) {
            'm' => { // SGR (Select Graphic Rendition)
                self.parseSGR(params);
            },
            'H', 'f' => { // Cursor position
                var row: u16 = 1;
                var col: u16 = 1;
                if (params.len > 0) {
                    var iter = std.mem.splitScalar(u8, params, ';');
                    if (iter.next()) |r| {
                        row = std.fmt.parseInt(u16, r, 10) catch 1;
                    }
                    if (iter.next()) |c| {
                        col = std.fmt.parseInt(u16, c, 10) catch 1;
                    }
                }
                self.setCursor(col -| 1, row -| 1);
            },
            'J' => { // Erase in display
                const n = if (params.len > 0)
                    std.fmt.parseInt(u8, params, 10) catch 0
                else
                    0;
                switch (n) {
                    0 => self.clearToEnd(),
                    2 => self.clear(),
                    else => {},
                }
            },
            'K' => { // Erase in line
                self.clearLine();
            },
            else => {},
        }

        return end + 1;
    }

    fn parseSGR(self: *Terminal, params: []const u8) void {
        if (params.len == 0) {
            self.current_style = .{};
            return;
        }

        var iter = std.mem.splitScalar(u8, params, ';');
        while (iter.next()) |param| {
            const code = std.fmt.parseInt(u8, param, 10) catch continue;
            switch (code) {
                0 => self.current_style = .{}, // Reset
                1 => self.current_style.attrs.bold = true,
                2 => self.current_style.attrs.dim = true,
                3 => self.current_style.attrs.italic = true,
                4 => self.current_style.attrs.underline = true,
                7 => self.current_style.attrs.reverse = true,
                22 => {
                    self.current_style.attrs.bold = false;
                    self.current_style.attrs.dim = false;
                },
                23 => self.current_style.attrs.italic = false,
                24 => self.current_style.attrs.underline = false,
                27 => self.current_style.attrs.reverse = false,
                30...37 => self.current_style.fg = .{ .index = code - 30 },
                39 => self.current_style.fg = .default,
                40...47 => self.current_style.bg = .{ .index = code - 40 },
                49 => self.current_style.bg = .default,
                90...97 => self.current_style.fg = .{ .index = code - 90 + 8 },
                100...107 => self.current_style.bg = .{ .index = code - 100 + 8 },
                else => {},
            }
        }
    }

    fn emptyCell() Cell {
        return .{
            .char = ' ',
            .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
            .fg = .default,
            .bg = .default,
            .attrs = .{},
        };
    }

    // Widget interface

    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Terminal = @ptrCast(@alignCast(ptr));
        return .{
            .width = @min(self.width, constraint.max_width),
            .height = @min(self.height, constraint.max_height),
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Terminal = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0) return;

        const render_height = @min(self.height, size.height);

        // Render visible portion (considering scroll)
        for (0..render_height) |screen_row| {
            const y: i32 = @intCast(screen_row);

            // Calculate which buffer row to show
            if (self.scroll_offset > 0) {
                // Showing scrollback
                const scrollback_row = self.scrollback.items.len -| self.scroll_offset + screen_row;
                if (scrollback_row < self.scrollback.items.len) {
                    // Render from scrollback
                    const row = self.scrollback.items[scrollback_row];
                    for (0..@min(row.len, size.width)) |x| {
                        view.setCell(@intCast(x), y, row[x]);
                    }
                } else {
                    // Render from screen buffer
                    const buf_row = screen_row - (self.scrollback.items.len - scrollback_row);
                    if (buf_row < self.height) {
                        for (0..@min(self.width, size.width)) |x| {
                            view.setCell(@intCast(x), y, self.screen[buf_row][x]);
                        }
                    }
                }
            } else {
                // Normal view (at bottom)
                if (screen_row < self.height) {
                    for (0..@min(self.width, size.width)) |x| {
                        view.setCell(@intCast(x), y, self.screen[screen_row][x]);
                    }
                }
            }
        }

        // Render cursor
        if (self.show_cursor and self.scroll_offset == 0 and self.widget_state.focused) {
            if (self.cursor_y < size.height and self.cursor_x < size.width) {
                const cursor_cell = self.screen[self.cursor_y][self.cursor_x];
                view.setCell(@intCast(self.cursor_x), @intCast(self.cursor_y), .{
                    .char = cursor_cell.char,
                    .combining = cursor_cell.combining,
                    .fg = self.cursor_style.fg,
                    .bg = self.cursor_style.bg,
                    .attrs = self.cursor_style.attrs,
                });
            }
        }
    }

    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *Terminal = @ptrCast(@alignCast(ptr));

        if (self.widget_state.disabled or !self.widget_state.focused) {
            return .ignored;
        }

        switch (event) {
            .key => |key| {
                // Page up/down for scrolling
                if (key.special) |special| {
                    switch (special) {
                        .page_up => {
                            for (0..self.height) |_| self.scrollUp();
                            return .consumed;
                        },
                        .page_down => {
                            for (0..self.height) |_| self.scrollDown();
                            return .consumed;
                        },
                        else => {},
                    }
                }

                // Forward input to callback
                if (self.on_input) |callback| {
                    if (key.special) |special| {
                        const seq = switch (special) {
                            .up => "\x1B[A",
                            .down => "\x1B[B",
                            .right => "\x1B[C",
                            .left => "\x1B[D",
                            .home => "\x1B[H",
                            .end => "\x1B[F",
                            .delete => "\x1B[3~",
                            .enter => "\r",
                            .tab => "\t",
                            .backspace => "\x7F",
                            else => "",
                        };
                        if (seq.len > 0) {
                            callback(self.callback_ctx, seq);
                            return .consumed;
                        }
                    } else if (key.codepoint) |cp| {
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &buf) catch 0;
                        if (len > 0) {
                            callback(self.callback_ctx, buf[0..len]);
                            return .consumed;
                        }
                    }
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

test "Terminal init" {
    var term = try Terminal.init(std.testing.allocator, 80, 24);
    defer term.deinit();

    try std.testing.expectEqual(@as(u16, 80), term.width);
    try std.testing.expectEqual(@as(u16, 24), term.height);
    try std.testing.expectEqual(@as(u16, 0), term.cursor_x);
    try std.testing.expectEqual(@as(u16, 0), term.cursor_y);
}

test "Terminal write" {
    var term = try Terminal.init(std.testing.allocator, 80, 24);
    defer term.deinit();

    term.write("Hello");
    try std.testing.expectEqual(@as(u16, 5), term.cursor_x);
    try std.testing.expectEqual(@as(u21, 'H'), term.screen[0][0].char);
    try std.testing.expectEqual(@as(u21, 'o'), term.screen[0][4].char);
}

test "Terminal newline" {
    var term = try Terminal.init(std.testing.allocator, 80, 24);
    defer term.deinit();

    term.write("Line1\nLine2");
    try std.testing.expectEqual(@as(u16, 1), term.cursor_y);
    try std.testing.expectEqual(@as(u21, 'L'), term.screen[1][0].char);
}

test "Terminal clear" {
    var term = try Terminal.init(std.testing.allocator, 80, 24);
    defer term.deinit();

    term.write("Test");
    term.clear();

    try std.testing.expectEqual(@as(u16, 0), term.cursor_x);
    try std.testing.expectEqual(@as(u16, 0), term.cursor_y);
    try std.testing.expectEqual(@as(u21, ' '), term.screen[0][0].char);
}

test "Terminal setCursor" {
    var term = try Terminal.init(std.testing.allocator, 80, 24);
    defer term.deinit();

    term.setCursor(10, 5);
    try std.testing.expectEqual(@as(u16, 10), term.cursor_x);
    try std.testing.expectEqual(@as(u16, 5), term.cursor_y);

    // Test clamping
    term.setCursor(100, 50);
    try std.testing.expectEqual(@as(u16, 79), term.cursor_x);
    try std.testing.expectEqual(@as(u16, 23), term.cursor_y);
}

test "Terminal scroll" {
    var term = try Terminal.init(std.testing.allocator, 80, 3);
    defer term.deinit();

    term.writeLine("Line1");
    term.writeLine("Line2");
    term.writeLine("Line3");
    term.writeLine("Line4");

    // Should have scrollback
    try std.testing.expectEqual(@as(usize, 1), term.scrollbackLength());

    term.scrollUp();
    try std.testing.expectEqual(@as(usize, 1), term.scroll_offset);

    term.scrollDown();
    try std.testing.expectEqual(@as(usize, 0), term.scroll_offset);
}

test "Terminal measure" {
    var term = try Terminal.init(std.testing.allocator, 80, 24);
    defer term.deinit();

    const widget = Widget.Widget.init(Terminal, &term);
    const measured = widget.measure(Widget.SizeConstraint.atMost(100, 30));

    try std.testing.expectEqual(@as(u16, 80), measured.width);
    try std.testing.expectEqual(@as(u16, 24), measured.height);
}

test "Terminal render" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 40, .height = 10 });
    defer root.deinit();

    var term = try Terminal.init(allocator, 40, 10);
    defer term.deinit();

    term.write("Hello");

    const widget = Widget.Widget.init(Terminal, &term);
    var view = PlaneView.init(root);
    widget.render(&view);

    try std.testing.expectEqual(@as(u21, 'H'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'e'), view.getCell(1, 0).?.char);
}

test "Terminal ANSI color" {
    var term = try Terminal.init(std.testing.allocator, 80, 24);
    defer term.deinit();

    term.write("\x1B[31mRed\x1B[0m");
    try std.testing.expectEqual(Cell.Color{ .index = 1 }, term.screen[0][0].fg); // Red
    try std.testing.expectEqual(Cell.Color.default, term.current_style.fg); // Reset
}

test "Terminal ANSI bold" {
    var term = try Terminal.init(std.testing.allocator, 80, 24);
    defer term.deinit();

    term.write("\x1B[1mBold");
    try std.testing.expect(term.screen[0][0].attrs.bold);
}

test "Terminal ANSI cursor position" {
    var term = try Terminal.init(std.testing.allocator, 80, 24);
    defer term.deinit();

    term.write("\x1B[5;10H"); // Row 5, Col 10
    try std.testing.expectEqual(@as(u16, 9), term.cursor_x); // 0-indexed
    try std.testing.expectEqual(@as(u16, 4), term.cursor_y);
}

test "Terminal tab" {
    var term = try Terminal.init(std.testing.allocator, 80, 24);
    defer term.deinit();

    term.write("A\tB");
    try std.testing.expectEqual(@as(u21, 'A'), term.screen[0][0].char);
    try std.testing.expectEqual(@as(u21, 'B'), term.screen[0][8].char);
}
