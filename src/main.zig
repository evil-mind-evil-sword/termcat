const std = @import("std");
const termcat = @import("termcat");

pub fn main() !void {
    // Demo showing capability detection
    const caps = termcat.detectCapabilities();

    std.debug.print("Termcat - Terminal Capabilities\n", .{});
    std.debug.print("================================\n", .{});
    std.debug.print("Color depth: {s}\n", .{@tagName(caps.color_depth)});
    std.debug.print("Width mode: {s}\n", .{@tagName(caps.width_mode)});
    std.debug.print("Explicit width: {}\n", .{caps.explicit_width});
    std.debug.print("Mouse support: {}\n", .{caps.mouse});
    std.debug.print("Bracketed paste: {}\n", .{caps.bracketed_paste});
    std.debug.print("Focus events: {}\n", .{caps.focus_events});
    std.debug.print("Synchronized output: {}\n", .{caps.synchronized_output});
    std.debug.print("Kitty graphics: {}\n", .{caps.kitty_graphics});

    if (std.posix.getenv("TERM")) |term| {
        std.debug.print("TERM: {s}\n", .{term});
    }
    if (std.posix.getenv("COLORTERM")) |colorterm| {
        std.debug.print("COLORTERM: {s}\n", .{colorterm});
    }
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
