//! StateStore: Persistent widget state across frames
//!
//! In immediate-mode UI, widgets are ephemeral (recreated each frame).
//! StateStore allows widgets to persist state like:
//! - Scroll position
//! - Text input cursor position
//! - Expanded/collapsed state
//! - Animation progress
//!
//! State is keyed by widget Id, enabling automatic cleanup of unused state.

const std = @import("std");
const Id = @import("Id.zig").Id;

/// Type-erased state entry
const StateEntry = struct {
    ptr: *anyopaque,
    deinit_fn: *const fn (*anyopaque, std.mem.Allocator) void,
    used_this_frame: bool,
};

/// Store for persistent widget state
pub const StateStore = struct {
    states: std.AutoHashMap(u64, StateEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StateStore {
        return .{
            .states = std.AutoHashMap(u64, StateEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StateStore) void {
        // Free all stored states
        var iter = self.states.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit_fn(entry.value_ptr.ptr, self.allocator);
        }
        self.states.deinit();
    }

    /// Get or create state for a widget Id
    ///
    /// If state doesn't exist, creates with default initialization.
    /// Marks state as used for this frame (prevents GC).
    pub fn get(self: *StateStore, comptime T: type, id: Id) !*T {
        if (self.states.getPtr(id.hash)) |entry| {
            entry.used_this_frame = true;
            return @ptrCast(@alignCast(entry.ptr));
        }

        // Create new state with default initialization
        const state = try self.allocator.create(T);
        errdefer self.allocator.destroy(state);
        state.* = T{};

        try self.states.put(id.hash, .{
            .ptr = state,
            .deinit_fn = struct {
                fn deinit(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                    const typed_ptr: *T = @ptrCast(@alignCast(ptr));
                    alloc.destroy(typed_ptr);
                }
            }.deinit,
            .used_this_frame = true,
        });

        return state;
    }

    /// Get state if it exists, without creating
    pub fn getExisting(self: *StateStore, comptime T: type, id: Id) ?*T {
        if (self.states.getPtr(id.hash)) |entry| {
            entry.used_this_frame = true;
            return @ptrCast(@alignCast(entry.ptr));
        }
        return null;
    }

    /// Check if state exists for an Id
    pub fn contains(self: *StateStore, id: Id) bool {
        return self.states.contains(id.hash);
    }

    /// Remove state for an Id
    pub fn remove(self: *StateStore, id: Id) void {
        if (self.states.fetchRemove(id.hash)) |kv| {
            kv.value.deinit_fn(kv.value.ptr, self.allocator);
        }
    }

    /// Call at start of frame to reset usage flags
    pub fn beginFrame(self: *StateStore) void {
        var iter = self.states.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.used_this_frame = false;
        }
    }

    /// Call at end of frame to remove unused state
    pub fn endFrame(self: *StateStore) void {
        var to_remove = std.ArrayList(u64).init(self.allocator);
        defer to_remove.deinit();

        var iter = self.states.iterator();
        while (iter.next()) |entry| {
            if (!entry.value_ptr.used_this_frame) {
                to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.states.fetchRemove(key)) |kv| {
                kv.value.deinit_fn(kv.value.ptr, self.allocator);
            }
        }
    }

    /// Get number of stored states
    pub fn count(self: *StateStore) usize {
        return self.states.count();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "StateStore basic get" {
    const TestState = struct {
        value: u32 = 0,
    };

    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    const id = Id.child(Id.root, "widget1");
    const state = try store.get(TestState, id);

    try std.testing.expectEqual(@as(u32, 0), state.value);

    state.value = 42;

    // Getting again should return same state
    const state2 = try store.get(TestState, id);
    try std.testing.expectEqual(@as(u32, 42), state2.value);
}

test "StateStore different ids" {
    const TestState = struct {
        value: u32 = 0,
    };

    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    const id1 = Id.child(Id.root, "widget1");
    const id2 = Id.child(Id.root, "widget2");

    const state1 = try store.get(TestState, id1);
    const state2 = try store.get(TestState, id2);

    state1.value = 1;
    state2.value = 2;

    try std.testing.expectEqual(@as(u32, 1), (try store.get(TestState, id1)).value);
    try std.testing.expectEqual(@as(u32, 2), (try store.get(TestState, id2)).value);
}

test "StateStore getExisting" {
    const TestState = struct {
        value: u32 = 0,
    };

    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    const id = Id.child(Id.root, "widget");

    // Should return null before creation
    try std.testing.expect(store.getExisting(TestState, id) == null);

    // Create state
    _ = try store.get(TestState, id);

    // Now should return the state
    try std.testing.expect(store.getExisting(TestState, id) != null);
}

test "StateStore frame lifecycle" {
    const TestState = struct {
        value: u32 = 0,
    };

    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    const id1 = Id.child(Id.root, "used");
    const id2 = Id.child(Id.root, "unused");

    // Frame 1: create both states
    store.beginFrame();
    _ = try store.get(TestState, id1);
    _ = try store.get(TestState, id2);
    store.endFrame();

    try std.testing.expectEqual(@as(usize, 2), store.count());

    // Frame 2: only use id1
    store.beginFrame();
    _ = try store.get(TestState, id1);
    // Don't access id2
    store.endFrame();

    // id2 should be pruned
    try std.testing.expectEqual(@as(usize, 1), store.count());
    try std.testing.expect(store.contains(id1));
    try std.testing.expect(!store.contains(id2));
}

test "StateStore remove" {
    const TestState = struct {
        value: u32 = 0,
    };

    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    const id = Id.child(Id.root, "widget");
    _ = try store.get(TestState, id);

    try std.testing.expect(store.contains(id));

    store.remove(id);

    try std.testing.expect(!store.contains(id));
}
