//! Diff: Side-by-side or unified diff view widget
//!
//! A widget for displaying differences between two texts,
//! similar to git diff output.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const Event = @import("../Event.zig");

/// Type of diff line
pub const LineType = enum {
    context,
    addition,
    deletion,
    header,
    hunk,
};

/// A single diff line
pub const DiffLine = struct {
    /// Line type
    line_type: LineType = .context,
    /// Left line number (null for additions)
    left_num: ?usize = null,
    /// Right line number (null for deletions)
    right_num: ?usize = null,
    /// Line content
    content: []const u8,
};

/// Diff view mode
pub const DiffMode = enum {
    unified,
    side_by_side,
};

/// Diff widget
pub const Diff = struct {
    /// Diff lines
    lines: []const DiffLine,
    /// Display mode
    mode: DiffMode = .unified,
    /// Scroll offset
    scroll_offset: usize = 0,
    /// Selected line
    selected_line: usize = 0,
    /// Visible height
    visible_height: u16 = 20,
    /// Show line numbers
    show_line_numbers: bool = true,
    /// Context line style
    context_style: Style = .{},
    /// Addition style (green background)
    addition_style: Style = .{ .fg = .{ .index = 2 } },
    /// Deletion style (red background)
    deletion_style: Style = .{ .fg = .{ .index = 1 } },
    /// Header style
    header_style: Style = .{ .attrs = .{ .bold = true } },
    /// Hunk header style
    hunk_style: Style = .{ .fg = .{ .index = 6 } }, // Cyan
    /// Selected line style
    selected_style: Style = .{ .attrs = .{ .reverse = true } },
    /// Line number style
    line_num_style: Style = .{ .fg = .{ .index = 8 } }, // Gray
    /// Widget state
    widget_state: Widget.WidgetState = .{},
    /// Callback context
    callback_ctx: ?*anyopaque = null,
    /// Called when selection changes
    on_select: ?*const fn (ctx: ?*anyopaque, line: usize) void = null,

    /// Create a diff widget
    pub fn init(lines: []const DiffLine) Diff {
        return .{ .lines = lines };
    }

    // Builder methods

    /// Set display mode
    pub fn withMode(self: *Diff, mode: DiffMode) *Diff {
        self.mode = mode;
        return self;
    }

    /// Set visible height
    pub fn withHeight(self: *Diff, height: u16) *Diff {
        self.visible_height = height;
        return self;
    }

    /// Set show line numbers
    pub fn withLineNumbers(self: *Diff, show: bool) *Diff {
        self.show_line_numbers = show;
        return self;
    }

    /// Set addition style
    pub fn withAdditionStyle(self: *Diff, style: Style) *Diff {
        self.addition_style = style;
        return self;
    }

    /// Set deletion style
    pub fn withDeletionStyle(self: *Diff, style: Style) *Diff {
        self.deletion_style = style;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *Diff, state: Widget.WidgetState) *Diff {
        self.widget_state = state;
        return self;
    }

    /// Set selection callback
    pub fn withOnSelect(self: *Diff, callback: *const fn (ctx: ?*anyopaque, line: usize) void, ctx: ?*anyopaque) *Diff {
        self.on_select = callback;
        self.callback_ctx = ctx;
        return self;
    }

    // Navigation methods

    /// Scroll up
    pub fn scrollUp(self: *Diff) void {
        if (self.selected_line > 0) {
            self.selected_line -= 1;
            self.ensureVisible();
            self.notifySelect();
        }
    }

    /// Scroll down
    pub fn scrollDown(self: *Diff) void {
        if (self.selected_line + 1 < self.lines.len) {
            self.selected_line += 1;
            self.ensureVisible();
            self.notifySelect();
        }
    }

    /// Go to first line
    pub fn goToFirst(self: *Diff) void {
        self.selected_line = 0;
        self.scroll_offset = 0;
        self.notifySelect();
    }

    /// Go to last line
    pub fn goToLast(self: *Diff) void {
        if (self.lines.len > 0) {
            self.selected_line = self.lines.len - 1;
            self.ensureVisible();
            self.notifySelect();
        }
    }

    /// Go to next hunk
    pub fn nextHunk(self: *Diff) void {
        var i = self.selected_line + 1;
        while (i < self.lines.len) : (i += 1) {
            if (self.lines[i].line_type == .hunk) {
                self.selected_line = i;
                self.ensureVisible();
                self.notifySelect();
                return;
            }
        }
    }

    /// Go to previous hunk
    pub fn prevHunk(self: *Diff) void {
        if (self.selected_line == 0) return;
        var i = self.selected_line - 1;
        while (i > 0) : (i -= 1) {
            if (self.lines[i].line_type == .hunk) {
                self.selected_line = i;
                self.ensureVisible();
                self.notifySelect();
                return;
            }
        }
        if (self.lines[0].line_type == .hunk) {
            self.selected_line = 0;
            self.ensureVisible();
            self.notifySelect();
        }
    }

    /// Go to next change (addition or deletion)
    pub fn nextChange(self: *Diff) void {
        var i = self.selected_line + 1;
        while (i < self.lines.len) : (i += 1) {
            const lt = self.lines[i].line_type;
            if (lt == .addition or lt == .deletion) {
                self.selected_line = i;
                self.ensureVisible();
                self.notifySelect();
                return;
            }
        }
    }

    /// Go to previous change
    pub fn prevChange(self: *Diff) void {
        if (self.selected_line == 0) return;
        var i = self.selected_line - 1;
        while (i > 0) : (i -= 1) {
            const lt = self.lines[i].line_type;
            if (lt == .addition or lt == .deletion) {
                self.selected_line = i;
                self.ensureVisible();
                self.notifySelect();
                return;
            }
        }
        const lt = self.lines[0].line_type;
        if (lt == .addition or lt == .deletion) {
            self.selected_line = 0;
            self.ensureVisible();
            self.notifySelect();
        }
    }

    /// Get selected line
    pub fn selectedLine(self: *const Diff) ?DiffLine {
        if (self.selected_line < self.lines.len) {
            return self.lines[self.selected_line];
        }
        return null;
    }

    /// Get statistics
    pub fn stats(self: *const Diff) struct { additions: usize, deletions: usize, hunks: usize } {
        var additions: usize = 0;
        var deletions: usize = 0;
        var hunks: usize = 0;
        for (self.lines) |line| {
            switch (line.line_type) {
                .addition => additions += 1,
                .deletion => deletions += 1,
                .hunk => hunks += 1,
                else => {},
            }
        }
        return .{ .additions = additions, .deletions = deletions, .hunks = hunks };
    }

    fn ensureVisible(self: *Diff) void {
        if (self.selected_line < self.scroll_offset) {
            self.scroll_offset = self.selected_line;
        } else if (self.selected_line >= self.scroll_offset + self.visible_height) {
            self.scroll_offset = self.selected_line - self.visible_height + 1;
        }
    }

    fn notifySelect(self: *Diff) void {
        if (self.on_select) |callback| {
            callback(self.callback_ctx, self.selected_line);
        }
    }

    // Widget interface

    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Diff = @ptrCast(@alignCast(ptr));
        return .{
            .width = constraint.max_width,
            .height = @min(self.visible_height, constraint.max_height),
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Diff = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0) return;

        switch (self.mode) {
            .unified => renderUnified(self, view, size),
            .side_by_side => renderSideBySide(self, view, size),
        }
    }

    fn renderUnified(self: *Diff, view: *PlaneView, size: Event.Size) void {
        const visible_count = @min(self.lines.len -| self.scroll_offset, size.height);

        for (0..visible_count) |i| {
            const line_idx = self.scroll_offset + i;
            const line = self.lines[line_idx];
            const y: i32 = @intCast(i);
            const is_selected = line_idx == self.selected_line;

            // Get style for line type
            var style = switch (line.line_type) {
                .context => self.context_style,
                .addition => self.addition_style,
                .deletion => self.deletion_style,
                .header => self.header_style,
                .hunk => self.hunk_style,
            };

            if (is_selected) {
                style = self.selected_style;
            }

            // Clear line
            for (0..size.width) |x| {
                view.setCell(@intCast(x), y, Cell.simple(' ', style.fg, style.bg));
            }

            var x: u16 = 0;

            // Line numbers
            if (self.show_line_numbers and line.line_type != .header and line.line_type != .hunk) {
                var num_buf: [16]u8 = undefined;

                // Left number
                if (line.left_num) |num| {
                    const num_str = std.fmt.bufPrint(&num_buf, "{d:>4}", .{num}) catch "????";
                    view.print(@intCast(x), y, num_str, self.line_num_style.fg, style.bg, .{});
                } else {
                    view.print(@intCast(x), y, "    ", self.line_num_style.fg, style.bg, .{});
                }
                x += 4;

                view.setCell(@intCast(x), y, Cell.simple(' ', style.fg, style.bg));
                x += 1;

                // Right number
                if (line.right_num) |num| {
                    const num_str = std.fmt.bufPrint(&num_buf, "{d:>4}", .{num}) catch "????";
                    view.print(@intCast(x), y, num_str, self.line_num_style.fg, style.bg, .{});
                } else {
                    view.print(@intCast(x), y, "    ", self.line_num_style.fg, style.bg, .{});
                }
                x += 4;

                view.setCell(@intCast(x), y, Cell.simple(' ', style.fg, style.bg));
                x += 1;
            }

            // Line prefix
            const prefix: u21 = switch (line.line_type) {
                .addition => '+',
                .deletion => '-',
                .context => ' ',
                .header, .hunk => ' ',
            };
            if (line.line_type != .header and line.line_type != .hunk) {
                view.setCell(@intCast(x), y, Cell.simple(prefix, style.fg, style.bg));
                x += 1;
            }

            // Content
            const available = size.width -| x;
            const content_len = @min(line.content.len, available);
            if (content_len > 0) {
                view.print(@intCast(x), y, line.content[0..content_len], style.fg, style.bg, style.attrs);
            }
        }

        // Fill remaining lines
        for (visible_count..size.height) |i| {
            const y: i32 = @intCast(i);
            for (0..size.width) |x_| {
                view.setCell(@intCast(x_), y, Cell.simple(' ', self.context_style.fg, self.context_style.bg));
            }
        }
    }

    fn renderSideBySide(self: *Diff, view: *PlaneView, size: Event.Size) void {
        const half_width = size.width / 2;
        const visible_count = @min(self.lines.len -| self.scroll_offset, size.height);

        for (0..visible_count) |i| {
            const line_idx = self.scroll_offset + i;
            const line = self.lines[line_idx];
            const y: i32 = @intCast(i);
            const is_selected = line_idx == self.selected_line;

            var style = switch (line.line_type) {
                .context => self.context_style,
                .addition => self.addition_style,
                .deletion => self.deletion_style,
                .header => self.header_style,
                .hunk => self.hunk_style,
            };

            if (is_selected) {
                style = self.selected_style;
            }

            // Clear line
            for (0..size.width) |x| {
                view.setCell(@intCast(x), y, Cell.simple(' ', self.context_style.fg, self.context_style.bg));
            }

            // Draw separator
            view.setCell(@intCast(half_width), y, Cell.simple('│', self.context_style.fg, self.context_style.bg));

            switch (line.line_type) {
                .header, .hunk => {
                    // Span both sides
                    const content_len = @min(line.content.len, size.width);
                    if (content_len > 0) {
                        view.print(0, y, line.content[0..content_len], style.fg, style.bg, style.attrs);
                    }
                },
                .context => {
                    // Show on both sides
                    const available = half_width -| 1;
                    const content_len = @min(line.content.len, available);
                    if (content_len > 0) {
                        view.print(0, y, line.content[0..content_len], style.fg, style.bg, style.attrs);
                        view.print(@intCast(half_width + 1), y, line.content[0..content_len], style.fg, style.bg, style.attrs);
                    }
                },
                .deletion => {
                    // Left side only
                    const available = half_width -| 1;
                    const content_len = @min(line.content.len, available);
                    if (content_len > 0) {
                        view.print(0, y, line.content[0..content_len], style.fg, style.bg, style.attrs);
                    }
                },
                .addition => {
                    // Right side only
                    const available = half_width -| 1;
                    const content_len = @min(line.content.len, available);
                    if (content_len > 0) {
                        view.print(@intCast(half_width + 1), y, line.content[0..content_len], style.fg, style.bg, style.attrs);
                    }
                },
            }
        }

        // Fill remaining lines
        for (visible_count..size.height) |i| {
            const y: i32 = @intCast(i);
            for (0..size.width) |x_| {
                view.setCell(@intCast(x_), y, Cell.simple(' ', self.context_style.fg, self.context_style.bg));
            }
        }
    }

    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *Diff = @ptrCast(@alignCast(ptr));

        if (self.widget_state.disabled or !self.widget_state.focused) {
            return .ignored;
        }

        switch (event) {
            .key => |key| {
                if (key.special) |special| {
                    switch (special) {
                        .up => {
                            self.scrollUp();
                            return .consumed;
                        },
                        .down => {
                            self.scrollDown();
                            return .consumed;
                        },
                        .home => {
                            self.goToFirst();
                            return .consumed;
                        },
                        .end => {
                            self.goToLast();
                            return .consumed;
                        },
                        else => {},
                    }
                }
                if (key.codepoint) |cp| {
                    switch (cp) {
                        'k' => {
                            self.scrollUp();
                            return .consumed;
                        },
                        'j' => {
                            self.scrollDown();
                            return .consumed;
                        },
                        'g' => {
                            self.goToFirst();
                            return .consumed;
                        },
                        'G' => {
                            self.goToLast();
                            return .consumed;
                        },
                        ']' => {
                            self.nextHunk();
                            return .consumed;
                        },
                        '[' => {
                            self.prevHunk();
                            return .consumed;
                        },
                        'n' => {
                            self.nextChange();
                            return .consumed;
                        },
                        'N' => {
                            self.prevChange();
                            return .consumed;
                        },
                        else => {},
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

test "Diff init" {
    const lines = [_]DiffLine{
        .{ .content = "context line", .line_type = .context },
        .{ .content = "added line", .line_type = .addition },
        .{ .content = "removed line", .line_type = .deletion },
    };
    const diff = Diff.init(&lines);
    try std.testing.expectEqual(@as(usize, 3), diff.lines.len);
}

test "Diff navigation" {
    const lines = [_]DiffLine{
        .{ .content = "line 1" },
        .{ .content = "line 2" },
        .{ .content = "line 3" },
    };
    var diff = Diff.init(&lines);

    try std.testing.expectEqual(@as(usize, 0), diff.selected_line);

    diff.scrollDown();
    try std.testing.expectEqual(@as(usize, 1), diff.selected_line);

    diff.scrollDown();
    try std.testing.expectEqual(@as(usize, 2), diff.selected_line);

    diff.scrollUp();
    try std.testing.expectEqual(@as(usize, 1), diff.selected_line);

    diff.goToFirst();
    try std.testing.expectEqual(@as(usize, 0), diff.selected_line);

    diff.goToLast();
    try std.testing.expectEqual(@as(usize, 2), diff.selected_line);
}

test "Diff stats" {
    const lines = [_]DiffLine{
        .{ .content = "@@ -1,3 +1,4 @@", .line_type = .hunk },
        .{ .content = "context", .line_type = .context },
        .{ .content = "added 1", .line_type = .addition },
        .{ .content = "added 2", .line_type = .addition },
        .{ .content = "removed", .line_type = .deletion },
    };
    const diff = Diff.init(&lines);
    const s = diff.stats();

    try std.testing.expectEqual(@as(usize, 2), s.additions);
    try std.testing.expectEqual(@as(usize, 1), s.deletions);
    try std.testing.expectEqual(@as(usize, 1), s.hunks);
}

test "Diff selectedLine" {
    const lines = [_]DiffLine{
        .{ .content = "first", .line_type = .context },
        .{ .content = "second", .line_type = .addition },
    };
    var diff = Diff.init(&lines);

    const first = diff.selectedLine();
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("first", first.?.content);

    diff.scrollDown();
    const second = diff.selectedLine();
    try std.testing.expectEqual(LineType.addition, second.?.line_type);
}

test "Diff measure" {
    const lines = [_]DiffLine{
        .{ .content = "line" },
    };
    var diff = Diff.init(&lines);
    _ = diff.withHeight(15);

    const widget = Widget.Widget.init(Diff, &diff);
    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));

    try std.testing.expectEqual(@as(u16, 80), measured.width);
    try std.testing.expectEqual(@as(u16, 15), measured.height);
}

test "Diff handleEvent down" {
    const lines = [_]DiffLine{
        .{ .content = "a" },
        .{ .content = "b" },
    };
    var diff = Diff.init(&lines);
    _ = diff.withState(.{ .focused = true });

    const widget = Widget.Widget.init(Diff, &diff);
    const event = Event.Event{ .key = Event.Key.fromSpecial(.down, .{}) };

    const result = widget.handleEvent(event);
    try std.testing.expectEqual(Widget.EventResult.consumed, result);
    try std.testing.expectEqual(@as(usize, 1), diff.selected_line);
}

test "Diff render unified" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 40, .height = 5 });
    defer root.deinit();

    const lines = [_]DiffLine{
        .{ .content = "+added", .line_type = .addition, .right_num = 1 },
    };
    var diff = Diff.init(&lines);

    const widget = Widget.Widget.init(Diff, &diff);
    var view = PlaneView.init(root);
    widget.render(&view);

    // The '+' prefix should be visible after line numbers
    try std.testing.expectEqual(@as(u21, '+'), view.getCell(10, 0).?.char);
}

test "Diff mode" {
    const lines = [_]DiffLine{};
    var diff = Diff.init(&lines);

    try std.testing.expectEqual(DiffMode.unified, diff.mode);

    _ = diff.withMode(.side_by_side);
    try std.testing.expectEqual(DiffMode.side_by_side, diff.mode);
}

test "LineType values" {
    try std.testing.expectEqual(LineType.context, LineType.context);
    try std.testing.expectEqual(LineType.addition, LineType.addition);
    try std.testing.expectEqual(LineType.deletion, LineType.deletion);
    try std.testing.expectEqual(LineType.header, LineType.header);
    try std.testing.expectEqual(LineType.hunk, LineType.hunk);
}
