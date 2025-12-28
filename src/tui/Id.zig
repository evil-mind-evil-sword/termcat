//! Widget Id: Stable identity for widgets across frames
//!
//! In immediate-mode UI, widgets are recreated each frame. To persist state
//! (focus, scroll position, animation), we need stable identifiers.
//!
//! The Id system uses a hash-based approach inspired by Dear ImGui's ID stack.
//! Each widget gets an Id computed from its position in the widget tree.

const std = @import("std");

/// A stable identifier for a widget
pub const Id = struct {
    hash: u64,

    /// The root/null Id
    pub const root = Id{ .hash = 0 };

    /// Create a child Id by combining parent hash with a local identifier
    pub fn child(parent: Id, local: anytype) Id {
        const local_hash = hashValue(local);
        return .{ .hash = hashCombine(parent.hash, local_hash) };
    }

    /// Check if two Ids are equal
    pub fn eql(self: Id, other: Id) bool {
        return self.hash == other.hash;
    }

    /// Format for debugging
    pub fn format(
        self: Id,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("Id(0x{x:0>16})", .{self.hash});
    }
};

/// Stack for building hierarchical widget Ids
pub const IdStack = struct {
    stack: std.BoundedArray(u64, 64) = .{},
    current: Id = Id.root,

    /// Push a local identifier onto the stack
    /// Returns error.Overflow if the stack is full (max 64 levels deep)
    pub fn push(self: *IdStack, local: anytype) error{Overflow}!void {
        try self.stack.append(self.current.hash);
        self.current = Id.child(self.current, local);
    }

    /// Pop the last identifier from the stack
    pub fn pop(self: *IdStack) void {
        if (self.stack.pop()) |parent_hash| {
            self.current = .{ .hash = parent_hash };
        }
    }

    /// Get the current Id
    pub fn getId(self: IdStack) Id {
        return self.current;
    }

    /// Push, execute a function, then pop (for defer-style usage)
    pub fn withId(self: *IdStack, local: anytype, func: anytype) error{Overflow}!void {
        try self.push(local);
        defer self.pop();
        func();
    }
};

// ============================================================================
// Hash utilities
// ============================================================================

/// Hash any value to u64
fn hashValue(value: anytype) u64 {
    const T = @TypeOf(value);

    if (T == u64) {
        return value;
    } else if (T == usize or T == u32 or T == u16 or T == u8) {
        return @as(u64, value);
    } else if (T == i64 or T == isize or T == i32 or T == i16 or T == i8) {
        return @bitCast(@as(i64, value));
    } else if (T == []const u8) {
        return hashString(value);
    } else if (@typeInfo(T) == .pointer) {
        if (@typeInfo(T).pointer.size == .slice) {
            if (@typeInfo(T).pointer.child == u8) {
                return hashString(value);
            }
        }
        // Hash pointer address
        return @intFromPtr(value);
    } else if (@typeInfo(T) == .@"enum") {
        return @intFromEnum(value);
    } else {
        // For other types, use the bytes
        const bytes = std.mem.asBytes(&value);
        return hashString(bytes);
    }
}

/// FNV-1a hash for strings
fn hashString(str: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325; // FNV offset basis
    for (str) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3; // FNV prime
    }
    return hash;
}

/// Combine two hashes (based on boost::hash_combine)
fn hashCombine(seed: u64, value: u64) u64 {
    return seed ^ (value +% 0x9e3779b97f4a7c15 +% (seed << 6) +% (seed >> 2));
}

// ============================================================================
// Tests
// ============================================================================

test "Id root" {
    try std.testing.expectEqual(@as(u64, 0), Id.root.hash);
}

test "Id child" {
    const parent = Id.root;
    const child1 = Id.child(parent, "button");
    const child2 = Id.child(parent, "label");

    // Children should have different hashes
    try std.testing.expect(!child1.eql(child2));

    // Same input should give same hash
    const child1_again = Id.child(parent, "button");
    try std.testing.expect(child1.eql(child1_again));
}

test "Id child with index" {
    const parent = Id.root;
    const child0 = Id.child(parent, @as(usize, 0));
    const child1 = Id.child(parent, @as(usize, 1));

    try std.testing.expect(!child0.eql(child1));
}

test "Id nested" {
    const root = Id.root;
    const list = Id.child(root, "list");
    const item0 = Id.child(list, @as(usize, 0));
    const item1 = Id.child(list, @as(usize, 1));

    try std.testing.expect(!item0.eql(item1));
}

test "IdStack basic" {
    var stack = IdStack{};

    try std.testing.expect(stack.getId().eql(Id.root));

    try stack.push("panel");
    const panel_id = stack.getId();
    try std.testing.expect(!panel_id.eql(Id.root));

    try stack.push("button");
    const button_id = stack.getId();
    try std.testing.expect(!button_id.eql(panel_id));

    stack.pop();
    try std.testing.expect(stack.getId().eql(panel_id));

    stack.pop();
    try std.testing.expect(stack.getId().eql(Id.root));
}

test "IdStack consistency" {
    var stack1 = IdStack{};
    var stack2 = IdStack{};

    // Same sequence should produce same ids
    try stack1.push("list");
    try stack1.push(@as(usize, 5));

    try stack2.push("list");
    try stack2.push(@as(usize, 5));

    try std.testing.expect(stack1.getId().eql(stack2.getId()));
}

test "hashValue various types" {
    // Integers
    _ = hashValue(@as(u64, 42));
    _ = hashValue(@as(i32, -5));
    _ = hashValue(@as(usize, 100));

    // Strings
    _ = hashValue("hello");
    _ = hashValue(@as([]const u8, "world"));

    // Enums
    const TestEnum = enum { a, b, c };
    _ = hashValue(TestEnum.b);
}
