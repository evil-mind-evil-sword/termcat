const std = @import("std");
const termcat = @import("termcat");
const Terminal = termcat.Terminal;
const Plane = termcat.Plane.Plane;
const Cell = termcat.Cell;
const Color = termcat.Color;
const Event = termcat.Event;
const Layout = termcat.Layout;

/// Log level with associated color
const LogLevel = enum {
    debug,
    info,
    warn,
    err,
    fatal,

    fn color(self: LogLevel) Color {
        return switch (self) {
            .debug => Color.fromRgb(128, 128, 128),
            .info => Color.cyan,
            .warn => Color.yellow,
            .err => Color.red,
            .fatal => Color.magenta,
        };
    }

    fn label(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO ",
            .warn => "WARN ",
            .err => "ERROR",
            .fatal => "FATAL",
        };
    }
};

/// A log entry
const LogEntry = struct {
    timestamp: []const u8,
    level: LogLevel,
    source: []const u8,
    message: []const u8,
};

/// Sample log data
const sample_logs = [_]LogEntry{
    .{ .timestamp = "12:34:01.123", .level = .info, .source = "main", .message = "Application starting..." },
    .{ .timestamp = "12:34:01.234", .level = .debug, .source = "config", .message = "Loading configuration from /etc/app/config.yaml" },
    .{ .timestamp = "12:34:01.345", .level = .info, .source = "db", .message = "Connecting to database at localhost:5432" },
    .{ .timestamp = "12:34:01.567", .level = .debug, .source = "db", .message = "Connection pool initialized with 10 connections" },
    .{ .timestamp = "12:34:02.012", .level = .info, .source = "http", .message = "HTTP server listening on :8080" },
    .{ .timestamp = "12:34:05.234", .level = .info, .source = "http", .message = "GET /api/users - 200 OK (45ms)" },
    .{ .timestamp = "12:34:05.789", .level = .debug, .source = "cache", .message = "Cache miss for key: user_123" },
    .{ .timestamp = "12:34:06.012", .level = .info, .source = "http", .message = "POST /api/login - 200 OK (123ms)" },
    .{ .timestamp = "12:34:07.345", .level = .warn, .source = "http", .message = "Request timeout approaching threshold (4.5s/5s)" },
    .{ .timestamp = "12:34:08.678", .level = .info, .source = "http", .message = "GET /api/products - 200 OK (89ms)" },
    .{ .timestamp = "12:34:10.123", .level = .err, .source = "db", .message = "Query failed: connection refused to replica-2" },
    .{ .timestamp = "12:34:10.234", .level = .warn, .source = "db", .message = "Falling back to primary database" },
    .{ .timestamp = "12:34:11.456", .level = .info, .source = "db", .message = "Reconnected to primary successfully" },
    .{ .timestamp = "12:34:15.789", .level = .debug, .source = "cache", .message = "Evicting 1024 stale entries" },
    .{ .timestamp = "12:34:20.012", .level = .info, .source = "http", .message = "GET /api/orders - 200 OK (67ms)" },
    .{ .timestamp = "12:34:25.345", .level = .warn, .source = "mem", .message = "Memory usage at 75% (1.5GB/2GB)" },
    .{ .timestamp = "12:34:30.678", .level = .info, .source = "http", .message = "DELETE /api/users/456 - 204 No Content (34ms)" },
    .{ .timestamp = "12:34:35.901", .level = .err, .source = "email", .message = "Failed to send notification: SMTP connection timeout" },
    .{ .timestamp = "12:34:36.234", .level = .info, .source = "email", .message = "Retrying email send (attempt 2/3)" },
    .{ .timestamp = "12:34:37.567", .level = .info, .source = "email", .message = "Email sent successfully on retry" },
    .{ .timestamp = "12:34:40.890", .level = .debug, .source = "gc", .message = "Garbage collection completed in 12ms" },
    .{ .timestamp = "12:34:45.123", .level = .info, .source = "http", .message = "WebSocket connection established from 192.168.1.100" },
    .{ .timestamp = "12:34:50.456", .level = .fatal, .source = "disk", .message = "Disk space critically low (98% used)" },
    .{ .timestamp = "12:34:51.789", .level = .warn, .source = "main", .message = "Initiating graceful shutdown due to disk space" },
    .{ .timestamp = "12:34:55.012", .level = .info, .source = "http", .message = "Closing WebSocket connections..." },
    .{ .timestamp = "12:34:56.345", .level = .info, .source = "db", .message = "Draining connection pool..." },
    .{ .timestamp = "12:34:57.678", .level = .info, .source = "main", .message = "Application shutdown complete" },
};

/// Filter state
const Filter = struct {
    show_debug: bool = true,
    show_info: bool = true,
    show_warn: bool = true,
    show_err: bool = true,
    show_fatal: bool = true,

    fn matches(self: Filter, level: LogLevel) bool {
        return switch (level) {
            .debug => self.show_debug,
            .info => self.show_info,
            .warn => self.show_warn,
            .err => self.show_err,
            .fatal => self.show_fatal,
        };
    }

    fn toggleLevel(self: *Filter, level: LogLevel) void {
        switch (level) {
            .debug => self.show_debug = !self.show_debug,
            .info => self.show_info = !self.show_info,
            .warn => self.show_warn = !self.show_warn,
            .err => self.show_err = !self.show_err,
            .fatal => self.show_fatal = !self.show_fatal,
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var term = try Terminal.init(allocator, .{
        .backend = .{
            .enable_mouse = true,
            .enable_focus_events = true,
            .enable_synchronized_output = true,
        },
    });
    defer term.deinit();

    var size = term.size();
    var running = true;

    // State
    var scroll_offset: usize = 0;
    var selected_line: usize = 0;
    var filter = Filter{};
    var show_details = false;

    while (running) {
        size = term.size();
        const root = term.rootPlane();
        root.clear();

        // Count visible logs
        var visible_count: usize = 0;
        for (sample_logs) |log| {
            if (filter.matches(log.level)) {
                visible_count += 1;
            }
        }

        // Clamp selection
        if (selected_line >= visible_count and visible_count > 0) {
            selected_line = visible_count - 1;
        }

        drawLogViewer(root, size, scroll_offset, selected_line, &filter, show_details);

        try term.present();

        if (try term.pollEvent(null)) |event| {
            switch (event) {
                .key => |key| {
                    if (key.codepoint) |cp| {
                        switch (cp) {
                            'q', 'Q' => running = false,
                            'd' => filter.toggleLevel(.debug),
                            'i' => filter.toggleLevel(.info),
                            'w' => filter.toggleLevel(.warn),
                            'e' => filter.toggleLevel(.err),
                            'f' => filter.toggleLevel(.fatal),
                            ' ', '\r' => show_details = !show_details,
                            'g' => {
                                scroll_offset = 0;
                                selected_line = 0;
                            },
                            'G' => {
                                if (visible_count > 0) {
                                    selected_line = visible_count - 1;
                                    const view_height = size.height -| 6;
                                    if (visible_count > view_height) {
                                        scroll_offset = visible_count - view_height;
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                    if (key.special) |sp| {
                        const view_height = size.height -| 6;
                        switch (sp) {
                            .escape => running = false,
                            .up, .page_up => {
                                if (selected_line > 0) {
                                    selected_line -= 1;
                                    if (selected_line < scroll_offset) {
                                        scroll_offset = selected_line;
                                    }
                                }
                            },
                            .down, .page_down => {
                                if (selected_line + 1 < visible_count) {
                                    selected_line += 1;
                                    if (selected_line >= scroll_offset + view_height) {
                                        scroll_offset = selected_line - view_height + 1;
                                    }
                                }
                            },
                            .enter => show_details = !show_details,
                            else => {},
                        }
                    }
                },
                .resize => |new_size| {
                    size = new_size;
                },
                else => {},
            }
        }
    }
}

fn drawLogViewer(root: *Plane, size: Event.Size, scroll_offset: usize, selected_line: usize, filter: *const Filter, show_details: bool) void {
    const width = size.width;
    const height = size.height;

    // Draw outer border
    Layout.drawBox(root.getBuffer(), .{
        .x = 0,
        .y = 0,
        .width = width,
        .height = height,
    }, Layout.BoxStyle.rounded, Color.fromRgb(80, 80, 80), .default, .{});

    // Title
    const title = " Log Viewer ";
    const title_x = (width -| @as(u16, @intCast(title.len))) / 2;
    root.print(title_x, 0, title, Color.green, .default, .{ .bold = true });

    // Filter bar
    drawFilterBar(root, width, filter);

    // Column headers
    const header_y: u16 = 2;
    root.print(2, header_y, "TIME", Color.fromRgb(150, 150, 150), .default, .{ .bold = true });
    root.print(15, header_y, "LEVEL", Color.fromRgb(150, 150, 150), .default, .{ .bold = true });
    root.print(22, header_y, "SOURCE", Color.fromRgb(150, 150, 150), .default, .{ .bold = true });
    root.print(32, header_y, "MESSAGE", Color.fromRgb(150, 150, 150), .default, .{ .bold = true });

    // Draw separator line
    var x: u16 = 1;
    while (x < width - 1) : (x += 1) {
        root.setCell(x, header_y + 1, .{
            .char = '─',
            .combining = .{ 0, 0 },
            .fg = Color.fromRgb(60, 60, 60),
            .bg = .default,
            .attrs = .{},
        });
    }

    // Draw logs
    const log_start_y: u16 = 4;
    const log_area_height = height -| 6;
    var visible_idx: usize = 0;
    var drawn_count: u16 = 0;

    for (sample_logs) |log| {
        if (!filter.matches(log.level)) continue;

        if (visible_idx >= scroll_offset and drawn_count < log_area_height) {
            const y = log_start_y + drawn_count;
            const is_selected = visible_idx == selected_line;

            drawLogLine(root, y, width, log, is_selected);
            drawn_count += 1;
        }

        visible_idx += 1;
    }

    // Draw details panel if enabled
    if (show_details) {
        drawDetailsPanel(root, size, selected_line, filter);
    }

    // Status bar
    const status_y = height - 1;
    const status_msg = " ↑↓ : Navigate | d/i/w/e/f : Toggle filters | Space : Details | g/G : Top/Bottom | q : Quit ";
    const status_x = (width -| @as(u16, @intCast(status_msg.len))) / 2;
    root.print(status_x, status_y, status_msg, Color.fromRgb(128, 128, 128), .default, .{});
}

fn drawFilterBar(root: *Plane, width: u16, filter: *const Filter) void {
    const y: u16 = 1;
    root.print(2, y, "Filters:", Color.fromRgb(150, 150, 150), .default, .{});

    const filters = [_]struct { key: u8, level: LogLevel, on: bool }{
        .{ .key = 'd', .level = .debug, .on = filter.show_debug },
        .{ .key = 'i', .level = .info, .on = filter.show_info },
        .{ .key = 'w', .level = .warn, .on = filter.show_warn },
        .{ .key = 'e', .level = .err, .on = filter.show_err },
        .{ .key = 'f', .level = .fatal, .on = filter.show_fatal },
    };

    var x: u16 = 12;
    for (filters) |f| {
        if (x + 10 >= width) break;

        // Key hint
        root.setCell(x, y, .{
            .char = '[',
            .combining = .{ 0, 0 },
            .fg = Color.fromRgb(100, 100, 100),
            .bg = .default,
            .attrs = .{},
        });
        x += 1;
        root.setCell(x, y, .{
            .char = f.key,
            .combining = .{ 0, 0 },
            .fg = Color.yellow,
            .bg = .default,
            .attrs = .{},
        });
        x += 1;
        root.setCell(x, y, .{
            .char = ']',
            .combining = .{ 0, 0 },
            .fg = Color.fromRgb(100, 100, 100),
            .bg = .default,
            .attrs = .{},
        });
        x += 1;

        // Level label with state indicator
        const label = f.level.label();
        const fg = if (f.on) f.level.color() else Color.fromRgb(60, 60, 60);
        const attrs: Cell.Attributes = if (f.on) .{} else .{ .dim = true };

        for (label) |c| {
            root.setCell(x, y, .{
                .char = c,
                .combining = .{ 0, 0 },
                .fg = fg,
                .bg = .default,
                .attrs = attrs,
            });
            x += 1;
        }
        x += 1;
    }
}

fn drawLogLine(root: *Plane, y: u16, width: u16, log: LogEntry, is_selected: bool) void {
    const bg: Color = if (is_selected) Color.fromRgb(40, 50, 70) else .default;

    // Draw background for selected line
    if (is_selected) {
        var x: u16 = 1;
        while (x < width - 1) : (x += 1) {
            root.setCell(x, y, .{
                .char = ' ',
                .combining = .{ 0, 0 },
                .fg = .default,
                .bg = bg,
                .attrs = .{},
            });
        }
    }

    // Selection indicator
    if (is_selected) {
        root.setCell(1, y, .{
            .char = '▶',
            .combining = .{ 0, 0 },
            .fg = Color.cyan,
            .bg = bg,
            .attrs = .{},
        });
    }

    // Timestamp
    var x: u16 = 2;
    for (log.timestamp) |c| {
        if (x >= 14) break;
        root.setCell(x, y, .{
            .char = c,
            .combining = .{ 0, 0 },
            .fg = Color.fromRgb(150, 150, 150),
            .bg = bg,
            .attrs = .{},
        });
        x += 1;
    }

    // Level
    x = 15;
    const level_label = log.level.label();
    for (level_label) |c| {
        root.setCell(x, y, .{
            .char = c,
            .combining = .{ 0, 0 },
            .fg = log.level.color(),
            .bg = bg,
            .attrs = .{ .bold = true },
        });
        x += 1;
    }

    // Source
    x = 22;
    for (log.source) |c| {
        if (x >= 31) break;
        root.setCell(x, y, .{
            .char = c,
            .combining = .{ 0, 0 },
            .fg = Color.fromRgb(180, 180, 180),
            .bg = bg,
            .attrs = .{},
        });
        x += 1;
    }

    // Message
    x = 32;
    const max_msg_len = width -| 34;
    const msg_len = @min(log.message.len, max_msg_len);
    for (log.message[0..msg_len]) |c| {
        root.setCell(x, y, .{
            .char = c,
            .combining = .{ 0, 0 },
            .fg = if (is_selected) Color.white else .default,
            .bg = bg,
            .attrs = .{},
        });
        x += 1;
    }

    // Truncation indicator
    if (log.message.len > max_msg_len) {
        root.print(width - 4, y, "...", Color.fromRgb(100, 100, 100), bg, .{});
    }
}

fn drawDetailsPanel(root: *Plane, size: Event.Size, selected_line: usize, filter: *const Filter) void {
    const panel_width: u16 = @min(60, size.width -| 10);
    const panel_height: u16 = 10;
    const panel_x = (size.width -| panel_width) / 2;
    const panel_y = (size.height -| panel_height) / 2;

    // Find the selected log entry
    var visible_idx: usize = 0;
    var selected_log: ?LogEntry = null;
    for (sample_logs) |log| {
        if (!filter.matches(log.level)) continue;
        if (visible_idx == selected_line) {
            selected_log = log;
            break;
        }
        visible_idx += 1;
    }

    const log = selected_log orelse return;

    // Draw panel background
    var y = panel_y;
    while (y < panel_y + panel_height) : (y += 1) {
        var x = panel_x;
        while (x < panel_x + panel_width) : (x += 1) {
            root.setCell(x, y, .{
                .char = ' ',
                .combining = .{ 0, 0 },
                .fg = .default,
                .bg = Color.fromRgb(30, 30, 40),
                .attrs = .{},
            });
        }
    }

    // Draw panel border
    Layout.drawBox(root.getBuffer(), .{
        .x = panel_x,
        .y = panel_y,
        .width = panel_width,
        .height = panel_height,
    }, Layout.BoxStyle.heavy, log.level.color(), .default, .{});

    // Title
    const detail_title = " Log Details ";
    root.print(panel_x + (panel_width -| @as(u16, @intCast(detail_title.len))) / 2, panel_y, detail_title, log.level.color(), .default, .{ .bold = true });

    // Details
    const content_x = panel_x + 2;
    const content_y = panel_y + 2;

    root.print(content_x, content_y, "Time:", Color.fromRgb(150, 150, 150), .default, .{});
    root.print(content_x + 10, content_y, log.timestamp, Color.white, .default, .{});

    root.print(content_x, content_y + 1, "Level:", Color.fromRgb(150, 150, 150), .default, .{});
    root.print(content_x + 10, content_y + 1, log.level.label(), log.level.color(), .default, .{ .bold = true });

    root.print(content_x, content_y + 2, "Source:", Color.fromRgb(150, 150, 150), .default, .{});
    root.print(content_x + 10, content_y + 2, log.source, Color.cyan, .default, .{});

    root.print(content_x, content_y + 4, "Message:", Color.fromRgb(150, 150, 150), .default, .{});

    // Word-wrap message
    const max_msg_width = panel_width -| 4;
    var msg_y = content_y + 5;
    var msg_start: usize = 0;
    while (msg_start < log.message.len and msg_y < panel_y + panel_height - 1) {
        const remaining = log.message.len - msg_start;
        const line_len = @min(remaining, max_msg_width);
        root.print(content_x, msg_y, log.message[msg_start .. msg_start + line_len], Color.white, .default, .{});
        msg_start += line_len;
        msg_y += 1;
    }
}
