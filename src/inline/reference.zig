//! Entity and numeric character references (CommonMark 0.31.2 §2.5) at an
//! `&` of a leaf's joined text: `&name;` for an HTML5 name, `&#digits;`
//! (1 to 7) and `&#xhex;` (1 to 6). Each is bounded, so a scan costs a
//! constant.
const std = @import("std");
const aegis = @import("aegis");
const entities = @import("../scan/entities.zig");

/// A reference's code points, `second` 0 for one, and the bytes it takes.
pub const Found = struct { first: u21, second: u21, end: usize };

const replacement: u21 = 0xFFFD;

/// A decimal or hexadecimal digit's value, or null for another byte.
fn digit(c: u8, hex: bool) ?u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => if (hex) c - 'a' + 10 else null,
        'A'...'F' => if (hex) c - 'A' + 10 else null,
        else => null,
    };
}

/// The reference starting at `s[at]` (an `&`), or null.
pub fn at(s: []const u8, start: usize, work: *u64) ?Found {
    aegis.assert.invariant(s[start] == '&', "a reference starts at an `&`");
    var i = start + 1;
    if (i < s.len and s[i] == '#') {
        i += 1;
        const hex = i < s.len and (s[i] == 'x' or s[i] == 'X');
        if (hex) i += 1;
        const digits = i;
        const most: usize = if (hex) 6 else 7;
        var value: u32 = 0;
        while (i < s.len and i - digits < most) : ({
            i += 1;
            work.* += 1;
        }) {
            const d = digit(s[i], hex) orelse break;
            value = value * (if (hex) @as(u32, 16) else 10) + d;
        }
        if (i == digits or i >= s.len or s[i] != ';') return null;
        // Zero, a surrogate or past Unicode reads as U+FFFD (§2.5).
        const cp: u21 = if (value == 0 or value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF)) replacement else @intCast(value);
        return .{ .first = cp, .second = 0, .end = i + 1 };
    }
    const name = i;
    while (i < s.len and i - name <= entities.longest and std.ascii.isAlphanumeric(s[i])) : (work.* += 1) i += 1;
    if (i == name or i >= s.len or s[i] != ';') return null;
    const e = entities.lookup(s[name..i]) orelse return null;
    return .{ .first = e.first, .second = e.second, .end = i + 1 };
}

const testing = std.testing;

fn expectReference(s: []const u8, first: u21, second: u21) !void {
    var work: u64 = 0;
    const f = at(s, 0, &work).?;
    try testing.expectEqual(first, f.first);
    try testing.expectEqual(second, f.second);
    try testing.expectEqual(s.len, f.end);
}

test "references as §2.5 reads them" {
    var work: u64 = 0;
    try expectReference("&nbsp;", 0xA0, 0);
    try expectReference("&ngE;", 0x2267, 0x338);
    try expectReference("&#35;", '#', 0);
    try expectReference("&#1234;", 0x4D2, 0);
    try expectReference("&#0;", 0xFFFD, 0);
    try expectReference("&#X22;", '"', 0);
    try expectReference("&#XD06;", 0xD06, 0);
    try expectReference("&#xcab;", 0xCAB, 0);
    try expectReference("&#9999999;", 0xFFFD, 0);
    try testing.expectEqual(null, at("&nbsp", 0, &work));
    try testing.expectEqual(null, at("&x;", 0, &work));
    try testing.expectEqual(null, at("&#87654321;", 0, &work));
    try testing.expectEqual(null, at("&#abcdef0;", 0, &work));
    try testing.expectEqual(null, at("&ThisIsNotDefined;", 0, &work));
    try testing.expectEqual(null, at("&hi?;", 0, &work));
    try testing.expectEqual(null, at("&#;", 0, &work));
    try testing.expectEqual(null, at("&;", 0, &work));
}
