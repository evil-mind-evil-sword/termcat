const std = @import("std");
const termcat = @import("termcat");
const tui = termcat.tui;

pub const std_options = std.Options{
    .log_level = .debug,
    .logFn = tui.consoleLogFn,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var console = try tui.ConsoleOverlay.init(allocator, .{
        .position = .bottom,
        .size_percent = 30,
        .start_visible = false,
    });
    defer console.deinit();
    tui.installConsoleOverlay(&console);
    defer tui.uninstallConsoleOverlay(&console);

    var term = try termcat.Terminal.init(allocator, .{
        .backend = .{
            .enable_mouse = true,
            .enable_focus_events = true,
            .enable_synchronized_output = true,
        },
    });
    defer term.deinit();

    var overlay_plane = try term.createPlane(0, 0, term.size());

    var running = true;
    var tick: usize = 0;
    var next_log_ms = std.time.milliTimestamp() + 1000;

    while (running) {
        const size = term.size();
        if (overlay_plane.width != size.width or overlay_plane.height != size.height) {
            try overlay_plane.resize(size);
        }

        const root = term.rootPlane();
        root.clear();
        root.print(2, 1, "Console overlay demo", termcat.Color.bright_white, .default, .{ .bold = true });
        root.print(2, 3, "F12: toggle console  +/-: resize  arrows: scroll", termcat.Color.white, .default, .{});
        root.print(2, 4, "i/w/e/d: log levels  q or Esc: quit", termcat.Color.white, .default, .{});

        var overlay_view = tui.PlaneView.init(overlay_plane);
        const overlay_widget = tui.Widget.init(tui.ConsoleOverlay, &console);
        overlay_widget.render(&overlay_view);

        try term.invalidatePlane(root);
        try term.invalidatePlane(overlay_plane);
        try term.present();

        if (try term.pollEvent(50)) |event| {
            if (overlay_widget.handleEvent(event) == .consumed) {
                continue;
            }

            switch (event) {
                .key => |key| {
                    if (key.special == .escape) {
                        running = false;
                        continue;
                    }
                    if (key.codepoint) |cp| {
                        switch (cp) {
                            'q', 'Q' => running = false,
                            'i' => std.log.info("info log {d}", .{tick}),
                            'w' => std.log.warn("warn log {d}", .{tick}),
                            'e' => std.log.err("error log {d}", .{tick}),
                            'd' => std.log.debug("debug log {d}", .{tick}),
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        const now_ms = std.time.milliTimestamp();
        if (now_ms >= next_log_ms) {
            std.log.info("tick {d}", .{tick});
            tick += 1;
            next_log_ms = now_ms + 1000;
        }
    }
}
