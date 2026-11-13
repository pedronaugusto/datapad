//! The scanners against models of CommonMark's text: columns taken in any
//! split land where expanding every tab to its stop says, and the code
//! points either side of an offset are std's own decoding of the text.
const std = @import("std");
const shakedown = @import("shakedown");
const line = @import("line.zig");
const chars = @import("chars.zig");

const testing = std.testing;
const gen = shakedown.gen;

test "columns: taken in any split, the cursor lands where expanding the tabs says" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            const s = case.source;
            var buffer: [16]u8 = undefined;
            const n = gen.intRange(s, usize, 0, buffer.len);
            for (buffer[0..n]) |*c| c.* = gen.oneOf(s, u8, " \t\tx");
            const text = buffer[0..n];
            // The model: each byte's starting column, tabs to the next stop of 4.
            var starts: [17]u32 = undefined;
            var column: u32 = 0;
            for (text, 0..) |c, i| {
                starts[i] = column;
                column = if (c == '\t') (column / 4 + 1) * 4 else column + 1;
            }
            starts[n] = column;
            // The blank run ahead, in columns.
            var blank_end: usize = 0;
            while (blank_end < n and text[blank_end] != 'x') blank_end += 1;
            const blank = starts[blank_end];
            try testing.expectEqual(blank, (line.Cursor{}).indent(text));
            // Two takes in any split: together, as one take of their sum.
            const first = gen.intRange(s, u32, 0, 12);
            const second = gen.intRange(s, u32, 0, 12);
            var a: line.Cursor = .{};
            const got = a.take(text, first) + a.take(text, second);
            var b: line.Cursor = .{};
            try testing.expectEqual(b.take(text, first + second), got);
            try testing.expectEqual(b.column, a.column);
            try testing.expectEqual(b.offset, a.offset);
            try testing.expectEqual(@min(first + second, blank), got);
            // The cursor is on the byte whose span holds its column.
            try testing.expect(a.column >= starts[a.offset]);
            if (a.offset < n) try testing.expect(a.column < starts[a.offset + 1] or a.taken == 0);
            try testing.expectEqual(blank - a.column, a.indent(text));
        }
    }.one, .{ .cases = 5000, .seed = 0x4c0 });
}

test "code points either side of an offset: std's decoding of the text" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            const s = case.source;
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(testing.allocator);
            var points: std.ArrayList(u21) = .empty;
            defer points.deinit(testing.allocator);
            for (0..gen.intRange(s, usize, 0, 8)) |_| {
                const cp = gen.oneOf(s, u21, &.{ 'a', '*', ' ', 0xE9, 0x20AC, 0x1F600, 0x3000 });
                var b: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(cp, &b);
                try text.appendSlice(testing.allocator, b[0..len]);
                try points.append(testing.allocator, cp);
            }
            var offset: usize = 0;
            for (points.items, 0..) |cp, i| {
                try testing.expectEqual(cp, chars.after(text.items, offset));
                try testing.expectEqual(if (i == 0) '\n' else points.items[i - 1], chars.before(text.items, offset));
                offset += std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
            }
            try testing.expectEqual(if (points.items.len == 0) '\n' else points.items[points.items.len - 1], chars.before(text.items, offset));
            try testing.expectEqual('\n', chars.after(text.items, offset));
        }
    }.one, .{ .cases = 3000, .seed = 0xc4 });
}
