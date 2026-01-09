const std = @import("std");
const termcat = @import("termcat");
const posix = std.posix;

/// Minimal InputReader test - tests lightweight input without full Terminal
/// Press 'q' to exit.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("InputReader Test - Press 'q' to exit\n", .{});
    std.debug.print("stdin isatty: {}\n", .{posix.isatty(posix.STDIN_FILENO)});

    var reader = termcat.InputReader.init(allocator, .{
        .enable_signals = true,
        .install_sigwinch = true,
    }) catch |err| {
        std.debug.print("Failed to init InputReader: {}\n", .{err});
        return err;
    };
    defer reader.deinit();

    std.debug.print("InputReader initialized, polling for events...\n", .{});

    var count: u32 = 0;
    while (count < 1000) : (count += 1) {
        const event = reader.pollEvent(100) catch |err| {
            std.debug.print("pollEvent error: {}\n", .{err});
            continue;
        };

        if (event) |ev| {
            switch (ev) {
                .key => |key| {
                    std.debug.print("KEY: ", .{});
                    if (key.mods.ctrl) std.debug.print("Ctrl+", .{});
                    if (key.mods.alt) std.debug.print("Alt+", .{});
                    if (key.mods.shift) std.debug.print("Shift+", .{});
                    if (key.codepoint) |cp| {
                        if (cp == 'q') {
                            std.debug.print("q - exiting\n", .{});
                            return;
                        }
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &buf) catch 1;
                        std.debug.print("{s}\n", .{buf[0..len]});
                    } else if (key.special) |sp| {
                        std.debug.print("{s}\n", .{@tagName(sp)});
                    } else {
                        std.debug.print("(unknown)\n", .{});
                    }
                },
                .resize => |sz| {
                    std.debug.print("RESIZE: {d}x{d}\n", .{ sz.width, sz.height });
                },
                .mouse => |m| {
                    std.debug.print("MOUSE: {s} at ({d},{d})\n", .{ @tagName(m.button), m.x, m.y });
                },
                .paste => |text| {
                    std.debug.print("PASTE: {s}\n", .{text});
                },
                .focus => |focused| {
                    std.debug.print("FOCUS: {}\n", .{focused});
                },
            }
        } else {
            // Timeout - print a dot every 10 timeouts to show we're alive
            if (count % 10 == 0) {
                std.debug.print(".", .{});
            }
        }
    }

    std.debug.print("\nTimeout after 1000 polls\n", .{});
}
