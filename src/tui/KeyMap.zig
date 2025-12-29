//! KeyMap: Declarative keybinding system
//!
//! Maps keys to named commands with modifier support:
//! - Scoped keymaps (app-level, widget-level)
//! - Conflict detection
//! - Help text generation

const std = @import("std");
const Event = @import("../Event.zig");
const Key = Event.Key;

/// Command types that can be bound to keys
pub const Command = union(enum) {
    // Application commands
    quit,
    save,
    undo,
    redo,
    // Focus navigation
    focus_next,
    focus_prev,
    // Custom user-defined command
    custom: u32,
};

/// A single key binding
pub const Binding = struct {
    key: Key,
    command: Command,
    /// Human-readable description for help text
    description: []const u8 = "",
};

/// Keymap that maps keys to commands
pub const KeyMap = struct {
    bindings: []const Binding,

    /// Create a keymap from a slice of bindings
    pub fn init(bindings: []const Binding) KeyMap {
        return .{ .bindings = bindings };
    }

    /// Look up a command for a key event
    pub fn lookup(self: KeyMap, key: Key) ?Command {
        for (self.bindings) |binding| {
            if (keysMatch(binding.key, key)) {
                return binding.command;
            }
        }
        return null;
    }

    /// Check for conflicting bindings (same key maps to different commands)
    pub fn hasConflicts(self: KeyMap) bool {
        for (self.bindings, 0..) |b1, i| {
            for (self.bindings[i + 1 ..]) |b2| {
                if (keysMatch(b1.key, b2.key)) {
                    return true;
                }
            }
        }
        return false;
    }

    /// Get all bindings as help text
    pub fn generateHelp(self: KeyMap, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        const writer = result.writer();
        try writer.writeAll("Key Bindings:\n");
        try writer.writeAll("─────────────\n");

        for (self.bindings) |binding| {
            try writer.writeAll("  ");
            try writeKeyDescription(writer, binding.key);
            try writer.writeAll(" → ");
            try writeCommandName(writer, binding.command);
            if (binding.description.len > 0) {
                try writer.writeAll(" (");
                try writer.writeAll(binding.description);
                try writer.writeAll(")");
            }
            try writer.writeAll("\n");
        }

        return result.toOwnedSlice();
    }
};

/// Check if two keys match (including modifiers)
fn keysMatch(a: Key, b: Key) bool {
    // Compare modifiers
    if (a.mods.ctrl != b.mods.ctrl) return false;
    if (a.mods.alt != b.mods.alt) return false;
    if (a.mods.shift != b.mods.shift) return false;

    // Compare key values
    if (a.special) |a_special| {
        if (b.special) |b_special| {
            return a_special == b_special;
        }
        return false;
    }

    if (b.special != null) return false;

    return a.codepoint == b.codepoint;
}

/// Write a human-readable key description
fn writeKeyDescription(writer: anytype, k: Key) !void {
    if (k.mods.ctrl) try writer.writeAll("Ctrl+");
    if (k.mods.alt) try writer.writeAll("Alt+");
    if (k.mods.shift) try writer.writeAll("Shift+");

    if (k.special) |s| {
        try writer.writeAll(@tagName(s));
    } else if (k.codepoint) |cp| {
        if (cp >= 0x20 and cp < 0x7F) {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch 0;
            try writer.writeAll(buf[0..len]);
        } else {
            try writer.print("U+{X:0>4}", .{cp});
        }
    } else {
        try writer.writeAll("(none)");
    }
}

/// Write a human-readable command name
fn writeCommandName(writer: anytype, command: Command) !void {
    switch (command) {
        .quit => try writer.writeAll("Quit"),
        .save => try writer.writeAll("Save"),
        .undo => try writer.writeAll("Undo"),
        .redo => try writer.writeAll("Redo"),
        .focus_next => try writer.writeAll("Focus Next"),
        .focus_prev => try writer.writeAll("Focus Previous"),
        .custom => |id| try writer.print("Custom({d})", .{id}),
    }
}

// ============================================================================
// Convenience constructors for common key bindings
// ============================================================================

/// Create a key with just a character (no modifiers)
pub fn char(c: u21) Key {
    return Key.fromCodepoint(c, .{});
}

/// Create a key with Ctrl modifier
pub fn ctrl(c: u21) Key {
    return Key.fromCodepoint(c, .{ .ctrl = true });
}

/// Create a key with Alt modifier
pub fn alt(c: u21) Key {
    return Key.fromCodepoint(c, .{ .alt = true });
}

/// Create a special key (no modifiers)
pub fn special(s: Key.Special) Key {
    return Key.fromSpecial(s, .{});
}

/// Create a special key with shift
pub fn shift(s: Key.Special) Key {
    return Key.fromSpecial(s, .{ .shift = true });
}

// ============================================================================
// Default keymaps
// ============================================================================

/// Standard application keymap
pub const default_app_keymap = KeyMap.init(&.{
    .{ .key = special(.escape), .command = .quit, .description = "Exit application" },
    .{ .key = ctrl('q'), .command = .quit, .description = "Exit application" },
    .{ .key = ctrl('s'), .command = .save, .description = "Save" },
    .{ .key = ctrl('z'), .command = .undo, .description = "Undo" },
    .{ .key = ctrl('y'), .command = .redo, .description = "Redo" },
    .{ .key = special(.tab), .command = .focus_next, .description = "Next widget" },
    .{ .key = shift(.tab), .command = .focus_prev, .description = "Previous widget" },
});

// ============================================================================
// Tests
// ============================================================================

test "KeyMap lookup" {
    const keymap = KeyMap.init(&.{
        .{ .key = ctrl('q'), .command = .quit },
        .{ .key = ctrl('s'), .command = .save },
    });

    const result = keymap.lookup(ctrl('q'));
    try std.testing.expect(result != null);
    try std.testing.expectEqual(Command.quit, result.?);

    const result2 = keymap.lookup(ctrl('s'));
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(Command.save, result2.?);

    // Not found
    try std.testing.expect(keymap.lookup(ctrl('x')) == null);
}

test "KeyMap no conflicts" {
    const keymap = KeyMap.init(&.{
        .{ .key = ctrl('q'), .command = .quit },
        .{ .key = ctrl('s'), .command = .save },
    });
    try std.testing.expect(!keymap.hasConflicts());
}

test "KeyMap detects conflicts" {
    const keymap = KeyMap.init(&.{
        .{ .key = ctrl('q'), .command = .quit },
        .{ .key = ctrl('q'), .command = .save }, // Conflict!
    });
    try std.testing.expect(keymap.hasConflicts());
}

test "KeyMap generateHelp" {
    const keymap = KeyMap.init(&.{
        .{ .key = ctrl('q'), .command = .quit, .description = "Exit" },
    });

    const help = try keymap.generateHelp(std.testing.allocator);
    defer std.testing.allocator.free(help);

    try std.testing.expect(std.mem.indexOf(u8, help, "Ctrl+q") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Quit") != null);
}

test "keysMatch" {
    try std.testing.expect(keysMatch(ctrl('q'), ctrl('q')));
    try std.testing.expect(!keysMatch(ctrl('q'), ctrl('s')));
    try std.testing.expect(!keysMatch(ctrl('q'), char('q'))); // Different modifiers
}
