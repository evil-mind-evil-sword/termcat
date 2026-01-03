//! KeyStateTracker: Key state smoothing for game-like input
//!
//! Terminals only deliver key press events (with OS-dependent repeat rates),
//! not key down/up events. This makes movement in games jittery since there's
//! no way to know if a key is "held".
//!
//! This helper tracks when keys were last pressed and considers a key "held"
//! if a press was received within a configurable timeout window.
//!
//! ## Usage
//!
//! ```zig
//! var tracker = KeyStateTracker.init(.{ .release_timeout_ms = 100 });
//!
//! while (running) {
//!     // Feed events to tracker
//!     if (try terminal.pollEvent(16)) |event| {
//!         if (event == .key) {
//!             tracker.recordKeyPress(event.key);
//!         }
//!     }
//!
//!     // Query held state for movement
//!     if (tracker.isHeld(.{ .codepoint = 'w', .special = null, .mods = .{} })) {
//!         player.moveForward();
//!     }
//!     if (tracker.isSpecialHeld(.up)) {
//!         player.moveForward();
//!     }
//!
//!     // Clean up expired keys periodically
//!     tracker.tick();
//! }
//! ```
//!
//! ## Reference
//!
//! Inspired by doom-ascii's key smoothing window:
//! https://github.com/wojciech-graj/doom-ascii

const std = @import("std");
const Event = @import("../Event.zig");
const Key = Event.Key;
const Modifiers = Event.Modifiers;

pub const KeyStateTracker = @This();

/// Configuration options
pub const Options = struct {
    /// Time in milliseconds after which a key is considered released
    /// if no repeat event is received. Typical terminal repeat rates
    /// are 30-50ms, so 80-120ms is a reasonable default.
    release_timeout_ms: u32 = 100,
};

/// Key identifier for tracking (combines codepoint and special key)
/// Special keys are encoded with offset +1 to avoid collision with codepoint 0.
pub const KeyId = packed struct(u32) {
    /// Codepoint if regular key (bits 0-20), 0 if special key
    codepoint: u21,
    /// Special key code + 1 (bits 21-25), 0 if regular key
    /// Offset by 1 to distinguish special=escape (enum 0) from codepoint=0
    special: u5,
    /// Modifier state (bits 26-28)
    mods_ctrl: bool,
    mods_alt: bool,
    mods_shift: bool,
    /// Padding to fill 32 bits
    _padding: u3 = 0,

    pub fn fromKey(key: Key) KeyId {
        return .{
            .codepoint = key.codepoint orelse 0,
            // Encode special keys with +1 offset to avoid collision with codepoint 0
            .special = if (key.special) |s| @intFromEnum(s) + 1 else 0,
            .mods_ctrl = key.mods.ctrl,
            .mods_alt = key.mods.alt,
            .mods_shift = key.mods.shift,
        };
    }

    /// Create KeyId from codepoint (convenience)
    pub fn fromCodepoint(cp: u21) KeyId {
        return .{
            .codepoint = cp,
            .special = 0,
            .mods_ctrl = false,
            .mods_alt = false,
            .mods_shift = false,
        };
    }

    /// Create KeyId from special key (convenience)
    pub fn fromSpecial(sp: Key.Special) KeyId {
        return .{
            .codepoint = 0,
            .special = @intFromEnum(sp) + 1, // +1 offset
            .mods_ctrl = false,
            .mods_alt = false,
            .mods_shift = false,
        };
    }

    pub fn eql(self: KeyId, other: KeyId) bool {
        return @as(u32, @bitCast(self)) == @as(u32, @bitCast(other));
    }
};

/// Maximum number of keys to track simultaneously
const MAX_TRACKED_KEYS = 16;

/// Tracked key entry
const TrackedKey = struct {
    id: KeyId,
    /// Monotonic timestamp when key was last pressed
    last_press: std.time.Instant,
};

/// Currently tracked keys
tracked: [MAX_TRACKED_KEYS]?TrackedKey,
/// Release timeout in nanoseconds
release_timeout_ns: u64,

/// Initialize the tracker
pub fn init(options: Options) KeyStateTracker {
    return .{
        .tracked = [_]?TrackedKey{null} ** MAX_TRACKED_KEYS,
        .release_timeout_ns = @as(u64, options.release_timeout_ms) * 1_000_000,
    };
}

/// Record a key press event
pub fn recordKeyPress(self: *KeyStateTracker, key: Key) void {
    const id = KeyId.fromKey(key);
    const now = std.time.Instant.now() catch return; // Ignore if unavailable

    // Check if key is already tracked
    for (&self.tracked) |*slot| {
        if (slot.*) |*entry| {
            if (entry.id.eql(id)) {
                entry.last_press = now;
                return;
            }
        }
    }

    // Find empty slot
    for (&self.tracked) |*slot| {
        if (slot.* == null) {
            slot.* = .{ .id = id, .last_press = now };
            return;
        }
    }

    // All slots full - evict oldest (largest elapsed time)
    var oldest_idx: usize = 0;
    var oldest_elapsed: u64 = 0;
    for (self.tracked, 0..) |entry, i| {
        if (entry) |e| {
            const elapsed = now.since(e.last_press);
            if (elapsed > oldest_elapsed) {
                oldest_elapsed = elapsed;
                oldest_idx = i;
            }
        }
    }
    self.tracked[oldest_idx] = .{ .id = id, .last_press = now };
}

/// Check if a key is currently held (pressed within timeout window)
pub fn isHeld(self: *const KeyStateTracker, key: Key) bool {
    return self.isKeyIdHeld(KeyId.fromKey(key));
}

/// Check if a codepoint key is held (ignoring modifiers)
pub fn isCodepointHeld(self: *const KeyStateTracker, cp: u21) bool {
    const now = std.time.Instant.now() catch return false;

    for (self.tracked) |entry| {
        if (entry) |e| {
            // Match codepoint only, ignore modifiers
            if (e.id.codepoint == cp and e.id.special == 0) {
                if (now.since(e.last_press) < self.release_timeout_ns) {
                    return true;
                }
            }
        }
    }
    return false;
}

/// Check if a special key is held (ignoring modifiers)
pub fn isSpecialHeld(self: *const KeyStateTracker, sp: Key.Special) bool {
    const now = std.time.Instant.now() catch return false;
    // +1 offset to match encoding in KeyId
    const sp_val: u5 = @intFromEnum(sp) + 1;

    for (self.tracked) |entry| {
        if (entry) |e| {
            // Match special key only, ignore modifiers
            if (e.id.special == sp_val and e.id.codepoint == 0) {
                if (now.since(e.last_press) < self.release_timeout_ns) {
                    return true;
                }
            }
        }
    }
    return false;
}

/// Check if a KeyId is held
fn isKeyIdHeld(self: *const KeyStateTracker, id: KeyId) bool {
    const now = std.time.Instant.now() catch return false;

    for (self.tracked) |entry| {
        if (entry) |e| {
            if (e.id.eql(id)) {
                return now.since(e.last_press) < self.release_timeout_ns;
            }
        }
    }
    return false;
}

/// Clean up expired entries (call periodically)
pub fn tick(self: *KeyStateTracker) void {
    const now = std.time.Instant.now() catch return;

    for (&self.tracked) |*slot| {
        if (slot.*) |entry| {
            if (now.since(entry.last_press) >= self.release_timeout_ns) {
                slot.* = null;
            }
        }
    }
}

/// Clear all tracked keys
pub fn clear(self: *KeyStateTracker) void {
    @memset(&self.tracked, null);
}

/// Get the number of currently held keys
pub fn heldCount(self: *const KeyStateTracker) usize {
    const now = std.time.Instant.now() catch return 0;
    var count: usize = 0;

    for (self.tracked) |entry| {
        if (entry) |e| {
            if (now.since(e.last_press) < self.release_timeout_ns) {
                count += 1;
            }
        }
    }
    return count;
}

// ============================================================================
// Tests
// ============================================================================

test "KeyStateTracker init" {
    const tracker = KeyStateTracker.init(.{ .release_timeout_ms = 100 });
    try std.testing.expectEqual(@as(usize, 0), tracker.heldCount());
}

test "KeyStateTracker recordKeyPress and isHeld" {
    var tracker = KeyStateTracker.init(.{ .release_timeout_ms = 100 });

    const key_w = Key.fromCodepoint('w', .{});
    tracker.recordKeyPress(key_w);

    // Key should be held immediately after press
    try std.testing.expect(tracker.isHeld(key_w));
    try std.testing.expect(tracker.isCodepointHeld('w'));
    try std.testing.expect(!tracker.isCodepointHeld('s'));
}

test "KeyStateTracker special keys" {
    var tracker = KeyStateTracker.init(.{ .release_timeout_ms = 100 });

    const key_up = Key.fromSpecial(.up, .{});
    tracker.recordKeyPress(key_up);

    try std.testing.expect(tracker.isSpecialHeld(.up));
    try std.testing.expect(!tracker.isSpecialHeld(.down));
}

test "KeyStateTracker modifiers" {
    var tracker = KeyStateTracker.init(.{ .release_timeout_ms = 100 });

    const key_ctrl_w = Key.fromCodepoint('w', .{ .ctrl = true });
    const key_w = Key.fromCodepoint('w', .{});

    tracker.recordKeyPress(key_ctrl_w);

    // Should differentiate between modified and unmodified
    try std.testing.expect(tracker.isHeld(key_ctrl_w));
    try std.testing.expect(!tracker.isHeld(key_w));

    // But isCodepointHeld ignores modifiers
    try std.testing.expect(tracker.isCodepointHeld('w'));
}

test "KeyStateTracker clear" {
    var tracker = KeyStateTracker.init(.{ .release_timeout_ms = 100 });

    tracker.recordKeyPress(Key.fromCodepoint('w', .{}));
    tracker.recordKeyPress(Key.fromCodepoint('a', .{}));

    try std.testing.expect(tracker.heldCount() > 0);

    tracker.clear();

    try std.testing.expectEqual(@as(usize, 0), tracker.heldCount());
}

test "KeyId packing" {
    // Ensure KeyId fits in 32 bits
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(KeyId));

    const id1 = KeyId.fromCodepoint('a');
    const id2 = KeyId.fromCodepoint('a');
    const id3 = KeyId.fromCodepoint('b');

    try std.testing.expect(id1.eql(id2));
    try std.testing.expect(!id1.eql(id3));
}
