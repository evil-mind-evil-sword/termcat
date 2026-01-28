const std = @import("std");

pub const TextBuffer = @import("TextBuffer.zig").TextBuffer;

test {
    std.testing.refAllDecls(@This());
}
