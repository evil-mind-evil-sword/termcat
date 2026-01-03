//! FramePacer: Frame rate control and frame skipping for smooth animations
//!
//! Provides frame pacing to maintain consistent frame rates and skip frames
//! when the system is under load. Helps prevent input lag and visual judder.
//!
//! ## Usage
//!
//! ```zig
//! var pacer = FramePacer.init(.{ .target_fps = 60 });
//!
//! while (running) {
//!     pacer.beginFrame();
//!
//!     // Process input
//!     handleEvents();
//!
//!     // Only render if we have time budget
//!     if (pacer.shouldRender()) {
//!         render();
//!     }
//!
//!     // Wait for next frame
//!     pacer.endFrame();
//! }
//! ```
//!
//! ## Frame Skipping
//!
//! When frames take longer than the budget, the pacer will recommend skipping
//! render frames while still processing input. This keeps the application
//! responsive even under load.

const std = @import("std");

pub const FramePacer = @This();

/// Configuration options
pub const Options = struct {
    /// Target frames per second (0 = unlimited)
    target_fps: u8 = 60,
    /// Maximum consecutive frames to skip before forcing a render
    max_skip_frames: u8 = 3,
    /// Enable vsync-style frame pacing (sleep to next frame boundary)
    vsync: bool = true,
};

/// Frame timing in nanoseconds
frame_time_ns: u64,
/// Time when current frame started
frame_start: i128,
/// Accumulated time debt from slow frames (nanoseconds)
time_debt: i64,
/// Consecutive frames skipped
frames_skipped: u8,
/// Maximum frames to skip
max_skip: u8,
/// Whether to sleep to frame boundary
vsync: bool,

/// Statistics
total_frames: u64,
total_renders: u64,
total_skips: u64,
/// Rolling average frame time (exponential moving average)
avg_frame_time_ns: u64,

/// Initialize the frame pacer
pub fn init(options: Options) FramePacer {
    const frame_time_ns: u64 = if (options.target_fps > 0)
        @as(u64, 1_000_000_000) / @as(u64, options.target_fps)
    else
        0;

    return .{
        .frame_time_ns = frame_time_ns,
        .frame_start = std.time.nanoTimestamp(),
        .time_debt = 0,
        .frames_skipped = 0,
        .max_skip = options.max_skip_frames,
        .vsync = options.vsync,
        .total_frames = 0,
        .total_renders = 0,
        .total_skips = 0,
        .avg_frame_time_ns = frame_time_ns,
    };
}

/// Call at the start of each frame
pub fn beginFrame(self: *FramePacer) void {
    self.frame_start = std.time.nanoTimestamp();
    self.total_frames += 1;
}

/// Check if we should render this frame
/// Returns false if we're behind and should skip render to catch up
pub fn shouldRender(self: *FramePacer) bool {
    // Always render if unlimited FPS
    if (self.frame_time_ns == 0) return true;

    // Always render if we've skipped too many frames
    if (self.frames_skipped >= self.max_skip) return true;

    // Render if we're not in debt
    if (self.time_debt <= 0) return true;

    // Skip this frame to catch up
    self.frames_skipped += 1;
    self.total_skips += 1;
    return false;
}

/// Call when a render is performed
pub fn didRender(self: *FramePacer) void {
    self.frames_skipped = 0;
    self.total_renders += 1;
}

/// Call at the end of each frame
/// Sleeps if needed to maintain frame rate, updates statistics
pub fn endFrame(self: *FramePacer) void {
    const now = std.time.nanoTimestamp();
    const elapsed: i64 = @intCast(now - self.frame_start);

    // Update rolling average (EMA with alpha = 0.1)
    const alpha: i64 = 10; // 10% weight to new sample
    self.avg_frame_time_ns = @intCast(
        (@as(i128, self.avg_frame_time_ns) * (100 - alpha) + @as(i128, @intCast(elapsed)) * alpha) / 100,
    );

    // Calculate time remaining in frame budget
    if (self.frame_time_ns > 0) {
        const target: i64 = @intCast(self.frame_time_ns);
        const remaining = target - elapsed;

        if (remaining > 0) {
            // We finished early - sleep if vsync enabled
            if (self.vsync) {
                // Reduce debt first
                if (self.time_debt > 0) {
                    const debt_reduction = @min(remaining, self.time_debt);
                    self.time_debt -= debt_reduction;
                    const sleep_time = remaining - debt_reduction;
                    if (sleep_time > 0) {
                        std.time.sleep(@intCast(sleep_time));
                    }
                } else {
                    std.time.sleep(@intCast(remaining));
                }
            }
        } else {
            // We're behind - accumulate debt (capped to prevent death spirals)
            // Cap at 1 second to handle system suspension gracefully
            const MAX_DEBT: i64 = 1_000_000_000; // 1 second in nanoseconds
            self.time_debt = @min(self.time_debt + (-remaining), MAX_DEBT);
        }
    }
}

/// Get the frame budget in milliseconds
pub fn frameBudgetMs(self: *const FramePacer) f32 {
    return @as(f32, @floatFromInt(self.frame_time_ns)) / 1_000_000.0;
}

/// Get the current average frame time in milliseconds
pub fn avgFrameTimeMs(self: *const FramePacer) f32 {
    return @as(f32, @floatFromInt(self.avg_frame_time_ns)) / 1_000_000.0;
}

/// Get the current effective FPS
pub fn currentFps(self: *const FramePacer) f32 {
    if (self.avg_frame_time_ns == 0) return 0;
    return 1_000_000_000.0 / @as(f32, @floatFromInt(self.avg_frame_time_ns));
}

/// Get statistics
pub fn getStats(self: *const FramePacer) Stats {
    return .{
        .total_frames = self.total_frames,
        .total_renders = self.total_renders,
        .total_skips = self.total_skips,
        .skip_rate = if (self.total_frames > 0)
            @as(f32, @floatFromInt(self.total_skips)) / @as(f32, @floatFromInt(self.total_frames))
        else
            0.0,
        .avg_frame_time_ms = self.avgFrameTimeMs(),
        .current_fps = self.currentFps(),
        .time_debt_ms = @as(f32, @floatFromInt(self.time_debt)) / 1_000_000.0,
    };
}

/// Statistics structure
pub const Stats = struct {
    total_frames: u64,
    total_renders: u64,
    total_skips: u64,
    skip_rate: f32,
    avg_frame_time_ms: f32,
    current_fps: f32,
    time_debt_ms: f32,
};

/// Reset statistics (but keep timing state)
pub fn resetStats(self: *FramePacer) void {
    self.total_frames = 0;
    self.total_renders = 0;
    self.total_skips = 0;
}

/// Check if we're currently behind schedule
pub fn isBehind(self: *const FramePacer) bool {
    return self.time_debt > @as(i64, @intCast(self.frame_time_ns));
}

/// Get the timeout for event polling (in milliseconds)
/// Use this with Terminal.pollEvent() to maintain frame pacing
pub fn pollTimeoutMs(self: *const FramePacer) u32 {
    if (self.frame_time_ns == 0) return 0; // Unlimited FPS

    const now = std.time.nanoTimestamp();
    const elapsed: i64 = @intCast(now - self.frame_start);
    const target: i64 = @intCast(self.frame_time_ns);
    const remaining = target - elapsed;

    if (remaining <= 0) return 0;

    // Convert to milliseconds, minimum 1ms
    const ms = @divFloor(remaining, 1_000_000);
    return @intCast(@max(1, @min(ms, 1000)));
}

// ============================================================================
// Tests
// ============================================================================

test "FramePacer init" {
    const pacer = FramePacer.init(.{ .target_fps = 60 });

    // 60 FPS = 16.67ms per frame
    try std.testing.expect(pacer.frame_time_ns > 16_000_000);
    try std.testing.expect(pacer.frame_time_ns < 17_000_000);
    try std.testing.expectEqual(@as(u64, 0), pacer.total_frames);
}

test "FramePacer unlimited fps" {
    const pacer = FramePacer.init(.{ .target_fps = 0 });

    try std.testing.expectEqual(@as(u64, 0), pacer.frame_time_ns);
    try std.testing.expect(pacer.shouldRender());
}

test "FramePacer shouldRender when not behind" {
    var pacer = FramePacer.init(.{ .target_fps = 60 });
    pacer.time_debt = 0;

    try std.testing.expect(pacer.shouldRender());
}

test "FramePacer shouldRender skips when behind" {
    var pacer = FramePacer.init(.{ .target_fps = 60, .max_skip_frames = 2 });
    pacer.time_debt = @intCast(pacer.frame_time_ns * 2); // 2 frames behind

    // Should skip first two frames
    try std.testing.expect(!pacer.shouldRender());
    try std.testing.expectEqual(@as(u8, 1), pacer.frames_skipped);

    try std.testing.expect(!pacer.shouldRender());
    try std.testing.expectEqual(@as(u8, 2), pacer.frames_skipped);

    // Third should render (max_skip reached)
    try std.testing.expect(pacer.shouldRender());
}

test "FramePacer didRender resets skip count" {
    var pacer = FramePacer.init(.{ .target_fps = 60 });
    pacer.frames_skipped = 2;

    pacer.didRender();

    try std.testing.expectEqual(@as(u8, 0), pacer.frames_skipped);
    try std.testing.expectEqual(@as(u64, 1), pacer.total_renders);
}

test "FramePacer statistics" {
    var pacer = FramePacer.init(.{ .target_fps = 60 });

    pacer.beginFrame();
    pacer.total_frames = 100;
    pacer.total_renders = 90;
    pacer.total_skips = 10;

    const stats = pacer.getStats();

    try std.testing.expectEqual(@as(u64, 100), stats.total_frames);
    try std.testing.expectEqual(@as(u64, 90), stats.total_renders);
    try std.testing.expectEqual(@as(u64, 10), stats.total_skips);
    try std.testing.expect(stats.skip_rate > 0.09 and stats.skip_rate < 0.11);
}

test "FramePacer pollTimeoutMs" {
    var pacer = FramePacer.init(.{ .target_fps = 60 });
    pacer.beginFrame();

    // Immediately after beginFrame, should have most of frame budget left
    const timeout = pacer.pollTimeoutMs();

    // Should be around 16ms (could be slightly less due to test overhead)
    try std.testing.expect(timeout >= 10);
    try std.testing.expect(timeout <= 20);
}

test "FramePacer isBehind" {
    var pacer = FramePacer.init(.{ .target_fps = 60 });

    pacer.time_debt = 0;
    try std.testing.expect(!pacer.isBehind());

    pacer.time_debt = @intCast(pacer.frame_time_ns * 2);
    try std.testing.expect(pacer.isBehind());
}

test "FramePacer frameBudgetMs" {
    const pacer = FramePacer.init(.{ .target_fps = 60 });
    const budget = pacer.frameBudgetMs();

    // 60 FPS = ~16.67ms
    try std.testing.expect(budget > 16.0);
    try std.testing.expect(budget < 17.0);
}
