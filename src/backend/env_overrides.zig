const std = @import("std");
const Cell = @import("../Cell.zig");
const unicode = @import("../unicode/width.zig");

pub const EnvOverrides = struct {
    color_depth: ?Cell.ColorDepth = null,
    kitty_graphics: ?bool = null,
    width_mode: ?unicode.WidthMode = null,
    explicit_width: ?bool = null,
};

pub fn read() EnvOverrides {
    var overrides: EnvOverrides = .{};
    var env_map = std.process.getEnvMap(std.heap.page_allocator) catch return overrides;
    defer env_map.deinit();

    if (env_map.get("TERMCAT_COLOR_DEPTH")) |value| {
        if (parseColorDepth(value)) |depth| {
            overrides.color_depth = depth;
        }
    }

    if (env_map.get("TERMCAT_FORCE_GRAPHICS") != null) {
        overrides.kitty_graphics = true;
    } else if (env_map.get("TERMCAT_NO_GRAPHICS") != null) {
        overrides.kitty_graphics = false;
    }

    if (env_map.get("TERMCAT_WIDTH_MODE")) |value| {
        if (parseWidthMode(value)) |mode| {
            overrides.width_mode = mode;
        }
    }

    if (env_map.get("TERMCAT_FORCE_WCWIDTH") != null) {
        overrides.width_mode = .wcwidth;
    } else if (env_map.get("TERMCAT_FORCE_UNICODE") != null) {
        overrides.width_mode = .unicode;
    } else if (env_map.get("TERMCAT_FORCE_NO_ZWJ") != null) {
        overrides.width_mode = .no_zwj;
    }

    if (env_map.get("TERMCAT_EXPLICIT_WIDTH")) |value| {
        if (parseBool(value)) |enabled| {
            overrides.explicit_width = enabled;
        }
    }

    return overrides;
}

fn parseBool(value: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes"))
    {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(value, "0") or
        std.ascii.eqlIgnoreCase(value, "false") or
        std.ascii.eqlIgnoreCase(value, "no"))
    {
        return false;
    }
    return null;
}

fn parseColorDepth(value: []const u8) ?Cell.ColorDepth {
    if (std.ascii.eqlIgnoreCase(value, "mono") or
        std.ascii.eqlIgnoreCase(value, "monochrome"))
    {
        return .mono;
    }
    if (std.ascii.eqlIgnoreCase(value, "basic") or
        std.ascii.eqlIgnoreCase(value, "ansi") or
        std.ascii.eqlIgnoreCase(value, "16"))
    {
        return .basic;
    }
    if (std.ascii.eqlIgnoreCase(value, "256") or
        std.ascii.eqlIgnoreCase(value, "color_256"))
    {
        return .color_256;
    }
    if (std.ascii.eqlIgnoreCase(value, "truecolor") or
        std.ascii.eqlIgnoreCase(value, "24bit") or
        std.ascii.eqlIgnoreCase(value, "rgb"))
    {
        return .true_color;
    }
    return null;
}

fn parseWidthMode(value: []const u8) ?unicode.WidthMode {
    if (std.ascii.eqlIgnoreCase(value, "wcwidth")) {
        return .wcwidth;
    }
    if (std.ascii.eqlIgnoreCase(value, "unicode")) {
        return .unicode;
    }
    if (std.ascii.eqlIgnoreCase(value, "no_zwj") or
        std.ascii.eqlIgnoreCase(value, "no-zwj"))
    {
        return .no_zwj;
    }
    return null;
}
