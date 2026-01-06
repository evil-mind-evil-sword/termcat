//! Doom in the Terminal - doomgeneric port using termcat
//!
//! This implements the doomgeneric platform hooks to run Doom
//! with termcat rendering (braille/Kitty) and input handling.
//!
//! Usage: doom [--kitty] [--mode ascii|half_block|quadrant|braille] <path/to/doom1.wad>
//!
//! Controls:
//!   Arrow keys / WASD: Move
//!   Space / Ctrl: Fire
//!   E / Enter: Use/Open
//!   Escape: Menu
//!   1-7: Select weapon
//!
//! Shareware WAD: https://doomwiki.org/wiki/DOOM1.WAD

const std = @import("std");
const termcat = @import("termcat");
const c = @cImport({
    @cInclude("stdlib.h");
});

const PixelBlitter = termcat.PixelBlitter;
const Surface = termcat.Surface;
const Pixel = Surface.Pixel;
const KeyStateTracker = termcat.input.KeyStateTracker;
const Event = termcat.Event;

// ============================================================================
// Global State (required for C interop - doomgeneric uses global callbacks)
// ============================================================================

var global_state: ?*DoomState = null;

const DoomState = struct {
    allocator: std.mem.Allocator,
    backend: termcat.Backend,
    renderer: termcat.Renderer,
    kitty: termcat.graphics.KittyGraphics,
    surface: Surface,
    key_tracker: KeyStateTracker,
    use_kitty: bool,
    blit_mode: PixelBlitter.BlitterMode,
    kitty_visible: bool,
    start_time: std.time.Instant,
    key_queue: KeyQueue,
    // Track which doom keys are currently "pressed" to generate release events
    pressed_doom_keys: [256]bool,

    const KeyQueue = struct {
        keys: [64]KeyEvent = undefined,
        head: usize = 0,
        tail: usize = 0,

        const KeyEvent = struct {
            pressed: bool,
            key: u8,
        };

        fn push(self: *KeyQueue, pressed: bool, key: u8) void {
            self.keys[self.tail] = .{ .pressed = pressed, .key = key };
            self.tail = (self.tail + 1) % 64;
            if (self.tail == self.head) {
                self.head = (self.head + 1) % 64; // Drop oldest
            }
        }

        fn pop(self: *KeyQueue) ?KeyEvent {
            if (self.head == self.tail) return null;
            const event = self.keys[self.head];
            self.head = (self.head + 1) % 64;
            return event;
        }
    };

    fn init(allocator: std.mem.Allocator, use_kitty: bool, blit_mode: PixelBlitter.BlitterMode) !*DoomState {
        var self = try allocator.create(DoomState);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.backend = try termcat.Backend.init(allocator, .{
            .enable_synchronized_output = true,
            .enable_mouse = false,
        });
        errdefer self.backend.deinit();

        const size = self.backend.getSize();
        self.renderer = try termcat.Renderer.init(allocator, size, self.backend.capabilities.color_depth);
        errdefer self.renderer.deinit();

        self.kitty = termcat.graphics.KittyGraphics.init(allocator);
        self.surface = try Surface.init(allocator, DOOMGENERIC_RESX, DOOMGENERIC_RESY);
        errdefer self.surface.deinit();

        self.key_tracker = KeyStateTracker.init(.{ .release_timeout_ms = 100 });
        self.use_kitty = use_kitty and self.backend.capabilities.kitty_graphics;
        self.blit_mode = blit_mode;
        self.kitty_visible = false;
        self.start_time = std.time.Instant.now() catch @panic("Failed to get time");
        self.key_queue = .{};
        self.pressed_doom_keys = [_]bool{false} ** 256;

        // Register atexit handler to clean up terminal on C exit()
        _ = c.atexit(atexitCleanup);

        return self;
    }

    /// Called by C runtime atexit() to clean up terminal state
    fn atexitCleanup() callconv(.c) void {
        if (global_state) |state| {
            // Clean up kitty graphics
            if (state.kitty_visible and state.backend.capabilities.kitty_graphics) {
                state.kitty.delete(state.backend.writer(), .{ .image_id = 1 }) catch {};
            }
            // Restore terminal state (deinit handles raw mode, cursor, etc.)
            state.backend.deinit();
            // Prevent double cleanup from defer
            global_state = null;
        }
    }

    fn deinit(self: *DoomState) void {
        // Clear global_state first to prevent atexit from accessing freed memory
        global_state = null;

        if (self.kitty_visible and self.backend.capabilities.kitty_graphics) {
            self.kitty.delete(self.backend.writer(), .{ .image_id = 1 }) catch {};
            self.backend.flushOutput() catch {};
        }
        self.surface.deinit();
        self.kitty.deinit();
        self.renderer.deinit();
        self.backend.deinit();
        self.allocator.destroy(self);
    }
};

// ============================================================================
// Doom Constants (must match doomgeneric.h)
// ============================================================================

const DOOMGENERIC_RESX: u32 = 640;
const DOOMGENERIC_RESY: u32 = 400;

// Doom key codes (from doomkeys.h)
const KEY_RIGHTARROW: u8 = 0xae;
const KEY_LEFTARROW: u8 = 0xac;
const KEY_UPARROW: u8 = 0xad;
const KEY_DOWNARROW: u8 = 0xaf;
const KEY_ESCAPE: u8 = 27;
const KEY_ENTER: u8 = 13;
const KEY_TAB: u8 = 9;
const KEY_FIRE: u8 = 0xa3;
const KEY_USE: u8 = 0xa2;
const KEY_RSHIFT: u8 = 0x80 + 0x36;
const KEY_RCTRL: u8 = 0x80 + 0x1d;

// ============================================================================
// doomgeneric Platform Hooks (exported with C ABI)
// ============================================================================

/// External screen buffer from doomgeneric (XRGB format, 32-bit per pixel)
extern var DG_ScreenBuffer: [*]u32;

/// Initialize the platform
export fn DG_Init() callconv(.c) void {
    // Initialization is done in main() before doomgeneric_Create
}

/// Draw the current frame
export fn DG_DrawFrame() callconv(.c) void {
    const state = global_state orelse return;

    // Copy DG_ScreenBuffer (XRGB) to termcat Surface (RGBA)
    const pixels = DG_ScreenBuffer[0 .. DOOMGENERIC_RESX * DOOMGENERIC_RESY];
    for (pixels, 0..) |xrgb, i| {
        const x: u32 = @intCast(i % DOOMGENERIC_RESX);
        const y: u32 = @intCast(i / DOOMGENERIC_RESX);
        // XRGB: byte order is typically BGRX in memory (little-endian)
        const b: u8 = @truncate(xrgb & 0xFF);
        const g: u8 = @truncate((xrgb >> 8) & 0xFF);
        const r: u8 = @truncate((xrgb >> 16) & 0xFF);
        state.surface.setPixel(x, y, Pixel.rgb(r, g, b));
    }

    // Render to terminal
    const buf = state.renderer.buffer();
    buf.clear();

    if (state.use_kitty) {
        // Kitty graphics mode - render after buffer flush
    } else {
        // Cell-based rendering
        PixelBlitter.blit(buf, 0, 0, state.surface, .{
            .mode = state.blit_mode,
            .color_depth = state.backend.capabilities.color_depth,
        });
    }

    state.backend.beginSynchronizedOutput() catch {};
    state.renderer.flush(state.backend.writer()) catch {};
    state.backend.endSynchronizedOutput() catch {};

    if (state.use_kitty and state.backend.capabilities.kitty_graphics) {
        const cell_size = PixelBlitter.calcCellSize(state.surface.width, state.surface.height, state.blit_mode);
        state.kitty.draw(state.backend.writer(), state.surface, .{
            .image_id = 1,
            .position = .{ .x = 0, .y = 0 },
            .columns = cell_size.width,
            .rows = cell_size.height,
            .z_index = 1,
        }) catch {};
        state.kitty_visible = true;
    }

    state.backend.flushOutput() catch {};
}

/// Sleep for specified milliseconds
export fn DG_SleepMs(ms: u32) callconv(.c) void {
    std.Thread.sleep(@as(u64, ms) * std.time.ns_per_ms);
}

/// Get elapsed time in milliseconds
export fn DG_GetTicksMs() callconv(.c) u32 {
    const state = global_state orelse return 0;
    const now = std.time.Instant.now() catch return 0;
    const elapsed_ns = now.since(state.start_time);
    return @intCast(elapsed_ns / std.time.ns_per_ms);
}

/// Poll for keyboard input
/// Returns 1 if key event available, 0 otherwise
export fn DG_GetKey(pressed: *c_int, doom_key: *u8) callconv(.c) c_int {
    const state = global_state orelse return 0;

    // Poll for new events (non-blocking)
    if (state.backend.pollEvent(0)) |maybe_event| {
        if (maybe_event) |event| {
            switch (event) {
                .key => |key| {
                    state.key_tracker.recordKeyPress(key);

                    // Convert termcat key to doom key and queue press event
                    if (mapToDoomKey(key)) |dk| {
                        if (!state.pressed_doom_keys[dk]) {
                            state.pressed_doom_keys[dk] = true;
                            state.key_queue.push(true, dk);
                        }
                    }
                },
                .resize => |new_size| {
                    state.renderer.resize(new_size) catch {};
                },
                else => {},
            }
        }
    } else |_| {}

    // Clean up expired key tracking
    state.key_tracker.tick();

    // Generate release events for doom keys that are no longer held
    // Check movement, action, and weapon keys
    // Include both lowercase and uppercase variants for Shift+WASD running
    const tracked_keys = [_]struct { doom: u8, termcat_cp: ?u21, termcat_cp_upper: ?u21, termcat_sp: ?Event.Key.Special }{
        // Movement keys
        .{ .doom = KEY_UPARROW, .termcat_cp = 'w', .termcat_cp_upper = 'W', .termcat_sp = .up },
        .{ .doom = KEY_DOWNARROW, .termcat_cp = 's', .termcat_cp_upper = 'S', .termcat_sp = .down },
        .{ .doom = KEY_LEFTARROW, .termcat_cp = 'a', .termcat_cp_upper = 'A', .termcat_sp = .left },
        .{ .doom = KEY_RIGHTARROW, .termcat_cp = 'd', .termcat_cp_upper = 'D', .termcat_sp = .right },
        // Action keys
        .{ .doom = KEY_FIRE, .termcat_cp = ' ', .termcat_cp_upper = null, .termcat_sp = null },
        .{ .doom = KEY_USE, .termcat_cp = 'e', .termcat_cp_upper = 'E', .termcat_sp = null },
        .{ .doom = KEY_ENTER, .termcat_cp = null, .termcat_cp_upper = null, .termcat_sp = .enter },
        .{ .doom = KEY_TAB, .termcat_cp = null, .termcat_cp_upper = null, .termcat_sp = .tab },
        .{ .doom = KEY_ESCAPE, .termcat_cp = 0x1b, .termcat_cp_upper = null, .termcat_sp = .escape },
        // Weapon selection keys (0-9)
        .{ .doom = '0', .termcat_cp = '0', .termcat_cp_upper = null, .termcat_sp = null },
        .{ .doom = '1', .termcat_cp = '1', .termcat_cp_upper = null, .termcat_sp = null },
        .{ .doom = '2', .termcat_cp = '2', .termcat_cp_upper = null, .termcat_sp = null },
        .{ .doom = '3', .termcat_cp = '3', .termcat_cp_upper = null, .termcat_sp = null },
        .{ .doom = '4', .termcat_cp = '4', .termcat_cp_upper = null, .termcat_sp = null },
        .{ .doom = '5', .termcat_cp = '5', .termcat_cp_upper = null, .termcat_sp = null },
        .{ .doom = '6', .termcat_cp = '6', .termcat_cp_upper = null, .termcat_sp = null },
        .{ .doom = '7', .termcat_cp = '7', .termcat_cp_upper = null, .termcat_sp = null },
        .{ .doom = '8', .termcat_cp = '8', .termcat_cp_upper = null, .termcat_sp = null },
        .{ .doom = '9', .termcat_cp = '9', .termcat_cp_upper = null, .termcat_sp = null },
    };

    for (tracked_keys) |tk| {
        if (state.pressed_doom_keys[tk.doom]) {
            // Check if either the codepoint (lower or upper) or special key is still held
            const cp_held = if (tk.termcat_cp) |cp| state.key_tracker.isCodepointHeld(cp) else false;
            const cp_upper_held = if (tk.termcat_cp_upper) |cp| state.key_tracker.isCodepointHeld(cp) else false;
            const sp_held = if (tk.termcat_sp) |sp| state.key_tracker.isSpecialHeld(sp) else false;

            if (!cp_held and !cp_upper_held and !sp_held) {
                // Key is no longer held, generate release event
                state.pressed_doom_keys[tk.doom] = false;
                state.key_queue.push(false, tk.doom);
            }
        }
    }

    // Return queued key event
    if (state.key_queue.pop()) |key_event| {
        pressed.* = if (key_event.pressed) 1 else 0;
        doom_key.* = key_event.key;
        return 1;
    }

    return 0;
}

/// Set window title (terminal title via OSC 2)
export fn DG_SetWindowTitle(title: [*:0]const u8) callconv(.c) void {
    const state = global_state orelse return;
    const writer = state.backend.writer();
    const title_slice = std.mem.span(title);
    writer.print("\x1b]2;{s}\x07", .{title_slice}) catch {};
    state.backend.flushOutput() catch {};
}

// ============================================================================
// Key Mapping
// ============================================================================

fn mapToDoomKey(key: Event.Key) ?u8 {
    // Special keys
    if (key.special) |sp| {
        return switch (sp) {
            .up => KEY_UPARROW,
            .down => KEY_DOWNARROW,
            .left => KEY_LEFTARROW,
            .right => KEY_RIGHTARROW,
            .escape => KEY_ESCAPE,
            .enter => KEY_ENTER,
            .tab => KEY_TAB,
            else => null,
        };
    }

    // Codepoint keys
    if (key.codepoint) |cp| {
        return switch (cp) {
            // WASD movement (map to arrows)
            'w', 'W' => KEY_UPARROW,
            's', 'S' => KEY_DOWNARROW,
            'a', 'A' => KEY_LEFTARROW,
            'd', 'D' => KEY_RIGHTARROW,

            // Fire (space, ctrl)
            ' ' => KEY_FIRE,

            // Use/open (e, enter)
            'e', 'E' => KEY_USE,

            // Shift for run
            // Note: Terminals often can't detect shift alone

            // Numbers for weapons
            '1'...'9' => @intCast(cp),
            '0' => '0',

            // Escape
            0x1b => KEY_ESCAPE,

            // Other printable ASCII
            else => if (cp < 128) @intCast(cp) else null,
        };
    }

    // Note: Terminals don't report standalone modifier key events,
    // so KEY_RCTRL/KEY_RSHIFT are not mapped here. Ctrl is sent
    // as modified codepoint (e.g., Ctrl+A = codepoint 1).

    return null;
}

// ============================================================================
// External doomgeneric functions
// ============================================================================

extern fn doomgeneric_Create(argc: c_int, argv: [*][*:0]u8) void;
extern fn doomgeneric_Tick() void;

// ============================================================================
// Main Entry Point
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var use_kitty = false;
    var blit_mode: PixelBlitter.BlitterMode = .braille;
    var wad_path: ?[:0]const u8 = null; // Keep sentinel for C interop

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--kitty")) {
            use_kitty = true;
        } else if (std.mem.eql(u8, arg, "--mode")) {
            i += 1;
            if (i < args.len) {
                const mode = args[i];
                if (std.mem.eql(u8, mode, "ascii")) {
                    blit_mode = .ascii;
                } else if (std.mem.eql(u8, mode, "half_block")) {
                    blit_mode = .half_block;
                } else if (std.mem.eql(u8, mode, "quadrant")) {
                    blit_mode = .quadrant;
                } else if (std.mem.eql(u8, mode, "braille")) {
                    blit_mode = .braille;
                }
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            wad_path = arg;
        }
    }

    if (wad_path == null) {
        std.debug.print("Usage: doom [--kitty] [--mode ascii|half_block|quadrant|braille] <path/to/doom1.wad>\n", .{});
        std.debug.print("\nDownload shareware WAD: https://doomwiki.org/wiki/DOOM1.WAD\n", .{});
        return;
    }

    // Initialize termcat state
    const state = try DoomState.init(allocator, use_kitty, blit_mode);
    defer state.deinit();
    global_state = state;

    // Build argv for doom using allocator to ensure proper memory layout
    // Doom expects: argv[0]=progname, argv[1]="-iwad", argv[2]=wadpath
    var doom_argv_ptrs: [4][*:0]u8 = undefined;
    doom_argv_ptrs[0] = @constCast("doom");
    doom_argv_ptrs[1] = @constCast("-iwad");
    doom_argv_ptrs[2] = @constCast(wad_path.?.ptr);

    // Start doom
    doomgeneric_Create(3, &doom_argv_ptrs);

    // Main loop
    while (true) {
        doomgeneric_Tick();
    }
}
