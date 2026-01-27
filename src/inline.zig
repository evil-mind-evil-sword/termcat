//! Inline TUI mode utilities for terminal history insertion.
//!
//! This module provides support for "inline" TUI mode where:
//! - The TUI lives at the bottom of the terminal
//! - Completed content is pushed into the scrollback history
//! - Content persists after the application exits
//!
//! This is the Codex-style TUI pattern, as opposed to the traditional
//! alternate screen buffer approach where all content is lost on exit.
//!
//! ## Architecture
//!
//! The inline viewport occupies the bottom N lines of the terminal.
//! When content is "finalized" (e.g., an assistant message is complete),
//! it gets pushed into the scrollback above the viewport using scroll regions.
//!
//! ```
//! ┌────────────────────────────────────────┐
//! │ Terminal Scrollback                    │ ← Historical content
//! │ (user can scroll back to see)          │
//! ├────────────────────────────────────────┤
//! │ Inline Viewport (bottom N lines)       │ ← Active TUI area
//! │ - Current assistant streaming          │
//! │ - Input composer                       │
//! │ - Status line                          │
//! └────────────────────────────────────────┘
//! ```
//!
//! ## Usage
//!
//! ```zig
//! const inline = @import("inline.zig");
//! const renderer = inline.HistoryRenderer.init(&backend, viewport_height);
//!
//! // When a message is complete, push it to scrollback
//! try renderer.insertLines(styled_lines);
//! ```

const std = @import("std");
const Cell = @import("Cell.zig");
const Style = @import("Style.zig");
const Renderer = @import("Renderer.zig");

/// A line of styled text for history insertion.
pub const StyledLine = struct {
    /// The text content of the line
    text: []const u8,
    /// Style to apply to the entire line (optional)
    style: ?Style = null,
};

/// A span of styled text within a line.
pub const StyledSpan = struct {
    /// The text content
    text: []const u8,
    /// Style for this span
    style: Style,
};

/// A line composed of multiple styled spans.
pub const RichLine = struct {
    /// Spans composing the line
    spans: []const StyledSpan,
};

/// History renderer for inline TUI mode.
///
/// Manages inserting completed content into the terminal scrollback
/// above the active viewport area.
pub fn HistoryRenderer(comptime BackendType: type) type {
    return struct {
        const Self = @This();

        /// Backend for terminal output
        backend: *BackendType,
        /// Height of the active viewport area (lines reserved at bottom)
        viewport_height: u16,
        /// Renderer for styled output
        renderer: Renderer,

        /// Initialize a history renderer.
        ///
        /// The viewport_height specifies how many lines at the bottom of the
        /// terminal are reserved for the active TUI. Content inserted via
        /// insertLines() will appear above this area.
        pub fn init(backend: *BackendType, viewport_height: u16) Self {
            return .{
                .backend = backend,
                .viewport_height = viewport_height,
                .renderer = Renderer.init(),
            };
        }

        /// Insert lines of text into the scrollback above the viewport.
        ///
        /// This uses scroll regions to:
        /// 1. Set scroll region from line 1 to (screen_height - viewport_height)
        /// 2. Position cursor at top of viewport
        /// 3. Use reverse index to scroll content up into scrollback
        /// 4. Write the new lines
        /// 5. Reset scroll region
        ///
        /// The lines appear just above the viewport, pushing older content
        /// into the scrollback.
        pub fn insertLines(self: *Self, lines: []const StyledLine) !void {
            if (lines.len == 0) return;

            const screen_height = self.backend.size.height;
            const screen_width = self.backend.size.width;

            // Calculate the scroll region: line 1 to (screen - viewport)
            // This is the area above the viewport where history lives
            const history_bottom = screen_height -| self.viewport_height;
            if (history_bottom == 0) return; // No room for history

            // Save cursor position
            try self.backend.saveCursor();

            // Set scroll region to history area (1-indexed)
            try self.backend.setScrollRegion(1, history_bottom);

            // Position cursor at bottom of history area
            try self.backend.setCursorPosition(history_bottom, 1);

            // For each line, scroll up and write
            for (lines) |line| {
                // Scroll the region up by one line (creates blank line at bottom)
                try self.backend.index();

                // Position at the new blank line (bottom of scroll region)
                try self.backend.setCursorPosition(history_bottom, 1);

                // Write the line content with style
                try self.writeLine(line, screen_width);
            }

            // Reset scroll region to full screen
            try self.backend.resetScrollRegion();

            // Restore cursor position
            try self.backend.restoreCursor();

            // Flush output
            try self.backend.flushOutput();
        }

        /// Insert rich lines (with multiple styled spans per line).
        pub fn insertRichLines(self: *Self, lines: []const RichLine) !void {
            if (lines.len == 0) return;

            const screen_height = self.backend.size.height;
            const screen_width = self.backend.size.width;
            _ = screen_width;

            const history_bottom = screen_height -| self.viewport_height;
            if (history_bottom == 0) return;

            try self.backend.saveCursor();
            try self.backend.setScrollRegion(1, history_bottom);
            try self.backend.setCursorPosition(history_bottom, 1);

            for (lines) |line| {
                try self.backend.index();
                try self.backend.setCursorPosition(history_bottom, 1);
                try self.writeRichLine(line);
            }

            try self.backend.resetScrollRegion();
            try self.backend.restoreCursor();
            try self.backend.flushOutput();
        }

        /// Write a single styled line to the terminal.
        fn writeLine(self: *Self, line: StyledLine, max_width: u16) !void {
            const writer = self.backend.writer();

            // Apply style if present
            if (line.style) |style| {
                try self.renderer.writeStyle(writer, style, .true_color);
            }

            // Write text, truncating to max width
            var written: u16 = 0;
            for (line.text) |byte| {
                if (written >= max_width) break;
                try writer.writeByte(byte);
                // Simple approximation: ASCII = 1 width
                // TODO: proper Unicode width handling
                if (byte < 0x80 and byte >= 0x20) {
                    written += 1;
                }
            }

            // Reset style
            if (line.style != null) {
                try writer.writeAll("\x1b[0m");
            }

            // Clear to end of line
            try writer.writeAll("\x1b[K");
        }

        /// Write a rich line (multiple spans) to the terminal.
        fn writeRichLine(self: *Self, line: RichLine) !void {
            const writer = self.backend.writer();

            for (line.spans) |span| {
                try self.renderer.writeStyle(writer, span.style, .true_color);
                try writer.writeAll(span.text);
            }

            // Reset and clear to end of line
            try writer.writeAll("\x1b[0m\x1b[K");
        }

        /// Push the viewport down by inserting blank lines at the top.
        /// Used when starting the TUI to create space for the viewport.
        pub fn reserveViewport(self: *Self) !void {
            const writer = self.backend.writer();

            // Move to bottom of screen and emit newlines to scroll
            try self.backend.setCursorPosition(self.backend.size.height, 1);

            // Emit enough newlines to create space for viewport
            for (0..self.viewport_height) |_| {
                try writer.writeByte('\n');
            }

            try self.backend.flushOutput();
        }

        /// Update the viewport height (e.g., after terminal resize).
        pub fn setViewportHeight(self: *Self, height: u16) void {
            self.viewport_height = height;
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

test "StyledLine creation" {
    const line = StyledLine{
        .text = "Hello, world!",
        .style = .{ .fg = .{ .index = 2 } },
    };
    try std.testing.expectEqualStrings("Hello, world!", line.text);
    try std.testing.expect(line.style != null);
}

test "StyledSpan creation" {
    const span = StyledSpan{
        .text = "bold",
        .style = .{ .attrs = .{ .bold = true } },
    };
    try std.testing.expectEqualStrings("bold", span.text);
    try std.testing.expect(span.style.attrs.bold);
}

test "RichLine with multiple spans" {
    const spans = [_]StyledSpan{
        .{ .text = "Hello ", .style = .{} },
        .{ .text = "world", .style = .{ .attrs = .{ .bold = true } } },
        .{ .text = "!", .style = .{ .fg = .{ .index = 1 } } },
    };
    const line = RichLine{ .spans = &spans };
    try std.testing.expectEqual(@as(usize, 3), line.spans.len);
}
