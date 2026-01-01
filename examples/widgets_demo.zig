//! Widget Integration Demo
//!
//! Demonstrates termcat's TUI widget system including:
//! - Label: Static text display with alignment
//! - Button: Interactive buttons with click handling
//! - InputField: Text input with editing
//! - ProgressBar: Progress indicators and spinners
//! - Tabs: Tab navigation between views
//! - Flex: Flexible layout containers
//! - Border: Decorative borders around content
//! - ScrollView: Scrollable content areas
//!
//! Controls:
//! - Tab/Shift+Tab: Navigate between widgets
//! - Enter: Activate buttons
//! - Arrow keys: Adjust values, navigate tabs
//! - Type: Edit input fields
//! - q: Quit

const std = @import("std");
const termcat = @import("termcat");
const Terminal = termcat.Terminal;
const Plane = termcat.Plane.Plane;
const Cell = termcat.Cell;
const Color = termcat.Color;
const Event = termcat.Event;
const Layout = termcat.Layout;
const tui = termcat.tui;

// Demo state
const DemoState = struct {
    // Current focus
    focus_index: usize = 0,

    // Widget states
    name_input: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    email_input: [64]u8 = [_]u8{0} ** 64,
    email_len: usize = 0,

    // Progress values
    download_progress: f32 = 0.0,
    upload_progress: f32 = 0.35,
    spinner_frame: usize = 0,

    // Tab state
    current_tab: usize = 0,

    // Messages
    status_message: []const u8 = "Welcome to the Widget Demo!",

    // Counter for button demo
    counter: i32 = 0,

    const num_focusable = 6; // name, email, submit, reset, counter+, counter-
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize terminal
    var term = try Terminal.init(allocator, .{});
    defer term.deinit();

    var state = DemoState{};

    // Animation timer
    var last_frame: i64 = std.time.milliTimestamp();

    // Main loop
    while (true) {
        const now = std.time.milliTimestamp();
        const delta = now - last_frame;

        // Animate every 100ms
        if (delta >= 100) {
            last_frame = now;

            // Animate progress
            state.download_progress += 0.02;
            if (state.download_progress > 1.0) state.download_progress = 0.0;

            // Animate spinner
            state.spinner_frame = (state.spinner_frame + 1) % 10;
        }

        // Render
        try render(&term, &state);
        try term.present();

        // Handle input
        if (try term.pollEvent(50)) |event| {
            switch (event) {
                .key => |key| {
                    if (key.codepoint == 'q' and key.mods.ctrl) break;
                    if (key.codepoint == 'c' and key.mods.ctrl) break;
                    if (key.codepoint == 'q') break;

                    handleInput(&state, key);
                },
                .resize => {},
                else => {},
            }
        }
    }
}

fn handleInput(state: *DemoState, key: Event.Key) void {
    // Tab navigation
    if (key.codepoint == '\t') {
        if (key.mods.shift) {
            state.focus_index = if (state.focus_index == 0) DemoState.num_focusable - 1 else state.focus_index - 1;
        } else {
            state.focus_index = (state.focus_index + 1) % DemoState.num_focusable;
        }
        return;
    }

    // Arrow keys for tab switching
    if (key.codepoint == 0 and key.base == .left) {
        if (state.current_tab > 0) state.current_tab -= 1;
        return;
    }
    if (key.codepoint == 0 and key.base == .right) {
        if (state.current_tab < 2) state.current_tab += 1;
        return;
    }

    // Handle input based on focus
    switch (state.focus_index) {
        0 => handleTextInput(&state.name_input, &state.name_len, key), // Name field
        1 => handleTextInput(&state.email_input, &state.email_len, key), // Email field
        2 => { // Submit button
            if (key.codepoint == '\r' or key.codepoint == ' ') {
                state.status_message = "Form submitted successfully!";
            }
        },
        3 => { // Reset button
            if (key.codepoint == '\r' or key.codepoint == ' ') {
                state.name_len = 0;
                state.email_len = 0;
                state.counter = 0;
                state.status_message = "Form reset!";
            }
        },
        4 => { // Counter +
            if (key.codepoint == '\r' or key.codepoint == ' ') {
                state.counter += 1;
                state.status_message = "Counter incremented!";
            }
        },
        5 => { // Counter -
            if (key.codepoint == '\r' or key.codepoint == ' ') {
                state.counter -= 1;
                state.status_message = "Counter decremented!";
            }
        },
        else => {},
    }
}

fn handleTextInput(buffer: *[64]u8, len: *usize, key: Event.Key) void {
    // Backspace
    if (key.codepoint == 0x7F or key.codepoint == 0x08) {
        if (len.* > 0) len.* -= 1;
        return;
    }

    // Printable characters
    if (key.codepoint >= 0x20 and key.codepoint < 0x7F) {
        if (len.* < buffer.len - 1) {
            buffer[len.*] = @truncate(key.codepoint);
            len.* += 1;
        }
    }
}

fn render(term: *Terminal, state: *DemoState) !void {
    const size = term.size();
    term.clear();

    // Title bar
    const title = " termcat Widget Demo ";
    const title_x = (size.width -| @as(u16, @intCast(title.len))) / 2;
    term.draw(title_x, 0, title, Color.bright_white, Color.blue, .{ .bold = true });

    // Fill title bar background
    var x: u16 = 0;
    while (x < size.width) : (x += 1) {
        if (x < title_x or x >= title_x + title.len) {
            term.draw(x, 0, " ", .default, Color.blue, .{});
        }
    }

    // Tab bar
    try renderTabs(term, state, 2);

    // Content area based on selected tab
    const content_y: u16 = 4;
    switch (state.current_tab) {
        0 => try renderFormTab(term, state, content_y),
        1 => try renderProgressTab(term, state, content_y),
        2 => try renderInfoTab(term, state, content_y),
        else => {},
    }

    // Status bar
    const status_y = size.height - 1;
    x = 0;
    while (x < size.width) : (x += 1) {
        term.draw(x, status_y, " ", .default, Color.bright_black, .{});
    }
    term.draw(1, status_y, state.status_message, Color.bright_white, Color.bright_black, .{});

    // Help text
    const help = " Tab:Navigate | Enter:Activate | Left/Right:Switch tabs | q:Quit ";
    const help_x = size.width -| @as(u16, @intCast(help.len)) -| 1;
    term.draw(help_x, status_y, help, Color.bright_yellow, Color.bright_black, .{});
}

fn renderTabs(term: *Terminal, state: *DemoState, y: u16) !void {
    const tabs = [_][]const u8{ " Form ", " Progress ", " Info " };
    var x: u16 = 2;

    for (tabs, 0..) |tab, i| {
        const is_selected = i == state.current_tab;
        const fg = if (is_selected) Color.bright_white else Color.white;
        const bg = if (is_selected) Color.blue else .default;
        const attrs: Cell.Attributes = if (is_selected) .{ .bold = true } else .{};

        term.draw(x, y, tab, fg, bg, attrs);
        x += @intCast(tab.len + 1);
    }
}

fn renderFormTab(term: *Terminal, state: *DemoState, start_y: u16) !void {
    var y = start_y;

    // Form title
    term.draw(4, y, "User Registration Form", Color.bright_cyan, .default, .{ .bold = true, .underline = true });
    y += 2;

    // Name field
    const name_focused = state.focus_index == 0;
    term.draw(4, y, "Name:", Color.white, .default, .{});
    renderInputField(term, 12, y, 30, state.name_input[0..state.name_len], name_focused);
    y += 2;

    // Email field
    const email_focused = state.focus_index == 1;
    term.draw(4, y, "Email:", Color.white, .default, .{});
    renderInputField(term, 12, y, 30, state.email_input[0..state.email_len], email_focused);
    y += 2;

    // Buttons
    const submit_focused = state.focus_index == 2;
    const reset_focused = state.focus_index == 3;

    renderButton(term, 12, y, " Submit ", submit_focused, Color.green);
    renderButton(term, 24, y, " Reset ", reset_focused, Color.red);
    y += 3;

    // Counter section
    term.draw(4, y, "Counter Demo:", Color.bright_cyan, .default, .{ .bold = true });
    y += 1;

    var buf: [16]u8 = undefined;
    const counter_str = std.fmt.bufPrint(&buf, "{d}", .{state.counter}) catch "?";

    term.draw(4, y, "Value:", Color.white, .default, .{});
    term.draw(12, y, counter_str, Color.bright_yellow, .default, .{ .bold = true });

    const plus_focused = state.focus_index == 4;
    const minus_focused = state.focus_index == 5;
    renderButton(term, 20, y, " + ", plus_focused, Color.cyan);
    renderButton(term, 26, y, " - ", minus_focused, Color.magenta);
}

fn renderProgressTab(term: *Terminal, state: *DemoState, start_y: u16) !void {
    var y = start_y;

    term.draw(4, y, "Progress Indicators", Color.bright_cyan, .default, .{ .bold = true, .underline = true });
    y += 2;

    // Download progress
    term.draw(4, y, "Download:", Color.white, .default, .{});
    renderProgressBar(term, 16, y, 30, state.download_progress, Color.green);
    var buf: [8]u8 = undefined;
    const pct = std.fmt.bufPrint(&buf, "{d:>3}%", .{@as(u8, @intFromFloat(state.download_progress * 100))}) catch "???%";
    term.draw(48, y, pct, Color.bright_green, .default, .{});
    y += 2;

    // Upload progress
    term.draw(4, y, "Upload:", Color.white, .default, .{});
    renderProgressBar(term, 16, y, 30, state.upload_progress, Color.blue);
    const pct2 = std.fmt.bufPrint(&buf, "{d:>3}%", .{@as(u8, @intFromFloat(state.upload_progress * 100))}) catch "???%";
    term.draw(48, y, pct2, Color.bright_blue, .default, .{});
    y += 2;

    // Spinner
    const spinner_chars = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    term.draw(4, y, "Processing:", Color.white, .default, .{});
    term.draw(16, y, spinner_chars[state.spinner_frame], Color.bright_yellow, .default, .{});
    term.draw(18, y, " Please wait...", Color.bright_black, .default, .{ .italic = true });
    y += 3;

    // Different progress bar styles
    term.draw(4, y, "Styles:", Color.bright_cyan, .default, .{ .bold = true });
    y += 1;

    term.draw(4, y, "Block:", Color.white, .default, .{});
    renderProgressBarStyle(term, 16, y, 20, 0.7, "█", "░", Color.magenta);
    y += 1;

    term.draw(4, y, "Arrow:", Color.white, .default, .{});
    renderProgressBarStyle(term, 16, y, 20, 0.5, "▶", "─", Color.cyan);
    y += 1;

    term.draw(4, y, "Dots:", Color.white, .default, .{});
    renderProgressBarStyle(term, 16, y, 20, 0.3, "●", "○", Color.yellow);
}

fn renderInfoTab(term: *Terminal, state: *DemoState, start_y: u16) !void {
    _ = state;
    var y = start_y;

    term.draw(4, y, "About termcat Widgets", Color.bright_cyan, .default, .{ .bold = true, .underline = true });
    y += 2;

    const info_lines = [_][]const u8{
        "This demo showcases termcat's TUI widget system:",
        "",
        "  • Label      - Static text with alignment and styling",
        "  • Button     - Interactive buttons with focus states",
        "  • InputField - Text input with cursor and editing",
        "  • ProgressBar - Progress indicators with custom styles",
        "  • Tabs       - Tab-based navigation between views",
        "  • Theme      - Consistent styling across widgets",
        "  • StyledText - Rich text with style spans",
        "  • Truncation - Text truncation with ellipsis/fade",
        "",
        "New Features:",
        "  • Extended Unicode support (8 combining marks)",
        "  • OSC 52 clipboard integration",
        "  • OSC 8 hyperlink support",
        "  • Cursor style control (block/underline/bar)",
        "",
        "Press 'q' to exit the demo.",
    };

    for (info_lines) |line| {
        term.draw(4, y, line, Color.white, .default, .{});
        y += 1;
    }
}

fn renderInputField(term: *Terminal, x: u16, y: u16, width: u16, text: []const u8, focused: bool) void {
    const fg = if (focused) Color.bright_white else Color.white;
    const bg = if (focused) Color.blue else Color.bright_black;

    // Draw field background
    var i: u16 = 0;
    while (i < width) : (i += 1) {
        term.draw(x + i, y, " ", fg, bg, .{});
    }

    // Draw text
    if (text.len > 0) {
        const display_text = if (text.len > width - 1) text[0 .. width - 1] else text;
        term.draw(x, y, display_text, fg, bg, .{});
    }

    // Draw cursor if focused
    if (focused) {
        const cursor_x = x + @as(u16, @intCast(@min(text.len, width - 1)));
        term.draw(cursor_x, y, "▌", Color.bright_yellow, bg, .{ .blink = true });
    }
}

fn renderButton(term: *Terminal, x: u16, y: u16, label: []const u8, focused: bool, accent: Color) void {
    const fg = if (focused) Color.bright_white else Color.white;
    const bg = if (focused) accent else .default;
    const attrs: Cell.Attributes = if (focused) .{ .bold = true } else .{};

    term.draw(x, y, label, fg, bg, attrs);
}

fn renderProgressBar(term: *Terminal, x: u16, y: u16, width: u16, progress: f32, color: Color) void {
    const filled = @as(u16, @intFromFloat(@as(f32, @floatFromInt(width)) * @min(progress, 1.0)));

    var i: u16 = 0;
    while (i < width) : (i += 1) {
        if (i < filled) {
            term.draw(x + i, y, "█", color, .default, .{});
        } else {
            term.draw(x + i, y, "░", Color.bright_black, .default, .{});
        }
    }
}

fn renderProgressBarStyle(term: *Terminal, x: u16, y: u16, width: u16, progress: f32, filled_char: []const u8, empty_char: []const u8, color: Color) void {
    const filled = @as(u16, @intFromFloat(@as(f32, @floatFromInt(width)) * @min(progress, 1.0)));

    var i: u16 = 0;
    while (i < width) : (i += 1) {
        if (i < filled) {
            term.draw(x + i, y, filled_char, color, .default, .{});
        } else {
            term.draw(x + i, y, empty_char, Color.bright_black, .default, .{});
        }
    }
}
