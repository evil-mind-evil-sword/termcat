//! iTerm2 Inline Images Protocol implementation for terminal image display.
//!
//! This module provides an API for displaying images on terminals that support
//! the iTerm2 inline images protocol (iTerm2, VSCode terminal, Hyper, and others).
//!
//! The protocol uses OSC (Operating System Command) escape sequences to transmit
//! base64-encoded image data with optional sizing and display parameters.
//!
//! Usage:
//! ```zig
//! var iterm = ITerm2Graphics.init(allocator);
//! defer iterm.deinit();
//!
//! // Draw an image at current cursor position
//! try iterm.draw(writer, surface, .{
//!     .width = .{ .cells = 40 },
//!     .height = .{ .cells = 20 },
//! });
//! ```
//!
//! References:
//! - https://iterm2.com/documentation-images.html

const std = @import("std");
const Surface = @import("../Surface.zig");
const Pixel = Surface.Pixel;

/// iTerm2 inline images protocol handler.
pub const ITerm2Graphics = @This();

/// Allocator for internal buffers.
allocator: std.mem.Allocator,

/// Temporary buffer for base64 encoding.
encode_buffer: std.ArrayList(u8),

/// Temporary buffer for PNG encoding.
png_buffer: std.ArrayList(u8),

/// Size specification for width/height parameters.
pub const SizeSpec = union(enum) {
    /// Automatic sizing based on image dimensions.
    auto,
    /// Size in terminal cells.
    cells: u16,
    /// Size in pixels.
    pixels: u32,
    /// Size as percentage of terminal/session width.
    percent: u8,

    /// Format for iTerm2 protocol string.
    pub fn format(self: SizeSpec, writer: anytype) !void {
        switch (self) {
            .auto => try writer.writeAll("auto"),
            .cells => |n| try writer.print("{d}", .{n}),
            .pixels => |n| try writer.print("{d}px", .{n}),
            .percent => |n| try writer.print("{d}%", .{n}),
        }
    }
};

/// Options for drawing an image.
pub const DrawOptions = struct {
    /// Width specification (default: auto).
    width: SizeSpec = .auto,

    /// Height specification (default: auto).
    height: SizeSpec = .auto,

    /// Whether to preserve aspect ratio (default: true).
    preserve_aspect_ratio: bool = true,

    /// Optional filename (for display purposes).
    filename: ?[]const u8 = null,

    /// If true, move cursor to position before drawing.
    position: ?CellPosition = null,
};

/// Cell position for image placement.
pub const CellPosition = struct {
    x: u16,
    y: u16,
};

/// Initialize an iTerm2 graphics handler.
pub fn init(allocator: std.mem.Allocator) ITerm2Graphics {
    return .{
        .allocator = allocator,
        .encode_buffer = .empty,
        .png_buffer = .empty,
    };
}

/// Free resources.
pub fn deinit(self: *ITerm2Graphics) void {
    self.encode_buffer.deinit(self.allocator);
    self.png_buffer.deinit(self.allocator);
    self.* = undefined;
}

/// Draw a surface to the terminal using the iTerm2 inline images protocol.
///
/// The image is transmitted as base64-encoded PNG data within an OSC 1337
/// escape sequence. If options.position is set, the cursor is moved to that
/// position before transmission.
pub fn draw(self: *ITerm2Graphics, writer: anytype, surface: Surface, options: DrawOptions) !void {
    if (surface.width == 0 or surface.height == 0) return;

    // Move cursor to placement position if specified
    if (options.position) |pos| {
        try moveCursor(writer, pos.x, pos.y);
    }

    // Encode surface as PNG
    try self.encodePNG(surface);

    // Base64 encode the PNG data
    self.encode_buffer.clearRetainingCapacity();
    const encoded_len = std.base64.standard.Encoder.calcSize(self.png_buffer.items.len);
    try self.encode_buffer.resize(self.allocator, encoded_len);
    _ = std.base64.standard.Encoder.encode(self.encode_buffer.items, self.png_buffer.items);

    // Write OSC sequence: ESC ] 1337 ; File = [args] : base64 BEL
    try writer.writeAll("\x1b]1337;File=");

    // Required: inline=1 for display
    try writer.writeAll("inline=1");

    // Optional: size parameter (helps terminal allocate space)
    try writer.print(";size={d}", .{self.png_buffer.items.len});

    // Width
    try writer.writeAll(";width=");
    try options.width.format(writer);

    // Height
    try writer.writeAll(";height=");
    try options.height.format(writer);

    // Preserve aspect ratio
    if (!options.preserve_aspect_ratio) {
        try writer.writeAll(";preserveAspectRatio=0");
    }

    // Optional filename
    if (options.filename) |name| {
        try writer.writeAll(";name=");
        // Filename must be base64 encoded
        const name_encoded_len = std.base64.standard.Encoder.calcSize(name.len);
        var name_buf: [256]u8 = undefined;
        if (name_encoded_len <= name_buf.len) {
            const encoded_name = name_buf[0..name_encoded_len];
            _ = std.base64.standard.Encoder.encode(encoded_name, name);
            try writer.writeAll(encoded_name);
        }
    }

    // Payload separator and data
    try writer.writeAll(":");
    try writer.writeAll(self.encode_buffer.items);

    // End with BEL (or ST, but BEL is more widely supported)
    try writer.writeAll("\x07");
}

/// Draw raw PNG data to the terminal.
///
/// Use this if you already have PNG-encoded data (avoids re-encoding).
pub fn drawPNG(self: *ITerm2Graphics, writer: anytype, png_data: []const u8, options: DrawOptions) !void {
    if (png_data.len == 0) return;

    // Move cursor to placement position if specified
    if (options.position) |pos| {
        try moveCursor(writer, pos.x, pos.y);
    }

    // Base64 encode the PNG data
    self.encode_buffer.clearRetainingCapacity();
    const encoded_len = std.base64.standard.Encoder.calcSize(png_data.len);
    try self.encode_buffer.resize(self.allocator, encoded_len);
    _ = std.base64.standard.Encoder.encode(self.encode_buffer.items, png_data);

    // Write OSC sequence
    try writer.writeAll("\x1b]1337;File=inline=1");
    try writer.print(";size={d}", .{png_data.len});

    try writer.writeAll(";width=");
    try options.width.format(writer);
    try writer.writeAll(";height=");
    try options.height.format(writer);

    if (!options.preserve_aspect_ratio) {
        try writer.writeAll(";preserveAspectRatio=0");
    }

    if (options.filename) |name| {
        try writer.writeAll(";name=");
        const name_encoded_len = std.base64.standard.Encoder.calcSize(name.len);
        var name_buf: [256]u8 = undefined;
        if (name_encoded_len <= name_buf.len) {
            const encoded_name = name_buf[0..name_encoded_len];
            _ = std.base64.standard.Encoder.encode(encoded_name, name);
            try writer.writeAll(encoded_name);
        }
    }

    try writer.writeAll(":");
    try writer.writeAll(self.encode_buffer.items);
    try writer.writeAll("\x07");
}

/// Encode a surface as PNG into the internal buffer.
fn encodePNG(self: *ITerm2Graphics, surface: Surface) !void {
    self.png_buffer.clearRetainingCapacity();

    // PNG signature
    try self.png_buffer.appendSlice(self.allocator, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A });

    // IHDR chunk
    try self.writeIHDR(surface.width, surface.height);

    // IDAT chunk (image data)
    try self.writeIDAT(surface);

    // IEND chunk
    try self.writeChunk("IEND", &[_]u8{});
}

/// Write PNG IHDR chunk.
fn writeIHDR(self: *ITerm2Graphics, width: u32, height: u32) !void {
    var data: [13]u8 = undefined;
    // Width (4 bytes, big-endian)
    std.mem.writeInt(u32, data[0..4], width, .big);
    // Height (4 bytes, big-endian)
    std.mem.writeInt(u32, data[4..8], height, .big);
    // Bit depth: 8
    data[8] = 8;
    // Color type: 6 (RGBA)
    data[9] = 6;
    // Compression method: 0 (deflate)
    data[10] = 0;
    // Filter method: 0
    data[11] = 0;
    // Interlace method: 0 (no interlace)
    data[12] = 0;

    try self.writeChunk("IHDR", &data);
}

/// Write PNG IDAT chunk with zlib-wrapped uncompressed deflate data.
/// Uses store blocks (no compression) for simplicity - valid PNG but larger.
fn writeIDAT(self: *ITerm2Graphics, surface: Surface) !void {
    // Prepare raw scanlines with filter bytes
    const row_size = @as(usize, surface.width) * 4 + 1; // +1 for filter byte
    const raw_size = row_size * @as(usize, surface.height);

    var raw_data = try self.allocator.alloc(u8, raw_size);
    defer self.allocator.free(raw_data);

    // Fill scanlines
    var y: u32 = 0;
    while (y < surface.height) : (y += 1) {
        const row_offset = @as(usize, y) * row_size;
        // Filter type 0 (None) for simplicity
        raw_data[row_offset] = 0;

        var x: u32 = 0;
        while (x < surface.width) : (x += 1) {
            const pixel = surface.getPixel(x, y) orelse Pixel.transparent;
            const px_offset = row_offset + 1 + @as(usize, x) * 4;
            raw_data[px_offset + 0] = pixel.r;
            raw_data[px_offset + 1] = pixel.g;
            raw_data[px_offset + 2] = pixel.b;
            raw_data[px_offset + 3] = pixel.a;
        }
    }

    // Wrap in zlib format with uncompressed deflate store blocks
    var zlib_data: std.ArrayList(u8) = .empty;
    defer zlib_data.deinit(self.allocator);

    // Zlib header: CMF=0x78 (deflate, 32K window), FLG=0x01 (no dict, level 0, checksum)
    try zlib_data.appendSlice(self.allocator, &[_]u8{ 0x78, 0x01 });

    // Write deflate store blocks (type 00)
    // Each store block: 1 byte header + 2 byte len + 2 byte nlen + data
    // Max block size is 65535 bytes
    const max_block: usize = 65535;
    var offset: usize = 0;
    while (offset < raw_size) {
        const remaining = raw_size - offset;
        const block_size = @min(remaining, max_block);
        const is_final = (offset + block_size >= raw_size);

        // Block header: BFINAL (1 bit) + BTYPE=00 (2 bits) = 0x00 or 0x01
        try zlib_data.append(self.allocator, if (is_final) 0x01 else 0x00);

        // LEN (2 bytes, little-endian)
        const len: u16 = @intCast(block_size);
        try zlib_data.append(self.allocator, @truncate(len & 0xFF));
        try zlib_data.append(self.allocator, @truncate(len >> 8));

        // NLEN (one's complement of LEN)
        const nlen: u16 = ~len;
        try zlib_data.append(self.allocator, @truncate(nlen & 0xFF));
        try zlib_data.append(self.allocator, @truncate(nlen >> 8));

        // Data
        try zlib_data.appendSlice(self.allocator, raw_data[offset..][0..block_size]);
        offset += block_size;
    }

    // Adler-32 checksum (zlib footer)
    const adler = adler32(raw_data);
    var adler_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_bytes, adler, .big);
    try zlib_data.appendSlice(self.allocator, &adler_bytes);

    try self.writeChunk("IDAT", zlib_data.items);
}

/// Compute Adler-32 checksum for zlib footer.
fn adler32(data: []const u8) u32 {
    const MOD_ADLER: u32 = 65521;
    var a: u32 = 1;
    var b: u32 = 0;

    for (data) |byte| {
        a = (a + byte) % MOD_ADLER;
        b = (b + a) % MOD_ADLER;
    }

    return (b << 16) | a;
}

/// Write a PNG chunk.
fn writeChunk(self: *ITerm2Graphics, chunk_type: *const [4]u8, data: []const u8) !void {
    // Length (4 bytes, big-endian)
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(data.len), .big);
    try self.png_buffer.appendSlice(self.allocator, &len_bytes);

    // Type (4 bytes)
    try self.png_buffer.appendSlice(self.allocator, chunk_type);

    // Data
    try self.png_buffer.appendSlice(self.allocator, data);

    // CRC32 (over type + data)
    var crc = std.hash.Crc32.init();
    crc.update(chunk_type);
    crc.update(data);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    try self.png_buffer.appendSlice(self.allocator, &crc_bytes);
}

/// Move cursor to specified cell position.
pub fn moveCursor(writer: anytype, x: u16, y: u16) !void {
    // ANSI cursor position (1-indexed)
    try writer.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
}

/// Clear images in the scrollback (iTerm2-specific).
pub fn clearScrollback(writer: anytype) !void {
    try writer.writeAll("\x1b]1337;ClearScrollback\x07");
}

// ============================================================================
// Tests
// ============================================================================

test "ITerm2Graphics init and deinit" {
    var iterm = ITerm2Graphics.init(std.testing.allocator);
    defer iterm.deinit();

    try std.testing.expect(iterm.encode_buffer.items.len == 0);
    try std.testing.expect(iterm.png_buffer.items.len == 0);
}

test "ITerm2Graphics draw small image" {
    var iterm = ITerm2Graphics.init(std.testing.allocator);
    defer iterm.deinit();

    // Create a tiny 2x2 surface
    var surface = try Surface.init(std.testing.allocator, 2, 2);
    defer surface.deinit();
    surface.setPixel(0, 0, Pixel.rgb(255, 0, 0));
    surface.setPixel(1, 0, Pixel.rgb(0, 255, 0));
    surface.setPixel(0, 1, Pixel.rgb(0, 0, 255));
    surface.setPixel(1, 1, Pixel.rgb(255, 255, 255));

    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try iterm.draw(output.writer(), surface, .{});

    // Verify output starts with OSC 1337
    try std.testing.expect(std.mem.startsWith(u8, output.items, "\x1b]1337;File="));
    // Should contain inline=1
    try std.testing.expect(std.mem.indexOf(u8, output.items, "inline=1") != null);
    // Should end with BEL
    try std.testing.expect(std.mem.endsWith(u8, output.items, "\x07"));
}

test "ITerm2Graphics draw with size options" {
    var iterm = ITerm2Graphics.init(std.testing.allocator);
    defer iterm.deinit();

    var surface = try Surface.init(std.testing.allocator, 1, 1);
    defer surface.deinit();
    surface.setPixel(0, 0, Pixel.white);

    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try iterm.draw(output.writer(), surface, .{
        .width = .{ .cells = 40 },
        .height = .{ .pixels = 200 },
        .preserve_aspect_ratio = false,
    });

    try std.testing.expect(std.mem.indexOf(u8, output.items, "width=40") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "height=200px") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "preserveAspectRatio=0") != null);
}

test "ITerm2Graphics draw at position" {
    var iterm = ITerm2Graphics.init(std.testing.allocator);
    defer iterm.deinit();

    var surface = try Surface.init(std.testing.allocator, 1, 1);
    defer surface.deinit();
    surface.setPixel(0, 0, Pixel.white);

    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try iterm.draw(output.writer(), surface, .{
        .position = .{ .x = 10, .y = 5 },
    });

    // Should start with cursor move sequence
    try std.testing.expect(std.mem.startsWith(u8, output.items, "\x1b[6;11H"));
}

test "SizeSpec formatting" {
    var buf: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    stream.reset();
    try SizeSpec.auto.format(writer);
    try std.testing.expectEqualSlices(u8, "auto", stream.getWritten());

    stream.reset();
    try (SizeSpec{ .cells = 40 }).format(writer);
    try std.testing.expectEqualSlices(u8, "40", stream.getWritten());

    stream.reset();
    try (SizeSpec{ .pixels = 200 }).format(writer);
    try std.testing.expectEqualSlices(u8, "200px", stream.getWritten());

    stream.reset();
    try (SizeSpec{ .percent = 50 }).format(writer);
    try std.testing.expectEqualSlices(u8, "50%", stream.getWritten());
}

test "PNG encoding produces valid header" {
    var iterm = ITerm2Graphics.init(std.testing.allocator);
    defer iterm.deinit();

    var surface = try Surface.init(std.testing.allocator, 2, 2);
    defer surface.deinit();
    surface.clear(Pixel.white);

    try iterm.encodePNG(surface);

    // Check PNG signature
    const png_sig = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    try std.testing.expect(std.mem.startsWith(u8, iterm.png_buffer.items, &png_sig));

    // Check IHDR chunk follows signature
    // After 8-byte signature: 4-byte length, 4-byte type
    try std.testing.expect(iterm.png_buffer.items.len >= 16);
    try std.testing.expectEqualSlices(u8, "IHDR", iterm.png_buffer.items[12..16]);
}

test "moveCursor helper" {
    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try moveCursor(output.writer(), 10, 5);

    // Should produce ANSI cursor position (1-indexed)
    try std.testing.expectEqualSlices(u8, "\x1b[6;11H", output.items);
}
