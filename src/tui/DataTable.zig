//! DataTable: Tabular data display widget
//!
//! A widget for displaying data in a table format with columns,
//! headers, row selection, and optional sorting.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const Event = @import("../Event.zig");
const Layout = @import("../Layout.zig");

/// Column definition
pub const Column = struct {
    /// Column header text
    header: []const u8,
    /// Column width (0 = auto/flex)
    width: u16 = 0,
    /// Minimum width
    min_width: u16 = 3,
    /// Maximum width (0 = unlimited)
    max_width: u16 = 0,
    /// Text alignment
    alignment: Alignment = .left,
    /// Whether column is sortable
    sortable: bool = false,

    pub const Alignment = enum {
        left,
        center,
        right,
    };
};

/// A row of data
pub const Row = struct {
    /// Cell values (one per column)
    cells: []const []const u8,
    /// Optional row identifier
    id: ?[]const u8 = null,
    /// User data
    data: ?*anyopaque = null,
};

/// Sort state
pub const SortState = struct {
    column: usize,
    ascending: bool,
};

/// DataTable widget
pub const DataTable = struct {
    /// Column definitions
    columns: []const Column,
    /// Row data
    rows: []const Row,
    /// Currently selected row
    selected_row: usize = 0,
    /// Horizontal scroll offset (column index)
    h_scroll: usize = 0,
    /// Vertical scroll offset
    v_scroll: usize = 0,
    /// Visible height (including header)
    visible_height: u16 = 10,
    /// Show header row
    show_header: bool = true,
    /// Show row numbers
    show_row_numbers: bool = false,
    /// Show vertical borders between columns
    show_column_borders: bool = true,
    /// Current sort state
    sort_state: ?SortState = null,
    /// Border style
    border_style: Layout.BoxStyle = Layout.BoxStyle.single,
    /// Header style
    header_style: Style = .{ .attrs = .{ .bold = true } },
    /// Row style
    row_style: Style = .{},
    /// Alternate row style (for zebra striping)
    alt_row_style: ?Style = null,
    /// Selected row style
    selected_style: Style = .{ .attrs = .{ .reverse = true } },
    /// Widget state
    widget_state: Widget.WidgetState = .{},
    /// Callback context
    callback_ctx: ?*anyopaque = null,
    /// Called when selection changes
    on_select: ?*const fn (ctx: ?*anyopaque, row: usize) void = null,
    /// Called when row is activated
    on_activate: ?*const fn (ctx: ?*anyopaque, row: usize) void = null,
    /// Called when sort is requested
    on_sort: ?*const fn (ctx: ?*anyopaque, column: usize, ascending: bool) void = null,

    /// Create a data table
    pub fn init(columns: []const Column, rows: []const Row) DataTable {
        return .{
            .columns = columns,
            .rows = rows,
        };
    }

    // Builder methods

    /// Set visible height
    pub fn withHeight(self: *DataTable, height: u16) *DataTable {
        self.visible_height = height;
        return self;
    }

    /// Set show header
    pub fn withHeader(self: *DataTable, show: bool) *DataTable {
        self.show_header = show;
        return self;
    }

    /// Set show row numbers
    pub fn withRowNumbers(self: *DataTable, show: bool) *DataTable {
        self.show_row_numbers = show;
        return self;
    }

    /// Set show column borders
    pub fn withColumnBorders(self: *DataTable, show: bool) *DataTable {
        self.show_column_borders = show;
        return self;
    }

    /// Set header style
    pub fn withHeaderStyle(self: *DataTable, style: Style) *DataTable {
        self.header_style = style;
        return self;
    }

    /// Set row style
    pub fn withRowStyle(self: *DataTable, style: Style) *DataTable {
        self.row_style = style;
        return self;
    }

    /// Set alternate row style
    pub fn withAltRowStyle(self: *DataTable, style: Style) *DataTable {
        self.alt_row_style = style;
        return self;
    }

    /// Set selected style
    pub fn withSelectedStyle(self: *DataTable, style: Style) *DataTable {
        self.selected_style = style;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *DataTable, state: Widget.WidgetState) *DataTable {
        self.widget_state = state;
        return self;
    }

    /// Set selection callback
    pub fn withOnSelect(self: *DataTable, callback: *const fn (ctx: ?*anyopaque, row: usize) void, ctx: ?*anyopaque) *DataTable {
        self.on_select = callback;
        self.callback_ctx = ctx;
        return self;
    }

    /// Set activation callback
    pub fn withOnActivate(self: *DataTable, callback: *const fn (ctx: ?*anyopaque, row: usize) void, ctx: ?*anyopaque) *DataTable {
        self.on_activate = callback;
        if (self.callback_ctx == null) self.callback_ctx = ctx;
        return self;
    }

    // Navigation methods

    /// Select previous row
    pub fn selectPrev(self: *DataTable) void {
        if (self.selected_row > 0) {
            self.selected_row -= 1;
            self.ensureRowVisible();
            self.notifySelect();
        }
    }

    /// Select next row
    pub fn selectNext(self: *DataTable) void {
        if (self.selected_row + 1 < self.rows.len) {
            self.selected_row += 1;
            self.ensureRowVisible();
            self.notifySelect();
        }
    }

    /// Select first row
    pub fn selectFirst(self: *DataTable) void {
        if (self.rows.len > 0) {
            self.selected_row = 0;
            self.v_scroll = 0;
            self.notifySelect();
        }
    }

    /// Select last row
    pub fn selectLast(self: *DataTable) void {
        if (self.rows.len > 0) {
            self.selected_row = self.rows.len - 1;
            self.ensureRowVisible();
            self.notifySelect();
        }
    }

    /// Page up
    pub fn pageUp(self: *DataTable) void {
        const data_height = self.dataHeight();
        if (self.selected_row >= data_height) {
            self.selected_row -= data_height;
        } else {
            self.selected_row = 0;
        }
        self.ensureRowVisible();
        self.notifySelect();
    }

    /// Page down
    pub fn pageDown(self: *DataTable) void {
        const data_height = self.dataHeight();
        if (self.selected_row + data_height < self.rows.len) {
            self.selected_row += data_height;
        } else if (self.rows.len > 0) {
            self.selected_row = self.rows.len - 1;
        }
        self.ensureRowVisible();
        self.notifySelect();
    }

    /// Scroll left
    pub fn scrollLeft(self: *DataTable) void {
        if (self.h_scroll > 0) {
            self.h_scroll -= 1;
        }
    }

    /// Scroll right
    pub fn scrollRight(self: *DataTable) void {
        if (self.h_scroll + 1 < self.columns.len) {
            self.h_scroll += 1;
        }
    }

    /// Activate current row
    pub fn activateSelected(self: *DataTable) void {
        if (self.on_activate) |callback| {
            callback(self.callback_ctx, self.selected_row);
        }
    }

    /// Get selected row
    pub fn selectedRow(self: *const DataTable) ?Row {
        if (self.selected_row < self.rows.len) {
            return self.rows[self.selected_row];
        }
        return null;
    }

    /// Get row count
    pub fn rowCount(self: *const DataTable) usize {
        return self.rows.len;
    }

    fn dataHeight(self: *const DataTable) u16 {
        const header_rows: u16 = if (self.show_header) 2 else 0; // header + separator
        return self.visible_height -| header_rows;
    }

    fn ensureRowVisible(self: *DataTable) void {
        const data_height = self.dataHeight();
        if (self.selected_row < self.v_scroll) {
            self.v_scroll = self.selected_row;
        } else if (self.selected_row >= self.v_scroll + data_height) {
            self.v_scroll = self.selected_row - data_height + 1;
        }
    }

    fn notifySelect(self: *DataTable) void {
        if (self.on_select) |callback| {
            callback(self.callback_ctx, self.selected_row);
        }
    }

    // Widget interface

    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *DataTable = @ptrCast(@alignCast(ptr));
        return .{
            .width = constraint.max_width,
            .height = @min(self.visible_height, constraint.max_height),
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *DataTable = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0) return;

        // Calculate column widths
        var col_widths: [32]u16 = undefined;
        var total_width: u16 = 0;
        const border_width: u16 = if (self.show_column_borders) 1 else 0;

        for (self.columns, 0..) |col, i| {
            if (i >= 32) break;
            var w = if (col.width > 0) col.width else @max(col.min_width, @as(u16, @intCast(col.header.len)));
            if (col.max_width > 0) w = @min(w, col.max_width);
            col_widths[i] = w;
            total_width += w + border_width;
        }

        var y: i32 = 0;

        // Render header
        if (self.show_header and y < size.height) {
            renderRow(self, view, null, 0, &col_widths, size.width, y, true);
            y += 1;

            // Header separator
            if (y < size.height) {
                renderSeparator(self, view, &col_widths, size.width, y);
                y += 1;
            }
        }

        // Render data rows
        const data_height = @as(usize, @intCast(size.height)) -| @as(usize, @intCast(y));
        const visible_rows = @min(self.rows.len -| self.v_scroll, data_height);

        for (0..visible_rows) |i| {
            const row_idx = self.v_scroll + i;
            if (row_idx >= self.rows.len) break;

            const is_selected = row_idx == self.selected_row;
            renderRow(self, view, &self.rows[row_idx], row_idx, &col_widths, size.width, y, false);
            _ = is_selected;
            y += 1;
        }

        // Fill remaining space
        while (y < size.height) : (y += 1) {
            for (0..size.width) |x| {
                view.setCell(@intCast(x), y, Cell.simple(' ', self.row_style.fg, self.row_style.bg));
            }
        }
    }

    fn renderRow(self: *DataTable, view: *PlaneView, row: ?*const Row, row_idx: usize, col_widths: *const [32]u16, width: u16, y: i32, is_header: bool) void {
        const is_selected = !is_header and row_idx == self.selected_row;
        const is_alt = !is_header and (row_idx % 2 == 1) and self.alt_row_style != null;

        const style = if (is_selected)
            self.selected_style
        else if (is_header)
            self.header_style
        else if (is_alt)
            self.alt_row_style.?
        else
            self.row_style;

        var x: u16 = 0;

        for (self.columns, 0..) |col, i| {
            if (i >= 32) break;
            if (x >= width) break;

            const col_width = col_widths[i];

            // Get cell text
            const text = if (is_header)
                col.header
            else if (row) |r|
                if (i < r.cells.len) r.cells[i] else ""
            else
                "";

            // Render cell content
            const available = @min(col_width, width -| x);
            const text_len = @min(text.len, available);

            // Calculate alignment offset
            const padding = available -| @as(u16, @intCast(text_len));
            const left_pad: u16 = switch (col.alignment) {
                .left => 0,
                .center => padding / 2,
                .right => padding,
            };

            // Fill with spaces
            for (0..available) |dx| {
                view.setCell(@intCast(x + dx), y, Cell.simple(' ', style.fg, style.bg));
            }

            // Print text
            if (text_len > 0) {
                view.print(@intCast(x + left_pad), y, text[0..text_len], style.fg, style.bg, style.attrs);
            }

            x += col_width;

            // Column border
            if (self.show_column_borders and i + 1 < self.columns.len and x < width) {
                view.setCell(@intCast(x), y, Cell.simple(self.border_style.vertical, self.row_style.fg, style.bg));
                x += 1;
            }
        }

        // Fill remaining width
        while (x < width) : (x += 1) {
            view.setCell(@intCast(x), y, Cell.simple(' ', style.fg, style.bg));
        }
    }

    fn renderSeparator(self: *DataTable, view: *PlaneView, col_widths: *const [32]u16, width: u16, y: i32) void {
        var x: u16 = 0;

        for (self.columns, 0..) |_, i| {
            if (i >= 32) break;
            if (x >= width) break;

            const col_width = col_widths[i];

            // Draw horizontal line
            for (0..col_width) |_| {
                if (x >= width) break;
                view.setCell(@intCast(x), y, Cell.simple(self.border_style.horizontal, self.header_style.fg, self.header_style.bg));
                x += 1;
            }

            // Column intersection
            if (self.show_column_borders and i + 1 < self.columns.len and x < width) {
                view.setCell(@intCast(x), y, Cell.simple('┼', self.header_style.fg, self.header_style.bg));
                x += 1;
            }
        }

        // Fill remaining width
        while (x < width) : (x += 1) {
            view.setCell(@intCast(x), y, Cell.simple(self.border_style.horizontal, self.header_style.fg, self.header_style.bg));
        }
    }

    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *DataTable = @ptrCast(@alignCast(ptr));

        if (self.widget_state.disabled or !self.widget_state.focused) {
            return .ignored;
        }

        switch (event) {
            .key => |key| {
                if (key.special) |special| {
                    switch (special) {
                        .up => {
                            self.selectPrev();
                            return .consumed;
                        },
                        .down => {
                            self.selectNext();
                            return .consumed;
                        },
                        .home => {
                            self.selectFirst();
                            return .consumed;
                        },
                        .end => {
                            self.selectLast();
                            return .consumed;
                        },
                        .page_up => {
                            self.pageUp();
                            return .consumed;
                        },
                        .page_down => {
                            self.pageDown();
                            return .consumed;
                        },
                        .left => {
                            self.scrollLeft();
                            return .consumed;
                        },
                        .right => {
                            self.scrollRight();
                            return .consumed;
                        },
                        .enter => {
                            self.activateSelected();
                            return .consumed;
                        },
                        else => {},
                    }
                }
                if (key.codepoint) |cp| {
                    switch (cp) {
                        'k' => {
                            self.selectPrev();
                            return .consumed;
                        },
                        'j' => {
                            self.selectNext();
                            return .consumed;
                        },
                        'g' => {
                            self.selectFirst();
                            return .consumed;
                        },
                        'G' => {
                            self.selectLast();
                            return .consumed;
                        },
                        'h' => {
                            self.scrollLeft();
                            return .consumed;
                        },
                        'l' => {
                            self.scrollRight();
                            return .consumed;
                        },
                        else => {},
                    }
                }
            },
            .mouse => |mouse| {
                if (mouse.button == .wheel_up) {
                    self.selectPrev();
                    return .consumed;
                } else if (mouse.button == .wheel_down) {
                    self.selectNext();
                    return .consumed;
                } else if (mouse.button == .left and mouse.state == .released) {
                    const header_offset: usize = if (self.show_header) 2 else 0;
                    if (mouse.y >= header_offset) {
                        const clicked_row = self.v_scroll + @as(usize, mouse.y) - header_offset;
                        if (clicked_row < self.rows.len) {
                            self.selected_row = clicked_row;
                            self.notifySelect();
                            return .consumed;
                        }
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

test "DataTable init" {
    const columns = [_]Column{
        .{ .header = "Name" },
        .{ .header = "Value" },
    };
    const rows = [_]Row{
        .{ .cells = &[_][]const u8{ "foo", "bar" } },
    };
    const table = DataTable.init(&columns, &rows);

    try std.testing.expectEqual(@as(usize, 2), table.columns.len);
    try std.testing.expectEqual(@as(usize, 1), table.rows.len);
}

test "DataTable navigation" {
    const columns = [_]Column{
        .{ .header = "Name" },
    };
    const rows = [_]Row{
        .{ .cells = &[_][]const u8{"a"} },
        .{ .cells = &[_][]const u8{"b"} },
        .{ .cells = &[_][]const u8{"c"} },
    };
    var table = DataTable.init(&columns, &rows);

    try std.testing.expectEqual(@as(usize, 0), table.selected_row);

    table.selectNext();
    try std.testing.expectEqual(@as(usize, 1), table.selected_row);

    table.selectNext();
    try std.testing.expectEqual(@as(usize, 2), table.selected_row);

    table.selectNext(); // At end, should stay
    try std.testing.expectEqual(@as(usize, 2), table.selected_row);

    table.selectPrev();
    try std.testing.expectEqual(@as(usize, 1), table.selected_row);

    table.selectFirst();
    try std.testing.expectEqual(@as(usize, 0), table.selected_row);

    table.selectLast();
    try std.testing.expectEqual(@as(usize, 2), table.selected_row);
}

test "DataTable selectedRow" {
    const columns = [_]Column{
        .{ .header = "Name" },
    };
    const rows = [_]Row{
        .{ .cells = &[_][]const u8{"first"} },
        .{ .cells = &[_][]const u8{"second"} },
    };
    var table = DataTable.init(&columns, &rows);

    const first = table.selectedRow();
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("first", first.?.cells[0]);

    table.selectNext();
    const second = table.selectedRow();
    try std.testing.expectEqualStrings("second", second.?.cells[0]);
}

test "DataTable measure" {
    const columns = [_]Column{
        .{ .header = "Name" },
    };
    const rows = [_]Row{};
    var table = DataTable.init(&columns, &rows);
    _ = table.withHeight(8);

    const widget = Widget.Widget.init(DataTable, &table);
    const measured = widget.measure(Widget.SizeConstraint.atMost(40, 20));

    try std.testing.expectEqual(@as(u16, 40), measured.width);
    try std.testing.expectEqual(@as(u16, 8), measured.height);
}

test "DataTable handleEvent down" {
    const columns = [_]Column{
        .{ .header = "Name" },
    };
    const rows = [_]Row{
        .{ .cells = &[_][]const u8{"a"} },
        .{ .cells = &[_][]const u8{"b"} },
    };
    var table = DataTable.init(&columns, &rows);
    _ = table.withState(.{ .focused = true });

    const widget = Widget.Widget.init(DataTable, &table);
    const event = Event.Event{ .key = Event.Key.fromSpecial(.down, .{}) };

    const result = widget.handleEvent(event);
    try std.testing.expectEqual(Widget.EventResult.consumed, result);
    try std.testing.expectEqual(@as(usize, 1), table.selected_row);
}

test "DataTable render" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 5 });
    defer root.deinit();

    const columns = [_]Column{
        .{ .header = "Col1", .width = 8 },
    };
    const rows = [_]Row{
        .{ .cells = &[_][]const u8{"Value"} },
    };
    var table = DataTable.init(&columns, &rows);

    const widget = Widget.Widget.init(DataTable, &table);
    var view = PlaneView.init(root);
    widget.render(&view);

    // Header should be visible
    try std.testing.expectEqual(@as(u21, 'C'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'o'), view.getCell(1, 0).?.char);
}

test "Column alignment" {
    const left_col = Column{ .header = "Left", .alignment = .left };
    const center_col = Column{ .header = "Center", .alignment = .center };
    const right_col = Column{ .header = "Right", .alignment = .right };

    try std.testing.expectEqual(Column.Alignment.left, left_col.alignment);
    try std.testing.expectEqual(Column.Alignment.center, center_col.alignment);
    try std.testing.expectEqual(Column.Alignment.right, right_col.alignment);
}

test "DataTable rowCount" {
    const columns = [_]Column{
        .{ .header = "Name" },
    };
    const rows = [_]Row{
        .{ .cells = &[_][]const u8{"a"} },
        .{ .cells = &[_][]const u8{"b"} },
        .{ .cells = &[_][]const u8{"c"} },
    };
    const table = DataTable.init(&columns, &rows);

    try std.testing.expectEqual(@as(usize, 3), table.rowCount());
}
