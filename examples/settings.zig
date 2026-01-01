const std = @import("std");
const termcat = @import("termcat");
const Terminal = termcat.Terminal;
const Plane = termcat.Plane.Plane;
const Cell = termcat.Cell;
const Color = termcat.Color;
const Event = termcat.Event;
const Layout = termcat.Layout;

/// A setting entry with label and current value
const Setting = struct {
    label: []const u8,
    value: Value,

    const Value = union(enum) {
        boolean: bool,
        choice: struct {
            options: []const []const u8,
            selected: usize,
        },
        range: struct {
            min: i32,
            max: i32,
            current: i32,
        },
    };
};

/// Settings category
const Category = struct {
    name: []const u8,
    icon: u21,
    settings: []const Setting,
};

/// Demo categories and settings
const categories = [_]Category{
    .{
        .name = "General",
        .icon = '⚙',
        .settings = &[_]Setting{
            .{ .label = "Auto-save", .value = .{ .boolean = true } },
            .{ .label = "Language", .value = .{ .choice = .{
                .options = &[_][]const u8{ "English", "Spanish", "French", "German", "Japanese" },
                .selected = 0,
            } } },
            .{ .label = "Font Size", .value = .{ .range = .{ .min = 8, .max = 24, .current = 14 } } },
        },
    },
    .{
        .name = "Appearance",
        .icon = '🎨',
        .settings = &[_]Setting{
            .{ .label = "Dark Mode", .value = .{ .boolean = true } },
            .{ .label = "Theme", .value = .{ .choice = .{
                .options = &[_][]const u8{ "Default", "Ocean", "Forest", "Sunset", "Midnight" },
                .selected = 3,
            } } },
            .{ .label = "Transparency", .value = .{ .range = .{ .min = 0, .max = 100, .current = 90 } } },
        },
    },
    .{
        .name = "Keyboard",
        .icon = '⌨',
        .settings = &[_]Setting{
            .{ .label = "Vim Mode", .value = .{ .boolean = false } },
            .{ .label = "Key Repeat", .value = .{ .boolean = true } },
            .{ .label = "Repeat Delay", .value = .{ .range = .{ .min = 100, .max = 500, .current = 250 } } },
        },
    },
    .{
        .name = "Network",
        .icon = '🌐',
        .settings = &[_]Setting{
            .{ .label = "Auto-connect", .value = .{ .boolean = true } },
            .{ .label = "Proxy", .value = .{ .choice = .{
                .options = &[_][]const u8{ "None", "System", "Manual" },
                .selected = 1,
            } } },
            .{ .label = "Timeout (sec)", .value = .{ .range = .{ .min = 5, .max = 120, .current = 30 } } },
        },
    },
};

/// Mutable state for the demo
const State = struct {
    selected_category: usize = 0,
    selected_setting: usize = 0,
    in_settings_pane: bool = false,
    // Copy settings so we can modify them
    settings: [categories.len][]Setting = undefined,

    fn init(allocator: std.mem.Allocator) !State {
        var state = State{};
        for (categories, 0..) |cat, i| {
            const settings_copy = try allocator.alloc(Setting, cat.settings.len);
            @memcpy(settings_copy, cat.settings);
            state.settings[i] = settings_copy;
        }
        return state;
    }

    fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (&self.settings) |settings| {
            allocator.free(settings);
        }
    }

    fn currentSettings(self: *State) []Setting {
        return self.settings[self.selected_category];
    }

    fn currentSetting(self: *State) *Setting {
        return &self.settings[self.selected_category][self.selected_setting];
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

    var state = try State.init(allocator);
    defer state.deinit(allocator);

    var size = term.size();
    var running = true;

    while (running) {
        size = term.size();
        const root = term.rootPlane();
        root.clear();

        drawSettingsUI(root, size, &state);

        try term.present();

        if (try term.pollEvent(null)) |event| {
            switch (event) {
                .key => |key| {
                    if (key.codepoint) |cp| {
                        if (cp == 'q' or cp == 'Q') {
                            running = false;
                        } else if (cp == 'h' or cp == '\t') {
                            state.in_settings_pane = !state.in_settings_pane;
                        } else if (cp == 'l') {
                            state.in_settings_pane = true;
                        } else if (cp == ' ' or cp == '\r') {
                            toggleCurrentSetting(&state);
                        }
                    }
                    if (key.special) |sp| {
                        switch (sp) {
                            .escape => running = false,
                            .left => state.in_settings_pane = false,
                            .right => state.in_settings_pane = true,
                            .up => {
                                if (state.in_settings_pane) {
                                    if (state.selected_setting > 0) {
                                        state.selected_setting -= 1;
                                    }
                                } else {
                                    if (state.selected_category > 0) {
                                        state.selected_category -= 1;
                                        state.selected_setting = 0;
                                    }
                                }
                            },
                            .down => {
                                if (state.in_settings_pane) {
                                    if (state.selected_setting < state.currentSettings().len - 1) {
                                        state.selected_setting += 1;
                                    }
                                } else {
                                    if (state.selected_category < categories.len - 1) {
                                        state.selected_category += 1;
                                        state.selected_setting = 0;
                                    }
                                }
                            },
                            .enter => toggleCurrentSetting(&state),
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

fn toggleCurrentSetting(state: *State) void {
    const setting = state.currentSetting();
    switch (setting.value) {
        .boolean => |*b| b.* = !b.*,
        .choice => |*c| {
            c.selected = (c.selected + 1) % c.options.len;
        },
        .range => |*r| {
            // Cycle through range in increments
            const step = @divFloor(r.max - r.min, 10);
            r.current += step;
            if (r.current > r.max) {
                r.current = r.min;
            }
        },
    }
}

fn drawSettingsUI(root: *Plane, size: Event.Size, state: *State) void {
    const width = size.width;
    const height = size.height;

    // Draw outer border
    Layout.drawBox(root.getBuffer(), .{
        .x = 0,
        .y = 0,
        .width = width,
        .height = height,
    }, Layout.BoxStyle.rounded, Color.fromRgb(100, 100, 100), .default, .{});

    // Title
    const title = " Settings ";
    const title_x = (width -| @as(u16, @intCast(title.len))) / 2;
    root.print(title_x, 0, title, Color.cyan, .default, .{ .bold = true });

    // Calculate pane widths
    const sidebar_width: u16 = 20;
    const content_x = sidebar_width + 1;
    const content_width = width -| sidebar_width -| 2;

    // Draw vertical divider
    var y: u16 = 1;
    while (y < height - 1) : (y += 1) {
        root.setCell(sidebar_width, y, .{
            .char = '│',
            .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
            .fg = Color.fromRgb(100, 100, 100),
            .bg = .default,
            .attrs = .{},
        });
    }

    // Draw categories in sidebar
    drawSidebar(root, sidebar_width, height, state);

    // Draw settings in content area
    drawContent(root, content_x, content_width, height, state);

    // Status bar
    const status_y = height - 1;
    const status_msg = " Tab/←→ : Switch pane | ↑↓ : Navigate | Space/Enter : Toggle | q : Quit ";
    const status_x = (width -| @as(u16, @intCast(status_msg.len))) / 2;
    root.print(status_x, status_y, status_msg, Color.fromRgb(128, 128, 128), .default, .{});
}

fn drawSidebar(root: *Plane, sidebar_width: u16, height: u16, state: *State) void {
    _ = height;
    const start_y: u16 = 2;

    for (categories, 0..) |cat, i| {
        const y = start_y + @as(u16, @intCast(i)) * 2;
        const is_selected = i == state.selected_category;
        const is_focused = is_selected and !state.in_settings_pane;

        // Highlight background for focused item
        if (is_focused) {
            var x: u16 = 1;
            while (x < sidebar_width) : (x += 1) {
                root.setCell(x, y, .{
                    .char = ' ',
                    .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                    .fg = .default,
                    .bg = Color.fromRgb(40, 60, 80),
                    .attrs = .{},
                });
            }
        }

        // Draw icon
        root.setCell(2, y, .{
            .char = cat.icon,
            .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
            .fg = if (is_selected) Color.cyan else Color.fromRgb(180, 180, 180),
            .bg = if (is_focused) Color.fromRgb(40, 60, 80) else .default,
            .attrs = .{},
        });

        // Draw name
        const fg: Color = if (is_selected) Color.cyan else .default;
        const bg: Color = if (is_focused) Color.fromRgb(40, 60, 80) else .default;
        const attrs: Cell.Attributes = if (is_selected) .{ .bold = true } else .{};

        var x: u16 = 4;
        for (cat.name) |c| {
            if (x >= sidebar_width - 1) break;
            root.setCell(x, y, .{
                .char = c,
                .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                .fg = fg,
                .bg = bg,
                .attrs = attrs,
            });
            x += 1;
        }

        // Selection indicator
        if (is_selected) {
            root.setCell(sidebar_width - 1, y, .{
                .char = if (state.in_settings_pane) '›' else '▶',
                .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                .fg = Color.cyan,
                .bg = if (is_focused) Color.fromRgb(40, 60, 80) else .default,
                .attrs = .{},
            });
        }
    }
}

fn drawContent(root: *Plane, content_x: u16, content_width: u16, height: u16, state: *State) void {
    _ = height;
    const cat = categories[state.selected_category];

    // Category header
    root.print(content_x + 2, 1, cat.name, Color.white, .default, .{ .bold = true, .underline = true });

    // Draw settings
    const start_y: u16 = 3;
    const settings = state.currentSettings();

    for (settings, 0..) |setting, i| {
        const y = start_y + @as(u16, @intCast(i)) * 2;
        const is_selected = i == state.selected_setting and state.in_settings_pane;

        // Highlight row if selected
        if (is_selected) {
            var x = content_x + 1;
            while (x < content_x + content_width - 1) : (x += 1) {
                root.setCell(x, y, .{
                    .char = ' ',
                    .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                    .fg = .default,
                    .bg = Color.fromRgb(40, 60, 80),
                    .attrs = .{},
                });
            }
        }

        // Draw label
        const label_fg: Color = if (is_selected) Color.white else Color.fromRgb(200, 200, 200);
        const label_bg: Color = if (is_selected) Color.fromRgb(40, 60, 80) else .default;

        var x = content_x + 2;
        for (setting.label) |c| {
            root.setCell(x, y, .{
                .char = c,
                .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                .fg = label_fg,
                .bg = label_bg,
                .attrs = .{},
            });
            x += 1;
        }

        // Draw value on the right side
        const value_x = content_x + content_width - 15;
        drawSettingValue(root, value_x, y, setting.value, is_selected);
    }
}

fn drawSettingValue(root: *Plane, x: u16, y: u16, value: Setting.Value, is_selected: bool) void {
    const bg: Color = if (is_selected) Color.fromRgb(40, 60, 80) else .default;

    switch (value) {
        .boolean => |b| {
            const text = if (b) "  ON " else " OFF ";
            const fg: Color = if (b) Color.green else Color.red;
            var px = x;
            for (text) |c| {
                root.setCell(px, y, .{
                    .char = c,
                    .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                    .fg = fg,
                    .bg = bg,
                    .attrs = .{ .bold = true },
                });
                px += 1;
            }
        },
        .choice => |c| {
            const selected_text = c.options[c.selected];
            const max_len: usize = 12;
            const display_len = @min(selected_text.len, max_len);
            var px = x;
            for (selected_text[0..display_len]) |ch| {
                root.setCell(px, y, .{
                    .char = ch,
                    .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                    .fg = Color.yellow,
                    .bg = bg,
                    .attrs = .{},
                });
                px += 1;
            }
        },
        .range => |r| {
            // Draw a small bar visualization
            const bar_width: u16 = 10;
            const filled = @as(u16, @intCast(@divFloor((r.current - r.min) * bar_width, r.max - r.min)));

            root.setCell(x, y, .{
                .char = '[',
                .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                .fg = Color.fromRgb(100, 100, 100),
                .bg = bg,
                .attrs = .{},
            });

            var px: u16 = 0;
            while (px < bar_width) : (px += 1) {
                const char: u21 = if (px < filled) '█' else '░';
                const fg: Color = if (px < filled) Color.cyan else Color.fromRgb(60, 60, 60);
                root.setCell(x + 1 + px, y, .{
                    .char = char,
                    .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                    .fg = fg,
                    .bg = bg,
                    .attrs = .{},
                });
            }

            root.setCell(x + bar_width + 1, y, .{
                .char = ']',
                .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                .fg = Color.fromRgb(100, 100, 100),
                .bg = bg,
                .attrs = .{},
            });
        },
    }
}
