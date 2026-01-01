const std = @import("std");
const Cell = @import("Cell.zig");
const Buffer = @import("Buffer.zig");
const Plane = @import("Plane.zig").Plane;
const Event = @import("Event.zig");
const Rect = Event.Rect;
const Size = Event.Size;

/// Blitting and sprite utilities for copying cell data between planes and buffers.
///
/// All blit operations support:
/// - Clipping to destination bounds (out-of-range coordinates are silently handled)
/// - Optional transparency (transparent cells do not overwrite destination)
/// - Source region selection (copy sub-rectangles)
///
/// A cell is considered transparent if:
/// - It is a space character (but NOT a continuation cell with char == 0)
/// - It has default foreground AND background colors
/// - It has no text attributes
/// - It has no combining marks
pub const Blit = @This();

/// Options for blit operations.
pub const BlitOptions = struct {
    /// If true, transparent cells in the source will not overwrite destination cells.
    /// Default: false (all cells are copied).
    transparent: bool = false,

    /// Source region to copy from. If null, copies the entire source.
    /// Coordinates are relative to the source origin.
    src_region: ?Rect = null,
};

/// Options for tiled fill operations.
pub const TileOptions = struct {
    /// If true, transparent cells in the tile will not overwrite destination cells.
    transparent: bool = false,
};

/// Check if a cell is transparent (should not overwrite underlying content).
///
/// A cell is transparent only if:
/// - It is a space character (not a continuation cell char==0)
/// - It has default foreground AND background colors
/// - It has no text attributes set
/// - It has no combining marks
pub fn isTransparent(cell: Cell) bool {
    // Continuation cells (char == 0) are never transparent - they preserve wide char integrity
    if (cell.char == 0) return false;

    return cell.char == ' ' and
        cell.fg.eql(.default) and
        cell.bg.eql(.default) and
        cell.attrs.eql(.{}) and
        !cell.hasCombining();
}

/// Copy cells from a source buffer to a destination plane.
///
/// Parameters:
/// - dest: Target plane to copy into
/// - dest_x, dest_y: Position in the destination plane (local coordinates)
/// - src: Source buffer to copy from
/// - options: Blit options (transparency, source region)
///
/// Clipping: If the source region extends beyond the destination bounds,
/// only the visible portion is copied.
pub fn blitBufferToPlane(
    dest: *Plane,
    dest_x: u16,
    dest_y: u16,
    src: *const Buffer,
    options: BlitOptions,
) void {
    const dest_buf = dest.getBuffer();
    blitBufferToBuffer(dest_buf, dest_x, dest_y, src, options);

    // Mark the affected region as dirty
    const src_rect = options.src_region orelse Rect{
        .x = 0,
        .y = 0,
        .width = src.width,
        .height = src.height,
    };

    // Step 1: Clip to source bounds
    const src_w = @min(src_rect.width, src.width -| src_rect.x);
    const src_h = @min(src_rect.height, src.height -| src_rect.y);

    // Step 2: Clip to destination bounds
    const copy_w = @min(src_w, dest.width -| dest_x);
    const copy_h = @min(src_h, dest.height -| dest_y);

    if (copy_w > 0 and copy_h > 0) {
        dest.markDirtyRect(.{
            .x = dest_x,
            .y = dest_y,
            .width = copy_w,
            .height = copy_h,
        });
    }
}

/// Copy cells from a source plane to a destination plane.
///
/// Parameters:
/// - dest: Target plane to copy into
/// - dest_x, dest_y: Position in the destination plane (local coordinates)
/// - src: Source plane to copy from
/// - options: Blit options (transparency, source region)
///
/// Clipping: If the source region extends beyond the destination bounds,
/// only the visible portion is copied.
pub fn blitPlaneToPlane(
    dest: *Plane,
    dest_x: u16,
    dest_y: u16,
    src: *const Plane,
    options: BlitOptions,
) void {
    const dest_buf = dest.getBuffer();
    blitBufferToBuffer(dest_buf, dest_x, dest_y, &src.buffer, options);

    // Mark the affected region as dirty
    const src_rect = options.src_region orelse Rect{
        .x = 0,
        .y = 0,
        .width = src.width,
        .height = src.height,
    };

    // Step 1: Clip to source bounds
    const src_w = @min(src_rect.width, src.width -| src_rect.x);
    const src_h = @min(src_rect.height, src.height -| src_rect.y);

    // Step 2: Clip to destination bounds
    const copy_w = @min(src_w, dest.width -| dest_x);
    const copy_h = @min(src_h, dest.height -| dest_y);

    if (copy_w > 0 and copy_h > 0) {
        dest.markDirtyRect(.{
            .x = dest_x,
            .y = dest_y,
            .width = copy_w,
            .height = copy_h,
        });
    }
}

/// Copy cells from a source buffer to a destination buffer.
///
/// Parameters:
/// - dest: Target buffer to copy into
/// - dest_x, dest_y: Position in the destination buffer
/// - src: Source buffer to copy from
/// - options: Blit options (transparency, source region)
///
/// Clipping: If the source region extends beyond the destination bounds,
/// only the visible portion is copied.
///
/// Wide character handling: Wide characters (2-cell glyphs) are copied atomically.
/// If a wide character would be split at a clip boundary, it is replaced with a
/// space to maintain buffer invariants. Orphan continuation cells at the start
/// of the source region are skipped.
pub fn blitBufferToBuffer(
    dest: *Buffer,
    dest_x: u16,
    dest_y: u16,
    src: *const Buffer,
    options: BlitOptions,
) void {
    // Determine source region
    const src_rect = options.src_region orelse Rect{
        .x = 0,
        .y = 0,
        .width = src.width,
        .height = src.height,
    };

    // Clip source region to source bounds
    var src_x = @min(src_rect.x, src.width);
    var src_y = @min(src_rect.y, src.height);
    const src_w = @min(src_rect.width, src.width -| src_x);
    const src_h = @min(src_rect.height, src.height -| src_y);

    if (src_w == 0 or src_h == 0) return;

    // Clip to destination bounds
    const copy_w = @min(src_w, dest.width -| dest_x);
    const copy_h = @min(src_h, dest.height -| dest_y);

    if (copy_w == 0 or copy_h == 0) return;

    var src_buf = src;
    var temp_buf: Buffer = undefined;
    var has_temp = false;
    var reverse_copy = false;

    if (buffersAlias(dest, src) and rectsOverlap(
        .{ .x = src_x, .y = src_y, .width = copy_w, .height = copy_h },
        .{ .x = dest_x, .y = dest_y, .width = copy_w, .height = copy_h },
    )) {
        const extra_col: u16 = if (src_x + copy_w < src.width) 1 else 0;
        const temp_width = copy_w + extra_col;
        const temp_height = copy_h;

        if (Buffer.init(dest.allocator, .{ .width = temp_width, .height = temp_height })) |buf| {
            temp_buf = buf;
            has_temp = true;

            var ty: u16 = 0;
            while (ty < temp_height) : (ty += 1) {
                var tx: u16 = 0;
                while (tx < temp_width) : (tx += 1) {
                    temp_buf.setCell(tx, ty, src.getCell(src_x +| tx, src_y +| ty));
                }
            }

            src_buf = &temp_buf;
            src_x = 0;
            src_y = 0;
        } else |_| {
            // Temp buffer allocation failed. Use reverse-order copy as fallback.
            // Check if we need to copy in reverse (dest starts after src in memory).
            // Convert to linear indices for comparison: index = y * width + x
            const src_start = @as(usize, src_y) * @as(usize, src.width) + @as(usize, src_x);
            const dest_start = @as(usize, dest_y) * @as(usize, dest.width) + @as(usize, dest_x);

            // If dest starts after src in the buffer, we need reverse copy to avoid corruption
            if (dest_start > src_start) {
                reverse_copy = true;
            }
        }
    }

    // Perform the copy with wide character awareness
    if (reverse_copy) {
        // Copy in reverse order (from end to start) to avoid overwriting source data
        // This handles the case where dest region starts after src region in memory
        var dy: i32 = @as(i32, copy_h) - 1;
        while (dy >= 0) : (dy -= 1) {
            var dx: i32 = @as(i32, copy_w) - 1;
            while (dx >= 0) : (dx -= 1) {
                const dx_u = @as(u16, @intCast(dx));
                const dy_u = @as(u16, @intCast(dy));
                const cell = src_buf.getCell(src_x +| dx_u, src_y +| dy_u);

                // Skip all continuation cells during iteration
                // In reverse, we encounter continuations before their base chars,
                // so they will be copied when we process the base char
                if (cell.isContinuation()) {
                    // Check if the base char is outside our copy region (orphan at HIGH end)
                    if (dx == @as(i32, copy_w) - 1) {
                        // This is an orphan continuation at the end - replace with space
                        dest.setCell(dest_x +| dx_u, dest_y +| dy_u, Cell{
                            .char = ' ',
                            .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                            .fg = cell.fg,
                            .bg = cell.bg,
                            .attrs = cell.attrs,
                        });
                    }
                    // Otherwise skip (will be handled by its base char)
                    continue;
                }

                // Skip transparent cells if transparency is enabled
                if (options.transparent and isTransparent(cell)) continue;

                // Check if this is a wide character that needs its continuation
                const is_wide = !cell.isContinuation() and isWideChar(src_buf, src_x +| dx_u, src_y +| dy_u);

                if (is_wide) {
                    // Check if there's room for both cells in the destination
                    if (dx + 1 >= @as(i32, copy_w)) {
                        // Wide char at right edge - replace with space to avoid orphan base
                        dest.setCell(dest_x +| dx_u, dest_y +| dy_u, Cell{
                            .char = ' ',
                            .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                            .fg = cell.fg,
                            .bg = cell.bg,
                            .attrs = cell.attrs,
                        });
                    } else {
                        // Copy both the base and continuation cells
                        dest.setCell(dest_x +| dx_u, dest_y +| dy_u, cell);
                        const cont = src_buf.getCell(src_x +| dx_u + 1, src_y +| dy_u);
                        dest.setCell(dest_x +| dx_u + 1, dest_y +| dy_u, cont);
                    }
                } else {
                    dest.setCell(dest_x +| dx_u, dest_y +| dy_u, cell);
                }
            }
        }
    } else {
        // Normal forward copy
        var dy: u16 = 0;
        while (dy < copy_h) : (dy += 1) {
            var dx: u16 = 0;
            while (dx < copy_w) : (dx += 1) {
                const cell = src_buf.getCell(src_x +| dx, src_y +| dy);

                // Skip orphan continuation cells (start of source region cut a wide char)
                if (cell.isContinuation()) {
                    // Check if the base char is outside our copy region
                    if (dx == 0) {
                        // This is an orphan continuation at the start - skip it
                        continue;
                    }
                    // Otherwise it's a valid continuation following a base char we copied
                }

                // Skip transparent cells if transparency is enabled
                if (options.transparent and isTransparent(cell)) continue;

                // Check if this is a wide character that needs its continuation
                const is_wide = !cell.isContinuation() and isWideChar(src_buf, src_x +| dx, src_y +| dy);

                if (is_wide) {
                    // Check if there's room for both cells in the destination
                    if (dx + 1 >= copy_w) {
                        // Wide char at right edge - replace with space to avoid orphan base
                        dest.setCell(dest_x +| dx, dest_y +| dy, Cell{
                            .char = ' ',
                            .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                            .fg = cell.fg,
                            .bg = cell.bg,
                            .attrs = cell.attrs,
                        });
                    } else {
                        // Copy both the base and continuation cells
                        dest.setCell(dest_x +| dx, dest_y +| dy, cell);
                        const cont = src_buf.getCell(src_x +| dx + 1, src_y +| dy);
                        dest.setCell(dest_x +| dx + 1, dest_y +| dy, cont);
                        dx += 1; // Skip the continuation in the next iteration
                    }
                } else {
                    dest.setCell(dest_x +| dx, dest_y +| dy, cell);
                }
            }
        }
    }

    if (has_temp) {
        temp_buf.deinit();
    }
}

/// Check if a cell at the given position is a wide character (has a continuation cell following it).
fn isWideChar(buf: *const Buffer, x: u16, y: u16) bool {
    const cell = buf.getCell(x, y);
    if (cell.isContinuation()) return false;
    if (x + 1 >= buf.width) return false;
    const next = buf.getCell(x + 1, y);
    return next.isContinuation();
}

fn buffersAlias(dest: *const Buffer, src: *const Buffer) bool {
    return dest.cells.ptr == src.cells.ptr;
}

fn rectsOverlap(a: Rect, b: Rect) bool {
    const a_right = a.x +| a.width;
    const a_bottom = a.y +| a.height;
    const b_right = b.x +| b.width;
    const b_bottom = b.y +| b.height;

    return a.x < b_right and b.x < a_right and a.y < b_bottom and b.y < a_bottom;
}

/// Tile a source buffer repeatedly to fill a destination region.
///
/// Parameters:
/// - dest: Target buffer to fill
/// - dest_rect: Region in the destination to fill
/// - tile: Source buffer used as the tile pattern
/// - options: Tile options (transparency)
///
/// The tile is repeated as many times as needed to fill the destination region.
/// Partial tiles at the edges are clipped.
///
/// Wide character handling: Wide characters are handled specially at tile boundaries.
/// If a wide character would be split at a tile boundary or clip edge, it is replaced
/// with a space to maintain buffer invariants.
pub fn tileBufferToBuffer(
    dest: *Buffer,
    dest_rect: Rect,
    tile: *const Buffer,
    options: TileOptions,
) void {
    if (tile.width == 0 or tile.height == 0) return;

    // Clip destination rect to buffer bounds using saturating arithmetic
    const dx_start = dest_rect.x;
    const dy_start = dest_rect.y;
    // Use saturating addition to prevent overflow
    const rect_end_x = @min(dest_rect.x, std.math.maxInt(u16) - dest_rect.width) + dest_rect.width;
    const rect_end_y = @min(dest_rect.y, std.math.maxInt(u16) - dest_rect.height) + dest_rect.height;
    const dx_end = @min(rect_end_x, dest.width);
    const dy_end = @min(rect_end_y, dest.height);

    if (dx_start >= dest.width or dy_start >= dest.height) return;
    if (dx_end <= dx_start or dy_end <= dy_start) return;

    // Tile the region with wide character awareness
    var dy = dy_start;
    while (dy < dy_end) : (dy += 1) {
        const tile_y: u16 = @intCast((dy - dy_start) % tile.height);

        var dx = dx_start;
        while (dx < dx_end) : (dx += 1) {
            const tile_x: u16 = @intCast((dx - dx_start) % tile.width);
            const cell = tile.getCell(tile_x, tile_y);

            // Skip orphan continuation cells at tile boundaries
            if (cell.isContinuation()) {
                // Check if this is the start of a tile instance (the base char is in the previous tile)
                if (tile_x == 0) {
                    // This continuation's base char is at end of previous tile - skip it
                    continue;
                }
                // Otherwise it's a valid continuation
            }

            // Skip transparent cells if transparency is enabled
            if (options.transparent and isTransparent(cell)) continue;

            // Check if this is a wide character
            const is_wide = !cell.isContinuation() and isWideChar(tile, tile_x, tile_y);

            if (is_wide) {
                // Check if there's room for both cells in the destination
                // Note: isWideChar already verifies the continuation is within tile bounds,
                // so we only need to check destination space
                if (dx + 1 >= dx_end) {
                    // Wide char at boundary - replace with space
                    dest.setCell(dx, dy, Cell{
                        .char = ' ',
                        .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
                        .fg = cell.fg,
                        .bg = cell.bg,
                        .attrs = cell.attrs,
                    });
                } else {
                    // Copy both cells
                    dest.setCell(dx, dy, cell);
                    const cont = tile.getCell(tile_x + 1, tile_y);
                    dest.setCell(dx + 1, dy, cont);
                    dx += 1; // Skip continuation in next iteration
                }
            } else {
                dest.setCell(dx, dy, cell);
            }
        }
    }
}

/// Tile a source buffer repeatedly to fill a plane region.
///
/// Parameters:
/// - dest: Target plane to fill
/// - dest_rect: Region in the plane to fill (local coordinates)
/// - tile: Source buffer used as the tile pattern
/// - options: Tile options (transparency)
pub fn tileBufferToPlane(
    dest: *Plane,
    dest_rect: Rect,
    tile: *const Buffer,
    options: TileOptions,
) void {
    const dest_buf = dest.getBuffer();
    tileBufferToBuffer(dest_buf, dest_rect, tile, options);

    // Mark the affected region as dirty
    // Clip to plane bounds (same logic as tileBufferToBuffer)
    const dx_start = dest_rect.x;
    const dy_start = dest_rect.y;
    const rect_end_x = @min(dest_rect.x, std.math.maxInt(u16) - dest_rect.width) + dest_rect.width;
    const rect_end_y = @min(dest_rect.y, std.math.maxInt(u16) - dest_rect.height) + dest_rect.height;
    const dx_end = @min(rect_end_x, dest.width);
    const dy_end = @min(rect_end_y, dest.height);

    if (dx_start < dest.width and dy_start < dest.height and dx_end > dx_start and dy_end > dy_start) {
        dest.markDirtyRect(.{
            .x = dx_start,
            .y = dy_start,
            .width = dx_end - dx_start,
            .height = dy_end - dy_start,
        });
    }
}

/// Sprite: a cell buffer that can be blitted with transparency.
///
/// Sprites are standalone cell buffers intended for sprite-style overlays.
/// They own their buffer and provide convenient methods for drawing and blitting.
pub const Sprite = struct {
    buffer: Buffer,

    /// Create a new sprite with the given dimensions.
    /// All cells are initialized to transparent (default cell).
    pub fn init(allocator: std.mem.Allocator, dimensions: Size) !Sprite {
        const buffer = try Buffer.init(allocator, dimensions);
        return .{ .buffer = buffer };
    }

    /// Free sprite resources.
    pub fn deinit(self: *Sprite) void {
        self.buffer.deinit();
    }

    /// Get the sprite's width.
    pub fn width(self: *const Sprite) u16 {
        return self.buffer.width;
    }

    /// Get the sprite's height.
    pub fn height(self: *const Sprite) u16 {
        return self.buffer.height;
    }

    /// Get the sprite's dimensions.
    pub fn size(self: *const Sprite) Size {
        return .{ .width = self.buffer.width, .height = self.buffer.height };
    }

    /// Set a cell in the sprite.
    pub fn setCell(self: *Sprite, x: u16, y: u16, cell: Cell) void {
        self.buffer.setCell(x, y, cell);
    }

    /// Get a cell from the sprite.
    pub fn getCell(self: *const Sprite, x: u16, y: u16) Cell {
        return self.buffer.getCell(x, y);
    }

    /// Set a wide character (width 2) with proper continuation marker.
    pub fn setWideCell(self: *Sprite, x: u16, y: u16, cell: Cell) bool {
        return self.buffer.setWideCell(x, y, cell);
    }

    /// Print text to the sprite.
    pub fn print(self: *Sprite, x: u16, y: u16, str: []const u8, fg: Cell.Color, bg: Cell.Color, attrs: Cell.Attributes) void {
        self.buffer.print(x, y, str, fg, bg, attrs);
    }

    /// Clear the sprite to transparent (default cells).
    pub fn clear(self: *Sprite) void {
        self.buffer.clear();
    }

    /// Fill a rectangle in the sprite.
    pub fn fill(self: *Sprite, rect: Rect, cell: Cell) void {
        self.buffer.fill(rect, cell);
    }

    /// Blit this sprite to a plane with transparency enabled.
    pub fn blitTo(self: *const Sprite, dest: *Plane, dest_x: u16, dest_y: u16) void {
        blitBufferToPlane(dest, dest_x, dest_y, &self.buffer, .{ .transparent = true });
    }

    /// Blit this sprite to a plane with custom options.
    pub fn blitToWithOptions(self: *const Sprite, dest: *Plane, dest_x: u16, dest_y: u16, options: BlitOptions) void {
        blitBufferToPlane(dest, dest_x, dest_y, &self.buffer, options);
    }

    /// Blit this sprite to a buffer with transparency enabled.
    pub fn blitToBuffer(self: *const Sprite, dest: *Buffer, dest_x: u16, dest_y: u16) void {
        blitBufferToBuffer(dest, dest_x, dest_y, &self.buffer, .{ .transparent = true });
    }

    /// Blit this sprite to a buffer with custom options.
    pub fn blitToBufferWithOptions(self: *const Sprite, dest: *Buffer, dest_x: u16, dest_y: u16, options: BlitOptions) void {
        blitBufferToBuffer(dest, dest_x, dest_y, &self.buffer, options);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "isTransparent" {
    // Default cell is transparent
    try std.testing.expect(isTransparent(Cell.default));

    // Cell with character is not transparent
    const char_cell = Cell{
        .char = 'A',
        .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };
    try std.testing.expect(!isTransparent(char_cell));

    // Cell with background color is not transparent
    const bg_cell = Cell{
        .char = ' ',
        .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .fg = .default,
        .bg = Cell.Color.blue,
        .attrs = .{},
    };
    try std.testing.expect(!isTransparent(bg_cell));

    // Cell with attributes is not transparent
    const attr_cell = Cell{
        .char = ' ',
        .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{ .reverse = true },
    };
    try std.testing.expect(!isTransparent(attr_cell));

    // Continuation cells (char == 0) are NEVER transparent
    const continuation_cell = Cell{
        .char = 0,
        .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };
    try std.testing.expect(!isTransparent(continuation_cell));

    // Cell with combining marks is not transparent
    const combining_cell = Cell{
        .char = ' ',
        .combining = .{ 0x0301, 0, 0, 0, 0, 0, 0, 0 },
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };
    try std.testing.expect(!isTransparent(combining_cell));
}

test "blitBufferToBuffer full copy" {
    const allocator = std.testing.allocator;

    // Create source buffer with content
    var src = try Buffer.init(allocator, .{ .width = 5, .height = 3 });
    defer src.deinit();
    src.print(0, 0, "Hello", Cell.Color.red, Cell.Color.black, .{});
    src.print(0, 1, "World", Cell.Color.green, Cell.Color.black, .{});

    // Create destination buffer
    var dest = try Buffer.init(allocator, .{ .width = 10, .height = 5 });
    defer dest.deinit();

    // Blit source to destination at position (2, 1)
    blitBufferToBuffer(&dest, 2, 1, &src, .{});

    // Verify content was copied
    try std.testing.expectEqual(@as(u21, 'H'), dest.getCell(2, 1).char);
    try std.testing.expectEqual(@as(u21, 'e'), dest.getCell(3, 1).char);
    try std.testing.expectEqual(@as(u21, 'W'), dest.getCell(2, 2).char);
    try std.testing.expectEqual(@as(u21, 'o'), dest.getCell(3, 2).char);

    // Verify destination outside blit area is unchanged
    try std.testing.expectEqual(@as(u21, ' '), dest.getCell(0, 0).char);
}

test "blitBufferToBuffer with transparency" {
    const allocator = std.testing.allocator;

    // Create destination with existing content
    var dest = try Buffer.init(allocator, .{ .width = 10, .height = 5 });
    defer dest.deinit();
    dest.print(0, 0, "BACKGROUND", Cell.Color.white, Cell.Color.black, .{});

    // Create source with sparse content (transparent holes)
    var src = try Buffer.init(allocator, .{ .width = 5, .height = 1 });
    defer src.deinit();
    // Set only positions 0 and 2, leave 1, 3, 4 as transparent (default)
    src.setCell(0, 0, Cell{ .char = 'X', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = Cell.Color.red, .bg = .default, .attrs = .{} });
    src.setCell(2, 0, Cell{ .char = 'Y', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = Cell.Color.red, .bg = .default, .attrs = .{} });

    // Blit with transparency
    blitBufferToBuffer(&dest, 0, 0, &src, .{ .transparent = true });

    // X and Y should be visible
    try std.testing.expectEqual(@as(u21, 'X'), dest.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'Y'), dest.getCell(2, 0).char);
    // Background should show through transparent cells
    try std.testing.expectEqual(@as(u21, 'A'), dest.getCell(1, 0).char); // 'A' from "BACKGROUND"
    try std.testing.expectEqual(@as(u21, 'K'), dest.getCell(3, 0).char); // 'K' from "BACKGROUND"
}

test "blitBufferToBuffer without transparency overwrites all" {
    const allocator = std.testing.allocator;

    // Create destination with existing content
    var dest = try Buffer.init(allocator, .{ .width = 10, .height = 5 });
    defer dest.deinit();
    dest.print(0, 0, "BACKGROUND", Cell.Color.white, Cell.Color.black, .{});

    // Create source with sparse content
    var src = try Buffer.init(allocator, .{ .width = 5, .height = 1 });
    defer src.deinit();
    src.setCell(0, 0, Cell{ .char = 'X', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = Cell.Color.red, .bg = .default, .attrs = .{} });

    // Blit without transparency (default)
    blitBufferToBuffer(&dest, 0, 0, &src, .{});

    // X should be visible
    try std.testing.expectEqual(@as(u21, 'X'), dest.getCell(0, 0).char);
    // Transparent source cells should OVERWRITE background
    try std.testing.expectEqual(@as(u21, ' '), dest.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), dest.getCell(2, 0).char);
}

test "blitBufferToBuffer clipping at destination edge" {
    const allocator = std.testing.allocator;

    // Create source larger than destination area
    var src = try Buffer.init(allocator, .{ .width = 10, .height = 5 });
    defer src.deinit();
    src.print(0, 0, "ABCDEFGHIJ", Cell.Color.white, Cell.Color.black, .{});

    // Create small destination
    var dest = try Buffer.init(allocator, .{ .width = 5, .height = 3 });
    defer dest.deinit();

    // Blit at position (3, 0) - only 2 columns available
    blitBufferToBuffer(&dest, 3, 0, &src, .{});

    // Only first 2 characters should be copied
    try std.testing.expectEqual(@as(u21, 'A'), dest.getCell(3, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), dest.getCell(4, 0).char);
    // Rest should be unchanged (default)
    try std.testing.expectEqual(@as(u21, ' '), dest.getCell(0, 0).char);
}

test "blitBufferToBuffer with source region" {
    const allocator = std.testing.allocator;

    // Create source buffer
    var src = try Buffer.init(allocator, .{ .width = 10, .height = 5 });
    defer src.deinit();
    src.print(0, 0, "0123456789", Cell.Color.white, Cell.Color.black, .{});
    src.print(0, 1, "ABCDEFGHIJ", Cell.Color.white, Cell.Color.black, .{});

    // Create destination
    var dest = try Buffer.init(allocator, .{ .width = 10, .height = 5 });
    defer dest.deinit();

    // Blit only a sub-region of source (columns 2-5, row 0-1)
    blitBufferToBuffer(&dest, 0, 0, &src, .{
        .src_region = .{ .x = 2, .y = 0, .width = 4, .height = 2 },
    });

    // Verify only sub-region was copied
    try std.testing.expectEqual(@as(u21, '2'), dest.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, '3'), dest.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, '4'), dest.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, '5'), dest.getCell(3, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), dest.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'D'), dest.getCell(1, 1).char);
    // Outside sub-region should be unchanged
    try std.testing.expectEqual(@as(u21, ' '), dest.getCell(4, 0).char);
}

test "blitBufferToBuffer handles overlapping copy" {
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 6, .height = 1 });
    defer buf.deinit();
    buf.print(0, 0, "ABCDE", .default, .default, .{});

    blitBufferToBuffer(&buf, 1, 0, &buf, .{
        .src_region = .{ .x = 0, .y = 0, .width = 5, .height = 1 },
    });

    try std.testing.expectEqual(@as(u21, 'A'), buf.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'A'), buf.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), buf.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), buf.getCell(3, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), buf.getCell(4, 0).char);
    try std.testing.expectEqual(@as(u21, 'E'), buf.getCell(5, 0).char);
}

test "blitBufferToBuffer overlapping preserves wide characters" {
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 6, .height = 1 });
    defer buf.deinit();
    buf.print(0, 0, "A中B", .default, .default, .{});

    blitBufferToBuffer(&buf, 1, 0, &buf, .{
        .src_region = .{ .x = 0, .y = 0, .width = 4, .height = 1 },
    });

    try std.testing.expectEqual(@as(u21, 'A'), buf.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 0x4E2D), buf.getCell(2, 0).char);
    try std.testing.expect(buf.getCell(3, 0).isContinuation());
    try std.testing.expectEqual(@as(u21, 'B'), buf.getCell(4, 0).char);
}

test "tileBufferToBuffer basic tiling" {
    const allocator = std.testing.allocator;

    // Create a 2x2 tile pattern
    var tile = try Buffer.init(allocator, .{ .width = 2, .height = 2 });
    defer tile.deinit();
    tile.setCell(0, 0, Cell{ .char = 'A', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    tile.setCell(1, 0, Cell{ .char = 'B', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    tile.setCell(0, 1, Cell{ .char = 'C', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    tile.setCell(1, 1, Cell{ .char = 'D', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });

    // Create destination
    var dest = try Buffer.init(allocator, .{ .width = 6, .height = 4 });
    defer dest.deinit();

    // Tile the pattern across the destination
    tileBufferToBuffer(&dest, .{ .x = 0, .y = 0, .width = 6, .height = 4 }, &tile, .{});

    // Verify tiling pattern (ABABAB / CDCDCD repeated)
    try std.testing.expectEqual(@as(u21, 'A'), dest.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), dest.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'A'), dest.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), dest.getCell(3, 0).char);
    try std.testing.expectEqual(@as(u21, 'A'), dest.getCell(4, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), dest.getCell(5, 0).char);

    try std.testing.expectEqual(@as(u21, 'C'), dest.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'D'), dest.getCell(1, 1).char);

    try std.testing.expectEqual(@as(u21, 'A'), dest.getCell(0, 2).char);
    try std.testing.expectEqual(@as(u21, 'C'), dest.getCell(0, 3).char);
}

test "tileBufferToBuffer with transparency" {
    const allocator = std.testing.allocator;

    // Create destination with existing content
    var dest = try Buffer.init(allocator, .{ .width = 4, .height = 2 });
    defer dest.deinit();
    dest.print(0, 0, "XXXX", Cell.Color.white, Cell.Color.black, .{});
    dest.print(0, 1, "XXXX", Cell.Color.white, Cell.Color.black, .{});

    // Create a 2x2 tile with a transparent hole
    var tile = try Buffer.init(allocator, .{ .width = 2, .height = 2 });
    defer tile.deinit();
    tile.setCell(0, 0, Cell{ .char = 'A', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = Cell.Color.red, .bg = .default, .attrs = .{} });
    // (1, 0) is transparent (default)
    tile.setCell(0, 1, Cell{ .char = 'B', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = Cell.Color.red, .bg = .default, .attrs = .{} });
    // (1, 1) is transparent (default)

    // Tile with transparency
    tileBufferToBuffer(&dest, .{ .x = 0, .y = 0, .width = 4, .height = 2 }, &tile, .{ .transparent = true });

    // A and B should be visible
    try std.testing.expectEqual(@as(u21, 'A'), dest.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'A'), dest.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), dest.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'B'), dest.getCell(2, 1).char);
    // X should show through transparent cells
    try std.testing.expectEqual(@as(u21, 'X'), dest.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'X'), dest.getCell(3, 0).char);
    try std.testing.expectEqual(@as(u21, 'X'), dest.getCell(1, 1).char);
    try std.testing.expectEqual(@as(u21, 'X'), dest.getCell(3, 1).char);
}

test "tileBufferToBuffer partial tile at edges" {
    const allocator = std.testing.allocator;

    // Create a 3x3 tile
    var tile = try Buffer.init(allocator, .{ .width = 3, .height = 3 });
    defer tile.deinit();
    tile.setCell(0, 0, Cell{ .char = '1', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    tile.setCell(1, 0, Cell{ .char = '2', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    tile.setCell(2, 0, Cell{ .char = '3', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    tile.setCell(0, 1, Cell{ .char = '4', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    tile.setCell(1, 1, Cell{ .char = '5', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    tile.setCell(2, 1, Cell{ .char = '6', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });

    // Create destination with odd size (5x4 != multiple of 3x3)
    var dest = try Buffer.init(allocator, .{ .width = 5, .height = 4 });
    defer dest.deinit();

    tileBufferToBuffer(&dest, .{ .x = 0, .y = 0, .width = 5, .height = 4 }, &tile, .{});

    // Verify partial tiling
    // Row 0: 1 2 3 1 2
    try std.testing.expectEqual(@as(u21, '1'), dest.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, '2'), dest.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, '3'), dest.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, '1'), dest.getCell(3, 0).char);
    try std.testing.expectEqual(@as(u21, '2'), dest.getCell(4, 0).char);

    // Row 1: 4 5 6 4 5
    try std.testing.expectEqual(@as(u21, '4'), dest.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u21, '5'), dest.getCell(1, 1).char);
}

test "Sprite basic operations" {
    const allocator = std.testing.allocator;

    var sprite = try Sprite.init(allocator, .{ .width = 5, .height = 3 });
    defer sprite.deinit();

    try std.testing.expectEqual(@as(u16, 5), sprite.width());
    try std.testing.expectEqual(@as(u16, 3), sprite.height());

    // Set and get cells
    sprite.setCell(1, 1, Cell{ .char = 'X', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = Cell.Color.red, .bg = .default, .attrs = .{} });
    try std.testing.expectEqual(@as(u21, 'X'), sprite.getCell(1, 1).char);

    // Default cells are transparent
    try std.testing.expect(isTransparent(sprite.getCell(0, 0)));

    // Clear resets to transparent
    sprite.clear();
    try std.testing.expect(isTransparent(sprite.getCell(1, 1)));
}

test "Sprite blitTo with transparency" {
    const allocator = std.testing.allocator;

    // Create plane with background
    const plane = try Plane.initRoot(allocator, .{ .width = 10, .height = 5 });
    defer plane.deinit();
    plane.print(0, 0, "BACKGROUND", Cell.Color.white, Cell.Color.black, .{});

    // Create sprite with sparse content
    var sprite = try Sprite.init(allocator, .{ .width = 3, .height = 1 });
    defer sprite.deinit();
    sprite.setCell(0, 0, Cell{ .char = '*', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = Cell.Color.yellow, .bg = .default, .attrs = .{} });
    // Position 1 is transparent
    sprite.setCell(2, 0, Cell{ .char = '*', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = Cell.Color.yellow, .bg = .default, .attrs = .{} });

    // Blit sprite to plane (transparency enabled by default)
    sprite.blitTo(plane, 2, 0);

    // Stars should be visible
    try std.testing.expectEqual(@as(u21, '*'), plane.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, '*'), plane.getCell(4, 0).char);
    // Background should show through (position 3 is 'K' in "BACKGROUND")
    try std.testing.expectEqual(@as(u21, 'K'), plane.getCell(3, 0).char);
    // Rest of background unchanged
    try std.testing.expectEqual(@as(u21, 'B'), plane.getCell(0, 0).char);
}

test "blitPlaneToPlane" {
    const allocator = std.testing.allocator;

    // Create source plane
    const src = try Plane.initRoot(allocator, .{ .width = 5, .height = 3 });
    defer src.deinit();
    src.print(0, 0, "Hello", Cell.Color.red, Cell.Color.black, .{});

    // Create destination plane
    const dest = try Plane.initRoot(allocator, .{ .width = 10, .height = 5 });
    defer dest.deinit();

    // Blit plane to plane
    blitPlaneToPlane(dest, 2, 1, src, .{});

    // Verify content
    try std.testing.expectEqual(@as(u21, 'H'), dest.getCell(2, 1).char);
    try std.testing.expectEqual(@as(u21, 'e'), dest.getCell(3, 1).char);
}

test "tileBufferToPlane" {
    const allocator = std.testing.allocator;

    // Create tile
    var tile = try Buffer.init(allocator, .{ .width = 2, .height = 1 });
    defer tile.deinit();
    tile.setCell(0, 0, Cell{ .char = '#', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = Cell.Color.blue, .bg = .default, .attrs = .{} });
    tile.setCell(1, 0, Cell{ .char = '.', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = Cell.Color.cyan, .bg = .default, .attrs = .{} });

    // Create plane
    const plane = try Plane.initRoot(allocator, .{ .width = 6, .height = 2 });
    defer plane.deinit();

    // Tile to plane
    tileBufferToPlane(plane, .{ .x = 0, .y = 0, .width = 6, .height = 2 }, &tile, .{});

    // Verify pattern
    try std.testing.expectEqual(@as(u21, '#'), plane.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, '.'), plane.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, '#'), plane.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, '.'), plane.getCell(3, 0).char);
}

test "blitBufferToBuffer zero size source" {
    const allocator = std.testing.allocator;

    // Create zero-size source
    var src = try Buffer.init(allocator, .{ .width = 0, .height = 0 });
    defer src.deinit();

    // Create destination
    var dest = try Buffer.init(allocator, .{ .width = 5, .height = 3 });
    defer dest.deinit();
    dest.print(0, 0, "Hello", Cell.Color.white, Cell.Color.black, .{});

    // Blit should be a no-op
    blitBufferToBuffer(&dest, 0, 0, &src, .{});

    // Content should be unchanged
    try std.testing.expectEqual(@as(u21, 'H'), dest.getCell(0, 0).char);
}

test "blitBufferToBuffer source region out of bounds" {
    const allocator = std.testing.allocator;

    var src = try Buffer.init(allocator, .{ .width = 5, .height = 3 });
    defer src.deinit();
    src.print(0, 0, "Hello", Cell.Color.white, Cell.Color.black, .{});

    var dest = try Buffer.init(allocator, .{ .width = 10, .height = 5 });
    defer dest.deinit();

    // Request source region that extends past source bounds
    blitBufferToBuffer(&dest, 0, 0, &src, .{
        .src_region = .{ .x = 3, .y = 0, .width = 10, .height = 10 },
    });

    // Only valid portion should be copied (positions 3,4 from "Hello" -> "lo")
    try std.testing.expectEqual(@as(u21, 'l'), dest.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'o'), dest.getCell(1, 0).char);
    // Rest should be default
    try std.testing.expectEqual(@as(u21, ' '), dest.getCell(2, 0).char);
}

test "tileBufferToBuffer clipping to destination bounds" {
    const allocator = std.testing.allocator;

    var tile = try Buffer.init(allocator, .{ .width = 2, .height = 2 });
    defer tile.deinit();
    tile.setCell(0, 0, Cell{ .char = 'X', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    tile.setCell(1, 0, Cell{ .char = 'X', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    tile.setCell(0, 1, Cell{ .char = 'X', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    tile.setCell(1, 1, Cell{ .char = 'X', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });

    var dest = try Buffer.init(allocator, .{ .width = 5, .height = 3 });
    defer dest.deinit();
    dest.print(0, 0, "AAAAA", Cell.Color.white, Cell.Color.black, .{});

    // Tile region extends past destination bounds
    tileBufferToBuffer(&dest, .{ .x = 3, .y = 1, .width = 10, .height = 10 }, &tile, .{});

    // Only valid portion should be tiled
    try std.testing.expectEqual(@as(u21, 'X'), dest.getCell(3, 1).char);
    try std.testing.expectEqual(@as(u21, 'X'), dest.getCell(4, 1).char);
    try std.testing.expectEqual(@as(u21, 'X'), dest.getCell(3, 2).char);
    try std.testing.expectEqual(@as(u21, 'X'), dest.getCell(4, 2).char);
    // Row 0 should be unchanged
    try std.testing.expectEqual(@as(u21, 'A'), dest.getCell(0, 0).char);
}

// ============================================================================
// Wide character tests
// ============================================================================

test "blitBufferToBuffer preserves wide character integrity" {
    const allocator = std.testing.allocator;

    // Create source with a CJK character (中 = U+4E2D, width 2)
    var src = try Buffer.init(allocator, .{ .width = 5, .height = 1 });
    defer src.deinit();
    src.print(0, 0, "A中B", .default, .default, .{});
    // Buffer should be: A, 中, [cont], B, [space]
    // Positions:        0,  1,    2,   3,    4

    var dest = try Buffer.init(allocator, .{ .width = 10, .height = 1 });
    defer dest.deinit();

    // Blit entire source
    blitBufferToBuffer(&dest, 0, 0, &src, .{});

    // Verify wide char was copied correctly with continuation
    try std.testing.expectEqual(@as(u21, 'A'), dest.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 0x4E2D), dest.getCell(1, 0).char); // 中
    try std.testing.expect(dest.getCell(2, 0).isContinuation()); // continuation
    try std.testing.expectEqual(@as(u21, 'B'), dest.getCell(3, 0).char);
}

test "blitBufferToBuffer clips wide char at right edge" {
    const allocator = std.testing.allocator;

    // Create source with wide char near the end
    var src = try Buffer.init(allocator, .{ .width = 4, .height = 1 });
    defer src.deinit();
    src.print(0, 0, "AB中", .default, .default, .{});
    // Buffer: A, B, 中, [cont]
    // Positions: 0, 1, 2, 3

    // Create small destination that can only fit 3 cells
    var dest = try Buffer.init(allocator, .{ .width = 3, .height = 1 });
    defer dest.deinit();

    // Blit - wide char at position 2 should be replaced with space (no room for continuation)
    blitBufferToBuffer(&dest, 0, 0, &src, .{});

    try std.testing.expectEqual(@as(u21, 'A'), dest.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), dest.getCell(1, 0).char);
    // Wide char replaced with space since continuation wouldn't fit
    try std.testing.expectEqual(@as(u21, ' '), dest.getCell(2, 0).char);
}

test "blitBufferToBuffer skips orphan continuation at source region start" {
    const allocator = std.testing.allocator;

    // Create source with wide char
    var src = try Buffer.init(allocator, .{ .width = 4, .height = 1 });
    defer src.deinit();
    src.print(0, 0, "中AB", .default, .default, .{});
    // Buffer: 中, [cont], A, B
    // Positions: 0, 1, 2, 3

    var dest = try Buffer.init(allocator, .{ .width = 10, .height = 1 });
    defer dest.deinit();

    // Blit starting from position 1 (the continuation cell)
    // Source region: [cont], A, B (positions 1, 2, 3 in source)
    // After blit: position 0 stays default (orphan cont skipped), A at 1, B at 2
    blitBufferToBuffer(&dest, 0, 0, &src, .{
        .src_region = .{ .x = 1, .y = 0, .width = 3, .height = 1 },
    });

    // The orphan continuation at position 0 is skipped (dest[0] stays default)
    // A is at source position 2, which is offset 1 in region, so dest[1]
    // B is at source position 3, which is offset 2 in region, so dest[2]
    try std.testing.expectEqual(@as(u21, ' '), dest.getCell(0, 0).char); // default (skipped orphan)
    try std.testing.expectEqual(@as(u21, 'A'), dest.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), dest.getCell(2, 0).char);
}

test "tileBufferToBuffer with wide characters" {
    const allocator = std.testing.allocator;

    // Create a tile with a wide character
    var tile = try Buffer.init(allocator, .{ .width = 4, .height = 1 });
    defer tile.deinit();
    tile.print(0, 0, "中AB", .default, .default, .{});
    // Tile: 中, [cont], A, B

    var dest = try Buffer.init(allocator, .{ .width = 8, .height = 1 });
    defer dest.deinit();

    // Tile the pattern
    tileBufferToBuffer(&dest, .{ .x = 0, .y = 0, .width = 8, .height = 1 }, &tile, .{});

    // First tile: 中, [cont], A, B
    try std.testing.expectEqual(@as(u21, 0x4E2D), dest.getCell(0, 0).char);
    try std.testing.expect(dest.getCell(1, 0).isContinuation());
    try std.testing.expectEqual(@as(u21, 'A'), dest.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), dest.getCell(3, 0).char);

    // Second tile: 中, [cont], A, B
    try std.testing.expectEqual(@as(u21, 0x4E2D), dest.getCell(4, 0).char);
    try std.testing.expect(dest.getCell(5, 0).isContinuation());
    try std.testing.expectEqual(@as(u21, 'A'), dest.getCell(6, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), dest.getCell(7, 0).char);
}

test "tileBufferToBuffer handles wide char at tile boundary" {
    const allocator = std.testing.allocator;

    // Create a tile where wide char is at the very end (its continuation would wrap)
    var tile = try Buffer.init(allocator, .{ .width = 3, .height = 1 });
    defer tile.deinit();
    tile.print(0, 0, "A中", .default, .default, .{});
    // Tile: A, 中, [cont]
    // When tiled: A, 中, [cont], A, 中, [cont], ...

    var dest = try Buffer.init(allocator, .{ .width = 6, .height = 1 });
    defer dest.deinit();

    tileBufferToBuffer(&dest, .{ .x = 0, .y = 0, .width = 6, .height = 1 }, &tile, .{});

    // First tile
    try std.testing.expectEqual(@as(u21, 'A'), dest.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 0x4E2D), dest.getCell(1, 0).char);
    try std.testing.expect(dest.getCell(2, 0).isContinuation());

    // Second tile
    try std.testing.expectEqual(@as(u21, 'A'), dest.getCell(3, 0).char);
    try std.testing.expectEqual(@as(u21, 0x4E2D), dest.getCell(4, 0).char);
    try std.testing.expect(dest.getCell(5, 0).isContinuation());
}

test "isWideChar helper" {
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 5, .height = 1 });
    defer buf.deinit();
    buf.print(0, 0, "A中B", .default, .default, .{});
    // Buffer: A, 中, [cont], B, [space]

    // 'A' is not wide
    try std.testing.expect(!isWideChar(&buf, 0, 0));
    // 中 is wide (followed by continuation)
    try std.testing.expect(isWideChar(&buf, 1, 0));
    // Continuation cell is not considered wide (it's part of the wide char)
    try std.testing.expect(!isWideChar(&buf, 2, 0));
    // 'B' is not wide
    try std.testing.expect(!isWideChar(&buf, 3, 0));
}

test "blitBufferToBuffer overlapping forward shift (dest after src)" {
    // This is the critical case: copying forward within the same buffer
    // where dest region starts after src region (forward copy would corrupt)
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 10, .height = 1 });
    defer buf.deinit();

    // Initialize with distinct pattern so we can see if copying is correct
    buf.print(0, 0, "ABCDEFGHIJ", .default, .default, .{});
    // Buffer: A B C D E F G H I J (positions 0-9)

    // Copy from [0-4] to [3-7] - forward shift by 3
    // This would corrupt if done naively (A gets overwritten before being read)
    blitBufferToBuffer(&buf, 3, 0, &buf, .{
        .src_region = .{ .x = 0, .y = 0, .width = 5, .height = 1 },
    });

    // Expected result: A B C A B C D E I J
    // The first 3 positions stay (source is protected by temp buffer)
    try std.testing.expectEqual(@as(u21, 'A'), buf.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), buf.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), buf.getCell(2, 0).char);
    // Destination positions 3-7 get the copy of A B C D E
    try std.testing.expectEqual(@as(u21, 'A'), buf.getCell(3, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), buf.getCell(4, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), buf.getCell(5, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), buf.getCell(6, 0).char);
    try std.testing.expectEqual(@as(u21, 'E'), buf.getCell(7, 0).char);
    // Positions 8-9 should be unchanged
    try std.testing.expectEqual(@as(u21, 'I'), buf.getCell(8, 0).char);
    try std.testing.expectEqual(@as(u21, 'J'), buf.getCell(9, 0).char);
}

test "blitBufferToBuffer overlapping backward shift (dest before src)" {
    // When dest region starts before src region, forward copy is safe
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 10, .height = 1 });
    defer buf.deinit();

    buf.print(0, 0, "ABCDEFGHIJ", .default, .default, .{});

    // Copy from [5-9] to [1-5] - backward shift by 4
    // This is safe to do forward because we read ahead of writes
    blitBufferToBuffer(&buf, 1, 0, &buf, .{
        .src_region = .{ .x = 5, .y = 0, .width = 5, .height = 1 },
    });

    // Expected: A F G H I J G H I J
    // Position 0 unchanged, positions 1-5 get F G H I J, 6-9 still have old content
    try std.testing.expectEqual(@as(u21, 'A'), buf.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'F'), buf.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'G'), buf.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, 'H'), buf.getCell(3, 0).char);
    try std.testing.expectEqual(@as(u21, 'I'), buf.getCell(4, 0).char);
    try std.testing.expectEqual(@as(u21, 'J'), buf.getCell(5, 0).char);
}

test "blitBufferToBuffer overlapping with wide chars forward shift" {
    // Verify wide character integrity when doing overlapping forward shifts
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 10, .height = 1 });
    defer buf.deinit();

    // Manually set cells to avoid print() complexity:
    // Position: 0    1      2         3  4  5  6  7  8  9
    // Content:  A    中     [cont]    B  C  D  E  F  G  H
    buf.setCell(0, 0, Cell{ .char = 'A', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    buf.setCell(1, 0, Cell{ .char = 0x4E2D, .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} }); // 中
    buf.setCell(2, 0, Cell{ .char = 0, .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} }); // continuation
    buf.setCell(3, 0, Cell{ .char = 'B', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    buf.setCell(4, 0, Cell{ .char = 'C', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    buf.setCell(5, 0, Cell{ .char = 'D', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    buf.setCell(6, 0, Cell{ .char = 'E', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    buf.setCell(7, 0, Cell{ .char = 'F', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    buf.setCell(8, 0, Cell{ .char = 'G', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    buf.setCell(9, 0, Cell{ .char = 'H', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });

    // Copy from [0-4] to [3-7] - shifts by 3
    // Source region copies: A, 中, [cont], B, C (5 cells)
    blitBufferToBuffer(&buf, 3, 0, &buf, .{
        .src_region = .{ .x = 0, .y = 0, .width = 5, .height = 1 },
    });

    // Expected after copy (using temp buffer protection):
    // Position: 0    1      2         3  4      5         6  7  8  9
    // Content:  A    中     [cont]    A  中     [cont]    B  C  G  H

    // First three cells should be unchanged
    try std.testing.expectEqual(@as(u21, 'A'), buf.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 0x4E2D), buf.getCell(1, 0).char); // 中
    try std.testing.expect(buf.getCell(2, 0).isContinuation());

    // At position 3-5 we should have the copied A, 中, and its continuation
    try std.testing.expectEqual(@as(u21, 'A'), buf.getCell(3, 0).char);
    try std.testing.expectEqual(@as(u21, 0x4E2D), buf.getCell(4, 0).char);
    try std.testing.expect(buf.getCell(5, 0).isContinuation());

    // Position 6-7 should have B and C
    try std.testing.expectEqual(@as(u21, 'B'), buf.getCell(6, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), buf.getCell(7, 0).char);

    // Positions 8-9 unchanged
    try std.testing.expectEqual(@as(u21, 'G'), buf.getCell(8, 0).char);
    try std.testing.expectEqual(@as(u21, 'H'), buf.getCell(9, 0).char);
}

test "blitBufferToBuffer overlapping multi-row forward shift" {
    // Test overlapping with multiple rows
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 5, .height = 4 });
    defer buf.deinit();

    // Fill with distinct pattern to verify correct copying
    buf.print(0, 0, "AAAAA", .default, .default, .{});
    buf.print(0, 1, "BBBBB", .default, .default, .{});
    buf.print(0, 2, "CCCCC", .default, .default, .{});
    buf.print(0, 3, "DDDDD", .default, .default, .{});

    // Copy from rows 0-1, cols 0-4 to rows 1-2, cols 0-4 (vertical shift)
    // This overlaps: source row 1 (BBBBB) is same as dest row 1
    blitBufferToBuffer(&buf, 0, 1, &buf, .{
        .src_region = .{ .x = 0, .y = 0, .width = 5, .height = 2 },
    });

    // Expected:
    // Row 0: AAAAA (unchanged)
    // Row 1: AAAAA (copied from src row 0)
    // Row 2: BBBBB (copied from src row 1)
    // Row 3: DDDDD (unchanged)

    for (0..5) |x| {
        try std.testing.expectEqual(@as(u21, 'A'), buf.getCell(@intCast(x), 0).char);
        try std.testing.expectEqual(@as(u21, 'A'), buf.getCell(@intCast(x), 1).char);
        try std.testing.expectEqual(@as(u21, 'B'), buf.getCell(@intCast(x), 2).char);
        try std.testing.expectEqual(@as(u21, 'D'), buf.getCell(@intCast(x), 3).char);
    }
}

test "blitBufferToBuffer reverse copy fallback for wide chars" {
    // Test reverse-order copying with wide characters
    // This verifies the fallback mechanism works correctly
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, .{ .width = 10, .height = 1 });
    defer buf.deinit();

    // Set up buffer with wide character
    // Position: 0    1      2         3  4  5  6  7  8  9
    // Content:  A    中     [cont]    B  C  D  E  F  G  H
    buf.setCell(0, 0, Cell{ .char = 'A', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    buf.setCell(1, 0, Cell{ .char = 0x4E2D, .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    buf.setCell(2, 0, Cell{ .char = 0, .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    buf.setCell(3, 0, Cell{ .char = 'B', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    buf.setCell(4, 0, Cell{ .char = 'C', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    buf.setCell(5, 0, Cell{ .char = 'D', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    buf.setCell(6, 0, Cell{ .char = 'E', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    buf.setCell(7, 0, Cell{ .char = 'F', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    buf.setCell(8, 0, Cell{ .char = 'G', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });
    buf.setCell(9, 0, Cell{ .char = 'H', .combining = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .fg = .default, .bg = .default, .attrs = .{} });

    // Forward shift by 2 (overlapping, would corrupt without reverse copy or temp buffer)
    blitBufferToBuffer(&buf, 2, 0, &buf, .{
        .src_region = .{ .x = 0, .y = 0, .width = 5, .height = 1 },
    });

    // Expected after safe copy:
    // Position: 0    1      2      3  4         5      6  7  8  9
    // Content:  A    中     A      中  [cont]    B      C  F  G  H

    try std.testing.expectEqual(@as(u21, 'A'), buf.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 0x4E2D), buf.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'A'), buf.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u21, 0x4E2D), buf.getCell(3, 0).char);
    try std.testing.expect(buf.getCell(4, 0).isContinuation());
    try std.testing.expectEqual(@as(u21, 'B'), buf.getCell(5, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), buf.getCell(6, 0).char);
    try std.testing.expectEqual(@as(u21, 'F'), buf.getCell(7, 0).char);
    try std.testing.expectEqual(@as(u21, 'G'), buf.getCell(8, 0).char);
    try std.testing.expectEqual(@as(u21, 'H'), buf.getCell(9, 0).char);
}
