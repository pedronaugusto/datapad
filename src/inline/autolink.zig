//! Autolinks (CommonMark 0.31.2 §6.5): an absolute URI or an email address
//! between `<` and `>`, at a `<` of a leaf's joined text. Neither holds a
//! space, a `<` or a line ending, so a scan never passes the next `<` and
//! the scans of one leaf cost its length.
const std = @import("std");
const aegis = @import("aegis");

pub const Kind = enum { uri, email };

pub const Autolink = struct {
    kind: Kind,
    /// Past the `>`.
    end: usize,
};

/// The autolink starting at `s[at]` (a `<`), or null.
pub fn at(s: []const u8, start: usize) ?Autolink {
    aegis.assert.invariant(s[start] == '<', "an autolink starts at a `<`");
    if (uri(s, start + 1)) |e| return .{ .kind = .uri, .end = e };
    if (email(s, start + 1)) |e| return .{ .kind = .email, .end = e };
    return null;
}

/// A scheme of 2 to 32 characters, `:`, and anything but controls, spaces,
/// `<` and `>`, then `>`: past the `>`.
fn uri(s: []const u8, from: usize) ?usize {
    var i = from;
    if (i >= s.len or !std.ascii.isAlphabetic(s[i])) return null;
    i += 1;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '+' or s[i] == '.' or s[i] == '-')) i += 1;
    const scheme = i - from;
    if (scheme < 2 or scheme > 32 or i >= s.len or s[i] != ':') return null;
    i += 1;
    while (i < s.len) : (i += 1) switch (s[i]) {
        '>' => return i + 1,
        '<', ' ', 0x7f => return null,
        else => if (s[i] < ' ') return null,
    };
    return null;
}

fn isLocalByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.findScalar(u8, ".!#$%&'*+/=?^_`{|}~-", c) != null;
}

/// HTML's valid email address, then `>`: past the `>`.
fn email(s: []const u8, from: usize) ?usize {
    var i = from;
    while (i < s.len and isLocalByte(s[i])) i += 1;
    if (i == from or i >= s.len or s[i] != '@') return null;
    i += 1;
    // Labels of 1 to 63 letters, digits and inner hyphens, joined by dots.
    while (true) {
        const label = i;
        while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '-')) i += 1;
        const len = i - label;
        if (len == 0 or len > 63 or s[label] == '-' or s[i - 1] == '-') return null;
        if (i >= s.len) return null;
        switch (s[i]) {
            '>' => return i + 1,
            '.' => i += 1,
            else => return null,
        }
    }
}

const testing = std.testing;

fn expectAutolink(s: []const u8, kind: ?Kind) !void {
    const got = at(s, 0);
    if (kind) |k| {
        try testing.expectEqual(k, got.?.kind);
        try testing.expectEqual(s.len, got.?.end);
    } else try testing.expectEqual(null, got);
}

test "autolinks as §6.5 reads them" {
    try expectAutolink("<http://foo.bar.baz>", .uri);
    try expectAutolink("<https://foo.bar.baz/test?q=hello&id=22&boolean>", .uri);
    try expectAutolink("<irc://foo.bar:2233/baz>", .uri);
    try expectAutolink("<MAILTO:FOO@BAR.BAZ>", .uri);
    try expectAutolink("<a+b+c:d>", .uri);
    try expectAutolink("<made-up-scheme://foo,bar>", .uri);
    try expectAutolink("<localhost:5001/foo>", .uri);
    try expectAutolink("<https://foo.bar/baz bim>", null);
    try expectAutolink("<https://example.com/\\[\\>", .uri);
    try expectAutolink("<foo@bar.example.com>", .email);
    try expectAutolink("<foo+special@Bar.baz-bar0.com>", .email);
    try expectAutolink("<foo\\+@bar.example.com>", null);
    try expectAutolink("<>", null);
    try expectAutolink("< http://foo.bar >", null);
    try expectAutolink("<m:abc>", null);
    try expectAutolink("<foo.bar.baz>", null);
    try expectAutolink("<a@b-.c>", null);
}
