//! Sparkline and Digits: Data visualization widgets
//!
//! Sparkline: Compact line chart using block characters
//! Digits: Large number display using tall characters

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");

/// Sparkline widget for compact data visualization
pub const Sparkline = struct {
    /// Data points (0.0 to 1.0 normalized)
    data: []const f32,
    /// Style
    style: Style = .{ .fg = .{ .index = 2 } }, // Green
    /// Height in rows
    height: u16 = 1,
    /// Widget state
    widget_state: Widget.WidgetState = .{},

    // Block characters for vertical resolution (8 levels)
    const blocks = [_]u21{ ' ', '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█' };

    /// Create a sparkline
    pub fn init(data: []const f32) Sparkline {
        return .{ .data = data };
    }

    // Builder methods

    /// Set style
    pub fn withStyle(self: *Sparkline, style: Style) *Sparkline {
        self.style = style;
        return self;
    }

    /// Set height
    pub fn withHeight(self: *Sparkline, height: u16) *Sparkline {
        self.height = height;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *Sparkline, state: Widget.WidgetState) *Sparkline {
        self.widget_state = state;
        return self;
    }

    // Widget interface

    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Sparkline = @ptrCast(@alignCast(ptr));
        return .{
            .width = @min(@as(u16, @intCast(self.data.len)), constraint.max_width),
            .height = @min(self.height, constraint.max_height),
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Sparkline = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0 or self.data.len == 0) return;

        const visible_points = @min(self.data.len, size.width);

        for (0..visible_points) |i| {
            const value = std.math.clamp(self.data[i], 0.0, 1.0);
            const block_idx: usize = @intFromFloat(value * 8.0);
            const block_char = blocks[@min(block_idx, 8)];

            view.setCell(@intCast(i), 0, .{
                .char = block_char,
                .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                .fg = self.style.fg,
                .bg = self.style.bg,
                .attrs = self.style.attrs,
            });
        }
    }

    /// VTable for Widget interface
    pub const widget_vtable = Widget.VTable{
        .measureFn = measure,
        .renderFn = render,
    };
};

/// Digits widget for large number display
pub const Digits = struct {
    /// Value to display
    value: i64 = 0,
    /// Number of digits to show (0 = auto)
    digits: u8 = 0,
    /// Style
    style: Style = .{},
    /// Widget state
    widget_state: Widget.WidgetState = .{},

    // 3x5 digit patterns (each digit is 3 wide, 5 tall)
    const digit_patterns = [10][5][]const u8{
        // 0
        .{ "┌─┐", "│ │", "│ │", "│ │", "└─┘" },
        // 1
        .{ "  ┐", "  │", "  │", "  │", "  ╵" },
        // 2
        .{ "╶─┐", "  │", "┌─┘", "│  ", "└─╴" },
        // 3
        .{ "╶─┐", "  │", " ─┤", "  │", "╶─┘" },
        // 4
        .{ "╷ ╷", "│ │", "└─┤", "  │", "  ╵" },
        // 5
        .{ "┌─╴", "│  ", "└─┐", "  │", "╶─┘" },
        // 6
        .{ "┌─╴", "│  ", "├─┐", "│ │", "└─┘" },
        // 7
        .{ "╶─┐", "  │", "  │", "  │", "  ╵" },
        // 8
        .{ "┌─┐", "│ │", "├─┤", "│ │", "└─┘" },
        // 9
        .{ "┌─┐", "│ │", "└─┤", "  │", "╶─┘" },
    };

    /// Create a digits display
    pub fn init(value: i64) Digits {
        return .{ .value = value };
    }

    // Builder methods

    /// Set value
    pub fn setValue(self: *Digits, value: i64) *Digits {
        self.value = value;
        return self;
    }

    /// Set fixed digit count
    pub fn withDigits(self: *Digits, digits: u8) *Digits {
        self.digits = digits;
        return self;
    }

    /// Set style
    pub fn withStyle(self: *Digits, style: Style) *Digits {
        self.style = style;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *Digits, state: Widget.WidgetState) *Digits {
        self.widget_state = state;
        return self;
    }

    /// Get number of digits in value
    fn digitCount(self: *const Digits) u8 {
        if (self.digits > 0) return self.digits;

        var v = @abs(self.value);
        if (v == 0) return 1;

        var count: u8 = 0;
        while (v > 0) {
            v = @divTrunc(v, 10);
            count += 1;
        }
        return count;
    }

    // Widget interface

    fn measure(ptr: *anyopaque, _: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Digits = @ptrCast(@alignCast(ptr));
        const num_digits = self.digitCount();
        const has_sign: u8 = if (self.value < 0) 1 else 0;

        return .{
            // Each digit is 3 wide, plus 1 space between, plus sign
            .width = @as(u16, num_digits) * 4 - 1 + has_sign * 2,
            .height = 5,
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Digits = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0) return;

        var x_offset: u16 = 0;

        // Draw minus sign if negative
        if (self.value < 0 and size.width > 1) {
            view.setCell(@intCast(x_offset), 2, .{
                .char = '─',
                .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                .fg = self.style.fg,
                .bg = self.style.bg,
                .attrs = self.style.attrs,
            });
            x_offset = 2;
        }

        // Get digits
        var digits_buf: [20]u8 = undefined;
        const abs_value: u64 = @abs(self.value);
        const digits_str = std.fmt.bufPrint(&digits_buf, "{d}", .{abs_value}) catch return;

        // Pad with leading zeros if needed
        const num_digits = self.digitCount();
        const leading_zeros = if (num_digits > digits_str.len)
            num_digits - @as(u8, @intCast(digits_str.len))
        else
            0;

        // Draw leading zeros
        for (0..leading_zeros) |_| {
            if (x_offset + 3 > size.width) break;
            drawDigit(view, x_offset, 0, self.style);
            x_offset += 4;
        }

        // Draw digits
        for (digits_str) |c| {
            if (x_offset + 3 > size.width) break;
            const digit = c - '0';
            drawDigit(view, x_offset, digit, self.style);
            x_offset += 4;
        }
    }

    fn drawDigit(view: *PlaneView, x: u16, digit: u8, style: Style) void {
        if (digit > 9) return;
        const pattern = digit_patterns[digit];

        for (pattern, 0..) |row_str, y| {
            var col: u16 = 0;
            var iter = std.unicode.Utf8View.initUnchecked(row_str).iterator();
            while (iter.nextCodepoint()) |cp| {
                view.setCell(@intCast(x + col), @intCast(y), .{
                    .char = cp,
                    .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                    .fg = style.fg,
                    .bg = style.bg,
                    .attrs = style.attrs,
                });
                col += 1;
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

test "Sparkline init" {
    const data = [_]f32{ 0.0, 0.5, 1.0 };
    const spark = Sparkline.init(&data);
    try std.testing.expectEqual(@as(usize, 3), spark.data.len);
}

test "Sparkline measure" {
    const data = [_]f32{ 0.0, 0.5, 1.0, 0.25, 0.75 };
    var spark = Sparkline.init(&data);
    const widget = Widget.Widget.init(Sparkline, &spark);

    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));
    try std.testing.expectEqual(@as(u16, 5), measured.width);
    try std.testing.expectEqual(@as(u16, 1), measured.height);
}

test "Sparkline render" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 10, .height = 1 });
    defer root.deinit();

    const data = [_]f32{ 0.0, 0.5, 1.0 };
    var spark = Sparkline.init(&data);
    const widget = Widget.Widget.init(Sparkline, &spark);

    var view = PlaneView.init(root);
    widget.render(&view);

    // First point (0.0) should be space
    try std.testing.expectEqual(@as(u21, ' '), view.getCell(0, 0).?.char);
    // Last point (1.0) should be full block
    try std.testing.expectEqual(@as(u21, '█'), view.getCell(2, 0).?.char);
}

test "Digits init" {
    const digits = Digits.init(42);
    try std.testing.expectEqual(@as(i64, 42), digits.value);
}

test "Digits digitCount" {
    var digits = Digits.init(0);
    try std.testing.expectEqual(@as(u8, 1), digits.digitCount());

    _ = digits.setValue(9);
    try std.testing.expectEqual(@as(u8, 1), digits.digitCount());

    _ = digits.setValue(10);
    try std.testing.expectEqual(@as(u8, 2), digits.digitCount());

    _ = digits.setValue(999);
    try std.testing.expectEqual(@as(u8, 3), digits.digitCount());

    _ = digits.setValue(-123);
    try std.testing.expectEqual(@as(u8, 3), digits.digitCount());
}

test "Digits measure" {
    var digits = Digits.init(123);
    const widget = Widget.Widget.init(Digits, &digits);

    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));
    // 3 digits * 4 - 1 = 11
    try std.testing.expectEqual(@as(u16, 11), measured.width);
    try std.testing.expectEqual(@as(u16, 5), measured.height);
}

test "Digits measure negative" {
    var digits = Digits.init(-42);
    const widget = Widget.Widget.init(Digits, &digits);

    const measured = widget.measure(Widget.SizeConstraint.atMost(80, 24));
    // 2 digits * 4 - 1 + 2 (sign) = 9
    try std.testing.expectEqual(@as(u16, 9), measured.width);
}

test "Digits render" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 5 });
    defer root.deinit();

    var digits = Digits.init(1);
    const widget = Widget.Widget.init(Digits, &digits);

    var view = PlaneView.init(root);
    widget.render(&view);

    // Top of digit '1' should be ┐
    try std.testing.expectEqual(@as(u21, '┐'), view.getCell(2, 0).?.char);
}
