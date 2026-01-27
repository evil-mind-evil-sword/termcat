//! Color utilities for terminal palette detection and color manipulation.
//!
//! Provides:
//! - Perceptual luminance checking (isLight)
//! - Color blending for semi-transparent overlays
//! - RGB color space utilities
//!
//! Used by inline TUI mode for:
//! - Detecting terminal background color (light vs dark)
//! - Blending user message backgrounds with terminal palette
//! - Creating subtle UI overlays

const std = @import("std");

/// RGB color components as array for easy manipulation
pub const Rgb = [3]u8;

/// Terminal palette colors detected via OSC queries
pub const TerminalPalette = struct {
    /// Terminal foreground color (OSC 10), null if detection failed
    fg: ?Rgb = null,
    /// Terminal background color (OSC 11), null if detection failed
    bg: ?Rgb = null,
    /// Whether the terminal background is perceptually light
    is_light_background: bool = false,

    /// Create palette with detected colors
    pub fn init(fg: ?Rgb, bg: ?Rgb) TerminalPalette {
        var self = TerminalPalette{
            .fg = fg,
            .bg = bg,
        };
        if (bg) |b| {
            self.is_light_background = isLight(b[0], b[1], b[2]);
        }
        return self;
    }

    /// Default dark theme palette (when detection fails)
    pub const dark_default: TerminalPalette = .{
        .fg = .{ 204, 204, 204 }, // Light gray
        .bg = .{ 30, 30, 30 }, // Dark gray
        .is_light_background = false,
    };

    /// Default light theme palette (when detection fails)
    pub const light_default: TerminalPalette = .{
        .fg = .{ 51, 51, 51 }, // Dark gray
        .bg = .{ 255, 255, 255 }, // White
        .is_light_background = true,
    };
};

/// Check if a color is perceptually light using luminance calculation.
/// Uses ITU-R BT.601 coefficients for perceived brightness.
///
/// Returns true if the color appears light to human vision.
///
/// Example:
///   isLight(255, 255, 255) // true (white)
///   isLight(0, 0, 0)       // false (black)
///   isLight(128, 128, 128) // true (gray is borderline, leans light)
pub fn isLight(r: u8, g: u8, b: u8) bool {
    // ITU-R BT.601 luminance formula:
    // Y = 0.299*R + 0.587*G + 0.114*B
    //
    // Using integer math to avoid floating point:
    // Y * 1000 = 299*R + 587*G + 114*B
    // Threshold at Y=128 means Y*1000 = 128000
    const y = @as(u32, r) * 299 + @as(u32, g) * 587 + @as(u32, b) * 114;
    return y > 128000;
}

/// Blend two colors with alpha compositing.
/// Alpha of 0.0 = full background, 1.0 = full foreground.
///
/// Uses linear interpolation: result = fg * alpha + bg * (1 - alpha)
///
/// Example:
///   blend(.{255, 0, 0}, .{0, 0, 255}, 0.5) // .{127, 0, 127} (purple)
///   blend(.{255, 255, 255}, .{0, 0, 0}, 0.1) // subtle white overlay on black
pub fn blend(fg: Rgb, bg: Rgb, alpha: f32) Rgb {
    // Clamp alpha to valid range
    const a = @max(0.0, @min(1.0, alpha));
    const inv_a = 1.0 - a;

    return .{
        @intFromFloat(@as(f32, @floatFromInt(fg[0])) * a + @as(f32, @floatFromInt(bg[0])) * inv_a),
        @intFromFloat(@as(f32, @floatFromInt(fg[1])) * a + @as(f32, @floatFromInt(bg[1])) * inv_a),
        @intFromFloat(@as(f32, @floatFromInt(fg[2])) * a + @as(f32, @floatFromInt(bg[2])) * inv_a),
    };
}

/// Create a subtle background tint for user messages based on terminal palette.
/// Light backgrounds get a slight darkening, dark backgrounds get a slight lightening.
///
/// Codex-style: 4% white overlay on dark, 4% black overlay on light.
pub fn userMessageBackground(palette: TerminalPalette) ?Rgb {
    const bg = palette.bg orelse return null;

    if (palette.is_light_background) {
        // Light background: subtle dark overlay
        return blend(.{ 0, 0, 0 }, bg, 0.04);
    } else {
        // Dark background: subtle light overlay
        return blend(.{ 255, 255, 255 }, bg, 0.12);
    }
}

/// Interpolate between two colors for gradient/shimmer effects.
/// Position 0.0 = start color, 1.0 = end color.
pub fn interpolate(start: Rgb, end: Rgb, position: f32) Rgb {
    return blend(end, start, position);
}

/// Calculate relative luminance for WCAG contrast calculations.
/// Returns value in range [0, 1] where 0 = darkest, 1 = lightest.
pub fn relativeLuminance(r: u8, g: u8, b: u8) f32 {
    // Convert to linear RGB (sRGB gamma correction)
    const r_lin = gammaToLinear(@as(f32, @floatFromInt(r)) / 255.0);
    const g_lin = gammaToLinear(@as(f32, @floatFromInt(g)) / 255.0);
    const b_lin = gammaToLinear(@as(f32, @floatFromInt(b)) / 255.0);

    // Rec. 709 coefficients
    return 0.2126 * r_lin + 0.7152 * g_lin + 0.0722 * b_lin;
}

/// Convert sRGB gamma value to linear
fn gammaToLinear(v: f32) f32 {
    if (v <= 0.04045) {
        return v / 12.92;
    }
    return std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

/// Calculate contrast ratio between two colors (WCAG formula).
/// Returns ratio in range [1, 21] where higher = more contrast.
pub fn contrastRatio(color1: Rgb, color2: Rgb) f32 {
    const l1 = relativeLuminance(color1[0], color1[1], color1[2]);
    const l2 = relativeLuminance(color2[0], color2[1], color2[2]);
    const lighter = @max(l1, l2);
    const darker = @min(l1, l2);
    return (lighter + 0.05) / (darker + 0.05);
}

// =============================================================================
// Tests
// =============================================================================

test "isLight detects light colors" {
    // White is light
    try std.testing.expect(isLight(255, 255, 255));
    // Yellow is light
    try std.testing.expect(isLight(255, 255, 0));
    // Cyan is light
    try std.testing.expect(isLight(0, 255, 255));
    // Light gray is light
    try std.testing.expect(isLight(200, 200, 200));
}

test "isLight detects dark colors" {
    // Black is dark
    try std.testing.expect(!isLight(0, 0, 0));
    // Dark blue is dark
    try std.testing.expect(!isLight(0, 0, 128));
    // Dark red is dark
    try std.testing.expect(!isLight(128, 0, 0));
    // Dark gray is dark
    try std.testing.expect(!isLight(50, 50, 50));
}

test "blend produces intermediate colors" {
    // 50% blend of red and blue
    const purple = blend(.{ 255, 0, 0 }, .{ 0, 0, 255 }, 0.5);
    try std.testing.expect(purple[0] >= 125 and purple[0] <= 130); // ~127
    try std.testing.expectEqual(@as(u8, 0), purple[1]);
    try std.testing.expect(purple[2] >= 125 and purple[2] <= 130); // ~127
}

test "blend alpha 0 returns background" {
    const result = blend(.{ 255, 255, 255 }, .{ 0, 0, 0 }, 0.0);
    try std.testing.expectEqual(@as(u8, 0), result[0]);
    try std.testing.expectEqual(@as(u8, 0), result[1]);
    try std.testing.expectEqual(@as(u8, 0), result[2]);
}

test "blend alpha 1 returns foreground" {
    const result = blend(.{ 255, 255, 255 }, .{ 0, 0, 0 }, 1.0);
    try std.testing.expectEqual(@as(u8, 255), result[0]);
    try std.testing.expectEqual(@as(u8, 255), result[1]);
    try std.testing.expectEqual(@as(u8, 255), result[2]);
}

test "blend clamps alpha out of range" {
    // Alpha > 1 should clamp to 1
    const result1 = blend(.{ 255, 0, 0 }, .{ 0, 0, 255 }, 2.0);
    try std.testing.expectEqual(@as(u8, 255), result1[0]);

    // Alpha < 0 should clamp to 0
    const result2 = blend(.{ 255, 0, 0 }, .{ 0, 0, 255 }, -1.0);
    try std.testing.expectEqual(@as(u8, 255), result2[2]);
}

test "userMessageBackground dark theme" {
    const palette = TerminalPalette{
        .bg = .{ 30, 30, 30 },
        .is_light_background = false,
    };
    const bg = userMessageBackground(palette);
    try std.testing.expect(bg != null);
    // Should be slightly lighter than terminal bg
    try std.testing.expect(bg.?[0] > 30);
}

test "userMessageBackground light theme" {
    const palette = TerminalPalette{
        .bg = .{ 250, 250, 250 },
        .is_light_background = true,
    };
    const bg = userMessageBackground(palette);
    try std.testing.expect(bg != null);
    // Should be slightly darker than terminal bg
    try std.testing.expect(bg.?[0] < 250);
}

test "userMessageBackground returns null without bg" {
    const palette = TerminalPalette{};
    try std.testing.expect(userMessageBackground(palette) == null);
}

test "TerminalPalette.init sets is_light_background" {
    const dark = TerminalPalette.init(null, .{ 30, 30, 30 });
    try std.testing.expect(!dark.is_light_background);

    const light = TerminalPalette.init(null, .{ 240, 240, 240 });
    try std.testing.expect(light.is_light_background);
}

test "contrastRatio white on black" {
    const ratio = contrastRatio(.{ 255, 255, 255 }, .{ 0, 0, 0 });
    // White on black should be close to 21:1
    try std.testing.expect(ratio > 20.0 and ratio <= 21.0);
}

test "contrastRatio same color" {
    const ratio = contrastRatio(.{ 100, 100, 100 }, .{ 100, 100, 100 });
    // Same color should be 1:1
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), ratio, 0.01);
}
