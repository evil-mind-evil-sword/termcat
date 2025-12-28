//! Constraint: Layout constraints for flexible widget sizing
//!
//! Provides a constraint system for Flex containers (Row/Column) to distribute
//! space among children. Each constraint specifies how much of the available
//! space a widget should receive.
//!
//! Constraint types:
//! - Fixed(n): Exact size in cells
//! - Ratio(num, denom): Proportional share of remaining space
//! - Minimum(n): At least n cells, can expand to fill remaining space
//!
//! Example usage in a Flex container:
//! ```
//! // Fixed 10 cells | 1/3 remaining | 2/3 remaining
//! const constraints = [_]Constraint{
//!     Constraint.fromFixed(10),
//!     Constraint.fromRatio(1, 3),
//!     Constraint.fromRatio(2, 3),
//! };
//! ```

const std = @import("std");

/// A layout constraint specifying how much space a child widget should receive
pub const Constraint = union(enum) {
    /// Exact size in cells - widget gets exactly this many cells
    fixed: u16,

    /// Proportional sizing - widget gets (num/denom) of remaining space after fixed allocations
    ratio: struct {
        num: u16,
        denom: u16,
    },

    /// Minimum size - at least n cells, expands to fill remaining space
    /// When multiple Minimum constraints exist, remaining space is split equally
    minimum: u16,

    /// Create a fixed constraint
    pub fn fromFixed(size: u16) Constraint {
        return .{ .fixed = size };
    }

    /// Create a ratio constraint
    pub fn fromRatio(num: u16, denom: u16) Constraint {
        std.debug.assert(denom > 0);
        return .{ .ratio = .{ .num = num, .denom = denom } };
    }

    /// Create a minimum constraint
    pub fn fromMinimum(min_size: u16) Constraint {
        return .{ .minimum = min_size };
    }

    /// Create a constraint that takes half the space
    pub fn half() Constraint {
        return fromRatio(1, 2);
    }

    /// Create a constraint that takes all remaining space (1/1)
    pub fn fill() Constraint {
        return fromRatio(1, 1);
    }
};

/// Resolve an array of constraints to actual sizes given total available space.
///
/// Algorithm:
/// 1. Allocate space for all fixed constraints
/// 2. Ensure minimum constraints get their minimum sizes
/// 3. Distribute remaining space to ratio and minimum constraints
///
/// Returns a list of sizes corresponding to each constraint, or null if
/// constraints cannot be satisfied (fixed + minimums exceed available space).
pub fn resolve(
    constraints: []const Constraint,
    available: u16,
) ?[]u16 {
    return resolveWithAllocator(std.heap.page_allocator, constraints, available);
}

/// Resolve constraints with a specific allocator
pub fn resolveWithAllocator(
    allocator: std.mem.Allocator,
    constraints: []const Constraint,
    available: u16,
) ?[]u16 {
    if (constraints.len == 0) return null;

    const sizes = allocator.alloc(u16, constraints.len) catch return null;
    @memset(sizes, 0);

    // First pass: allocate fixed sizes and minimum bases
    var consumed: u32 = 0;
    var ratio_total: u32 = 0; // Sum of all ratio numerators (normalized to common denominator)
    var min_count: u16 = 0;

    for (constraints, 0..) |c, i| {
        switch (c) {
            .fixed => |size| {
                sizes[i] = size;
                consumed += size;
            },
            .minimum => |min_size| {
                sizes[i] = min_size;
                consumed += min_size;
                min_count += 1;
            },
            .ratio => |r| {
                // Track ratio for second pass
                ratio_total += r.num;
            },
        }
    }

    // Check if we've exceeded available space
    if (consumed > available) {
        allocator.free(sizes);
        return null;
    }

    const remaining: u32 = available - consumed;

    // Second pass: distribute remaining space to ratio and minimum constraints
    if (remaining > 0) {
        // Calculate total "weight" for distribution
        // Ratio constraints use their num value
        // Minimum constraints share equally (treated as weight of 1 each)
        const total_weight: u32 = ratio_total + min_count;

        if (total_weight > 0) {
            var distributed: u32 = 0;

            // Distribute to ratio constraints
            for (constraints, 0..) |c, i| {
                switch (c) {
                    .ratio => |r| {
                        // Each ratio gets (r.num / total_weight) * remaining
                        const share = (remaining * r.num) / total_weight;
                        sizes[i] = @intCast(@min(share, std.math.maxInt(u16)));
                        distributed += share;
                    },
                    else => {},
                }
            }

            // Distribute to minimum constraints (they share equally)
            if (min_count > 0) {
                const remaining_after_ratios = remaining - distributed;
                const per_min = remaining_after_ratios / min_count;
                var min_distributed: u32 = 0;

                for (constraints, 0..) |c, i| {
                    switch (c) {
                        .minimum => {
                            sizes[i] += @intCast(@min(per_min, std.math.maxInt(u16) - sizes[i]));
                            min_distributed += per_min;
                        },
                        else => {},
                    }
                }

                distributed += min_distributed;
            }

            // Handle rounding remainder by giving extra to the last non-fixed constraint
            const leftover = remaining - distributed;
            if (leftover > 0) {
                var last_flex_idx: ?usize = null;
                for (constraints, 0..) |c, i| {
                    switch (c) {
                        .ratio, .minimum => last_flex_idx = i,
                        .fixed => {},
                    }
                }
                if (last_flex_idx) |idx| {
                    sizes[idx] += @intCast(@min(leftover, std.math.maxInt(u16) - sizes[idx]));
                }
            }
        }
    }

    return sizes;
}

/// Free sizes array allocated by resolve
pub fn freeSizes(allocator: std.mem.Allocator, sizes: []u16) void {
    allocator.free(sizes);
}

// ============================================================================
// Tests
// ============================================================================

test "Constraint.fromFixed" {
    const c = Constraint.fromFixed(10);
    try std.testing.expectEqual(@as(u16, 10), c.fixed);
}

test "Constraint.fromRatio" {
    const c = Constraint.fromRatio(1, 3);
    try std.testing.expectEqual(@as(u16, 1), c.ratio.num);
    try std.testing.expectEqual(@as(u16, 3), c.ratio.denom);
}

test "Constraint.fromMinimum" {
    const c = Constraint.fromMinimum(5);
    try std.testing.expectEqual(@as(u16, 5), c.minimum);
}

test "Constraint.half" {
    const c = Constraint.half();
    try std.testing.expectEqual(@as(u16, 1), c.ratio.num);
    try std.testing.expectEqual(@as(u16, 2), c.ratio.denom);
}

test "Constraint.fill" {
    const c = Constraint.fill();
    try std.testing.expectEqual(@as(u16, 1), c.ratio.num);
    try std.testing.expectEqual(@as(u16, 1), c.ratio.denom);
}

test "resolve: single fixed" {
    const constraints = [_]Constraint{.{ .fixed = 10 }};
    const sizes = resolveWithAllocator(std.testing.allocator, &constraints, 100).?;
    defer freeSizes(std.testing.allocator, sizes);

    try std.testing.expectEqual(@as(u16, 10), sizes[0]);
}

test "resolve: multiple fixed" {
    const constraints = [_]Constraint{
        .{ .fixed = 10 },
        .{ .fixed = 20 },
        .{ .fixed = 30 },
    };
    const sizes = resolveWithAllocator(std.testing.allocator, &constraints, 100).?;
    defer freeSizes(std.testing.allocator, sizes);

    try std.testing.expectEqual(@as(u16, 10), sizes[0]);
    try std.testing.expectEqual(@as(u16, 20), sizes[1]);
    try std.testing.expectEqual(@as(u16, 30), sizes[2]);
}

test "resolve: fixed exceeds available" {
    const constraints = [_]Constraint{
        .{ .fixed = 60 },
        .{ .fixed = 50 },
    };
    const result = resolveWithAllocator(std.testing.allocator, &constraints, 100);
    try std.testing.expect(result == null);
}

test "resolve: single ratio fills space" {
    const constraints = [_]Constraint{Constraint.fill()};
    const sizes = resolveWithAllocator(std.testing.allocator, &constraints, 100).?;
    defer freeSizes(std.testing.allocator, sizes);

    try std.testing.expectEqual(@as(u16, 100), sizes[0]);
}

test "resolve: two equal ratios" {
    const constraints = [_]Constraint{
        Constraint.fromRatio(1, 2),
        Constraint.fromRatio(1, 2),
    };
    const sizes = resolveWithAllocator(std.testing.allocator, &constraints, 100).?;
    defer freeSizes(std.testing.allocator, sizes);

    // Each gets 50 (1 / (1+1) * 100)
    try std.testing.expectEqual(@as(u16, 50), sizes[0]);
    try std.testing.expectEqual(@as(u16, 50), sizes[1]);
}

test "resolve: 1:2 ratio split" {
    const constraints = [_]Constraint{
        Constraint.fromRatio(1, 3),
        Constraint.fromRatio(2, 3),
    };
    const sizes = resolveWithAllocator(std.testing.allocator, &constraints, 90).?;
    defer freeSizes(std.testing.allocator, sizes);

    // Total weight = 1 + 2 = 3
    // First: 1/3 * 90 = 30
    // Second: 2/3 * 90 = 60
    try std.testing.expectEqual(@as(u16, 30), sizes[0]);
    try std.testing.expectEqual(@as(u16, 60), sizes[1]);
}

test "resolve: fixed plus ratio" {
    const constraints = [_]Constraint{
        .{ .fixed = 20 },
        Constraint.fill(),
    };
    const sizes = resolveWithAllocator(std.testing.allocator, &constraints, 100).?;
    defer freeSizes(std.testing.allocator, sizes);

    try std.testing.expectEqual(@as(u16, 20), sizes[0]);
    try std.testing.expectEqual(@as(u16, 80), sizes[1]);
}

test "resolve: minimum basic" {
    const constraints = [_]Constraint{
        .{ .minimum = 10 },
    };
    const sizes = resolveWithAllocator(std.testing.allocator, &constraints, 100).?;
    defer freeSizes(std.testing.allocator, sizes);

    // Minimum expands to fill
    try std.testing.expectEqual(@as(u16, 100), sizes[0]);
}

test "resolve: fixed with minimum" {
    const constraints = [_]Constraint{
        .{ .fixed = 30 },
        .{ .minimum = 10 },
    };
    const sizes = resolveWithAllocator(std.testing.allocator, &constraints, 100).?;
    defer freeSizes(std.testing.allocator, sizes);

    try std.testing.expectEqual(@as(u16, 30), sizes[0]);
    // Minimum gets its base (10) plus remaining (70) = 70 extra (weight 1 out of 1)
    try std.testing.expectEqual(@as(u16, 70), sizes[1]);
}

test "resolve: multiple minimums share equally" {
    const constraints = [_]Constraint{
        .{ .minimum = 10 },
        .{ .minimum = 10 },
    };
    const sizes = resolveWithAllocator(std.testing.allocator, &constraints, 100).?;
    defer freeSizes(std.testing.allocator, sizes);

    // Each starts at 10, remaining 80 split equally = 40 each extra
    // Total: 10 + 40 = 50 each
    try std.testing.expectEqual(@as(u16, 50), sizes[0]);
    try std.testing.expectEqual(@as(u16, 50), sizes[1]);
}

test "resolve: empty constraints" {
    const constraints = [_]Constraint{};
    const result = resolveWithAllocator(std.testing.allocator, &constraints, 100);
    try std.testing.expect(result == null);
}

test "resolve: complex mixed example" {
    // Fixed 10 | 1:1 ratio | Minimum 5
    const constraints = [_]Constraint{
        .{ .fixed = 10 },
        Constraint.fromRatio(1, 2),
        .{ .minimum = 5 },
    };
    const sizes = resolveWithAllocator(std.testing.allocator, &constraints, 100).?;
    defer freeSizes(std.testing.allocator, sizes);

    try std.testing.expectEqual(@as(u16, 10), sizes[0]);
    // Remaining: 90 - 5 (min base) = 85 distributable
    // Total weight: 1 (ratio num) + 1 (min count) = 2
    // Ratio gets: 1/2 * 85 = 42
    // Min gets: 5 + (85 - 42) = 5 + 43 = 48
    try std.testing.expectEqual(@as(u16, 45), sizes[1]); // 90 * 1 / 2 = 45
    try std.testing.expectEqual(@as(u16, 45), sizes[2]); // 5 + 40 = 45
}
