//! MeasureCache: Layout measure result caching for performance optimization
//!
//! Caches widget measure() results to avoid redundant layout calculations.
//! Particularly useful for complex widget trees where multiple measure passes occur.
//!
//! ## Usage
//!
//! ```zig
//! var cache = MeasureCache.init(allocator);
//! defer cache.deinit();
//!
//! // Check cache first
//! if (cache.get(widget.ptr, constraint)) |cached_size| {
//!     return cached_size;
//! }
//!
//! // Cache miss - compute and store
//! const size = widget.measure(constraint);
//! cache.put(widget.ptr, constraint, size);
//! return size;
//! ```
//!
//! ## Invalidation
//!
//! Call `invalidate()` when widget content changes, or `invalidateAll()` on resize.

const std = @import("std");
const Widget = @import("Widget.zig");

pub const MeasureCache = @This();

/// Cache entry key
const CacheKey = struct {
    /// Widget pointer (identity)
    widget_ptr: usize,
    /// Full constraint (stored to avoid hash collision bugs)
    constraint: Widget.SizeConstraint,
};

/// Cache entry
const CacheEntry = struct {
    key: CacheKey,
    size: Widget.MeasuredSize,
    /// Frame number when cached (for LRU-style eviction)
    frame: u64,
};

/// Maximum cache entries (power of 2 for efficient modulo)
const MAX_ENTRIES = 256;

/// Cache storage
entries: [MAX_ENTRIES]?CacheEntry,
/// Current frame number (for freshness tracking)
current_frame: u64,
/// Statistics
hits: u64,
misses: u64,

/// Initialize an empty cache
pub fn init() MeasureCache {
    return .{
        .entries = [_]?CacheEntry{null} ** MAX_ENTRIES,
        .current_frame = 0,
        .hits = 0,
        .misses = 0,
    };
}

/// No deinitialization needed (stack-allocated)
pub fn deinit(self: *MeasureCache) void {
    _ = self;
}

/// Advance to next frame (call once per render frame)
pub fn nextFrame(self: *MeasureCache) void {
    self.current_frame += 1;
}

/// Get cached measure result, or null if not cached
pub fn get(
    self: *MeasureCache,
    widget_ptr: *anyopaque,
    constraint: Widget.SizeConstraint,
) ?Widget.MeasuredSize {
    const key = makeKey(widget_ptr, constraint);
    const idx = hashToIndex(key);

    // Check primary slot
    if (self.entries[idx]) |entry| {
        if (keysEqual(entry.key, key)) {
            self.hits += 1;
            return entry.size;
        }
    }

    // Check adjacent slots (linear probing)
    const probe_limit: usize = 4;
    for (1..probe_limit + 1) |offset| {
        const probe_idx = (idx + offset) % MAX_ENTRIES;
        if (self.entries[probe_idx]) |entry| {
            if (keysEqual(entry.key, key)) {
                self.hits += 1;
                return entry.size;
            }
        }
    }

    self.misses += 1;
    return null;
}

/// Store a measure result in the cache
pub fn put(
    self: *MeasureCache,
    widget_ptr: *anyopaque,
    constraint: Widget.SizeConstraint,
    size: Widget.MeasuredSize,
) void {
    const key = makeKey(widget_ptr, constraint);
    const idx = hashToIndex(key);

    const entry = CacheEntry{
        .key = key,
        .size = size,
        .frame = self.current_frame,
    };

    // Try primary slot
    if (self.entries[idx] == null) {
        self.entries[idx] = entry;
        return;
    }

    // Check if we're updating same key
    if (keysEqual(self.entries[idx].?.key, key)) {
        self.entries[idx] = entry;
        return;
    }

    // Linear probing for free slot or LRU eviction
    var oldest_idx = idx;
    var oldest_frame = self.current_frame;

    const probe_limit: usize = 4;
    for (1..probe_limit + 1) |offset| {
        const probe_idx = (idx + offset) % MAX_ENTRIES;

        if (self.entries[probe_idx] == null) {
            self.entries[probe_idx] = entry;
            return;
        }

        if (keysEqual(self.entries[probe_idx].?.key, key)) {
            self.entries[probe_idx] = entry;
            return;
        }

        // Track oldest for LRU eviction
        if (self.entries[probe_idx].?.frame < oldest_frame) {
            oldest_frame = self.entries[probe_idx].?.frame;
            oldest_idx = probe_idx;
        }
    }

    // Evict oldest entry
    self.entries[oldest_idx] = entry;
}

/// Invalidate cache entry for a specific widget
pub fn invalidate(self: *MeasureCache, widget_ptr: *anyopaque) void {
    const ptr_hash = @intFromPtr(widget_ptr);

    for (&self.entries) |*slot| {
        if (slot.*) |entry| {
            if (entry.key.widget_ptr == ptr_hash) {
                slot.* = null;
            }
        }
    }
}

/// Invalidate all cached entries (call on window resize)
pub fn invalidateAll(self: *MeasureCache) void {
    @memset(&self.entries, null);
}

/// Get cache statistics
pub fn getStats(self: *const MeasureCache) struct { hits: u64, misses: u64, hit_rate: f32 } {
    const total = self.hits + self.misses;
    const hit_rate: f32 = if (total > 0)
        @as(f32, @floatFromInt(self.hits)) / @as(f32, @floatFromInt(total))
    else
        0.0;

    return .{
        .hits = self.hits,
        .misses = self.misses,
        .hit_rate = hit_rate,
    };
}

/// Reset statistics
pub fn resetStats(self: *MeasureCache) void {
    self.hits = 0;
    self.misses = 0;
}

// ============================================================================
// Internal helpers
// ============================================================================

fn makeKey(widget_ptr: *anyopaque, constraint: Widget.SizeConstraint) CacheKey {
    return .{
        .widget_ptr = @intFromPtr(widget_ptr),
        .constraint = constraint,
    };
}

fn hashConstraint(c: Widget.SizeConstraint) u64 {
    // Simple hash combining all constraint values (for index calculation only)
    var hash: u64 = 0;
    hash = hash *% 31 +% c.min_width;
    hash = hash *% 31 +% c.max_width;
    hash = hash *% 31 +% c.min_height;
    hash = hash *% 31 +% c.max_height;
    return hash;
}

fn hashToIndex(key: CacheKey) usize {
    // Use constraint hash for bucket selection only (not for equality)
    const constraint_hash = hashConstraint(key.constraint);
    const combined = key.widget_ptr ^ constraint_hash;
    return @intCast(combined % MAX_ENTRIES);
}

fn keysEqual(a: CacheKey, b: CacheKey) bool {
    // Compare widget pointer and full constraint values (no hash collision possible)
    if (a.widget_ptr != b.widget_ptr) return false;
    return a.constraint.min_width == b.constraint.min_width and
        a.constraint.max_width == b.constraint.max_width and
        a.constraint.min_height == b.constraint.min_height and
        a.constraint.max_height == b.constraint.max_height;
}

// ============================================================================
// Tests
// ============================================================================

test "MeasureCache init" {
    var cache = MeasureCache.init();
    defer cache.deinit();

    try std.testing.expectEqual(@as(u64, 0), cache.current_frame);
    try std.testing.expectEqual(@as(u64, 0), cache.hits);
    try std.testing.expectEqual(@as(u64, 0), cache.misses);
}

test "MeasureCache put and get" {
    var cache = MeasureCache.init();

    var dummy: u32 = 42;
    const ptr: *anyopaque = @ptrCast(&dummy);
    const constraint = Widget.SizeConstraint.atMost(100, 50);
    const size = Widget.MeasuredSize{ .width = 80, .height = 40 };

    // Cache miss initially
    try std.testing.expect(cache.get(ptr, constraint) == null);
    try std.testing.expectEqual(@as(u64, 1), cache.misses);

    // Put value
    cache.put(ptr, constraint, size);

    // Cache hit
    const result = cache.get(ptr, constraint);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u16, 80), result.?.width);
    try std.testing.expectEqual(@as(u16, 40), result.?.height);
    try std.testing.expectEqual(@as(u64, 1), cache.hits);
}

test "MeasureCache different constraints" {
    var cache = MeasureCache.init();

    var dummy: u32 = 42;
    const ptr: *anyopaque = @ptrCast(&dummy);

    const c1 = Widget.SizeConstraint.atMost(100, 50);
    const c2 = Widget.SizeConstraint.atMost(200, 100);
    const s1 = Widget.MeasuredSize{ .width = 80, .height = 40 };
    const s2 = Widget.MeasuredSize{ .width = 150, .height = 80 };

    cache.put(ptr, c1, s1);
    cache.put(ptr, c2, s2);

    // Both should be retrievable
    const r1 = cache.get(ptr, c1);
    const r2 = cache.get(ptr, c2);

    try std.testing.expect(r1 != null);
    try std.testing.expect(r2 != null);
    try std.testing.expectEqual(@as(u16, 80), r1.?.width);
    try std.testing.expectEqual(@as(u16, 150), r2.?.width);
}

test "MeasureCache invalidate" {
    var cache = MeasureCache.init();

    var dummy1: u32 = 1;
    var dummy2: u32 = 2;
    const ptr1: *anyopaque = @ptrCast(&dummy1);
    const ptr2: *anyopaque = @ptrCast(&dummy2);
    const constraint = Widget.SizeConstraint.atMost(100, 50);

    cache.put(ptr1, constraint, .{ .width = 10, .height = 10 });
    cache.put(ptr2, constraint, .{ .width = 20, .height = 20 });

    // Invalidate first widget only
    cache.invalidate(ptr1);

    try std.testing.expect(cache.get(ptr1, constraint) == null);
    try std.testing.expect(cache.get(ptr2, constraint) != null);
}

test "MeasureCache invalidateAll" {
    var cache = MeasureCache.init();

    var dummy: u32 = 42;
    const ptr: *anyopaque = @ptrCast(&dummy);
    const constraint = Widget.SizeConstraint.atMost(100, 50);

    cache.put(ptr, constraint, .{ .width = 10, .height = 10 });

    cache.invalidateAll();

    try std.testing.expect(cache.get(ptr, constraint) == null);
}

test "MeasureCache statistics" {
    var cache = MeasureCache.init();

    var dummy: u32 = 42;
    const ptr: *anyopaque = @ptrCast(&dummy);
    const constraint = Widget.SizeConstraint.atMost(100, 50);

    // 1 miss
    _ = cache.get(ptr, constraint);

    cache.put(ptr, constraint, .{ .width = 10, .height = 10 });

    // 2 hits
    _ = cache.get(ptr, constraint);
    _ = cache.get(ptr, constraint);

    const stats = cache.getStats();
    try std.testing.expectEqual(@as(u64, 2), stats.hits);
    try std.testing.expectEqual(@as(u64, 1), stats.misses);
    // 2/3 = 0.666...
    try std.testing.expect(stats.hit_rate > 0.6 and stats.hit_rate < 0.7);
}

test "MeasureCache nextFrame" {
    var cache = MeasureCache.init();

    try std.testing.expectEqual(@as(u64, 0), cache.current_frame);

    cache.nextFrame();
    try std.testing.expectEqual(@as(u64, 1), cache.current_frame);

    cache.nextFrame();
    try std.testing.expectEqual(@as(u64, 2), cache.current_frame);
}
