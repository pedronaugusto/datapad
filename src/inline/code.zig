//! Code spans (CommonMark 0.31.2 §6.1): a backtick string, then the first
//! backtick string of the same length after it that no backtick touches.
//!
//! The leaf's maximal backtick runs are listed once, in order, and chained
//! by length: `heads[n]` is the first run of length `n` not yet passed.
//! The parser asks from left to right, so a head only moves forward, and a
//! leaf of many openers with no closer costs its length, not its length
//! times its openers (cmark's pathological backtick case).
const std = @import("std");
const aegis = @import("aegis");

pub const none = std.math.maxInt(u32);

/// A maximal run of backticks.
pub const Run = struct { start: u32, end: u32 };

/// The runs of one leaf and their chains, in memory the caller sized by
/// `bounds`.
pub const Table = struct {
    runs: []Run,
    /// The next run of the same length, `none` for the last.
    next: []u32,
    /// The first run of each length not yet passed, `none` for none.
    heads: []u32,

    /// How many runs and lengths a text of `len` bytes can hold.
    pub fn bounds(len: usize) struct { runs: usize, lengths: usize } {
        // Two runs have a byte between them.
        return .{ .runs = len / 2 + 1, .lengths = len + 1 };
    }

    /// Lists the runs of `s` into memory `bounds(s.len)` sized. Returns
    /// the table over what it filled.
    pub fn build(s: []const u8, runs: []Run, next: []u32, heads: []u32) Table {
        var count: usize = 0;
        var longest: usize = 0;
        var i: usize = 0;
        while (std.mem.findScalarPos(u8, s, i, '`')) |start| {
            var e = start;
            while (e < s.len and s[e] == '`') e += 1;
            runs[count] = .{ .start = @intCast(start), .end = @intCast(e) };
            count += 1;
            longest = @max(longest, e - start);
            i = e;
        }
        const t: Table = .{ .runs = runs[0..count], .next = next[0..count], .heads = heads[0 .. longest + 1] };
        @memset(t.heads, none);
        // Backwards, so each head ends as its length's first run.
        var k = count;
        while (k > 0) {
            k -= 1;
            const n = t.runs[k].end - t.runs[k].start;
            t.next[k] = t.heads[n];
            t.heads[n] = @intCast(k);
        }
        return t;
    }

    /// The first run of exactly `len` backticks starting at or after
    /// `from`, or null. `from` never goes back between calls.
    pub fn closer(t: Table, len: usize, from: usize) ?Run {
        if (len >= t.heads.len) return null;
        var h = t.heads[len];
        while (h != none and t.runs[h].start < from) h = t.next[h];
        t.heads[len] = h;
        return if (h == none) null else t.runs[h];
    }
};

/// A code span's content after §6.1's stripping: one space off each end
/// where both ends are a space or a line ending and not all of it is.
/// `start` and `end` bound the content between the backtick strings.
pub fn strip(s: []const u8, start: usize, end: usize) struct { start: usize, end: usize } {
    aegis.assert.invariant(start < end, "a code span holds at least one byte");
    const first = s[start];
    const last = s[end - 1];
    const blank_end = (first == ' ' or first == '\n') and (last == ' ' or last == '\n');
    if (!blank_end or end - start < 2) return .{ .start = start, .end = end };
    for (s[start..end]) |c| if (c != ' ' and c != '\n') return .{ .start = start + 1, .end = end - 1 };
    return .{ .start = start, .end = end };
}

const testing = std.testing;

test "a code span's closer is the next run of its length" {
    const s = "`a`` ``b` ```c``";
    var runs: [9]Run = undefined;
    var next: [9]u32 = undefined;
    var heads: [17]u32 = undefined;
    const t = Table.build(s, &runs, &next, &heads);
    try testing.expectEqual(6, t.runs.len);
    try testing.expectEqual(Run{ .start = 8, .end = 9 }, t.closer(1, 1).?);
    try testing.expectEqual(Run{ .start = 5, .end = 7 }, t.closer(2, 4).?);
    try testing.expectEqual(null, t.closer(3, 13));
    try testing.expectEqual(null, t.closer(4, 0));
}

test "stripping takes one space off each end, never off all spaces" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ " a ", "a" },
        .{ "  a  ", " a " },
        .{ " a", " a" },
        .{ "\na\n", "a" },
        .{ "   ", "   " },
        .{ " ", " " },
    };
    for (cases) |c| {
        const r = strip(c[0], 0, c[0].len);
        try testing.expectEqualStrings(c[1], c[0][r.start..r.end]);
    }
}
