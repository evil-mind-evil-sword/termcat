//! Tree: Hierarchical data display widget
//!
//! A widget for displaying tree-structured data with expand/collapse
//! functionality, similar to a file browser or nested menu.

const std = @import("std");
const Widget = @import("Widget.zig");
const PlaneView = @import("PlaneView.zig").PlaneView;
const Style = @import("Theme.zig").Style;
const Cell = @import("../Cell.zig");
const Event = @import("../Event.zig");

/// A node in the tree
pub const TreeNode = struct {
    /// Display label
    label: []const u8,
    /// Optional icon character
    icon: ?u21 = null,
    /// Child nodes (null for leaves)
    children: ?[]const TreeNode = null,
    /// Whether expanded (only matters if has children)
    expanded: bool = true,
    /// User data (for callbacks)
    data: ?*anyopaque = null,

    /// Check if this is a leaf node
    pub fn isLeaf(self: TreeNode) bool {
        return self.children == null or self.children.?.len == 0;
    }

    /// Get child count
    pub fn childCount(self: TreeNode) usize {
        if (self.children) |c| return c.len;
        return 0;
    }
};

/// Flat representation of a visible tree row
const FlatRow = struct {
    node_path: [16]usize, // Path of indices to reach this node
    depth: u8,
    is_last_at_depth: [16]bool, // Whether this is the last child at each depth
};

/// Tree widget
pub const Tree = struct {
    /// Root nodes
    roots: []const TreeNode,
    /// Currently selected row index (in flattened visible list)
    selected_index: usize = 0,
    /// Scroll offset
    scroll_offset: usize = 0,
    /// Visible height
    visible_height: u16 = 10,
    /// Show guide lines
    show_guides: bool = true,
    /// Guide line style
    guide_chars: GuideChars = .unicode,
    /// Text style
    text_style: Style = .{},
    /// Selected style
    selected_style: Style = .{ .attrs = .{ .reverse = true } },
    /// Expanded icon
    expanded_icon: u21 = '▾',
    /// Collapsed icon
    collapsed_icon: u21 = '▸',
    /// Leaf icon (when no children)
    leaf_icon: u21 = '•',
    /// Widget state
    widget_state: Widget.WidgetState = .{},
    /// Allocator for mutable tree operations
    allocator: ?std.mem.Allocator = null,
    /// Callback context
    callback_ctx: ?*anyopaque = null,
    /// Called when selection changes
    on_select: ?*const fn (ctx: ?*anyopaque, path: []const usize) void = null,
    /// Called when a node is activated (Enter)
    on_activate: ?*const fn (ctx: ?*anyopaque, path: []const usize) void = null,

    // Cached flattened rows
    flat_rows: [256]FlatRow = undefined,
    flat_count: usize = 0,

    // Internal expanded state tracking (toggled from initial TreeNode.expanded)
    // Key: hash of path, Value: whether toggled from default
    toggled_paths: [64]u32 = [_]u32{0} ** 64,
    toggled_count: usize = 0,

    pub const GuideChars = enum {
        ascii,
        unicode,

        pub fn vertical(self: GuideChars) u21 {
            return switch (self) {
                .ascii => '|',
                .unicode => '│',
            };
        }

        pub fn branch(self: GuideChars) u21 {
            return switch (self) {
                .ascii => '+',
                .unicode => '├',
            };
        }

        pub fn corner(self: GuideChars) u21 {
            return switch (self) {
                .ascii => '\\',
                .unicode => '└',
            };
        }

        pub fn horizontal(self: GuideChars) u21 {
            return switch (self) {
                .ascii => '-',
                .unicode => '─',
            };
        }
    };

    /// Create a tree widget
    pub fn init(roots: []const TreeNode) Tree {
        var tree = Tree{ .roots = roots };
        tree.rebuildFlat();
        return tree;
    }

    // Builder methods

    /// Set visible height
    pub fn withHeight(self: *Tree, height: u16) *Tree {
        self.visible_height = height;
        return self;
    }

    /// Set show guides
    pub fn withGuides(self: *Tree, show: bool) *Tree {
        self.show_guides = show;
        return self;
    }

    /// Set guide style
    pub fn withGuideChars(self: *Tree, chars: GuideChars) *Tree {
        self.guide_chars = chars;
        return self;
    }

    /// Set text style
    pub fn withTextStyle(self: *Tree, style: Style) *Tree {
        self.text_style = style;
        return self;
    }

    /// Set selected style
    pub fn withSelectedStyle(self: *Tree, style: Style) *Tree {
        self.selected_style = style;
        return self;
    }

    /// Set widget state
    pub fn withState(self: *Tree, state: Widget.WidgetState) *Tree {
        self.widget_state = state;
        return self;
    }

    /// Set allocator for mutable operations
    pub fn withAllocator(self: *Tree, allocator: std.mem.Allocator) *Tree {
        self.allocator = allocator;
        return self;
    }

    /// Set selection callback
    pub fn withOnSelect(self: *Tree, callback: *const fn (ctx: ?*anyopaque, path: []const usize) void, ctx: ?*anyopaque) *Tree {
        self.on_select = callback;
        self.callback_ctx = ctx;
        return self;
    }

    /// Set activation callback
    pub fn withOnActivate(self: *Tree, callback: *const fn (ctx: ?*anyopaque, path: []const usize) void, ctx: ?*anyopaque) *Tree {
        self.on_activate = callback;
        if (self.callback_ctx == null) self.callback_ctx = ctx;
        return self;
    }

    // Navigation methods

    /// Move selection up
    pub fn selectPrev(self: *Tree) void {
        if (self.selected_index > 0) {
            self.selected_index -= 1;
            self.ensureVisible();
            self.notifySelect();
        }
    }

    /// Move selection down
    pub fn selectNext(self: *Tree) void {
        if (self.selected_index + 1 < self.flat_count) {
            self.selected_index += 1;
            self.ensureVisible();
            self.notifySelect();
        }
    }

    /// Move to first item
    pub fn selectFirst(self: *Tree) void {
        if (self.flat_count > 0) {
            self.selected_index = 0;
            self.scroll_offset = 0;
            self.notifySelect();
        }
    }

    /// Move to last item
    pub fn selectLast(self: *Tree) void {
        if (self.flat_count > 0) {
            self.selected_index = self.flat_count - 1;
            self.ensureVisible();
            self.notifySelect();
        }
    }

    /// Toggle expand/collapse of selected node
    pub fn toggleSelected(self: *Tree) void {
        if (self.selected_index >= self.flat_count) return;

        const row = &self.flat_rows[self.selected_index];
        const path = row.node_path[0..row.depth];
        if (self.getNode(path)) |node| {
            if (!node.isLeaf()) {
                const currently_expanded = self.isNodeExpanded(path, node);
                self.setNodeExpanded(path, !currently_expanded);
                self.rebuildFlat();
            }
        }
    }

    /// Activate selected node
    pub fn activateSelected(self: *Tree) void {
        if (self.selected_index >= self.flat_count) return;

        const row = &self.flat_rows[self.selected_index];
        if (self.on_activate) |callback| {
            callback(self.callback_ctx, row.node_path[0..row.depth]);
        }
    }

    /// Expand selected node
    pub fn expandSelected(self: *Tree) void {
        if (self.selected_index >= self.flat_count) return;

        const row = &self.flat_rows[self.selected_index];
        const path = row.node_path[0..row.depth];
        if (self.getNode(path)) |node| {
            if (!node.isLeaf() and !self.isNodeExpanded(path, node)) {
                self.setNodeExpanded(path, true);
                self.rebuildFlat();
            }
        }
    }

    /// Collapse selected node
    pub fn collapseSelected(self: *Tree) void {
        if (self.selected_index >= self.flat_count) return;

        const row = &self.flat_rows[self.selected_index];
        const path = row.node_path[0..row.depth];
        if (self.getNode(path)) |node| {
            if (!node.isLeaf() and self.isNodeExpanded(path, node)) {
                self.setNodeExpanded(path, false);
                self.rebuildFlat();
            }
        }
    }

    /// Hash a path for internal state tracking
    fn hashPath(path: []const usize) u32 {
        var hash: u32 = 0x811c9dc5; // FNV-1a offset basis
        for (path) |idx| {
            hash ^= @truncate(idx);
            hash *%= 0x01000193; // FNV-1a prime
        }
        return hash;
    }

    /// Check if a node is expanded (considering internal toggle state)
    fn isNodeExpanded(self: *const Tree, path: []const usize, node: TreeNode) bool {
        const hash = hashPath(path);
        // Check if this path has been toggled from its default
        for (self.toggled_paths[0..self.toggled_count]) |h| {
            if (h == hash) {
                return !node.expanded; // Toggled from default
            }
        }
        return node.expanded; // Use default from node
    }

    /// Set expanded state for a node path
    fn setNodeExpanded(self: *Tree, path: []const usize, expanded: bool) void {
        const hash = hashPath(path);
        const node = self.getNode(path) orelse return;

        // If setting to default, remove from toggled list
        if (expanded == node.expanded) {
            for (self.toggled_paths[0..self.toggled_count], 0..) |h, i| {
                if (h == hash) {
                    // Remove by swapping with last
                    if (i < self.toggled_count - 1) {
                        self.toggled_paths[i] = self.toggled_paths[self.toggled_count - 1];
                    }
                    self.toggled_count -= 1;
                    return;
                }
            }
        } else {
            // Add to toggled list if not already there
            for (self.toggled_paths[0..self.toggled_count]) |h| {
                if (h == hash) return; // Already toggled
            }
            if (self.toggled_count < self.toggled_paths.len) {
                self.toggled_paths[self.toggled_count] = hash;
                self.toggled_count += 1;
            }
        }
    }

    /// Get current selection path
    pub fn selectedPath(self: *const Tree) ?[]const usize {
        if (self.selected_index >= self.flat_count) return null;
        const row = &self.flat_rows[self.selected_index];
        return row.node_path[0..row.depth];
    }

    /// Get node at path
    pub fn getNode(self: *const Tree, path: []const usize) ?TreeNode {
        if (path.len == 0) return null;

        var current: TreeNode = undefined;
        var nodes: []const TreeNode = self.roots;

        for (path) |idx| {
            if (idx >= nodes.len) return null;
            current = nodes[idx];
            if (current.children) |children| {
                nodes = children;
            } else {
                nodes = &[_]TreeNode{};
            }
        }

        return current;
    }

    fn ensureVisible(self: *Tree) void {
        if (self.selected_index < self.scroll_offset) {
            self.scroll_offset = self.selected_index;
        } else if (self.selected_index >= self.scroll_offset + self.visible_height) {
            self.scroll_offset = self.selected_index - self.visible_height + 1;
        }
    }

    fn notifySelect(self: *Tree) void {
        if (self.on_select) |callback| {
            if (self.selectedPath()) |path| {
                callback(self.callback_ctx, path);
            }
        }
    }

    fn rebuildFlat(self: *Tree) void {
        self.flat_count = 0;
        var path: [16]usize = undefined;
        var is_last: [16]bool = undefined;
        self.flattenNodes(self.roots, 0, &path, &is_last);

        // Clamp selection
        if (self.flat_count > 0 and self.selected_index >= self.flat_count) {
            self.selected_index = self.flat_count - 1;
        }
    }

    fn flattenNodes(self: *Tree, nodes: []const TreeNode, depth: u8, path: *[16]usize, is_last: *[16]bool) void {
        for (nodes, 0..) |node, i| {
            if (self.flat_count >= self.flat_rows.len) return;

            path[depth] = i;
            is_last[depth] = (i == nodes.len - 1);

            self.flat_rows[self.flat_count] = .{
                .node_path = path.*,
                .depth = depth + 1,
                .is_last_at_depth = is_last.*,
            };
            self.flat_count += 1;

            // Use internal expanded state tracking
            const node_path = path[0 .. depth + 1];
            if (self.isNodeExpanded(node_path, node) and !node.isLeaf()) {
                self.flattenNodes(node.children.?, depth + 1, path, is_last);
            }
        }
    }

    // Widget interface

    fn measure(ptr: *anyopaque, constraint: Widget.SizeConstraint) Widget.MeasuredSize {
        const self: *Tree = @ptrCast(@alignCast(ptr));
        return .{
            .width = constraint.max_width,
            .height = @min(self.visible_height, constraint.max_height),
        };
    }

    fn render(ptr: *anyopaque, view: *PlaneView) void {
        const self: *Tree = @ptrCast(@alignCast(ptr));
        const size = view.size();

        if (size.width == 0 or size.height == 0) return;

        const visible_count = @min(self.flat_count -| self.scroll_offset, size.height);

        for (0..visible_count) |i| {
            const row_idx = self.scroll_offset + i;
            const row = &self.flat_rows[row_idx];
            const y: i32 = @intCast(i);

            const is_selected = row_idx == self.selected_index;
            const style = if (is_selected) self.selected_style else self.text_style;

            // Clear line
            for (0..size.width) |x| {
                view.setCell(@intCast(x), y, Cell.simple(' ', style.fg, style.bg));
            }

            var x: u16 = 0;

            // Draw guide lines
            if (self.show_guides and row.depth > 1) {
                for (0..row.depth - 1) |d| {
                    if (x + 2 > size.width) break;

                    if (d < row.depth - 1) {
                        // Draw vertical continuation or space
                        const guide_char = if (!row.is_last_at_depth[d])
                            self.guide_chars.vertical()
                        else
                            ' ';
                        view.setCell(@intCast(x), y, Cell.simple(guide_char, self.text_style.fg, style.bg));
                    }
                    x += 2;
                }

                // Draw branch/corner
                if (x + 2 <= size.width) {
                    const branch_char = if (row.is_last_at_depth[row.depth - 1])
                        self.guide_chars.corner()
                    else
                        self.guide_chars.branch();
                    view.setCell(@intCast(x), y, Cell.simple(branch_char, self.text_style.fg, style.bg));
                    x += 1;
                    view.setCell(@intCast(x), y, Cell.simple(self.guide_chars.horizontal(), self.text_style.fg, style.bg));
                    x += 1;
                }
            } else if (row.depth > 1) {
                // Indent without guides
                x = @intCast((row.depth - 1) * 2);
            }

            // Get the actual node
            const node_path = row.node_path[0..row.depth];
            if (self.getNode(node_path)) |node| {
                // Draw expand/collapse icon
                if (x < size.width) {
                    const icon_char: u21 = if (node.isLeaf())
                        self.leaf_icon
                    else if (self.isNodeExpanded(node_path, node))
                        self.expanded_icon
                    else
                        self.collapsed_icon;
                    view.setCell(@intCast(x), y, Cell.simple(icon_char, style.fg, style.bg));
                    x += 1;
                }

                // Space
                if (x < size.width) {
                    view.setCell(@intCast(x), y, Cell.simple(' ', style.fg, style.bg));
                    x += 1;
                }

                // Draw optional node icon
                if (node.icon) |icon| {
                    if (x < size.width) {
                        view.setCell(@intCast(x), y, Cell.simple(icon, style.fg, style.bg));
                        x += 1;
                    }
                    if (x < size.width) {
                        view.setCell(@intCast(x), y, Cell.simple(' ', style.fg, style.bg));
                        x += 1;
                    }
                }

                // Draw label
                const available = size.width -| x;
                const label_len = @min(node.label.len, available);
                if (label_len > 0) {
                    view.print(@intCast(x), y, node.label[0..label_len], style.fg, style.bg, style.attrs);
                }
            }
        }

        // Fill remaining rows
        for (visible_count..size.height) |i| {
            const y: i32 = @intCast(i);
            for (0..size.width) |x_| {
                view.setCell(@intCast(x_), y, Cell.simple(' ', self.text_style.fg, self.text_style.bg));
            }
        }
    }

    fn handleEvent(ptr: *anyopaque, event: Event.Event) Widget.EventResult {
        const self: *Tree = @ptrCast(@alignCast(ptr));

        if (self.widget_state.disabled or !self.widget_state.focused) {
            return .ignored;
        }

        switch (event) {
            .key => |key| {
                if (key.special) |special| {
                    switch (special) {
                        .up => {
                            self.selectPrev();
                            return .consumed;
                        },
                        .down => {
                            self.selectNext();
                            return .consumed;
                        },
                        .home => {
                            self.selectFirst();
                            return .consumed;
                        },
                        .end => {
                            self.selectLast();
                            return .consumed;
                        },
                        .enter => {
                            self.activateSelected();
                            return .consumed;
                        },
                        .left => {
                            self.collapseSelected();
                            return .consumed;
                        },
                        .right => {
                            self.expandSelected();
                            return .consumed;
                        },
                        else => {},
                    }
                }
                if (key.codepoint) |cp| {
                    switch (cp) {
                        'k' => {
                            self.selectPrev();
                            return .consumed;
                        },
                        'j' => {
                            self.selectNext();
                            return .consumed;
                        },
                        'g' => {
                            self.selectFirst();
                            return .consumed;
                        },
                        'G' => {
                            self.selectLast();
                            return .consumed;
                        },
                        ' ' => {
                            self.toggleSelected();
                            return .consumed;
                        },
                        'h' => {
                            self.collapseSelected();
                            return .consumed;
                        },
                        'l' => {
                            self.expandSelected();
                            return .consumed;
                        },
                        else => {},
                    }
                }
            },
            .mouse => |mouse| {
                if (mouse.button == .wheel_up) {
                    self.selectPrev();
                    return .consumed;
                } else if (mouse.button == .wheel_down) {
                    self.selectNext();
                    return .consumed;
                } else if (mouse.button == .left and mouse.state == .released) {
                    // Click to select
                    const clicked_row = self.scroll_offset + @as(usize, mouse.y);
                    if (clicked_row < self.flat_count) {
                        self.selected_index = clicked_row;
                        self.notifySelect();
                        return .consumed;
                    }
                }
            },
            else => {},
        }

        return .ignored;
    }

    /// VTable for Widget interface
    pub const widget_vtable = Widget.VTable{
        .measureFn = measure,
        .renderFn = render,
        .handleEventFn = handleEvent,
    };
};

// ============================================================================
// Tests
// ============================================================================

const Plane = @import("../Plane.zig");

test "Tree init" {
    const nodes = [_]TreeNode{
        .{ .label = "Root" },
    };
    const tree = Tree.init(&nodes);
    try std.testing.expectEqual(@as(usize, 1), tree.roots.len);
    try std.testing.expectEqual(@as(usize, 1), tree.flat_count);
}

test "Tree nested nodes" {
    const children = [_]TreeNode{
        .{ .label = "Child 1" },
        .{ .label = "Child 2" },
    };
    const nodes = [_]TreeNode{
        .{ .label = "Root", .children = &children },
    };
    const tree = Tree.init(&nodes);

    // Root + 2 children = 3 visible rows
    try std.testing.expectEqual(@as(usize, 3), tree.flat_count);
}

test "Tree collapsed node" {
    const children = [_]TreeNode{
        .{ .label = "Child" },
    };
    const nodes = [_]TreeNode{
        .{ .label = "Root", .children = &children, .expanded = false },
    };
    const tree = Tree.init(&nodes);

    // Only root visible when collapsed
    try std.testing.expectEqual(@as(usize, 1), tree.flat_count);
}

test "Tree navigation" {
    const children = [_]TreeNode{
        .{ .label = "Child 1" },
        .{ .label = "Child 2" },
    };
    const nodes = [_]TreeNode{
        .{ .label = "Root", .children = &children },
    };
    var tree = Tree.init(&nodes);

    try std.testing.expectEqual(@as(usize, 0), tree.selected_index);

    tree.selectNext();
    try std.testing.expectEqual(@as(usize, 1), tree.selected_index);

    tree.selectNext();
    try std.testing.expectEqual(@as(usize, 2), tree.selected_index);

    tree.selectPrev();
    try std.testing.expectEqual(@as(usize, 1), tree.selected_index);

    tree.selectFirst();
    try std.testing.expectEqual(@as(usize, 0), tree.selected_index);

    tree.selectLast();
    try std.testing.expectEqual(@as(usize, 2), tree.selected_index);
}

test "Tree getNode" {
    const grandchildren = [_]TreeNode{
        .{ .label = "Grandchild" },
    };
    const children = [_]TreeNode{
        .{ .label = "Child", .children = &grandchildren },
    };
    const nodes = [_]TreeNode{
        .{ .label = "Root", .children = &children },
    };
    const tree = Tree.init(&nodes);

    const root = tree.getNode(&[_]usize{0});
    try std.testing.expect(root != null);
    try std.testing.expectEqualStrings("Root", root.?.label);

    const child = tree.getNode(&[_]usize{ 0, 0 });
    try std.testing.expect(child != null);
    try std.testing.expectEqualStrings("Child", child.?.label);

    const grandchild = tree.getNode(&[_]usize{ 0, 0, 0 });
    try std.testing.expect(grandchild != null);
    try std.testing.expectEqualStrings("Grandchild", grandchild.?.label);
}

test "Tree measure" {
    const nodes = [_]TreeNode{
        .{ .label = "Root" },
    };
    var tree = Tree.init(&nodes);
    _ = tree.withHeight(5);
    const widget = Widget.Widget.init(Tree, &tree);

    const measured = widget.measure(Widget.SizeConstraint.atMost(40, 10));
    try std.testing.expectEqual(@as(u16, 40), measured.width);
    try std.testing.expectEqual(@as(u16, 5), measured.height);
}

test "Tree handleEvent down" {
    const children = [_]TreeNode{
        .{ .label = "Child" },
    };
    const nodes = [_]TreeNode{
        .{ .label = "Root", .children = &children },
    };
    var tree = Tree.init(&nodes);
    _ = tree.withState(.{ .focused = true });

    const widget = Widget.Widget.init(Tree, &tree);
    const event = Event.Event{ .key = Event.Key.fromSpecial(.down, .{}) };

    const result = widget.handleEvent(event);
    try std.testing.expectEqual(Widget.EventResult.consumed, result);
    try std.testing.expectEqual(@as(usize, 1), tree.selected_index);
}

test "Tree render" {
    const allocator = std.testing.allocator;
    const root = try Plane.initRoot(allocator, .{ .width = 30, .height = 5 });
    defer root.deinit();

    const nodes = [_]TreeNode{
        .{ .label = "Root" },
    };
    var tree = Tree.init(&nodes);
    _ = tree.withHeight(5);

    const widget = Widget.Widget.init(Tree, &tree);
    var view = PlaneView.init(root);
    widget.render(&view);

    // Leaf icon should be visible (•)
    try std.testing.expectEqual(@as(u21, '•'), view.getCell(0, 0).?.char);
}

test "TreeNode isLeaf" {
    const leaf = TreeNode{ .label = "Leaf" };
    try std.testing.expect(leaf.isLeaf());

    const children = [_]TreeNode{.{ .label = "Child" }};
    const parent = TreeNode{ .label = "Parent", .children = &children };
    try std.testing.expect(!parent.isLeaf());
}

test "Tree GuideChars" {
    try std.testing.expectEqual(@as(u21, '│'), Tree.GuideChars.unicode.vertical());
    try std.testing.expectEqual(@as(u21, '|'), Tree.GuideChars.ascii.vertical());
}
