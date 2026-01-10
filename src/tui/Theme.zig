//! Theme: Styling system for widgets
//!
//! Provides Theme type for consistent widget appearance.
//! Style is re-exported from the canonical definition in Style.zig.

const Cell = @import("../Cell.zig");

/// Style type for widget theming (re-exported from Style.zig)
pub const Style = @import("../Style.zig");

/// Theme containing styles for various widget states and semantic purposes
pub const Theme = struct {
    // Base text styles
    text: Style = .{},
    text_muted: Style = .{ .fg = .{ .index = 8 } }, // Gray

    // Interactive widget states
    focused: Style = .{ .attrs = .{ .bold = true } },
    hovered: Style = .{ .attrs = .{ .underline = true } },
    pressed: Style = .{ .attrs = .{ .reverse = true } },
    disabled: Style = .{ .fg = .{ .index = 8 } },

    // Semantic colors
    primary: Style = .{ .fg = .{ .index = 4 } }, // Blue
    secondary: Style = .{ .fg = .{ .index = 6 } }, // Cyan
    success: Style = .{ .fg = .{ .index = 2 } }, // Green
    warning: Style = .{ .fg = .{ .index = 3 } }, // Yellow
    error_style: Style = .{ .fg = .{ .index = 1 } }, // Red

    // Border styles
    border: Style = .{},
    border_focused: Style = .{ .fg = .{ .index = 4 } },

    /// The default theme
    pub const default = Theme{};

    /// Get style for a widget based on its state
    pub fn styleForState(self: Theme, base: Style, state: @import("Widget.zig").WidgetState) Style {
        var result = base;
        if (state.disabled) {
            result = result.merge(self.disabled);
        } else {
            if (state.pressed) {
                result = result.merge(self.pressed);
            } else if (state.hovered) {
                result = result.merge(self.hovered);
            }
            if (state.focused) {
                result = result.merge(self.focused);
            }
        }
        return result;
    }
};

// ============================================================================
// Tests
// ============================================================================

const std = @import("std");

test "Style merge" {
    const base = Style{ .fg = .{ .index = 1 }, .attrs = .{ .bold = true } };
    const overlay = Style{ .fg = .{ .index = 2 }, .attrs = .{ .underline = true } };

    const merged = base.merge(overlay);
    try std.testing.expectEqual(Cell.Color{ .index = 2 }, merged.fg);
    try std.testing.expect(merged.attrs.bold);
    try std.testing.expect(merged.attrs.underline);
}

test "Theme default" {
    const theme = Theme.default;
    try std.testing.expectEqual(Cell.Color.default, theme.text.fg);
}

test "Theme styleForState" {
    const theme = Theme.default;
    const Widget = @import("Widget.zig");

    const base = Style{ .fg = .{ .index = 7 } };

    // Normal state
    const normal = theme.styleForState(base, Widget.WidgetState.normal());
    try std.testing.expectEqual(Cell.Color{ .index = 7 }, normal.fg);

    // Focused state
    const focused = theme.styleForState(base, .{ .focused = true });
    try std.testing.expect(focused.attrs.bold);

    // Disabled state
    const disabled = theme.styleForState(base, .{ .disabled = true });
    try std.testing.expectEqual(Cell.Color{ .index = 8 }, disabled.fg);
}
