//! CommandPalette: Quick command/action search overlay
//!
//! A modal overlay for searching and executing commands,
//! similar to VS Code's command palette (Ctrl+Shift+P).

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const Event = @import("../Event.zig");
const Layout = @import("../Layout.zig");

/// A command in the palette
pub const Command = struct {
    /// Command identifier
    id: []const u8,
    /// Display label
    label: []const u8,
    /// Optional description
    description: ?[]const u8 = null,
    /// Optional keyboard shortcut display
    shortcut: ?[]const u8 = null,
    /// Optional category for grouping
    category: ?[]const u8 = null,
    /// User data
    data: ?*anyopaque = null,
};

/// Command filter function
pub const FilterFn = *const fn (query: []const u8, command: Command) bool;

/// Default fuzzy filter
pub fn fuzzyFilter(query: []const u8, command: Command) bool {
    if (query.len == 0) return true;

    var query_idx: usize = 0;
    for (command.label) |c| {
        if (query_idx >= query.len) break;

        const qc = query[query_idx];
        const qc_lower = if (qc >= 'A' and qc <= 'Z') qc + 32 else qc;
        const c_lower = if (c >= 'A' and c <= 'Z') c + 32 else c;

        if (qc_lower == c_lower) {
            query_idx += 1;
        }
    }

    return query_idx >= query.len;
}

/// Prefix filter
pub fn prefixFilter(query: []const u8, command: Command) bool {
    if (query.len == 0) return true;
    if (query.len > command.label.len) return false;

    for (query, 0..) |qc, i| {
        const c = command.label[i];
        const qc_lower = if (qc >= 'A' and qc <= 'Z') qc + 32 else qc;
        const c_lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
        if (qc_lower != c_lower) return false;
    }
    return true;
}

/// Command palette widget
pub const CommandPalette = struct {
    /// Available commands
    commands: []const Command,
    /// Current query text
    query: [256]u8 = undefined,
    /// Query length
    query_len: usize = 0,
    /// Cursor position in query
    cursor: usize = 0,
    /// Selected command index (in filtered list)
    selected_index: usize = 0,
    /// Whether palette is visible
    visible: bool = false,
    /// Max visible commands
    max_visible: usize = 10,
    /// Palette width (0 = auto)
    width: u16 = 60,
    /// Filter function
    filter_fn: FilterFn = fuzzyFilter,
    /// Prompt text
    prompt: []const u8 = "> ",
    /// Placeholder text
    placeholder: []const u8 = "Type to search commands...",
    /// Border style
    border_style: Layout.BoxStyle = Layout.BoxStyle.rounded,
    /// Background style
    bg_style: Style = .{ .bg = .{ .index = 0 } },
    /// Input style
    input_style: Style = .{},
    /// Placeholder style
    placeholder_style: Style = .{ .fg = .{ .index = 8 } },
    /// Command style
    command_style: Style = .{},
    /// Selected command style
    selected_style: Style = .{ .bg = .{ .index = 4 }, .fg = .{ .index = 15 } },
    /// Shortcut style
    shortcut_style: Style = .{ .fg = .{ .index = 8 } },
    /// Widget state
    widget_state: Widget.WidgetState = .{},
    /// Callback context
    callback_ctx: ?*anyopaque = null,
    /// Called when a command is selected
    on_select: ?*const fn (ctx: ?*anyopaque, command: Command) void = null,
    /// Called when palette is dismissed
    on_dismiss: ?*const fn (ctx: ?*anyopaque) void = null,

    // Cached filtered indices
    filtered_indices: [128]usize = undefined,
    filtered_count: usize = 0,

    /// Create a command palette
    pub fn init(commands: []const Command) CommandPalette {
        var palette = CommandPalette{ .commands = commands };
        palette.updateFiltered();
        return palette;
    }

    // Builder methods

    /// Set max visible commands
    pub fn withMaxVisible(self: *CommandPalette, max: usize) *CommandPalette {
        self.max_visible = max;
        return self;
    }

    /// Set width
    pub fn withWidth(self: *CommandPalette, width: u16) *CommandPalette {
        self.width = width;
        return self;
    }

    /// Set filter function
    pub fn withFilter(self: *CommandPalette, filter: FilterFn) *CommandPalette {
        self.filter_fn = filter;
        return self;
    }

    /// Set prompt
    pub fn withPrompt(self: *CommandPalette, prompt: []const u8) *CommandPalette {
        self.prompt = prompt;
        return self;
    }

    /// Set placeholder
    pub fn withPlaceholder(self: *CommandPalette, placeholder: []const u8) *CommandPalette {
        self.placeholder = placeholder;
        return self;
    }

    /// Set selected style
    pub fn withSelectedStyle(self: *CommandPalette, style: Style) *CommandPalette {
        self.selected_style = style;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *CommandPalette, state: Widget.WidgetState) *CommandPalette {
        self.widget_state = state;
        return self;
    }

    /// Set selection callback
    pub fn withOnSelect(self: *CommandPalette, callback: *const fn (ctx: ?*anyopaque, command: Command) void, ctx: ?*anyopaque) *CommandPalette {
        self.on_select = callback;
        self.callback_ctx = ctx;
        return self;
    }

    /// Set dismiss callback
    pub fn withOnDismiss(self: *CommandPalette, callback: *const fn (ctx: ?*anyopaque) void, ctx: ?*anyopaque) *CommandPalette {
        self.on_dismiss = callback;
        if (self.callback_ctx == null) self.callback_ctx = ctx;
        return self;
    }

    // Methods

    /// Show the palette
    pub fn show(self: *CommandPalette) void {
        self.visible = true;
        self.query_len = 0;
        self.cursor = 0;
        self.selected_index = 0;
        self.updateFiltered();
    }

    /// Hide the palette
    pub fn hide(self: *CommandPalette) void {
        self.visible = false;
        if (self.on_dismiss) |callback| {
            callback(self.callback_ctx);
        }
    }

    /// Toggle visibility
    pub fn toggle(self: *CommandPalette) void {
        if (self.visible) {
            self.hide();
        } else {
            self.show();
        }
    }

    /// Get query text
    pub fn getQuery(self: *const CommandPalette) []const u8 {
        return self.query[0..self.query_len];
    }

    /// Set query text
    pub fn setQuery(self: *CommandPalette, text: []const u8) void {
        const len = @min(text.len, self.query.len);
        @memcpy(self.query[0..len], text[0..len]);
        self.query_len = len;
        self.cursor = len;
        self.selected_index = 0;
        self.updateFiltered();
    }

    /// Get selected command
    pub fn selectedCommand(self: *const CommandPalette) ?Command {
        if (self.filtered_count == 0) return null;
        if (self.selected_index >= self.filtered_count) return null;
        return self.commands[self.filtered_indices[self.selected_index]];
    }

    /// Select next command
    pub fn selectNext(self: *CommandPalette) void {
        if (self.filtered_count > 0) {
            self.selected_index = (self.selected_index + 1) % self.filtered_count;
        }
    }

    /// Select previous command
    pub fn selectPrev(self: *CommandPalette) void {
        if (self.filtered_count > 0) {
            if (self.selected_index == 0) {
                self.selected_index = self.filtered_count - 1;
            } else {
                self.selected_index -= 1;
            }
        }
    }

    /// Confirm selection
    pub fn confirm(self: *CommandPalette) void {
        if (self.selectedCommand()) |cmd| {
            if (self.on_select) |callback| {
                callback(self.callback_ctx, cmd);
            }
        }
        self.hide();
    }

    /// Insert character at cursor
    pub fn insertChar(self: *CommandPalette, c: u21) void {
        if (c > 127) return; // ASCII only for now
        if (self.query_len >= self.query.len - 1) return;

        // Shift characters right
        var i = self.query_len;
        while (i > self.cursor) : (i -= 1) {
            self.query[i] = self.query[i - 1];
        }

        self.query[self.cursor] = @intCast(c);
        self.cursor += 1;
        self.query_len += 1;
        self.selected_index = 0;
        self.updateFiltered();
    }

    /// Delete character before cursor
    pub fn deleteBack(self: *CommandPalette) void {
        if (self.cursor == 0) return;

        // Shift characters left
        for (self.cursor - 1..self.query_len - 1) |i| {
            self.query[i] = self.query[i + 1];
        }

        self.cursor -= 1;
        self.query_len -= 1;
        self.selected_index = 0;
        self.updateFiltered();
    }

    /// Move cursor left
    pub fn cursorLeft(self: *CommandPalette) void {
        if (self.cursor > 0) self.cursor -= 1;
    }

    /// Move cursor right
    pub fn cursorRight(self: *CommandPalette) void {
        if (self.cursor < self.query_len) self.cursor += 1;
    }

    fn updateFiltered(self: *CommandPalette) void {
        self.filtered_count = 0;
        const query = self.getQuery();

        for (self.commands, 0..) |cmd, i| {
            if (self.filter_fn(query, cmd)) {
                if (self.filtered_count < self.filtered_indices.len) {
                    self.filtered_indices[self.filtered_count] = i;
                    self.filtered_count += 1;
                }
            }
        }
    }

    // Widget interface

    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *CommandPalette = @ptrCast(@alignCast(ptr));

        if (!self.visible) {
            return .{ .width = 0, .height = 0 };
        }

        const visible_count = @min(self.filtered_count, self.max_visible);
        // 2 for border, 1 for input, 1 for separator, N for commands
        const height: u16 = @intCast(4 + visible_count);

        return .{
            .width = @min(self.width, constraint.max_width),
            .height = @min(height, constraint.max_height),
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *CommandPalette = @ptrCast(@alignCast(ptr));

        if (!self.visible) return;

        const size = view.size();
        if (size.width < 10 or size.height < 4) return;

        const box = self.border_style;
        var y: i32 = 0;

        // Top border
        view.setCell(0, y, makeCell(box.top_left, self.bg_style.fg, self.bg_style.bg));
        for (1..size.width - 1) |x| {
            view.setCell(@intCast(x), y, makeCell(box.horizontal, self.bg_style.fg, self.bg_style.bg));
        }
        view.setCell(@intCast(size.width - 1), y, makeCell(box.top_right, self.bg_style.fg, self.bg_style.bg));
        y += 1;

        // Input line
        view.setCell(0, y, makeCell(box.vertical, self.bg_style.fg, self.bg_style.bg));

        // Clear input area
        for (1..size.width - 1) |x| {
            view.setCell(@intCast(x), y, makeCell(' ', self.input_style.fg, self.bg_style.bg));
        }

        // Draw prompt
        var x: u16 = 1;
        for (self.prompt) |c| {
            if (x >= size.width - 1) break;
            view.setCell(@intCast(x), y, makeCell(c, self.input_style.fg, self.bg_style.bg));
            x += 1;
        }

        // Draw query or placeholder
        if (self.query_len == 0) {
            for (self.placeholder) |c| {
                if (x >= size.width - 1) break;
                view.setCell(@intCast(x), y, makeCell(c, self.placeholder_style.fg, self.bg_style.bg));
                x += 1;
            }
        } else {
            const query = self.getQuery();
            for (query) |c| {
                if (x >= size.width - 1) break;
                view.setCell(@intCast(x), y, makeCell(c, self.input_style.fg, self.bg_style.bg));
                x += 1;
            }
        }

        // Draw cursor
        if (self.widget_state.focused) {
            const cursor_x = @as(u16, @intCast(self.prompt.len)) + 1 + @as(u16, @intCast(self.cursor));
            if (cursor_x < size.width - 1) {
                const cursor_char: u21 = if (self.cursor < self.query_len) self.query[self.cursor] else ' ';
                view.setCell(@intCast(cursor_x), y, .{
                    .char = cursor_char,
                    .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                    .fg = self.bg_style.bg,
                    .bg = self.input_style.fg,
                    .attrs = .{},
                });
            }
        }

        view.setCell(@intCast(size.width - 1), y, makeCell(box.vertical, self.bg_style.fg, self.bg_style.bg));
        y += 1;

        // Separator
        view.setCell(0, y, makeCell('├', self.bg_style.fg, self.bg_style.bg));
        for (1..size.width - 1) |x_| {
            view.setCell(@intCast(x_), y, makeCell(box.horizontal, self.bg_style.fg, self.bg_style.bg));
        }
        view.setCell(@intCast(size.width - 1), y, makeCell('┤', self.bg_style.fg, self.bg_style.bg));
        y += 1;

        // Commands
        const visible_count = @min(self.filtered_count, @min(self.max_visible, size.height -| 4));
        for (0..visible_count) |i| {
            if (y >= size.height - 1) break;

            const cmd_idx = self.filtered_indices[i];
            const cmd = self.commands[cmd_idx];
            const is_selected = i == self.selected_index;
            const style = if (is_selected) self.selected_style else self.command_style;

            view.setCell(0, y, makeCell(box.vertical, self.bg_style.fg, self.bg_style.bg));

            // Clear line
            for (1..size.width - 1) |x_| {
                view.setCell(@intCast(x_), y, makeCell(' ', style.fg, style.bg));
            }

            // Selection indicator
            if (is_selected) {
                view.setCell(1, y, makeCell('›', style.fg, style.bg));
            }

            // Command label
            x = 3;
            for (cmd.label) |c| {
                if (x >= size.width - 1) break;
                view.setCell(@intCast(x), y, makeCell(c, style.fg, style.bg));
                x += 1;
            }

            // Shortcut (right-aligned)
            if (cmd.shortcut) |shortcut| {
                const shortcut_x = size.width -| 2 -| @as(u16, @intCast(shortcut.len));
                if (shortcut_x > x + 2) {
                    var sx = shortcut_x;
                    for (shortcut) |c| {
                        if (sx >= size.width - 1) break;
                        const sc_style = if (is_selected) style else self.shortcut_style;
                        view.setCell(@intCast(sx), y, makeCell(c, sc_style.fg, style.bg));
                        sx += 1;
                    }
                }
            }

            view.setCell(@intCast(size.width - 1), y, makeCell(box.vertical, self.bg_style.fg, self.bg_style.bg));
            y += 1;
        }

        // Bottom border
        if (y < size.height) {
            view.setCell(0, y, makeCell(box.bottom_left, self.bg_style.fg, self.bg_style.bg));
            for (1..size.width - 1) |x_| {
                view.setCell(@intCast(x_), y, makeCell(box.horizontal, self.bg_style.fg, self.bg_style.bg));
            }
            view.setCell(@intCast(size.width - 1), y, makeCell(box.bottom_right, self.bg_style.fg, self.bg_style.bg));
        }
    }

    fn makeCell(char: u21, fg: Cell.Color, bg: Cell.Color) Cell {
        return .{
            .char = char,
            .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
            .fg = fg,
            .bg = bg,
            .attrs = .{},
        };
    }

    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *CommandPalette = @ptrCast(@alignCast(ptr));

        if (!self.visible or self.widget_state.disabled) {
            return .ignored;
        }

        switch (event) {
            .key => |key| {
                if (key.special) |special| {
                    switch (special) {
                        .escape => {
                            self.hide();
                            return .consumed;
                        },
                        .enter => {
                            self.confirm();
                            return .consumed;
                        },
                        .up => {
                            self.selectPrev();
                            return .consumed;
                        },
                        .down => {
                            self.selectNext();
                            return .consumed;
                        },
                        .left => {
                            self.cursorLeft();
                            return .consumed;
                        },
                        .right => {
                            self.cursorRight();
                            return .consumed;
                        },
                        .backspace => {
                            self.deleteBack();
                            return .consumed;
                        },
                        .tab => {
                            self.selectNext();
                            return .consumed;
                        },
                        else => {},
                    }
                }
                if (key.codepoint) |cp| {
                    if (cp >= 32 and cp < 127) {
                        self.insertChar(cp);
                        return .consumed;
                    }
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

test "CommandPalette init" {
    const commands = [_]Command{
        .{ .id = "open", .label = "Open File" },
        .{ .id = "save", .label = "Save File" },
    };
    const palette = CommandPalette.init(&commands);

    try std.testing.expectEqual(@as(usize, 2), palette.commands.len);
    try std.testing.expectEqual(false, palette.visible);
}

test "CommandPalette show/hide" {
    const commands = [_]Command{};
    var palette = CommandPalette.init(&commands);

    try std.testing.expectEqual(false, palette.visible);

    palette.show();
    try std.testing.expectEqual(true, palette.visible);

    palette.hide();
    try std.testing.expectEqual(false, palette.visible);

    palette.toggle();
    try std.testing.expectEqual(true, palette.visible);
}

test "CommandPalette fuzzy filter" {
    const commands = [_]Command{
        .{ .id = "open", .label = "Open File" },
        .{ .id = "save", .label = "Save File" },
        .{ .id = "close", .label = "Close Tab" },
    };
    var palette = CommandPalette.init(&commands);

    palette.setQuery("of");
    try std.testing.expectEqual(@as(usize, 1), palette.filtered_count);

    palette.setQuery("file");
    try std.testing.expectEqual(@as(usize, 2), palette.filtered_count);

    palette.setQuery("");
    try std.testing.expectEqual(@as(usize, 3), palette.filtered_count);
}

test "CommandPalette prefix filter" {
    const commands = [_]Command{
        .{ .id = "open", .label = "Open File" },
        .{ .id = "save", .label = "Save File" },
    };
    var palette = CommandPalette.init(&commands);
    _ = palette.withFilter(prefixFilter);

    palette.setQuery("O");
    try std.testing.expectEqual(@as(usize, 1), palette.filtered_count);

    palette.setQuery("S");
    try std.testing.expectEqual(@as(usize, 1), palette.filtered_count);
}

test "CommandPalette navigation" {
    const commands = [_]Command{
        .{ .id = "a", .label = "A" },
        .{ .id = "b", .label = "B" },
        .{ .id = "c", .label = "C" },
    };
    var palette = CommandPalette.init(&commands);

    try std.testing.expectEqual(@as(usize, 0), palette.selected_index);

    palette.selectNext();
    try std.testing.expectEqual(@as(usize, 1), palette.selected_index);

    palette.selectNext();
    try std.testing.expectEqual(@as(usize, 2), palette.selected_index);

    palette.selectNext(); // Wraps
    try std.testing.expectEqual(@as(usize, 0), palette.selected_index);

    palette.selectPrev(); // Wraps back
    try std.testing.expectEqual(@as(usize, 2), palette.selected_index);
}

test "CommandPalette selectedCommand" {
    const commands = [_]Command{
        .{ .id = "first", .label = "First" },
        .{ .id = "second", .label = "Second" },
    };
    var palette = CommandPalette.init(&commands);

    const first = palette.selectedCommand();
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("first", first.?.id);

    palette.selectNext();
    const second = palette.selectedCommand();
    try std.testing.expectEqualStrings("second", second.?.id);
}

test "CommandPalette insertChar" {
    const commands = [_]Command{};
    var palette = CommandPalette.init(&commands);

    palette.insertChar('h');
    palette.insertChar('i');
    try std.testing.expectEqualStrings("hi", palette.getQuery());
    try std.testing.expectEqual(@as(usize, 2), palette.cursor);
}

test "CommandPalette deleteBack" {
    const commands = [_]Command{};
    var palette = CommandPalette.init(&commands);

    palette.setQuery("hello");
    palette.deleteBack();
    try std.testing.expectEqualStrings("hell", palette.getQuery());
}

test "CommandPalette measure hidden" {
    const commands = [_]Command{};
    var palette = CommandPalette.init(&commands);

    const widget = Widget.Widget.init(CommandPalette, &palette);
    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));

    try std.testing.expectEqual(@as(u16, 0), measured.width);
    try std.testing.expectEqual(@as(u16, 0), measured.height);
}

test "CommandPalette measure visible" {
    const commands = [_]Command{
        .{ .id = "a", .label = "A" },
        .{ .id = "b", .label = "B" },
    };
    var palette = CommandPalette.init(&commands);
    palette.show();

    const widget = Widget.Widget.init(CommandPalette, &palette);
    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));

    try std.testing.expectEqual(@as(u16, 60), measured.width);
    // 4 base + 2 commands = 6
    try std.testing.expectEqual(@as(u16, 6), measured.height);
}

test "CommandPalette handleEvent escape" {
    const commands = [_]Command{};
    var palette = CommandPalette.init(&commands);
    palette.visible = true;

    const widget = Widget.Widget.init(CommandPalette, &palette);
    const event = Event.Event{ .key = Event.Key.fromSpecial(.escape, .{}) };

    const result = widget.handleEvent(event);
    try std.testing.expectEqual(Widget.EventResult.consumed, result);
    try std.testing.expectEqual(false, palette.visible);
}

test "CommandPalette render" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 40, .height = 10 });
    defer root.deinit();

    const commands = [_]Command{
        .{ .id = "test", .label = "Test Command" },
    };
    var palette = CommandPalette.init(&commands);
    palette.show();

    const widget = Widget.Widget.init(CommandPalette, &palette);
    var view = PlaneView.init(root);
    widget.render(&view);

    // Top-left corner should be rounded border
    try std.testing.expectEqual(@as(u21, '╭'), view.getCell(0, 0).?.char);
}

test "fuzzyFilter" {
    const cmd = Command{ .id = "test", .label = "Open File" };

    try std.testing.expect(fuzzyFilter("of", cmd));
    try std.testing.expect(fuzzyFilter("opfi", cmd));
    try std.testing.expect(fuzzyFilter("", cmd));
    try std.testing.expect(!fuzzyFilter("xyz", cmd));
}

test "prefixFilter" {
    const cmd = Command{ .id = "test", .label = "Open File" };

    try std.testing.expect(prefixFilter("Op", cmd));
    try std.testing.expect(prefixFilter("open", cmd));
    try std.testing.expect(prefixFilter("", cmd));
    try std.testing.expect(!prefixFilter("File", cmd));
}
