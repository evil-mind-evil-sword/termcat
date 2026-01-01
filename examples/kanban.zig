const std = @import("std");
const termcat = @import("termcat");
const Terminal = termcat.Terminal;
const Plane = termcat.Plane.Plane;
const Cell = termcat.Cell;
const Color = termcat.Color;
const Event = termcat.Event;

// TUI widgets
const tui = termcat.tui;
const Widget = tui.Widget;
const Flex = tui.Flex;
const Border = tui.Border;
const Padding = tui.Padding;
const Label = tui.Label;
const PlaneView = tui.PlaneView;
const Constraint = tui.Constraint;

/// A single task in the kanban board
const Task = struct {
    title: []const u8,
    priority: enum { low, medium, high },
};

/// Kanban column data
const Column = struct {
    title: []const u8,
    tasks: []const Task,
};

/// Demo data for the kanban board
const columns = [_]Column{
    .{
        .title = "To Do",
        .tasks = &[_]Task{
            .{ .title = "Implement Flex widget", .priority = .high },
            .{ .title = "Add ScrollView", .priority = .medium },
            .{ .title = "Write documentation", .priority = .low },
            .{ .title = "Add mouse support", .priority = .medium },
            .{ .title = "Performance tuning", .priority = .low },
        },
    },
    .{
        .title = "In Progress",
        .tasks = &[_]Task{
            .{ .title = "Border decorators", .priority = .high },
            .{ .title = "Label widget", .priority = .medium },
        },
    },
    .{
        .title = "Done",
        .tasks = &[_]Task{
            .{ .title = "Plane abstraction", .priority = .high },
            .{ .title = "Input decoder", .priority = .high },
            .{ .title = "Color support", .priority = .medium },
        },
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize terminal
    var term = try Terminal.init(allocator, .{
        .backend = .{
            .enable_mouse = true,
            .enable_focus_events = true,
            .enable_synchronized_output = true,
        },
    });
    defer term.deinit();

    var size = term.size();

    // State
    var selected_column: usize = 0;
    var selected_task: usize = 0;
    var running = true;

    while (running) {
        // Get current size (may have changed)
        size = term.size();

        // Clear and redraw
        const root = term.rootPlane();
        root.clear();

        // Draw the board
        drawKanbanBoard(root, size, selected_column, selected_task);

        // Present
        try term.present();

        // Wait for input
        if (try term.pollEvent(null)) |event| {
            switch (event) {
                .key => |key| {
                    // Handle regular character keys
                    if (key.codepoint) |cp| {
                        if (cp == 'q' or cp == 'Q') {
                            running = false;
                        } else if (cp == 'h') {
                            if (selected_column > 0) {
                                selected_column -= 1;
                                selected_task = @min(selected_task, columns[selected_column].tasks.len -| 1);
                            }
                        } else if (cp == 'l') {
                            if (selected_column < columns.len - 1) {
                                selected_column += 1;
                                selected_task = @min(selected_task, columns[selected_column].tasks.len -| 1);
                            }
                        } else if (cp == 'k') {
                            if (selected_task > 0) {
                                selected_task -= 1;
                            }
                        } else if (cp == 'j') {
                            if (selected_task < columns[selected_column].tasks.len -| 1) {
                                selected_task += 1;
                            }
                        }
                    }
                    // Handle special keys (arrows, escape)
                    if (key.special) |sp| {
                        switch (sp) {
                            .escape => running = false,
                            .left => {
                                if (selected_column > 0) {
                                    selected_column -= 1;
                                    selected_task = @min(selected_task, columns[selected_column].tasks.len -| 1);
                                }
                            },
                            .right => {
                                if (selected_column < columns.len - 1) {
                                    selected_column += 1;
                                    selected_task = @min(selected_task, columns[selected_column].tasks.len -| 1);
                                }
                            },
                            .up => {
                                if (selected_task > 0) {
                                    selected_task -= 1;
                                }
                            },
                            .down => {
                                if (selected_task < columns[selected_column].tasks.len -| 1) {
                                    selected_task += 1;
                                }
                            },
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

fn drawKanbanBoard(root: *Plane, size: Event.Size, selected_col: usize, selected_task_idx: usize) void {
    const width = size.width;
    const height = size.height;

    // Draw outer border using Layout (takes *Buffer, so use getBuffer)
    const Layout = termcat.Layout;
    Layout.drawBox(root.getBuffer(), .{
        .x = 0,
        .y = 0,
        .width = width,
        .height = height,
    }, Layout.BoxStyle.rounded, Color.cyan, .default, .{});

    // Draw title
    const title = " Kanban Board - Press q to quit, arrows to navigate ";
    const title_x = (width -| @as(u16, @intCast(title.len))) / 2;
    root.print(title_x, 0, title, Color.cyan, .default, .{ .bold = true });

    // Calculate column widths (equal distribution with 1-cell padding)
    const inner_width = width -| 2; // subtract border
    const inner_height = height -| 3; // subtract border + status
    const col_count: u16 = @intCast(columns.len);
    const col_width = inner_width / col_count;

    // Draw each column
    for (columns, 0..) |column, col_idx| {
        const col_x = 1 + @as(u16, @intCast(col_idx)) * col_width;
        const is_selected_col = col_idx == selected_col;

        // Column border style
        const col_style: Layout.BoxStyle = if (is_selected_col) Layout.BoxStyle.heavy else Layout.BoxStyle.light;
        const col_color: Color = if (is_selected_col) Color.yellow else Color.white;

        // Draw column box
        Layout.drawBox(root.getBuffer(), .{
            .x = col_x,
            .y = 1,
            .width = col_width -| 1,
            .height = inner_height,
        }, col_style, col_color, .default, .{});

        // Draw column title
        const title_start = col_x + 2;
        root.print(title_start, 1, column.title, col_color, .default, .{ .bold = true });

        // Draw tasks
        for (column.tasks, 0..) |task, task_idx| {
            const task_y = 3 + @as(u16, @intCast(task_idx));
            if (task_y >= inner_height) break; // Don't overflow

            const is_selected = is_selected_col and task_idx == selected_task_idx;

            // Priority indicator
            const priority_char: u21 = switch (task.priority) {
                .high => '!',
                .medium => '*',
                .low => '-',
            };
            const priority_color: Color = switch (task.priority) {
                .high => Color.red,
                .medium => Color.yellow,
                .low => Color.green,
            };

            // Draw task
            const task_x = col_x + 1;
            const max_title_len = col_width -| 5;

            // Selection indicator
            if (is_selected) {
                root.setCell(task_x, task_y, .{
                    .char = '>',
                    .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                    .fg = Color.cyan,
                    .bg = .default,
                    .attrs = .{ .bold = true },
                });
            }

            // Priority
            root.setCell(task_x + 1, task_y, .{
                .char = priority_char,
                .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                .fg = priority_color,
                .bg = .default,
                .attrs = .{},
            });

            // Task title (truncated if needed)
            const display_len = @min(task.title.len, max_title_len);
            const title_slice = task.title[0..display_len];
            const fg: Color = if (is_selected) Color.cyan else .default;
            const attrs: Cell.Attributes = if (is_selected) .{ .bold = true } else .{};
            root.print(task_x + 3, task_y, title_slice, fg, .default, attrs);
        }
    }

    // Status bar
    const status_y = height - 1;
    const status_msg = " <- -> : Switch column | Up/Down : Select task | q : Quit ";
    const status_x = (width -| @as(u16, @intCast(status_msg.len))) / 2;
    root.print(status_x, status_y, status_msg, Color.fromRgb(128, 128, 128), .default, .{});
}
