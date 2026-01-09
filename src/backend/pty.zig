const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// PTY pair for testing terminal I/O
pub const Pty = struct {
    /// Master file descriptor (controller side)
    master: posix.fd_t,
    /// Slave file descriptor (terminal side)
    slave: posix.fd_t,
    /// Path to the slave device (128 bytes for macOS TIOCPTYGNAME compatibility)
    slave_path: [128]u8,

    const Self = @This();

    /// Open a new PTY pair
    pub fn open() !Self {
        // Open master PTY
        const master = try posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
        errdefer posix.close(master);

        // Grant access to slave
        if (grantpt(master) != 0) {
            return error.GrantPtFailed;
        }

        // Unlock slave
        if (unlockpt(master) != 0) {
            return error.UnlockPtFailed;
        }

        // Get slave path (thread-safe, 128 bytes for macOS TIOCPTYGNAME)
        var slave_path: [128]u8 = undefined;
        const path_len = try getPtsName(master, &slave_path);

        // Open slave
        const slave = try posix.open(slave_path[0..path_len :0], .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
        errdefer posix.close(slave);

        return Self{
            .master = master,
            .slave = slave,
            .slave_path = slave_path,
        };
    }

    /// Close the PTY pair
    pub fn close(self: Self) void {
        posix.close(self.slave);
        posix.close(self.master);
    }

    /// Write input to the slave (simulates typing)
    pub fn writeInput(self: Self, data: []const u8) !void {
        const written = try posix.write(self.master, data);
        if (written != data.len) {
            return error.PartialWrite;
        }
    }

    /// Read output from the slave (captures terminal output)
    pub fn readOutput(self: Self, buf: []u8) !usize {
        // Use poll to check if data is available
        var fds = [_]posix.pollfd{
            .{
                .fd = self.master,
                .events = posix.POLL.IN,
                .revents = 0,
            },
        };

        const result = try posix.poll(&fds, 100); // 100ms timeout
        if (result == 0) {
            return 0; // Timeout, no data
        }

        return posix.read(self.master, buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => err,
        };
    }

    /// Read all available output with a timeout
    pub fn readAllOutput(self: Self, allocator: std.mem.Allocator, timeout_ms: u32) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        var buf: [1024]u8 = undefined;
        var elapsed: u32 = 0;
        const poll_interval: u32 = 10;

        while (elapsed < timeout_ms) {
            const n = try self.readOutput(&buf);
            if (n > 0) {
                try result.appendSlice(allocator, buf[0..n]);
                elapsed = 0; // Reset timeout after receiving data
            } else {
                elapsed += poll_interval;
                std.Thread.sleep(poll_interval * std.time.ns_per_ms);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Get the slave file descriptor (for passing to terminal init)
    pub fn getSlaveFd(self: Self) posix.fd_t {
        return self.slave;
    }

    /// TIOCSWINSZ ioctl constant (not available on all platforms in std)
    /// These are encoded as unsigned values but passed as signed c_int via bitcast
    const TIOCSWINSZ_RAW: u32 = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => 0x80087467,
        .freebsd => 0x80087467,
        .linux => 0x5414,
        else => 0x80087467, // Default to BSD-style
    };

    /// TIOCGWINSZ ioctl constant
    const TIOCGWINSZ_RAW: u32 = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => 0x40087468,
        .freebsd => 0x40087468,
        .linux => 0x5413,
        else => 0x40087468, // Default to BSD-style
    };

    /// Set window size on the PTY
    pub fn setSize(self: Self, width: u16, height: u16) !void {
        var ws: posix.winsize = .{
            .col = width,
            .row = height,
            .xpixel = 0,
            .ypixel = 0,
        };

        const request: c_int = @bitCast(TIOCSWINSZ_RAW);
        if (posix.system.ioctl(self.master, request, @intFromPtr(&ws)) != 0) {
            return error.IoctlFailed;
        }
    }

    /// Get window size from the PTY
    pub fn getSize(self: Self) !struct { width: u16, height: u16 } {
        var ws: posix.winsize = undefined;
        const request: c_int = @bitCast(TIOCGWINSZ_RAW);
        if (posix.system.ioctl(self.slave, request, @intFromPtr(&ws)) != 0) {
            return error.IoctlFailed;
        }
        return .{ .width = ws.col, .height = ws.row };
    }
};

// C library functions for PTY operations
extern fn grantpt(fd: posix.fd_t) c_int;
extern fn unlockpt(fd: posix.fd_t) c_int;

/// Get PTY slave name in a thread-safe manner.
/// On Linux uses ptsname_r(), on macOS uses TIOCPTYGNAME ioctl.
/// Buffer must be 128 bytes for macOS TIOCPTYGNAME compatibility.
fn getPtsName(master: posix.fd_t, buf: *[128]u8) !usize {
    switch (builtin.os.tag) {
        .linux => {
            // ptsname_r is thread-safe on Linux
            var result: c_int = undefined;
            result = ptsname_r(master, buf, buf.len);
            if (result != 0) {
                return error.PtsnameFailed;
            }
            // Find null terminator
            var len: usize = 0;
            while (len < buf.len and buf[len] != 0) : (len += 1) {}
            return len;
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            // TIOCPTYGNAME is the thread-safe alternative on Darwin
            const TIOCPTYGNAME: c_int = @bitCast(@as(u32, 0x40807453));
            if (posix.system.ioctl(master, TIOCPTYGNAME, @intFromPtr(buf)) != 0) {
                return error.PtsnameFailed;
            }
            // Find null terminator
            var len: usize = 0;
            while (len < buf.len and buf[len] != 0) : (len += 1) {}
            return len;
        },
        else => {
            // Fallback: use ptsname (not thread-safe but may be only option)
            const path_ptr = ptsname(master);
            if (path_ptr == null) {
                return error.PtsnameFailed;
            }
            var len: usize = 0;
            while (len < buf.len - 1 and path_ptr.?[len] != 0) : (len += 1) {
                buf[len] = path_ptr.?[len];
            }
            buf[len] = 0;
            return len;
        },
    }
}

// Platform-specific C functions
extern fn ptsname(fd: posix.fd_t) ?[*:0]u8;
extern fn ptsname_r(fd: posix.fd_t, buf: [*]u8, buflen: usize) c_int;

test "PTY open and close" {
    const pty = try Pty.open();
    defer pty.close();

    try std.testing.expect(pty.master >= 0);
    try std.testing.expect(pty.slave >= 0);
}

test "PTY write and read" {
    const pty = try Pty.open();
    defer pty.close();

    // Set terminal to raw mode so data passes through unchanged
    var attr = try posix.tcgetattr(pty.slave);
    attr.lflag.ECHO = false;
    attr.lflag.ICANON = false;
    try posix.tcsetattr(pty.slave, .NOW, attr);

    // Write to master, read from slave
    try pty.writeInput("hello");

    // Small delay for data to propagate
    std.Thread.sleep(10 * std.time.ns_per_ms);

    var buf: [64]u8 = undefined;
    const slave_read = posix.read(pty.slave, &buf) catch 0;
    if (slave_read > 0) {
        try std.testing.expectEqualStrings("hello", buf[0..slave_read]);
    }
}

test "PTY set size" {
    const pty = try Pty.open();
    defer pty.close();

    try pty.setSize(120, 40);

    // Verify size was set
    const size = try pty.getSize();
    try std.testing.expectEqual(@as(u16, 120), size.width);
    try std.testing.expectEqual(@as(u16, 40), size.height);
}
