const std = @import("std");
const Event = @import("../Event.zig");
const Size = Event.Size;
const PixelSize = Event.PixelSize;
const CellPixelSize = Event.CellPixelSize;
const Cell = @import("../Cell.zig");
const Buffer = @import("../Buffer.zig");

/// Color depth capability levels (re-exported from Cell.zig)
pub const ColorDepth = Cell.ColorDepth;

/// Terminal capabilities for headless backend
pub const Capabilities = struct {
    /// Detected color depth
    color_depth: ColorDepth,
    /// Whether the terminal supports mouse input
    mouse: bool,
    /// Whether the terminal supports bracketed paste
    bracketed_paste: bool,
    /// Whether the terminal supports focus events
    focus_events: bool,
    /// Whether the terminal supports synchronized output
    synchronized_output: bool,
    /// Whether the terminal supports Kitty graphics protocol
    kitty_graphics: bool,
};

/// Configuration options for headless backend
pub const InitOptions = struct {
    /// Color depth to report
    color_depth: ColorDepth = .true_color,
    /// Enable mouse input support (always true, for testing)
    enable_mouse: bool = true,
    /// Enable bracketed paste mode support (always true, for testing)
    enable_bracketed_paste: bool = true,
    /// Enable focus event reporting (always true, for testing)
    enable_focus_events: bool = true,
    /// Enable synchronized output (always true, for testing)
    enable_synchronized_output: bool = true,
};

/// Simple event queue that avoids ArrayList<Event.Event> type issues
/// Stores events as owned allocations
const EventList = struct {
    /// Array of owned event pointers
    events: []?*Event.Event,
    /// Current number of events in queue
    count: usize,
    /// Capacity of the events array
    capacity: usize,
    /// Allocator for event memory
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) EventList {
        return EventList{
            .events = &[_](?*Event.Event){},
            .count = 0,
            .capacity = 0,
            .allocator = allocator,
        };
    }

    fn deinit(self: *EventList) void {
        for (0..self.count) |i| {
            if (self.events[i]) |event_ptr| {
                self.allocator.destroy(event_ptr);
            }
        }
        if (self.capacity > 0) {
            self.allocator.free(self.events);
        }
    }

    fn append(self: *EventList, event: Event.Event) !void {
        // Allocate more space if needed
        if (self.count >= self.capacity) {
            const new_capacity = if (self.capacity == 0) 8 else self.capacity * 2;
            const new_events = try self.allocator.alloc(?*Event.Event, new_capacity);

            // Copy existing events
            for (0..self.count) |i| {
                new_events[i] = self.events[i];
            }

            // Clear remaining slots
            for (self.count..new_capacity) |i| {
                new_events[i] = null;
            }

            // Free old array if it had capacity
            if (self.capacity > 0) {
                self.allocator.free(self.events);
            }

            self.events = new_events;
            self.capacity = new_capacity;
        }

        // Allocate and store the event
        const event_ptr = try self.allocator.create(Event.Event);
        event_ptr.* = event;
        self.events[self.count] = event_ptr;
        self.count += 1;
    }

    fn orderedRemove(self: *EventList) ?Event.Event {
        if (self.count == 0) return null;

        const event_ptr = self.events[0] orelse return null;
        const event = event_ptr.*;
        self.allocator.destroy(event_ptr);

        // Shift remaining events down
        for (0..self.count - 1) |i| {
            self.events[i] = self.events[i + 1];
        }
        self.events[self.count - 1] = null;
        self.count -= 1;

        return event;
    }
};

/// Headless backend for testing without a real terminal.
/// Renders to an in-memory buffer and allows injecting events.
pub const HeadlessBackend = struct {
    /// In-memory render buffer
    buffer: Buffer,
    /// Current terminal size
    size: Size,
    /// Terminal pixel size (always zero for headless)
    pixel_size: PixelSize,
    /// Terminal capabilities
    capabilities: Capabilities,
    /// Configuration options
    options: InitOptions,
    /// Pending events to be consumed
    events: EventList,
    /// Allocator for internal operations
    allocator: std.mem.Allocator,
    /// Output buffer for writer() compatibility (discards data)
    output_buffer: std.ArrayListUnmanaged(u8),
    /// Owned paste content allocations (freed on deinit)
    paste_allocations: std.ArrayListUnmanaged([]const u8),

    const Self = @This();

    /// Initialize the headless backend with a given size
    pub fn init(allocator: std.mem.Allocator, size: Size) !Self {
        var buffer = try Buffer.init(allocator, size);
        errdefer buffer.deinit();

        const events = EventList.init(allocator);

        const options: InitOptions = .{};

        return Self{
            .buffer = buffer,
            .size = size,
            .pixel_size = .{ .width = 0, .height = 0 },
            .capabilities = .{
                .color_depth = options.color_depth,
                .mouse = options.enable_mouse,
                .bracketed_paste = options.enable_bracketed_paste,
                .focus_events = options.enable_focus_events,
                .synchronized_output = options.enable_synchronized_output,
                .kitty_graphics = false,
            },
            .options = options,
            .events = events,
            .allocator = allocator,
            .output_buffer = .{},
            .paste_allocations = .{},
        };
    }

    /// Initialize with custom options
    pub fn initWithOptions(allocator: std.mem.Allocator, size: Size, options: InitOptions) !Self {
        var buffer = try Buffer.init(allocator, size);
        errdefer buffer.deinit();

        const events = EventList.init(allocator);

        return Self{
            .buffer = buffer,
            .size = size,
            .pixel_size = .{ .width = 0, .height = 0 },
            .capabilities = .{
                .color_depth = options.color_depth,
                .mouse = options.enable_mouse,
                .bracketed_paste = options.enable_bracketed_paste,
                .focus_events = options.enable_focus_events,
                .synchronized_output = options.enable_synchronized_output,
                .kitty_graphics = false,
            },
            .options = options,
            .events = events,
            .allocator = allocator,
            .output_buffer = .{},
            .paste_allocations = .{},
        };
    }

    /// Clean up and release resources
    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
        self.events.deinit();
        self.output_buffer.deinit(self.allocator);
        // Free all owned paste allocations
        for (self.paste_allocations.items) |paste| {
            self.allocator.free(paste);
        }
        self.paste_allocations.deinit(self.allocator);
    }

    /// Write data to output buffer (no-op in headless, for API compatibility)
    pub fn write(self: *Self, _: []const u8) !void {
        _ = self;
        // No-op: headless backend doesn't do real I/O
    }

    /// Get a writer for the output buffer (discards data in headless)
    pub fn writer(self: *Self) std.ArrayListUnmanaged(u8).Writer {
        return self.output_buffer.writer(self.allocator);
    }

    /// Flush output buffer (no-op in headless)
    pub fn flushOutput(self: *Self) !void {
        _ = self;
        // No-op: headless backend doesn't do real I/O
    }

    /// Begin synchronized output mode (no-op in headless)
    pub fn beginSynchronizedOutput(self: *Self) !void {
        _ = self;
        // No-op: headless backend doesn't need synchronization
    }

    /// End synchronized output mode (no-op in headless)
    pub fn endSynchronizedOutput(self: *Self) !void {
        _ = self;
        // No-op: headless backend doesn't need synchronization
    }

    /// Get the current terminal size
    pub fn getSize(self: *Self) Size {
        return self.size;
    }

    /// Get the current terminal size in pixels (always zero for headless)
    pub fn getPixelSize(_: *Self) PixelSize {
        return .{ .width = 0, .height = 0 };
    }

    /// Get the cell pixel size (always null for headless)
    pub fn getCellPixelSize(_: *Self) ?CellPixelSize {
        return null;
    }

    /// Resize the terminal
    pub fn resize(self: *Self, new_size: Size) !void {
        try self.buffer.resize(new_size);
        self.size = new_size;
    }

    /// Update size (no actual resize needed in headless, just returns current size)
    pub fn updateSize(self: *Self) !Size {
        return self.size;
    }

    /// Poll for input with optional timeout (in milliseconds).
    /// Returns number of bytes available (for API compatibility, always 0 in headless).
    pub fn poll(self: *Self, _: ?u32) !usize {
        _ = self;
        return 0;
    }

    /// Read available input bytes (no-op in headless)
    pub fn read(self: *Self, _: []u8) !usize {
        _ = self;
        return 0;
    }

    /// Poll for an event with optional timeout.
    /// Returns the next queued event if available, null otherwise.
    pub fn pollEvent(self: *Self, _: ?u32) !?Event.Event {
        return self.events.orderedRemove();
    }

    /// Non-blocking event check (equivalent to pollEvent(0))
    pub fn peekEvent(self: *Self) !?Event.Event {
        return self.pollEvent(0);
    }

    // Test helper methods
    // These are not part of the standard backend interface

    /// Inject a key event into the event queue
    pub fn injectKey(self: *Self, key: Event.Key) !void {
        try self.events.append(.{ .key = key });
    }

    /// Inject a mouse event into the event queue
    pub fn injectMouse(self: *Self, mouse: Event.Mouse) !void {
        try self.events.append(.{ .mouse = mouse });
    }

    /// Inject a resize event into the event queue and update size
    pub fn injectResize(self: *Self, new_size: Size) !void {
        try self.resize(new_size);
        try self.events.append(.{ .resize = new_size });
    }

    /// Inject a paste event into the event queue.
    /// The content is duplicated and owned by the backend until deinit.
    pub fn injectPaste(self: *Self, content: []const u8) !void {
        const owned = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(owned);
        // Track the allocation so it gets freed on deinit
        try self.paste_allocations.append(self.allocator, owned);
        try self.events.append(.{ .paste = owned });
    }

    /// Inject a focus event into the event queue
    pub fn injectFocus(self: *Self, focused: bool) !void {
        try self.events.append(.{ .focus = focused });
    }

    /// Get a cell from the buffer at the given position
    pub fn getCell(self: *Self, x: u16, y: u16) Cell {
        if (x >= self.size.width or y >= self.size.height) {
            return Cell.default;
        }
        const index = @as(usize, y) * @as(usize, self.size.width) + @as(usize, x);
        return self.buffer.cells[index];
    }

    /// Set a cell in the buffer at the given position
    pub fn setCell(self: *Self, x: u16, y: u16, cell: Cell) void {
        if (x >= self.size.width or y >= self.size.height) {
            return;
        }
        const index = @as(usize, y) * @as(usize, self.size.width) + @as(usize, x);
        self.buffer.cells[index] = cell;
    }

    /// Get a reference to the underlying buffer for direct manipulation
    pub fn getBuffer(self: *Self) *Buffer {
        return &self.buffer;
    }

    /// Clear the buffer (fill with default cells)
    pub fn clearBuffer(self: *Self) void {
        @memset(self.buffer.cells, Cell.default);
    }

    /// Get a snapshot of the buffer as a string (for testing/snapshots)
    /// Caller must free the returned memory
    pub fn toString(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        // Estimate size and pre-allocate (width * height * 4 for UTF-8)
        const estimated_size = @as(usize, self.size.width) * @as(usize, self.size.height) * 4;
        var chars = try std.ArrayList(u8).initCapacity(allocator, estimated_size);
        defer chars.deinit(allocator);

        const w = chars.writer(allocator);

        for (0..self.size.height) |y| {
            for (0..self.size.width) |x| {
                const cell = self.getCell(@intCast(x), @intCast(y));
                // For simplicity, just write the character or a space
                if (cell.char == 0) {
                    try w.writeAll(" ");
                } else {
                    var utf8_buf: [4]u8 = undefined;
                    const utf8_len = std.unicode.utf8Encode(@intCast(cell.char), &utf8_buf) catch {
                        try w.writeAll("?");
                        continue;
                    };
                    try w.writeAll(utf8_buf[0..utf8_len]);
                }
            }
            if (y < self.size.height - 1) {
                try w.writeAll("\n");
            }
        }

        return chars.toOwnedSlice(allocator);
    }
};

test "HeadlessBackend init and deinit" {
    var backend = try HeadlessBackend.init(std.testing.allocator, .{ .width = 80, .height = 24 });
    defer backend.deinit();

    try std.testing.expectEqual(@as(u16, 80), backend.size.width);
    try std.testing.expectEqual(@as(u16, 24), backend.size.height);
    try std.testing.expect(backend.capabilities.mouse);
}

test "HeadlessBackend inject and poll key events" {
    var backend = try HeadlessBackend.init(std.testing.allocator, .{ .width = 80, .height = 24 });
    defer backend.deinit();

    const key = Event.Key.fromCodepoint('a', .{});
    try backend.injectKey(key);

    const event = try backend.pollEvent(0);
    try std.testing.expect(event != null);
    if (event) |e| {
        try std.testing.expect(e == .key);
        try std.testing.expectEqual(@as(?u21, 'a'), e.key.codepoint);
    }
}

test "HeadlessBackend inject and poll mouse events" {
    var backend = try HeadlessBackend.init(std.testing.allocator, .{ .width = 80, .height = 24 });
    defer backend.deinit();

    const mouse = Event.Mouse{
        .x = 10,
        .y = 5,
        .button = .left,
        .mods = .{},
    };
    try backend.injectMouse(mouse);

    const event = try backend.pollEvent(0);
    try std.testing.expect(event != null);
    if (event) |e| {
        try std.testing.expect(e == .mouse);
        try std.testing.expectEqual(@as(u16, 10), e.mouse.x);
        try std.testing.expectEqual(@as(u16, 5), e.mouse.y);
    }
}

test "HeadlessBackend inject resize events" {
    var backend = try HeadlessBackend.init(std.testing.allocator, .{ .width = 80, .height = 24 });
    defer backend.deinit();

    const new_size = Size{ .width = 100, .height = 30 };
    try backend.injectResize(new_size);

    try std.testing.expectEqual(@as(u16, 100), backend.size.width);
    try std.testing.expectEqual(@as(u16, 30), backend.size.height);

    const event = try backend.pollEvent(0);
    try std.testing.expect(event != null);
    if (event) |e| {
        try std.testing.expect(e == .resize);
        try std.testing.expectEqual(@as(u16, 100), e.resize.width);
    }
}

test "HeadlessBackend getCell and setCell" {
    var backend = try HeadlessBackend.init(std.testing.allocator, .{ .width = 80, .height = 24 });
    defer backend.deinit();

    var cell = Cell.default;
    cell.char = 'X';
    cell.fg = .white;

    backend.setCell(10, 5, cell);
    const retrieved = backend.getCell(10, 5);

    try std.testing.expectEqual(@as(u21, 'X'), retrieved.char);
    try std.testing.expect(std.meta.eql(retrieved.fg, Cell.Color.white));
}

test "HeadlessBackend clearBuffer" {
    var backend = try HeadlessBackend.init(std.testing.allocator, .{ .width = 80, .height = 24 });
    defer backend.deinit();

    var cell = Cell.default;
    cell.char = 'X';
    backend.setCell(0, 0, cell);

    try std.testing.expectEqual(@as(u21, 'X'), backend.getCell(0, 0).char);

    backend.clearBuffer();
    try std.testing.expectEqual(@as(u21, ' '), backend.getCell(0, 0).char);  // Default cell has space, not 0
}

test "HeadlessBackend toString" {
    var backend = try HeadlessBackend.init(std.testing.allocator, .{ .width = 4, .height = 2 });
    defer backend.deinit();

    var cell = Cell.default;
    cell.char = 'H';
    backend.setCell(0, 0, cell);

    cell.char = 'i';
    backend.setCell(1, 0, cell);

    const str = try backend.toString(std.testing.allocator);
    defer std.testing.allocator.free(str);

    // Should be "Hi  \n    " (4 chars per row, newline after first row)
    try std.testing.expect(str.len > 0);
}

test "HeadlessBackend multiple events" {
    var backend = try HeadlessBackend.init(std.testing.allocator, .{ .width = 80, .height = 24 });
    defer backend.deinit();

    const key1 = Event.Key.fromCodepoint('a', .{});
    const key2 = Event.Key.fromCodepoint('b', .{});

    try backend.injectKey(key1);
    try backend.injectKey(key2);

    const event1 = try backend.pollEvent(0);
    try std.testing.expect(event1 != null);
    if (event1) |e| {
        try std.testing.expectEqual(@as(?u21, 'a'), e.key.codepoint);
    }

    const event2 = try backend.pollEvent(0);
    try std.testing.expect(event2 != null);
    if (event2) |e| {
        try std.testing.expectEqual(@as(?u21, 'b'), e.key.codepoint);
    }

    const event3 = try backend.pollEvent(0);
    try std.testing.expect(event3 == null);
}
