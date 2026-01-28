//! ConsoleOverlay: Toggleable log console overlay with preallocated storage.
//!
//! Designed for zero allocations per log append in steady-state by using
//! fixed-size entry slots and a ring buffer.

const std = @import("std");
const builtin = @import("builtin");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Event = @import("../Event.zig");
const Cell = @import("../Cell.zig");
const Layout = @import("../Layout.zig");
const Style = @import("Theme.zig").Style;
const LogLevel = @import("Log.zig").LogLevel;

pub const CopyHandler = *const fn (ctx: ?*anyopaque, text: []const u8) void;

pub const Position = enum {
    top,
    bottom,
    left,
    right,
};

pub const Options = struct {
    /// Maximum number of entries retained in the ring.
    max_entries: usize = 500,
    /// Maximum byte length per entry (truncated if exceeded).
    max_entry_len: usize = 512,
    /// Overlay size as a percent of the terminal dimension.
    size_percent: u8 = 30,
    /// Minimum allowed size percent.
    min_size_percent: u8 = 10,
    /// Maximum allowed size percent.
    max_size_percent: u8 = 80,
    /// Size change step for +/- keys.
    size_step_percent: u8 = 5,
    /// Overlay position (top/bottom/left/right).
    position: Position = .bottom,
    /// Show log level prefixes.
    show_level: bool = true,
    /// Auto-scroll to bottom on new entries.
    auto_scroll: bool = true,
    /// Start visible.
    start_visible: bool = false,
    /// Start focused (only applies if start_visible is true).
    start_focused: bool = false,
    /// Toggle key (default: F12).
    toggle_key: Event.Key = Event.Key.fromSpecial(.f12, .{}),
    /// Panel background style.
    panel_style: Style = .{ .fg = .default, .bg = .{ .index = 0 } },
    /// Border style (applies to box and title).
    border_style: Style = .{ .fg = .{ .index = 8 } },
    /// Additional style when focused.
    border_focused_style: Style = .{ .attrs = .{ .bold = true } },
    /// Log level styles (debug, info, warn, err).
    level_styles: [4]Style = defaultLevelStyles(),
    /// Border box style.
    box_style: Layout.BoxStyle = Layout.BoxStyle.ascii,
    /// Title text in the border.
    title: []const u8 = "Console",
    /// Selection highlight style.
    selection_style: Style = .{ .attrs = .{ .reverse = true } },
    /// Key used to copy selected text.
    copy_key: Event.Key = Event.Key.fromCodepoint('c', .{ .ctrl = true }),
    /// Optional selection copy handler.
    on_copy: ?CopyHandler = null,
    /// Context for the selection copy handler.
    copy_ctx: ?*anyopaque = null,
};

pub const ConsoleOverlay = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    text_storage: []u8,
    entry_head: usize = 0,
    entry_count: usize = 0,
    scroll_offset: usize = 0,
    max_entry_len: usize,
    max_entries: usize,
    size_percent: u8,
    min_size_percent: u8,
    max_size_percent: u8,
    size_step_percent: u8,
    position: Position,
    show_level: bool,
    auto_scroll: bool,
    visible: bool,
    focused: bool,
    toggle_key: Event.Key,
    panel_style: Style,
    border_style: Style,
    border_focused_style: Style,
    level_styles: [4]Style,
    box_style: Layout.BoxStyle,
    title: []const u8,
    selection_style: Style,
    copy_key: Event.Key,
    on_copy: ?CopyHandler,
    copy_ctx: ?*anyopaque,
    last_rect: ?Event.Rect = null,
    last_content_rect: ?Event.Rect = null,
    last_content_lines: u16 = 0,
    selection_anchor: ?SelectionPoint = null,
    selection_focus: ?SelectionPoint = null,
    selection: ?SelectionRange = null,
    dragging: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: Options) !ConsoleOverlay {
        const max_entries = @max(options.max_entries, 1);
        const max_entry_len = @max(options.max_entry_len, 1);

        const entries = try allocator.alloc(Entry, max_entries);
        errdefer allocator.free(entries);

        const text_storage = try allocator.alloc(u8, max_entries * max_entry_len);
        errdefer allocator.free(text_storage);

        const visible = options.start_visible;
        const focused = visible and options.start_focused;

        return .{
            .allocator = allocator,
            .entries = entries,
            .text_storage = text_storage,
            .max_entry_len = max_entry_len,
            .max_entries = max_entries,
            .size_percent = options.size_percent,
            .min_size_percent = options.min_size_percent,
            .max_size_percent = options.max_size_percent,
            .size_step_percent = options.size_step_percent,
            .position = options.position,
            .show_level = options.show_level,
            .auto_scroll = options.auto_scroll,
            .visible = visible,
            .focused = focused,
            .toggle_key = options.toggle_key,
            .panel_style = options.panel_style,
            .border_style = options.border_style,
            .border_focused_style = options.border_focused_style,
            .level_styles = options.level_styles,
            .box_style = options.box_style,
            .title = options.title,
            .selection_style = options.selection_style,
            .copy_key = options.copy_key,
            .on_copy = options.on_copy,
            .copy_ctx = options.copy_ctx,
        };
    }

    pub fn deinit(self: *ConsoleOverlay) void {
        self.allocator.free(self.entries);
        self.allocator.free(self.text_storage);
        self.* = undefined;
    }

    pub fn isVisible(self: *const ConsoleOverlay) bool {
        return self.visible;
    }

    pub fn isFocused(self: *const ConsoleOverlay) bool {
        return self.focused;
    }

    pub fn setVisible(self: *ConsoleOverlay, visible: bool) void {
        self.visible = visible;
        if (!visible) self.focused = false;
    }

    pub fn setFocused(self: *ConsoleOverlay, focused: bool) void {
        if (self.visible) {
            self.focused = focused;
        }
    }

    pub fn toggle(self: *ConsoleOverlay) void {
        if (!self.visible) {
            self.visible = true;
            self.focused = true;
            if (self.auto_scroll) self.scroll_offset = 0;
            return;
        }

        if (!self.focused) {
            self.focused = true;
            return;
        }

        self.visible = false;
        self.focused = false;
    }

    pub fn clear(self: *ConsoleOverlay) void {
        self.entry_head = 0;
        self.entry_count = 0;
        self.scroll_offset = 0;
        self.clearSelection();
    }

    pub fn append(self: *ConsoleOverlay, level: LogLevel, text: []const u8) void {
        if (self.entry_count == self.max_entries) {
            self.clearSelection();
        }
        const slot = self.textSlot(self.entry_head);
        const len = @min(slot.len, text.len);
        if (len > 0) {
            std.mem.copy(u8, slot[0..len], text[0..len]);
        }

        self.entries[self.entry_head] = .{
            .len = len,
            .level = level,
            .truncated = text.len > len,
        };

        self.entry_head = (self.entry_head + 1) % self.max_entries;
        if (self.entry_count < self.max_entries) {
            self.entry_count += 1;
        }

        if (self.auto_scroll) {
            self.scroll_offset = 0;
        } else {
            self.scroll_offset = @min(self.scroll_offset, self.maxScroll());
        }
    }

    pub fn appendFmt(self: *ConsoleOverlay, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        var buf: [MAX_LOG_LINE]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.append(level, msg);
    }

    pub fn debug(self: *ConsoleOverlay, text: []const u8) void {
        self.append(.debug, text);
    }

    pub fn info(self: *ConsoleOverlay, text: []const u8) void {
        self.append(.info, text);
    }

    pub fn warn(self: *ConsoleOverlay, text: []const u8) void {
        self.append(.warn, text);
    }

    pub fn err(self: *ConsoleOverlay, text: []const u8) void {
        self.append(.err, text);
    }

    pub fn scrollUp(self: *ConsoleOverlay) void {
        const max_scroll = self.maxScroll();
        if (self.scroll_offset < max_scroll) {
            self.scroll_offset += 1;
        }
    }

    pub fn scrollDown(self: *ConsoleOverlay) void {
        if (self.scroll_offset > 0) {
            self.scroll_offset -= 1;
        }
    }

    pub fn scrollToBottom(self: *ConsoleOverlay) void {
        self.scroll_offset = 0;
    }

    pub fn scrollToTop(self: *ConsoleOverlay) void {
        self.scroll_offset = self.maxScroll();
    }

    pub fn layoutRect(self: *const ConsoleOverlay, size: Event.Size) Event.Rect {
        if (size.width == 0 or size.height == 0) {
            return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        }

        const min_percent = @min(self.min_size_percent, self.max_size_percent);
        const max_percent = @max(self.min_size_percent, self.max_size_percent);
        const percent = @min(@max(self.size_percent, min_percent), max_percent);

        switch (self.position) {
            .top, .bottom => {
                const height = @max(@as(u16, 1), @as(u16, @intCast((@as(u32, size.height) * percent) / 100)));
                const y = if (self.position == .bottom) size.height -| height else 0;
                return .{ .x = 0, .y = y, .width = size.width, .height = height };
            },
            .left, .right => {
                const width = @max(@as(u16, 1), @as(u16, @intCast((@as(u32, size.width) * percent) / 100)));
                const x = if (self.position == .right) size.width -| width else 0;
                return .{ .x = x, .y = 0, .width = width, .height = size.height };
            },
        }
    }

    pub fn setCopyHandler(self: *ConsoleOverlay, ctx: ?*anyopaque, handler: ?CopyHandler) void {
        self.copy_ctx = ctx;
        self.on_copy = handler;
    }

    pub fn selectionText(self: *ConsoleOverlay, allocator: std.mem.Allocator) !?[]u8 {
        const selection = self.selection orelse return null;
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        var line_idx = selection.start.line;
        while (line_idx <= selection.end.line) : (line_idx += 1) {
            const entry_view = self.entryView(line_idx);
            const entry = entry_view.entry;
            const line_len = self.lineDisplayLen(entry);
            const start_col: usize = if (line_idx == selection.start.line) selection.start.col else 0;
            const end_col: usize = if (line_idx == selection.end.line) selection.end.col else line_len;
            if (start_col < end_col) {
                try self.appendLineSegment(&buffer, entry_view, start_col, end_col);
            }
            if (line_idx != selection.end.line) {
                try buffer.append('\n');
            }
        }

        return buffer.toOwnedSlice();
    }

    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *ConsoleOverlay = @ptrCast(@alignCast(ptr));
        _ = self;
        return .{ .width = constraint.max_width, .height = constraint.max_height };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *ConsoleOverlay = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0) {
            self.clearLastRect(view);
            return;
        }

        if (!self.visible) {
            self.clearLastRect(view);
            return;
        }

        const rect = self.layoutRect(size);
        if (rect.width == 0 or rect.height == 0) {
            self.clearLastRect(view);
            return;
        }

        if (self.last_rect) |last| {
            if (!rectEql(last, rect)) {
                clearRect(view, last);
            }
        }
        self.last_rect = rect;
        self.last_content_rect = null;

        var overlay_view = view.subView(rect);
        overlay_view.fill(Cell.styled(' ', self.panel_style.fg, self.panel_style.bg, self.panel_style.attrs));

        if (rect.width < 2 or rect.height < 2) {
            self.last_content_lines = rect.height;
            self.last_content_rect = rect;
            self.renderEntries(&overlay_view, overlay_view.size());
            return;
        }

        var border_style = self.border_style;
        if (self.focused) {
            border_style = border_style.merge(self.border_focused_style);
        }

        drawBorder(&overlay_view, rect, self.box_style, border_style, self.title);

        const content_width = rect.width -| 2;
        const content_height = rect.height -| 2;
        if (content_width == 0 or content_height == 0) {
            self.last_content_lines = 0;
            return;
        }
        self.last_content_lines = content_height;

        const content_rect = Event.Rect{ .x = rect.x + 1, .y = rect.y + 1, .width = content_width, .height = content_height };
        self.last_content_rect = content_rect;

        var content_view = overlay_view.subView(.{ .x = 1, .y = 1, .width = content_width, .height = content_height });
        self.renderEntries(&content_view, content_view.size());
    }

    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *ConsoleOverlay = @ptrCast(@alignCast(ptr));

        switch (event) {
            .key => |key| {
                if (keysMatch(self.toggle_key, key)) {
                    self.toggle();
                    return .consumed;
                }

                if (!self.visible) return .ignored;

                if (!self.focused) {
                    return .ignored;
                }

                if (keysMatch(self.copy_key, key)) {
                    self.copySelection();
                    return .consumed;
                }

                if (key.codepoint) |cp| {
                    if (cp == '+' or cp == '=') {
                        self.increaseSize();
                        return .consumed;
                    } else if (cp == '-') {
                        self.decreaseSize();
                        return .consumed;
                    } else if (cp == 'k') {
                        self.scrollUp();
                        return .consumed;
                    } else if (cp == 'j') {
                        self.scrollDown();
                        return .consumed;
                    } else if (cp == 'g') {
                        self.scrollToTop();
                        return .consumed;
                    } else if (cp == 'G') {
                        self.scrollToBottom();
                        return .consumed;
                    }
                }

                if (key.special) |sp| {
                    if (sp == .up) {
                        self.scrollUp();
                        return .consumed;
                    } else if (sp == .down) {
                        self.scrollDown();
                        return .consumed;
                    } else if (sp == .page_up) {
                        self.pageUp();
                        return .consumed;
                    } else if (sp == .page_down) {
                        self.pageDown();
                        return .consumed;
                    } else if (sp == .home) {
                        self.scrollToTop();
                        return .consumed;
                    } else if (sp == .end) {
                        self.scrollToBottom();
                        return .consumed;
                    } else if (sp == .escape) {
                        if (self.selection != null) {
                            self.clearSelection();
                            return .consumed;
                        }
                    }
                }
            },
            .mouse => |mouse| {
                if (!self.visible) return .ignored;
                if (!self.isMouseInside(mouse.x, mouse.y)) {
                    if (mouse.button == .release) {
                        self.dragging = false;
                    }
                    return .ignored;
                }
                self.focused = true;
                if (mouse.button == .left) {
                    if (self.selectionPointFromMouse(mouse)) |point| {
                        self.startSelection(point);
                        self.dragging = true;
                    }
                    return .consumed;
                } else if (mouse.button == .move) {
                    if (self.dragging) {
                        if (self.selectionPointFromMouse(mouse)) |point| {
                            self.updateSelection(point);
                        }
                        return .consumed;
                    }
                } else if (mouse.button == .release) {
                    self.dragging = false;
                    return .consumed;
                }
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

    fn renderEntries(self: *ConsoleOverlay, view: *PlaneView, size: Event.Size) void {
        if (size.width == 0 or size.height == 0) return;

        const total = self.entry_count;
        if (total == 0) return;

        const end_idx = if (total > self.scroll_offset) total - self.scroll_offset else 0;
        const start_idx = if (end_idx > size.height) end_idx - size.height else 0;

        var y: u16 = 0;
        var idx = start_idx;
        while (y < size.height and idx < end_idx) : ({
            y += 1;
            idx += 1;
        }) {
            const entry_view = self.entryView(idx);
            const entry = entry_view.entry;
            const style = self.panel_style.merge(self.level_styles[levelIndex(entry.level)]);

            var text_x: u16 = 0;
            if (self.show_level) {
                const prefix = entry.level.prefix();
                view.print(0, @intCast(y), prefix, style.fg, style.bg, style.attrs);
                text_x = @intCast(prefix.len + 1);
            }

            const available_width = size.width -| text_x;
            if (available_width == 0) continue;

            const text = self.entryText(entry_view.slot, entry.len);
            const display_len = @min(text.len, @as(usize, available_width));
            if (display_len > 0) {
                view.print(@intCast(text_x), @intCast(y), text[0..display_len], style.fg, style.bg, style.attrs);
            }

            if (self.selectionSpanForLine(idx, self.lineDisplayLen(entry))) |span| {
                self.renderSelectionSpan(view, y, entry_view, span);
            }
        }
    }

    fn pageUp(self: *ConsoleOverlay) void {
        const step = self.pageStep();
        var i: usize = 0;
        while (i < step) : (i += 1) {
            self.scrollUp();
        }
    }

    fn pageDown(self: *ConsoleOverlay) void {
        const step = self.pageStep();
        var i: usize = 0;
        while (i < step) : (i += 1) {
            self.scrollDown();
        }
    }

    fn pageStep(self: *ConsoleOverlay) usize {
        _ = self;
        return 5;
    }

    fn increaseSize(self: *ConsoleOverlay) void {
        const max_percent = @max(self.min_size_percent, self.max_size_percent);
        const next = self.size_percent +| self.size_step_percent;
        self.size_percent = @min(next, max_percent);
    }

    fn decreaseSize(self: *ConsoleOverlay) void {
        const min_percent = @min(self.min_size_percent, self.max_size_percent);
        if (self.size_percent <= min_percent) return;
        self.size_percent -|= self.size_step_percent;
        if (self.size_percent < min_percent) self.size_percent = min_percent;
    }

    fn maxScroll(self: *ConsoleOverlay) usize {
        if (self.last_content_lines == 0) return 0;
        const visible = @as(usize, self.last_content_lines);
        return if (self.entry_count > visible) self.entry_count - visible else 0;
    }

    fn isMouseInside(self: *ConsoleOverlay, x: u16, y: u16) bool {
        if (self.last_rect) |rect| {
            return x >= rect.x and x < rect.x +| rect.width and y >= rect.y and y < rect.y +| rect.height;
        }
        return false;
    }

    fn selectionPointFromMouse(self: *ConsoleOverlay, mouse: Event.Mouse) ?SelectionPoint {
        const rect = self.last_content_rect orelse return null;
        if (rect.width == 0 or rect.height == 0) return null;
        if (mouse.x < rect.x or mouse.y < rect.y) return null;
        if (mouse.x >= rect.x +| rect.width or mouse.y >= rect.y +| rect.height) return null;

        const local_x: usize = @intCast(mouse.x - rect.x);
        const local_y: usize = @intCast(mouse.y - rect.y);

        const visible = rect.height;
        const total = self.entry_count;
        if (total == 0) return null;

        const end_idx = if (total > self.scroll_offset) total - self.scroll_offset else 0;
        const start_idx = if (end_idx > visible) end_idx - visible else 0;

        const line_idx = start_idx + local_y;
        if (line_idx >= end_idx) return null;

        const entry_view = self.entryView(line_idx);
        const line_len = self.lineDisplayLen(entry_view.entry);
        const caret: usize = @min(local_x, line_len);
        return .{ .line = line_idx, .col = caret };
    }

    fn startSelection(self: *ConsoleOverlay, point: SelectionPoint) void {
        const focus = self.bumpSelectionPoint(point);
        self.selection_anchor = point;
        self.selection_focus = focus;
        self.selection = normalizeSelection(point, focus);
    }

    fn updateSelection(self: *ConsoleOverlay, point: SelectionPoint) void {
        const anchor = self.selection_anchor orelse return;
        const focus = self.bumpSelectionPoint(point);
        self.selection_focus = focus;
        self.selection = normalizeSelection(anchor, focus);
    }

    fn clearSelection(self: *ConsoleOverlay) void {
        self.selection_anchor = null;
        self.selection_focus = null;
        self.selection = null;
        self.dragging = false;
    }

    fn bumpSelectionPoint(self: *ConsoleOverlay, point: SelectionPoint) SelectionPoint {
        const entry_view = self.entryView(point.line);
        const line_len = self.lineDisplayLen(entry_view.entry);
        if (point.col < line_len) {
            return .{ .line = point.line, .col = point.col + 1 };
        }
        return point;
    }

    fn selectionSpanForLine(self: *ConsoleOverlay, line_idx: usize, line_len: usize) ?SelectionSpan {
        const selection = self.selection orelse return null;
        if (line_idx < selection.start.line or line_idx > selection.end.line) return null;
        var start_col: usize = 0;
        var end_col: usize = line_len;
        if (line_idx == selection.start.line) start_col = selection.start.col;
        if (line_idx == selection.end.line) end_col = selection.end.col;
        if (start_col >= end_col) return null;
        return .{
            .start_col = @min(start_col, line_len),
            .end_col = @min(end_col, line_len),
        };
    }

    fn renderSelectionSpan(self: *ConsoleOverlay, view: *PlaneView, y: u16, entry_view: EntryView, span: SelectionSpan) void {
        const entry = entry_view.entry;
        const selection_style = self.selection_style;
        var start = span.start_col;
        var end = span.end_col;
        if (start >= end) return;

        const prefix_len: usize = if (self.show_level) entry.level.prefix().len else 0;
        const prefix_total = if (self.show_level) prefix_len + 1 else 0;

        if (self.show_level) {
            const prefix = entry.level.prefix();
            if (start < prefix_total) {
                const prefix_end = @min(end, prefix_total);
                if (start < prefix.len) {
                    const part_end = @min(prefix.len, prefix_end);
                    view.print(@intCast(start), @intCast(y), prefix[start..part_end], selection_style.fg, selection_style.bg, selection_style.attrs);
                    if (prefix_end > prefix.len) {
                        view.print(@intCast(part_end), @intCast(y), " ", selection_style.fg, selection_style.bg, selection_style.attrs);
                    }
                } else {
                    view.print(@intCast(start), @intCast(y), " ", selection_style.fg, selection_style.bg, selection_style.attrs);
                }
            }
            if (end <= prefix_total) return;
            start = if (start > prefix_total) start - prefix_total else 0;
            end -= prefix_total;
        }

        const text = self.entryText(entry_view.slot, entry.len);
        const text_start = @min(start, text.len);
        const text_end = @min(end, text.len);
        if (text_end > text_start) {
            const x = if (self.show_level) @as(u16, @intCast(text_start + prefix_total)) else @as(u16, @intCast(text_start));
            view.print(x, @intCast(y), text[text_start..text_end], selection_style.fg, selection_style.bg, selection_style.attrs);
        }
    }

    fn entrySlotIndex(self: *ConsoleOverlay, logical_index: usize) usize {
        if (self.entry_count < self.max_entries) {
            return logical_index;
        }
        const start = self.entry_head;
        return (start + logical_index) % self.max_entries;
    }

    fn entryView(self: *ConsoleOverlay, logical_index: usize) EntryView {
        const slot = self.entrySlotIndex(logical_index);
        return .{ .entry = self.entries[slot], .slot = slot };
    }

    fn entryText(self: *ConsoleOverlay, slot: usize, len: usize) []const u8 {
        const offset = slot * self.max_entry_len;
        return self.text_storage[offset .. offset + len];
    }

    fn textSlot(self: *ConsoleOverlay, index: usize) []u8 {
        const offset = index * self.max_entry_len;
        return self.text_storage[offset .. offset + self.max_entry_len];
    }

    fn clearLastRect(self: *ConsoleOverlay, view: *PlaneView) void {
        if (self.last_rect) |rect| {
            clearRect(view, rect);
            self.last_rect = null;
            self.last_content_rect = null;
        }
        self.last_content_lines = 0;
    }

    fn lineDisplayLen(self: *ConsoleOverlay, entry: Entry) usize {
        if (!self.show_level) return entry.len;
        return entry.level.prefix().len + 1 + entry.len;
    }

    fn appendLineSegment(self: *ConsoleOverlay, buffer: *std.ArrayList(u8), entry_view: EntryView, start_col: usize, end_col: usize) !void {
        var start = start_col;
        var end = end_col;
        if (start >= end) return;

        if (self.show_level) {
            const prefix = entry_view.entry.level.prefix();
            const prefix_total = prefix.len + 1;
            if (start < prefix_total) {
                const prefix_end = @min(end, prefix_total);
                if (start < prefix.len) {
                    const part_end = @min(prefix.len, prefix_end);
                    try buffer.appendSlice(prefix[start..part_end]);
                    if (prefix_end > prefix.len) {
                        try buffer.append(' ');
                    }
                } else {
                    try buffer.append(' ');
                }
            }
            if (end <= prefix_total) return;
            start = if (start > prefix_total) start - prefix_total else 0;
            end -= prefix_total;
        }

        const text = self.entryText(entry_view.slot, entry_view.entry.len);
        const text_start = @min(start, text.len);
        const text_end = @min(end, text.len);
        if (text_end > text_start) {
            try buffer.appendSlice(text[text_start..text_end]);
        }
    }

    fn copySelection(self: *ConsoleOverlay) void {
        const handler = self.on_copy orelse return;
        const selection = self.selection orelse return;
        _ = selection;
        const text = self.selectionText(self.allocator) catch return;
        if (text) |slice| {
            defer self.allocator.free(slice);
            handler(self.copy_ctx, slice);
        }
    }

    pub const widget_vtable = Widget.VTable{
        .measureFn = measure,
        .renderFn = render,
        .handleEventFn = handleEvent,
    };
};

pub const MAX_LOG_LINE: usize = 1024;

var global_console: ?*ConsoleOverlay = null;

pub fn installGlobal(console: *ConsoleOverlay) void {
    global_console = console;
}

pub const CaptureStream = enum {
    stdout,
    stderr,
};

pub const StdIoCapture = if (builtin.os.tag == .windows) struct {
    pub fn init(allocator: std.mem.Allocator, console: *ConsoleOverlay, stream: CaptureStream) !StdIoCapture {
        _ = allocator;
        _ = console;
        _ = stream;
        return error.Unsupported;
    }

    pub fn deinit(self: *StdIoCapture) void {
        _ = self;
    }
} else struct {
    allocator: std.mem.Allocator,
    console: *ConsoleOverlay,
    stream: CaptureStream,
    thread: ?std.Thread = null,
    pipe_read: std.posix.fd_t = -1,
    pipe_write: std.posix.fd_t = -1,
    original_fd: std.posix.fd_t = -1,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator, console: *ConsoleOverlay, stream: CaptureStream) !StdIoCapture {
        var capture = StdIoCapture{
            .allocator = allocator,
            .console = console,
            .stream = stream,
        };

        const fds = try std.posix.pipe();
        capture.pipe_read = fds[0];
        capture.pipe_write = fds[1];

        const target_fd: std.posix.fd_t = switch (stream) {
            .stdout => std.posix.STDOUT_FILENO,
            .stderr => std.posix.STDERR_FILENO,
        };

        capture.original_fd = try std.posix.dup(target_fd);
        try std.posix.dup2(capture.pipe_write, target_fd);

        capture.thread = try std.Thread.spawn(.{}, captureThread, .{&capture});
        return capture;
    }

    pub fn deinit(self: *StdIoCapture) void {
        if (self.original_fd >= 0) {
            const target_fd: std.posix.fd_t = switch (self.stream) {
                .stdout => std.posix.STDOUT_FILENO,
                .stderr => std.posix.STDERR_FILENO,
            };
            _ = std.posix.dup2(self.original_fd, target_fd) catch {};
            std.posix.close(self.original_fd);
            self.original_fd = -1;
        }

        self.done.store(true, .monotonic);
        if (self.pipe_write >= 0) {
            std.posix.close(self.pipe_write);
            self.pipe_write = -1;
        }
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.pipe_read >= 0) {
            std.posix.close(self.pipe_read);
            self.pipe_read = -1;
        }
    }

    fn captureThread(self: *StdIoCapture) void {
        var buffer: [4096]u8 = undefined;
        var pending = std.ArrayListUnmanaged(u8){};
        defer pending.deinit(self.allocator);

        while (!self.done.load(.monotonic)) {
            const count = std.posix.read(self.pipe_read, &buffer) catch |err| switch (err) {
                error.Interrupted => continue,
                else => break,
            };
            if (count == 0) break;
            var idx: usize = 0;
            while (idx < count) {
                if (std.mem.indexOfScalar(u8, buffer[idx..count], '\n')) |rel| {
                    const next = idx + rel;
                    _ = pending.appendSlice(self.allocator, buffer[idx..next]) catch {
                        pending.clearRetainingCapacity();
                    };
                    self.flushPending(&pending);
                    pending.clearRetainingCapacity();
                    idx = next + 1;
                } else {
                    _ = pending.appendSlice(self.allocator, buffer[idx..count]) catch {
                        pending.clearRetainingCapacity();
                    };
                    idx = count;
                }
            }
        }

        if (pending.items.len > 0) {
            self.flushPending(&pending);
        }
    }

    fn flushPending(self: *StdIoCapture, pending: *std.ArrayListUnmanaged(u8)) void {
        if (pending.items.len == 0) return;
        const level: LogLevel = switch (self.stream) {
            .stdout => .info,
            .stderr => .err,
        };
        self.console.append(level, pending.items);
    }
};

pub fn uninstallGlobal(console: *ConsoleOverlay) void {
    if (global_console == console) {
        global_console = null;
    }
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (global_console) |console| {
        var buf: [MAX_LOG_LINE]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, format, args) catch {
            std.log.defaultLogFn(level, scope, format, args);
            return;
        };
        console.append(stdLevelToLogLevel(level), msg);
        return;
    }

    std.log.defaultLogFn(level, scope, format, args);
}

fn stdLevelToLogLevel(level: std.log.Level) LogLevel {
    return switch (level) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    };
}

fn defaultLevelStyles() [4]Style {
    return .{
        LogLevel.debug.style(),
        LogLevel.info.style(),
        LogLevel.warn.style(),
        LogLevel.err.style(),
    };
}

fn levelIndex(level: LogLevel) usize {
    return switch (level) {
        .debug => 0,
        .info => 1,
        .warn => 2,
        .err => 3,
    };
}

fn keysMatch(a: Event.Key, b: Event.Key) bool {
    if (a.mods.ctrl != b.mods.ctrl) return false;
    if (a.mods.alt != b.mods.alt) return false;
    if (a.mods.shift != b.mods.shift) return false;

    if (a.special) |a_special| {
        if (b.special) |b_special| {
            return a_special == b_special;
        }
        return false;
    }

    if (b.special != null) return false;

    return a.codepoint == b.codepoint;
}

fn rectEql(a: Event.Rect, b: Event.Rect) bool {
    return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
}

fn clearRect(view: *PlaneView, rect: Event.Rect) void {
    if (rect.width == 0 or rect.height == 0) return;
    var sub = view.subView(rect);
    sub.clear();
}

fn drawBorder(view: *PlaneView, rect: Event.Rect, style: Layout.BoxStyle, border_style: Style, title: []const u8) void {
    if (rect.width < 2 or rect.height < 2) return;

    const fg = border_style.fg;
    const bg = border_style.bg;
    const attrs = border_style.attrs;

    const max_x: i32 = @intCast(rect.width - 1);
    const max_y: i32 = @intCast(rect.height - 1);

    view.setCell(0, 0, Cell.styled(style.top_left, fg, bg, attrs));
    view.setCell(max_x, 0, Cell.styled(style.top_right, fg, bg, attrs));
    view.setCell(0, max_y, Cell.styled(style.bottom_left, fg, bg, attrs));
    view.setCell(max_x, max_y, Cell.styled(style.bottom_right, fg, bg, attrs));

    if (rect.width > 2) {
        var x: i32 = 1;
        while (x < max_x) : (x += 1) {
            view.setCell(x, 0, Cell.styled(style.horizontal, fg, bg, attrs));
            view.setCell(x, max_y, Cell.styled(style.horizontal, fg, bg, attrs));
        }
    }

    if (rect.height > 2) {
        var y: i32 = 1;
        while (y < max_y) : (y += 1) {
            view.setCell(0, y, Cell.styled(style.vertical, fg, bg, attrs));
            view.setCell(max_x, y, Cell.styled(style.vertical, fg, bg, attrs));
        }
    }

    if (title.len > 0 and rect.width > 4) {
        const available = rect.width -| 4;
        const display_len = @min(title.len, @as(usize, available));
        if (display_len > 0) {
            view.setCell(1, 0, Cell.styled(' ', fg, bg, attrs));
            view.print(2, 0, title[0..display_len], fg, bg, attrs);
        }
    }
}

const Entry = struct {
    len: usize = 0,
    level: LogLevel = .info,
    truncated: bool = false,
};

const EntryView = struct {
    entry: Entry,
    slot: usize,
};

const SelectionPoint = struct {
    line: usize,
    col: usize,
};

const SelectionRange = struct {
    start: SelectionPoint,
    end: SelectionPoint,
};

const SelectionSpan = struct {
    start_col: usize,
    end_col: usize,
};

fn normalizeSelection(a: SelectionPoint, b: SelectionPoint) ?SelectionRange {
    if (a.line == b.line and a.col == b.col) return null;
    if (pointBefore(a, b)) {
        return .{ .start = a, .end = b };
    }
    return .{ .start = b, .end = a };
}

fn pointBefore(a: SelectionPoint, b: SelectionPoint) bool {
    if (a.line < b.line) return true;
    if (a.line > b.line) return false;
    return a.col < b.col;
}

// ============================================================================
// Tests
// ============================================================================

test "ConsoleOverlay ring overwrites oldest" {
    var overlay = try ConsoleOverlay.init(std.testing.allocator, .{ .max_entries = 2, .max_entry_len = 4 });
    defer overlay.deinit();

    overlay.append(.info, "one");
    overlay.append(.info, "two");
    overlay.append(.info, "three");

    try std.testing.expectEqual(@as(usize, 2), overlay.entry_count);

    const first = overlay.entryView(0);
    const second = overlay.entryView(1);

    try std.testing.expectEqualStrings("two", overlay.entryText(first.slot, first.entry.len));
    try std.testing.expectEqualStrings("thre", overlay.entryText(second.slot, second.entry.len));
}

test "ConsoleOverlay selectionText spans lines" {
    var overlay = try ConsoleOverlay.init(std.testing.allocator, .{
        .max_entries = 4,
        .max_entry_len = 16,
        .show_level = false,
    });
    defer overlay.deinit();

    overlay.append(.info, "hello");
    overlay.append(.info, "world");

    overlay.selection = normalizeSelection(
        .{ .line = 0, .col = 1 },
        .{ .line = 1, .col = 2 },
    );

    const selected = try overlay.selectionText(std.testing.allocator);
    defer if (selected) |slice| std.testing.allocator.free(slice);

    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("ello\nwo", selected.?);
}
