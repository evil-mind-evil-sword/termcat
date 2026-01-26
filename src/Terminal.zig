const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Cell = @import("Cell.zig");
const Input = @import("input/Input.zig");
const Color = Cell.Color;
const Attributes = Cell.Attributes;
const Plane = @import("Plane.zig");
const Compositor = @import("Compositor.zig");
const Renderer = @import("Renderer.zig");
const Event = @import("Event.zig");
const Size = Event.Size;
const Position = Event.Position;
const Rect = Event.Rect;
const unicode = @import("unicode/width.zig");

// Platform-specific backend selection
const posix_backend = @import("backend/posix.zig");
const windows_backend = @import("backend/windows.zig");

const Backend = if (builtin.os.tag == .windows)
    windows_backend.WindowsBackend
else
    posix_backend.PosixBackend;

const Capabilities = if (builtin.os.tag == .windows)
    windows_backend.Capabilities
else
    posix_backend.Capabilities;

const InitOptions = if (builtin.os.tag == .windows)
    windows_backend.InitOptions
else
    posix_backend.InitOptions;

/// High-level terminal facade with auto-present.
///
/// Terminal provides a simplified API for terminal applications by coordinating:
/// - Backend: Platform-specific terminal I/O
/// - Renderer: Diff-based terminal output
/// - Compositor: Plane composition with dirty tracking
/// - Root plane: Primary drawing surface
///
/// Key features:
/// - Automatic resize handling
/// - Auto-present mode for immediate rendering
/// - Convenience drawing methods on the root plane
/// - Simplified event polling
///
/// Example usage:
/// ```zig
/// var term = try Terminal.init(allocator, .{});
/// defer term.deinit();
///
/// term.draw(10, 5, "Hello, World!", .white, .default, .{});
/// try term.present();
///
/// while (true) {
///     if (try term.pollEvent(100)) |event| {
///         switch (event) {
///             .key => |key| if (key.codepoint == 'q') break,
///             .resize => {}, // Handled automatically
///             else => {},
///         }
///     }
/// }
/// ```
pub const Terminal = @This();

/// Platform-specific backend
backend: Backend,
/// Diff-based renderer
renderer: Renderer,
/// Plane compositor
compositor: Compositor,
/// Root plane (full screen)
root: *Plane,
/// Allocator for internal operations
allocator: std.mem.Allocator,
/// Whether auto-present is enabled (present after each draw operation)
auto_present: bool,
/// Whether there are pending changes that need presenting
dirty: bool,

/// Terminal initialization options
pub const Options = struct {
    /// Backend init options (mouse, paste, focus, sigwinch)
    backend: InitOptions = .{},
    /// Enable auto-present mode (present after each draw operation)
    auto_present: bool = false,
};

/// Initialize the terminal.
///
/// This sets up the backend (raw mode, alternate screen), creates the renderer
/// and compositor, and initializes the root plane to the terminal size.
///
/// Caller must call `deinit` to restore terminal state.
pub fn init(allocator: std.mem.Allocator, options: Options) !Terminal {
    // Initialize backend first
    var bkend = try Backend.init(allocator, options.backend);
    errdefer bkend.deinit();

    const term_size = bkend.getSize();

    // Initialize renderer
    var renderer_inst = try Renderer.init(allocator, term_size, bkend.capabilities.color_depth);
    errdefer renderer_inst.deinit();

    // Initialize root plane
    const root = try Plane.initRoot(allocator, term_size);
    errdefer root.deinit();

    // Build terminal and then wire compositor to the renderer's buffer.
    var term = Terminal{
        .backend = bkend,
        .renderer = renderer_inst,
        .compositor = undefined,
        .root = root,
        .allocator = allocator,
        .auto_present = options.auto_present,
        .dirty = false,
    };

    // Important: compositor needs a pointer to the renderer's back buffer
    // after the renderer has reached its final location. Taking the pointer
    // before constructing `term` would dangle after the move.
    term.compositor = Compositor.init(allocator, term.renderer.buffer());
    return term;
}

/// Clean up and restore terminal state.
pub fn deinit(self: *Terminal) void {
    self.compositor.deinit();
    self.root.deinit();
    self.renderer.deinit();
    self.backend.deinit();
    self.* = undefined;
}

/// Get the terminal size.
pub fn size(self: *const Terminal) Size {
    return self.backend.size;
}

/// Get the terminal capabilities.
pub fn capabilities(self: *const Terminal) Capabilities {
    return self.backend.capabilities;
}

/// Get the root plane for direct manipulation.
pub fn rootPlane(self: *Terminal) *Plane {
    return self.root;
}

// ============================================================================
// Drawing operations
// ============================================================================

/// Draw text at the given position on the root plane.
pub fn draw(
    self: *Terminal,
    x: u16,
    y: u16,
    text: []const u8,
    fg: Color,
    bg: Color,
    attrs: Attributes,
) void {
    // Plane.printLen returns the actual display width, handling invalid UTF-8 consistently.
    const cell_width = self.root.printLen(x, y, text, fg, bg, attrs);
    if (cell_width > 0) {
        self.markDirtyRect(.{ .x = x, .y = y, .width = cell_width, .height = 1 });
    }
}

/// Set a single cell on the root plane.
pub fn setCell(self: *Terminal, x: u16, y: u16, cell: Cell) void {
    self.root.setCell(x, y, cell);
    self.markDirtyRect(.{ .x = x, .y = y, .width = 1, .height = 1 });
}

/// Get a cell from the root plane.
pub fn getCell(self: *const Terminal, x: u16, y: u16) Cell {
    return self.root.getCell(x, y);
}

/// Fill a rectangle on the root plane.
pub fn fill(self: *Terminal, rect: Rect, cell: Cell) void {
    self.root.fill(rect, cell);
    self.markDirtyRect(rect);
}

/// Clear the entire root plane.
pub fn clear(self: *Terminal) void {
    self.root.clear();
    self.compositor.invalidateAll();
    self.dirty = true;
    self.maybeAutoPresent();
}

// ============================================================================
// Plane management
// ============================================================================

/// Create a child plane at the given position.
/// The plane is automatically added to the root's z-order (topmost).
pub fn createPlane(self: *Terminal, x: i32, y: i32, dimensions: Size) !*Plane {
    return Plane.initChild(self.root, x, y, dimensions);
}

/// Invalidate a plane (mark its visible area as dirty).
/// Call this after modifying a plane's content.
pub fn invalidatePlane(self: *Terminal, plane: *const Plane) !void {
    try self.compositor.invalidatePlane(plane);
    self.dirty = true;
    self.maybeAutoPresent();
}

/// Invalidate a plane after moving it.
/// Call this AFTER moving a plane, passing the old position.
pub fn invalidatePlaneMove(self: *Terminal, plane: *const Plane, old_x: i32, old_y: i32) !void {
    try self.compositor.invalidatePlaneMove(plane, old_x, old_y);
    self.dirty = true;
    self.maybeAutoPresent();
}

// ============================================================================
// Rendering
// ============================================================================

/// Present all pending changes to the terminal.
///
/// This composes all visible planes and flushes the result to the terminal.
/// Only changed regions are rendered (diff-based).
/// Uses synchronized output (DEC mode 2026) for flicker-free rendering
/// on terminals that support it.
pub fn present(self: *Terminal) !void {
    // Early return if nothing is dirty - avoids unnecessary allocation and composition
    if (!self.dirty and !self.renderer.cursor_dirty) {
        return;
    }

    // Ensure compositor targets the current renderer buffer (Terminal can be moved).
    self.compositor.target = self.renderer.buffer();

    // Compose planes into renderer's back buffer
    const dirty_regions = try self.compositor.compose(self.root);
    defer self.allocator.free(dirty_regions);

    // Begin synchronized output for flicker-free rendering
    try self.backend.beginSynchronizedOutput();
    // Ensure sync output is disabled on error (ignore errors in cleanup)
    errdefer self.backend.endSynchronizedOutput() catch {};

    // Flush to terminal
    try self.renderer.flush(self.backend.writer());

    // End synchronized output
    try self.backend.endSynchronizedOutput();

    try self.backend.flushOutput();

    self.dirty = false;
}

/// Set the cursor position (visible cursor).
pub fn setCursor(self: *Terminal, pos: ?Position) void {
    self.renderer.setCursor(pos);
    if (self.renderer.cursor_dirty) {
        self.dirty = true;
        self.maybeAutoPresent();
    }
}

/// Show the cursor at the given position.
pub fn showCursor(self: *Terminal, x: u16, y: u16) void {
    self.setCursor(.{ .x = x, .y = y });
}

/// Hide the cursor.
pub fn hideCursor(self: *Terminal) void {
    self.setCursor(null);
}

// ============================================================================
// Terminal control
// ============================================================================

/// Cursor styles supported by most modern terminals (DECSCUSR)
pub const CursorStyle = enum(u3) {
    /// Default cursor (terminal-defined, usually blinking block)
    default = 0,
    /// Blinking block cursor
    blinking_block = 1,
    /// Steady (non-blinking) block cursor
    steady_block = 2,
    /// Blinking underline cursor
    blinking_underline = 3,
    /// Steady underline cursor
    steady_underline = 4,
    /// Blinking bar (vertical line) cursor
    blinking_bar = 5,
    /// Steady bar cursor
    steady_bar = 6,
};

/// Set the cursor style.
/// Uses DECSCUSR (CSI Ps SP q) escape sequence.
pub fn setCursorStyle(self: *Terminal, style: CursorStyle) !void {
    const w = self.backend.output_buffer.writer(self.backend.allocator);
    try w.print("\x1b[{d} q", .{@intFromEnum(style)});
}

/// Send a bell (audible or visual alert).
/// Uses BEL character (0x07).
pub fn bell(self: *Terminal) !void {
    try self.backend.output_buffer.appendSlice(self.backend.allocator, "\x07");
}

/// Set the terminal window title.
/// Uses OSC 2 (Set Window Title) escape sequence.
pub fn setTitle(self: *Terminal, title: []const u8) !void {
    const w = self.backend.output_buffer.writer(self.backend.allocator);
    try w.print("\x1b]2;{s}\x1b\\", .{title});
}

/// Set the terminal icon name (shown in taskbar/dock).
/// Uses OSC 1 (Set Icon Name) escape sequence.
pub fn setIconName(self: *Terminal, name: []const u8) !void {
    const w = self.backend.output_buffer.writer(self.backend.allocator);
    try w.print("\x1b]1;{s}\x1b\\", .{name});
}

/// Set both window title and icon name.
/// Uses OSC 0 (Set Icon Name and Window Title) escape sequence.
pub fn setTitleAndIcon(self: *Terminal, title: []const u8) !void {
    const w = self.backend.output_buffer.writer(self.backend.allocator);
    try w.print("\x1b]0;{s}\x1b\\", .{title});
}

// ============================================================================
// Clipboard (OSC 52)
// ============================================================================

/// Clipboard selection target
pub const ClipboardSelection = enum {
    /// Primary selection (middle-click paste on X11)
    primary,
    /// Clipboard (Ctrl+C/Ctrl+V)
    clipboard,
};

/// Write data to the system clipboard using OSC 52.
/// Note: Not all terminals support this; some require explicit opt-in.
/// Supported by: kitty, iTerm2, WezTerm, foot, Alacritty, xterm (with allowWindowOps).
pub fn clipboardWrite(self: *Terminal, selection: ClipboardSelection, data: []const u8) !void {
    const w = self.backend.output_buffer.writer(self.backend.allocator);
    const sel_char: u8 = switch (selection) {
        .primary => 'p',
        .clipboard => 'c',
    };

    // OSC 52 ; selection ; base64-data ST
    try w.print("\x1b]52;{c};", .{sel_char});

    // Write base64-encoded data
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(data.len);
    const encoded_buf = try self.allocator.alloc(u8, encoded_len);
    defer self.allocator.free(encoded_buf);
    _ = encoder.encode(encoded_buf, data);
    try w.writeAll(encoded_buf);

    // String terminator
    try w.writeAll("\x1b\\");
}

/// Copy text to the clipboard (convenience wrapper for clipboardWrite).
pub fn copy(self: *Terminal, text: []const u8) !void {
    try self.clipboardWrite(.clipboard, text);
}

// ============================================================================
// Hyperlinks (OSC 8)
// ============================================================================

/// Begin a hyperlink region.
/// All text written after this will be part of the clickable link until endHyperlink is called.
/// Uses OSC 8 escape sequence.
/// Supported by: kitty, iTerm2, VTE-based terminals, Windows Terminal.
pub fn beginHyperlink(self: *Terminal, url: []const u8) !void {
    const w = self.backend.output_buffer.writer(self.backend.allocator);
    // OSC 8 ; params ; uri ST
    // params can include id=value for linking multiple regions
    try w.print("\x1b]8;;{s}\x1b\\", .{url});
}

/// Begin a hyperlink region with an explicit ID.
/// Multiple regions with the same ID are treated as part of the same link.
pub fn beginHyperlinkWithId(self: *Terminal, url: []const u8, id: []const u8) !void {
    const w = self.backend.output_buffer.writer(self.backend.allocator);
    try w.print("\x1b]8;id={s};{s}\x1b\\", .{ id, url });
}

/// End the current hyperlink region.
pub fn endHyperlink(self: *Terminal) !void {
    try self.backend.output_buffer.appendSlice(self.backend.allocator, "\x1b]8;;\x1b\\");
}

/// Write a complete hyperlink (convenience wrapper).
/// Writes the URL, then the display text, then ends the link.
pub fn writeHyperlink(self: *Terminal, url: []const u8, text: []const u8) !void {
    try self.beginHyperlink(url);
    try self.backend.output_buffer.appendSlice(self.backend.allocator, text);
    try self.endHyperlink();
}

// ============================================================================
// Palette Colors (OSC 4)
// ============================================================================

/// Set a palette color (indices 0-255).
/// Uses OSC 4 escape sequence with X11 rgb: format.
/// This modifies the terminal's color palette for the duration of the session.
///
/// Color indices:
/// - 0-7: Standard colors (black, red, green, yellow, blue, magenta, cyan, white)
/// - 8-15: Bright colors
/// - 16-231: 6x6x6 color cube
/// - 232-255: Grayscale ramp
///
/// Supported by: xterm, VTE-based terminals, kitty, iTerm2, Windows Terminal.
pub fn setPaletteColor(self: *Terminal, index: u8, r: u8, g: u8, b: u8) !void {
    const w = self.backend.output_buffer.writer(self.backend.allocator);
    // OSC 4 ; index ; rgb:RR/GG/BB ST
    // Using 2-digit hex (scaled to 16-bit range is also valid, but 8-bit is simpler)
    try w.print("\x1b]4;{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\", .{ index, r, g, b });
}

/// Reset a palette color to the terminal's default.
/// Uses OSC 104 escape sequence.
pub fn resetPaletteColor(self: *Terminal, index: u8) !void {
    const w = self.backend.output_buffer.writer(self.backend.allocator);
    // OSC 104 ; index ST
    try w.print("\x1b]104;{d}\x1b\\", .{index});
}

/// Reset all palette colors to the terminal's defaults.
/// Uses OSC 104 with no index parameter.
pub fn resetAllPaletteColors(self: *Terminal) !void {
    try self.backend.output_buffer.appendSlice(self.backend.allocator, "\x1b]104\x1b\\");
}

// ============================================================================
// Events
// ============================================================================

/// Poll result when using pollEventWithExtraFd (re-exported from Input)
pub const PollResult = Input.PollResult;

/// Poll for an event with optional timeout (in milliseconds).
///
/// Returns null on timeout. Resize events are handled automatically,
/// resizing the root plane and renderer.
pub fn pollEvent(self: *Terminal, timeout_ms: ?u32) !?Event.Event {
    const event = try self.backend.pollEvent(timeout_ms);

    if (event) |ev| {
        switch (ev) {
            .resize => |new_size| {
                try self.handleResize(new_size);
            },
            else => {},
        }
    }

    return event;
}

/// Poll for an event, but also return if an extra fd becomes readable.
///
/// Returns .extra_ready when the extra fd is readable. This enables efficient
/// wakeup from background threads via a pipe/eventfd.
///
/// Example usage for background thread communication:
/// ```zig
/// // Create a pipe for wakeup
/// const wakeup_pipe = try posix.pipe();
///
/// // In event loop:
/// const result = try term.pollEventWithExtraFd(100, wakeup_pipe[0]);
/// if (result) |r| switch (r) {
///     .event => |ev| { ... },
///     .extra_ready => {
///         // Background thread signaled, process messages
///     },
/// };
/// ```
pub fn pollEventWithExtraFd(self: *Terminal, timeout_ms: ?u32, extra_fd: posix.fd_t) !?PollResult {
    const result = try self.backend.input_handler.pollEventWithExtraFd(timeout_ms, extra_fd);

    if (result) |outcome| {
        switch (outcome) {
            .event => |ev| {
                switch (ev) {
                    .resize => |new_size| {
                        try self.handleResize(new_size);
                    },
                    else => {},
                }
                return .{ .event = ev };
            },
            .extra_ready => return .extra_ready,
        }
    }

    return null;
}

/// Non-blocking event check.
pub fn peekEvent(self: *Terminal) !?Event.Event {
    return self.pollEvent(0);
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Handle terminal resize.
fn handleResize(self: *Terminal, new_size: Size) !void {
    const old_size = self.root.size();

    if (old_size.width == new_size.width and old_size.height == new_size.height) {
        return;
    }

    var root_resized = false;
    errdefer {
        if (root_resized) {
            // Best-effort rollback to keep renderer/root sizes consistent.
            _ = self.root.resize(old_size) catch {};
        }

        // Ensure the next frame redraws fully after any partial resize attempt.
        self.compositor.invalidateAll();
        self.dirty = true;
    }

    // Resize root plane first so renderer resize failure can roll back cleanly.
    try self.root.resize(new_size);
    root_resized = true;

    // Resize renderer buffers.
    try self.renderer.resize(new_size);

    // Re-initialize compositor with new buffer.
    self.compositor.deinit();
    self.compositor = Compositor.init(self.allocator, self.renderer.buffer());

    // Mark full redraw needed.
    self.compositor.invalidateAll();
    self.dirty = true;
}

/// Mark a rectangle as dirty and optionally auto-present.
fn markDirtyRect(self: *Terminal, rect: Rect) void {
    self.compositor.invalidateRect(rect) catch {
        // On allocation failure, fall back to full redraw
        self.compositor.invalidateAll();
    };
    self.dirty = true;
    self.maybeAutoPresent();
}

/// Present if auto-present is enabled.
/// Note: Errors are logged but not propagated to avoid breaking the drawing API.
/// Use explicit present() calls if error handling is needed.
fn maybeAutoPresent(self: *Terminal) void {
    if (self.auto_present and self.dirty) {
        self.present() catch |err| {
            // Log error but don't propagate - auto-present is best-effort
            std.log.warn("Terminal auto-present failed: {}", .{err});
        };
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Terminal struct size" {
    // Basic sanity check that struct compiles
    try std.testing.expect(@sizeOf(Terminal) > 0);
}
