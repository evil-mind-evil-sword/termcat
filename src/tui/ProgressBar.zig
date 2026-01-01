//! ProgressBar: Horizontal progress indicator widget
//!
//! A stateless widget for displaying progress as a horizontal bar.
//! Progress state comes from external state (Model), not stored in widget.
//! Supports various bar styles and optional spinner animation.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Theme = @import("Theme.zig").Theme;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const unicode = @import("../unicode/width.zig");

/// Bar fill style options
pub const BarStyle = enum {
    /// Simple ASCII: [####    ]
    ascii,
    /// Unicode blocks: [████    ]
    blocks,
    /// Smooth blocks with partial fill: [███▌    ]
    smooth,
};

/// ProgressBar widget for displaying completion progress
pub const ProgressBar = struct {
    /// Current progress value (0.0 to 1.0)
    progress: f32 = 0.0,
    /// Optional label to show before the bar
    label: ?[]const u8 = null,
    /// Whether to show percentage text
    show_percentage: bool = true,
    /// Bar fill style
    bar_style: BarStyle = .blocks,
    /// Filled bar style
    filled_style: Style = .{ .fg = .{ .index = 2 } }, // Green
    /// Empty bar style
    empty_style: Style = .{ .fg = .{ .index = 8 } }, // Gray
    /// Widget state
    widget_state: Widget.WidgetState = .{},

    /// Initialize a ProgressBar with a progress value (0.0 to 1.0)
    pub fn init(progress: f32) ProgressBar {
        return .{
            .progress = std.math.clamp(progress, 0.0, 1.0),
        };
    }

    /// Set the progress value
    pub fn withProgress(self: *ProgressBar, progress: f32) *ProgressBar {
        self.progress = std.math.clamp(progress, 0.0, 1.0);
        return self;
    }

    /// Set an optional label
    pub fn withLabel(self: *ProgressBar, label: []const u8) *ProgressBar {
        self.label = label;
        return self;
    }

    /// Set whether to show percentage
    pub fn withPercentage(self: *ProgressBar, show: bool) *ProgressBar {
        self.show_percentage = show;
        return self;
    }

    /// Set the bar style
    pub fn withBarStyle(self: *ProgressBar, style: BarStyle) *ProgressBar {
        self.bar_style = style;
        return self;
    }

    /// Set the filled bar style
    pub fn withFilledStyle(self: *ProgressBar, style: Style) *ProgressBar {
        self.filled_style = style;
        return self;
    }

    /// Set the empty bar style
    pub fn withEmptyStyle(self: *ProgressBar, style: Style) *ProgressBar {
        self.empty_style = style;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *ProgressBar, state: Widget.WidgetState) *ProgressBar {
        self.widget_state = state;
        return self;
    }

    /// Get the filled and empty characters for the current style
    fn getBarChars(self: *const ProgressBar) struct { filled: u21, empty: u21, partials: []const u21 } {
        return switch (self.bar_style) {
            .ascii => .{ .filled = '#', .empty = ' ', .partials = &[_]u21{} },
            .blocks => .{ .filled = 0x2588, .empty = ' ', .partials = &[_]u21{} }, // █
            .smooth => .{
                .filled = 0x2588, // █
                .empty = ' ',
                .partials = &[_]u21{
                    0x258F, // ▏ 1/8
                    0x258E, // ▎ 2/8
                    0x258D, // ▍ 3/8
                    0x258C, // ▌ 4/8
                    0x258B, // ▋ 5/8
                    0x258A, // ▊ 6/8
                    0x2589, // ▉ 7/8
                },
            },
        };
    }

    /// Measure the progress bar's preferred size
    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *ProgressBar = @ptrCast(@alignCast(ptr));

        // Minimum width: [##] = 4, with label add label width + 1
        // With percentage: add " 100%" = 5
        var min_width: u16 = 4;
        if (self.label) |label| {
            min_width += @intCast(unicode.stringWidth(label) + 1);
        }
        if (self.show_percentage) {
            min_width += 5; // " 100%"
        }

        // Prefer taking available width, but at least min_width
        const preferred_width = @max(min_width, constraint.max_width);

        return constraint.clamp(.{
            .width = preferred_width,
            .height = 1,
        });
    }

    /// Render the progress bar
    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *ProgressBar = @ptrCast(@alignCast(ptr));

        const view_size = view.size();
        if (view_size.height == 0 or view_size.width == 0) return;

        const theme = Theme.default;
        const filled_style = theme.styleForState(self.filled_style, self.widget_state);
        const empty_style = theme.styleForState(self.empty_style, self.widget_state);

        var col: i32 = 0;

        // Render label if present
        if (self.label) |label| {
            view.print(col, 0, label, filled_style.fg, filled_style.bg, filled_style.attrs);
            col += @intCast(unicode.stringWidth(label) + 1);
        }

        // Calculate bar width (remaining space minus brackets and optional percentage)
        var bar_width: i32 = @as(i32, view_size.width) - col - 2; // -2 for brackets
        if (self.show_percentage) {
            bar_width -= 5; // " 100%"
        }
        if (bar_width < 1) bar_width = 1;

        // Render opening bracket
        view.print(col, 0, "[", filled_style.fg, filled_style.bg, filled_style.attrs);
        col += 1;

        // Calculate filled and empty portions
        const bar_chars = self.getBarChars();
        const filled_exact = self.progress * @as(f32, @floatFromInt(bar_width));
        const filled_full: i32 = @intFromFloat(filled_exact);
        const partial = filled_exact - @as(f32, @floatFromInt(filled_full));

        // Render filled portion
        var i: i32 = 0;
        while (i < filled_full and i < bar_width) : (i += 1) {
            const cell = Cell{
                .char = bar_chars.filled,
                .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                .fg = filled_style.fg,
                .bg = filled_style.bg,
                .attrs = filled_style.attrs,
            };
            view.setCell(col + i, 0, cell);
        }

        // Render partial block for smooth style.
        // The partial value (0.0-1.0) maps to one of 7 partial block characters (▏▎▍▌▋▊▉).
        // partial_idx = floor(partial * 7), giving 0-7. We only draw if idx is 1-7 (non-zero fill).
        // When partial approaches 1.0, idx=7 which accesses partials[6], the widest partial block.
        if (self.bar_style == .smooth and filled_full < bar_width and bar_chars.partials.len > 0) {
            const partial_idx: usize = @intFromFloat(partial * @as(f32, @floatFromInt(bar_chars.partials.len)));
            if (partial_idx > 0 and partial_idx <= bar_chars.partials.len) {
                const cell = Cell{
                    .char = bar_chars.partials[partial_idx - 1],
                    .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                    .fg = filled_style.fg,
                    .bg = filled_style.bg,
                    .attrs = filled_style.attrs,
                };
                view.setCell(col + filled_full, 0, cell);
                i += 1;
            }
        }

        // Render empty portion
        while (i < bar_width) : (i += 1) {
            const cell = Cell{
                .char = bar_chars.empty,
                .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                .fg = empty_style.fg,
                .bg = empty_style.bg,
                .attrs = empty_style.attrs,
            };
            view.setCell(col + i, 0, cell);
        }
        col += bar_width;

        // Render closing bracket
        view.print(col, 0, "]", filled_style.fg, filled_style.bg, filled_style.attrs);
        col += 1;

        // Render percentage if enabled
        if (self.show_percentage) {
            var buf: [5]u8 = undefined;
            // Clamp to 100 to prevent overflow if progress exceeds 1.0
            const percent: u8 = @min(100, @as(u8, @intFromFloat(@max(0.0, self.progress) * 100.0)));
            const len = std.fmt.formatIntBuf(&buf, percent, 10, .lower, .{});
            buf[len] = '%';

            // Right-align percentage in 5 chars: " 100%"
            const start_col = col + @as(i32, 5 - @as(i32, @intCast(len + 1)));
            view.print(start_col, 0, buf[0 .. len + 1], filled_style.fg, filled_style.bg, filled_style.attrs);
        }
    }

    /// Handle events - progress bars don't handle events
    fn handleEvent(_: *anyopaque, _: @import("../Event.zig").Event) Widget.EventResult {
        return .ignored;
    }

    /// VTable for Widget interface
    pub const widget_vtable = Widget.VTable{
        .measureFn = measure,
        .renderFn = render,
        .handleEventFn = handleEvent,
    };
};

/// Spinner widget for indeterminate progress
pub const Spinner = struct {
    /// Current frame index (updated by external timer)
    frame: u8 = 0,
    /// Spinner style
    style: SpinnerStyle = .dots,
    /// Text style
    text_style: Style = .{ .fg = .{ .index = 6 } }, // Cyan
    /// Widget state
    widget_state: Widget.WidgetState = .{},

    pub const SpinnerStyle = enum {
        /// Simple ASCII: |/-\
        ascii,
        /// Braille dots: ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏
        dots,
        /// Block: ▖▘▝▗
        blocks,
    };

    /// Get the spinner frames for current style
    fn getFrames(self: *const Spinner) []const u21 {
        return switch (self.style) {
            .ascii => &[_]u21{ '|', '/', '-', '\\' },
            .dots => &[_]u21{ 0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F },
            .blocks => &[_]u21{ 0x2596, 0x2598, 0x259D, 0x2597 },
        };
    }

    /// Initialize a Spinner
    pub fn init() Spinner {
        return .{};
    }

    /// Set the current frame (call from timer subscription)
    pub fn withFrame(self: *Spinner, frame: u8) *Spinner {
        self.frame = frame;
        return self;
    }

    /// Advance to next frame
    pub fn advance(self: *Spinner) void {
        const frames = self.getFrames();
        self.frame = (self.frame + 1) % @as(u8, @intCast(frames.len));
    }

    /// Set spinner style
    pub fn withStyle(self: *Spinner, style: SpinnerStyle) *Spinner {
        self.style = style;
        return self;
    }

    /// Set text style
    pub fn withTextStyle(self: *Spinner, style: Style) *Spinner {
        self.text_style = style;
        return self;
    }

    /// Set widget state
    pub fn withWidgetState(self: *Spinner, state: Widget.WidgetState) *Spinner {
        self.widget_state = state;
        return self;
    }

    fn measure(_: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        return constraint.clamp(.{ .width = 1, .height = 1 });
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Spinner = @ptrCast(@alignCast(ptr));

        const view_size = view.size();
        if (view_size.height == 0 or view_size.width == 0) return;

        const theme = Theme.default;
        const style = theme.styleForState(self.text_style, self.widget_state);

        const frames = self.getFrames();
        const frame_idx = self.frame % @as(u8, @intCast(frames.len));
        const char = frames[frame_idx];

        const cell = Cell{
            .char = char,
            .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
            .fg = style.fg,
            .bg = style.bg,
            .attrs = style.attrs,
        };
        view.setCell(0, 0, cell);
    }

    fn handleEvent(_: *anyopaque, _: @import("../Event.zig").Event) Widget.EventResult {
        return .ignored;
    }

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

test "ProgressBar init" {
    const bar = ProgressBar.init(0.5);
    try std.testing.expectEqual(@as(f32, 0.5), bar.progress);
    try std.testing.expect(bar.show_percentage);
    try std.testing.expect(bar.label == null);
}

test "ProgressBar clamps progress" {
    const bar1 = ProgressBar.init(1.5);
    try std.testing.expectEqual(@as(f32, 1.0), bar1.progress);

    const bar2 = ProgressBar.init(-0.5);
    try std.testing.expectEqual(@as(f32, 0.0), bar2.progress);
}

test "ProgressBar builder pattern" {
    var bar = ProgressBar.init(0.75);
    _ = bar.withLabel("Loading")
        .withPercentage(false)
        .withBarStyle(.ascii);

    try std.testing.expectEqualStrings("Loading", bar.label.?);
    try std.testing.expect(!bar.show_percentage);
    try std.testing.expectEqual(BarStyle.ascii, bar.bar_style);
}

test "ProgressBar measure" {
    var bar = ProgressBar.init(0.5);
    const widget = Widget.Widget.init(ProgressBar, &bar);

    const measured = widget.measure(Widget.SizeConstraint.atMost(40, 1));
    try std.testing.expectEqual(@as(u16, 40), measured.width);
    try std.testing.expectEqual(@as(u16, 1), measured.height);
}

test "ProgressBar render empty" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 1 });
    defer root.deinit();

    var view = PlaneView.init(root);
    var bar = ProgressBar.init(0.0);
    _ = bar.withPercentage(false).withBarStyle(.ascii);
    const widget = Widget.Widget.init(ProgressBar, &bar);

    widget.render(&view);

    // Should render [ ... ] with no fill
    try std.testing.expectEqual(@as(u21, '['), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, ']'), view.getCell(19, 0).?.char);
}

test "ProgressBar render full" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 12, .height = 1 });
    defer root.deinit();

    var view = PlaneView.init(root);
    var bar = ProgressBar.init(1.0);
    _ = bar.withPercentage(false).withBarStyle(.ascii);
    const widget = Widget.Widget.init(ProgressBar, &bar);

    widget.render(&view);

    // Should render [##########]
    try std.testing.expectEqual(@as(u21, '['), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, '#'), view.getCell(1, 0).?.char);
    try std.testing.expectEqual(@as(u21, '#'), view.getCell(10, 0).?.char);
    try std.testing.expectEqual(@as(u21, ']'), view.getCell(11, 0).?.char);
}

test "ProgressBar render half" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 12, .height = 1 });
    defer root.deinit();

    var view = PlaneView.init(root);
    var bar = ProgressBar.init(0.5);
    _ = bar.withPercentage(false).withBarStyle(.ascii);
    const widget = Widget.Widget.init(ProgressBar, &bar);

    widget.render(&view);

    // Should render [#####     ]
    try std.testing.expectEqual(@as(u21, '['), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, '#'), view.getCell(1, 0).?.char);
    try std.testing.expectEqual(@as(u21, '#'), view.getCell(5, 0).?.char);
    try std.testing.expectEqual(@as(u21, ' '), view.getCell(6, 0).?.char);
    try std.testing.expectEqual(@as(u21, ']'), view.getCell(11, 0).?.char);
}

test "Spinner init" {
    const spinner = Spinner.init();
    try std.testing.expectEqual(@as(u8, 0), spinner.frame);
}

test "Spinner advance" {
    var spinner = Spinner.init();
    _ = spinner.withStyle(.ascii);

    spinner.advance();
    try std.testing.expectEqual(@as(u8, 1), spinner.frame);

    spinner.advance();
    spinner.advance();
    spinner.advance();
    try std.testing.expectEqual(@as(u8, 0), spinner.frame); // Wrapped around
}

test "Spinner measure" {
    var spinner = Spinner.init();
    const widget = Widget.Widget.init(Spinner, &spinner);

    const measured = widget.measure(Widget.SizeConstraint{});
    try std.testing.expectEqual(@as(u16, 1), measured.width);
    try std.testing.expectEqual(@as(u16, 1), measured.height);
}

test "Spinner render" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 5, .height = 1 });
    defer root.deinit();

    var view = PlaneView.init(root);
    var spinner = Spinner.init();
    _ = spinner.withStyle(.ascii);
    const widget = Widget.Widget.init(Spinner, &spinner);

    widget.render(&view);

    // First frame of ascii spinner is '|'
    try std.testing.expectEqual(@as(u21, '|'), view.getCell(0, 0).?.char);
}

test "ProgressBar render with percentage" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 1 });
    defer root.deinit();

    var view = PlaneView.init(root);
    var bar = ProgressBar.init(0.5);
    _ = bar.withPercentage(true).withBarStyle(.ascii);
    const widget = Widget.Widget.init(ProgressBar, &bar);

    widget.render(&view);

    // Should have brackets and percentage at end
    try std.testing.expectEqual(@as(u21, '['), view.getCell(0, 0).?.char);
    // Percentage "50%" should be at the right side
    try std.testing.expectEqual(@as(u21, '5'), view.getCell(16, 0).?.char);
    try std.testing.expectEqual(@as(u21, '0'), view.getCell(17, 0).?.char);
    try std.testing.expectEqual(@as(u21, '%'), view.getCell(18, 0).?.char);
}

test "ProgressBar render 100% percentage" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 20, .height = 1 });
    defer root.deinit();

    var view = PlaneView.init(root);
    var bar = ProgressBar.init(1.0);
    _ = bar.withPercentage(true).withBarStyle(.ascii);
    const widget = Widget.Widget.init(ProgressBar, &bar);

    widget.render(&view);

    // "100%" at the right side
    try std.testing.expectEqual(@as(u21, '1'), view.getCell(15, 0).?.char);
    try std.testing.expectEqual(@as(u21, '0'), view.getCell(16, 0).?.char);
    try std.testing.expectEqual(@as(u21, '0'), view.getCell(17, 0).?.char);
    try std.testing.expectEqual(@as(u21, '%'), view.getCell(18, 0).?.char);
}

test "ProgressBar render blocks style" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 12, .height = 1 });
    defer root.deinit();

    var view = PlaneView.init(root);
    var bar = ProgressBar.init(0.5);
    _ = bar.withPercentage(false).withBarStyle(.blocks);
    const widget = Widget.Widget.init(ProgressBar, &bar);

    widget.render(&view);

    // Should render [█████     ] with Unicode full block
    try std.testing.expectEqual(@as(u21, '['), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, 0x2588), view.getCell(1, 0).?.char); // Full block █
    try std.testing.expectEqual(@as(u21, 0x2588), view.getCell(5, 0).?.char);
    try std.testing.expectEqual(@as(u21, ' '), view.getCell(6, 0).?.char);
    try std.testing.expectEqual(@as(u21, ']'), view.getCell(11, 0).?.char);
}

test "ProgressBar render smooth style with partial block" {
    const allocator = std.testing.allocator;
    // Width 12: [ + 10 chars + ] = 12, so bar_width = 10
    const root = try Plane.initRoot(allocator, .{ .width = 12, .height = 1 });
    defer root.deinit();

    var view = PlaneView.init(root);
    // 0.35 = 3.5 cells, so 3 full blocks + partial
    var bar = ProgressBar.init(0.35);
    _ = bar.withPercentage(false).withBarStyle(.smooth);
    const widget = Widget.Widget.init(ProgressBar, &bar);

    widget.render(&view);

    // Should have brackets
    try std.testing.expectEqual(@as(u21, '['), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, ']'), view.getCell(11, 0).?.char);

    // Should have full blocks at beginning
    try std.testing.expectEqual(@as(u21, 0x2588), view.getCell(1, 0).?.char); // Full block
    try std.testing.expectEqual(@as(u21, 0x2588), view.getCell(2, 0).?.char);
    try std.testing.expectEqual(@as(u21, 0x2588), view.getCell(3, 0).?.char);

    // Position 4 should have a partial block (one of the partial chars)
    const partial_char = view.getCell(4, 0).?.char;
    // Partial blocks are in range 0x258F - 0x2589
    try std.testing.expect(partial_char >= 0x2589 and partial_char <= 0x258F);
}

test "ProgressBar render with label" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 30, .height = 1 });
    defer root.deinit();

    var view = PlaneView.init(root);
    var bar = ProgressBar.init(0.5);
    _ = bar.withLabel("Loading").withPercentage(false).withBarStyle(.ascii);
    const widget = Widget.Widget.init(ProgressBar, &bar);

    widget.render(&view);

    // Label should be at the start
    try std.testing.expectEqual(@as(u21, 'L'), view.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'o'), view.getCell(1, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'a'), view.getCell(2, 0).?.char);
    // Bar should start after label + space
    try std.testing.expectEqual(@as(u21, '['), view.getCell(8, 0).?.char);
}
