//! Columns in a line as CommonMark 0.31.2 §2.2 counts them: a tab moves to
//! the next multiple of 4, and a block structure that takes part of a tab
//! leaves the rest of it as spaces for what follows.
const std = @import("std");

/// A place in a line: the byte it is at, the column it stands at, and how
/// many columns of the tab at that byte were already taken.
pub const Cursor = struct {
    offset: u32 = 0,
    column: u32 = 0,
    /// Columns of the tab at `offset` already taken by what came before.
    taken: u3 = 0,

    /// How many columns the space or tab at the cursor still spans.
    fn width(c: Cursor, line: []const u8) u32 {
        return switch (line[c.offset]) {
            ' ' => 1,
            '\t' => 4 - c.column % 4,
            else => 0,
        };
    }

    /// Takes up to `n` columns of spaces and tabs; returns how many it took.
    /// A tab taken in part leaves the cursor on it, its rest still there.
    pub fn take(c: *Cursor, line: []const u8, n: u32) u32 {
        var taken: u32 = 0;
        while (taken < n and c.offset < line.len) {
            const w = c.width(line);
            if (w == 0) break;
            const step = @min(w, n - taken);
            taken += step;
            c.column += step;
            if (step == w) {
                c.offset += 1;
                c.taken = 0;
            } else {
                c.taken += @intCast(step);
            }
        }
        return taken;
    }

    /// How many columns of spaces and tabs lie ahead, without taking them.
    pub fn indent(c: Cursor, line: []const u8) u32 {
        var copy = c;
        return copy.take(line, std.math.maxInt(u32));
    }
};

const testing = std.testing;

test "a tab stops at the next multiple of four, and a part taken leaves the rest" {
    var c: Cursor = .{};
    try testing.expectEqual(4, c.indent("\tx"));
    try testing.expectEqual(6, (Cursor{}).indent("  \t  x"));
    // `>` then a tab: one column taken for the marker's space, three left.
    c = .{ .offset = 1, .column = 1 };
    try testing.expectEqual(1, c.take(">\tfoo", 1));
    try testing.expectEqual(1, c.offset);
    try testing.expectEqual(2, c.indent(">\tfoo"));
    try testing.expectEqual(2, c.take(">\tfoo", 5));
    try testing.expectEqual(2, c.offset);
    try testing.expectEqual(4, c.column);
    // A tab after a column not on a stop.
    try testing.expectEqual(4, (Cursor{}).indent(" \t"));
}
