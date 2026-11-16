//! GFM's extended autolinks: a `www.` link, an `http://`, `https://` or
//! `ftp://` link, or an e-mail address, recognized in text without angle
//! brackets, as cmark-gfm's autolink extension reads them. Each scan stops
//! at the first byte its link cannot hold, and a link's end is then trimmed
//! of what reads as the text around it; a scan's bytes are the link's or
//! the byte that ended it, so the scans of one leaf cost its length.
const std = @import("std");

/// A link found: its bytes in the text, and whether it is an e-mail
/// address.
pub const Found = struct { start: usize, end: usize, email: bool };

/// Whether a `www.` or URL link may start after `s[at - 1]`: at the
/// text's start, or after whitespace or one of `*`, `_`, `~` and `(`.
fn boundary(s: []const u8, at: usize) bool {
    if (at == 0) return true;
    return switch (s[at - 1]) {
        ' ', '\t', '\n', '*', '_', '~', '(' => true,
        else => false,
    };
}

/// A byte of a domain: a letter, a digit, `-`, `_`, or any byte of a
/// multibyte character.
fn hostByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c >= 0x80;
}

/// Where the domain from `s[from]` ends: segments of host bytes split by
/// periods, with no underscore in its last two; at least one period unless
/// `short` allows none. Null where there is none.
fn domain(s: []const u8, from: usize, short: bool, work: *u64) ?usize {
    var i = from;
    var periods: usize = 0;
    // Underscores in the segment before the last, and in the last.
    var before: usize = 0;
    var last: usize = 0;
    while (i < s.len) : ({
        i += 1;
        work.* += 1;
    }) {
        const c = s[i];
        if (c == '.') {
            // A period ends the domain unless a segment follows it.
            if (i + 1 >= s.len or !hostByte(s[i + 1])) break;
            before = last;
            last = 0;
            periods += 1;
        } else if (c == '_') {
            last += 1;
        } else if (!hostByte(c)) break;
    }
    if (i == from or before > 0 or last > 0) return null;
    if (periods == 0 and !short) return null;
    return i;
}

/// `end` moved back past what ends a link but is not its: trailing
/// punctuation, a `)` the link opened no `(` for, and a trailing entity
/// reference's `&name;`.
fn trim(s: []const u8, start: usize, end_in: usize, work: *u64) usize {
    var end = end_in;
    // The link's parentheses, counted once when a `)` is first met: trimming
    // takes off only `)` of them, so `closing` goes down by one for each.
    var counted = false;
    var opening: usize = 0;
    var closing: usize = 0;
    while (end > start) {
        work.* += 1;
        const c = s[end - 1];
        if (std.mem.findScalar(u8, "?!.,:*_~'\"", c) != null) {
            end -= 1;
        } else if (c == ';') {
            var amp = end - 1;
            while (amp > start and std.ascii.isAlphanumeric(s[amp - 1])) : (work.* += 1) amp -= 1;
            if (amp > start and amp < end - 1 and s[amp - 1] == '&') {
                end = amp - 1;
            } else break;
        } else if (c == ')') {
            if (!counted) {
                for (s[start..end]) |b| {
                    work.* += 1;
                    if (b == '(') opening += 1;
                    if (b == ')') closing += 1;
                }
                counted = true;
            }
            if (closing <= opening) break;
            closing -= 1;
            end -= 1;
        } else break;
    }
    return end;
}

/// The `www.` or URL link starting at `s[at]`, or null.
pub fn url(s: []const u8, at: usize, work: *u64) ?Found {
    if (!boundary(s, at)) return null;
    const rest = s[at..];
    const www = std.mem.startsWith(u8, rest, "www.");
    const scheme: usize = if (www) 0 else for ([_][]const u8{ "http://", "https://", "ftp://" }) |prefix| {
        if (std.mem.startsWith(u8, rest, prefix)) break prefix.len;
    } else return null;
    const host_end = domain(s, at + scheme, !www, work) orelse return null;
    var end = host_end;
    while (end < s.len and !(s[end] == ' ' or s[end] == '\t' or s[end] == '\n' or s[end] == '<')) : (work.* += 1) end += 1;
    end = trim(s, at, end, work);
    if (end <= at + scheme) return null;
    return .{ .start = at, .end = end, .email = false };
}

fn localByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '+' or c == '-' or c == '_';
}

/// The e-mail address around the `@` at `s[at]`, its local part read back
/// no further than `from`, or null.
pub fn email(s: []const u8, from: usize, at: usize, work: *u64) ?Found {
    var start = at;
    while (start > from and localByte(s[start - 1])) : (work.* += 1) start -= 1;
    if (start == at) return null;
    var end = at + 1;
    var periods: usize = 0;
    while (end < s.len) : ({
        end += 1;
        work.* += 1;
    }) {
        const c = s[end];
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') continue;
        if (c == '.' and end + 1 < s.len and std.ascii.isAlphanumeric(s[end + 1])) {
            periods += 1;
            continue;
        }
        break;
    }
    if (end < at + 2 or periods == 0) return null;
    const last = s[end - 1];
    if (!std.ascii.isAlphanumeric(last) and last != '.') return null;
    end = trim(s, start, end, work);
    return .{ .start = start, .end = end, .email = true };
}

const testing = std.testing;

fn expectUrl(s: []const u8, link: ?[]const u8) !void {
    const at = std.mem.find(u8, s, "www.") orelse std.mem.find(u8, s, "http") orelse std.mem.find(u8, s, "ftp").?;
    var work: u64 = 0;
    const f = url(s, at, &work);
    if (link) |l| try testing.expectEqualStrings(l, s[f.?.start..f.?.end]) else try testing.expectEqual(null, f);
}

test "www and URL links, trimmed as GFM trims them" {
    var work: u64 = 0;
    try expectUrl("www.commonmark.org", "www.commonmark.org");
    try expectUrl("www.commonmark.org.", "www.commonmark.org");
    try expectUrl("www.commonmark.org/a.b.", "www.commonmark.org/a.b");
    try expectUrl("www.google.com/search?q=Markup+(business)))", "www.google.com/search?q=Markup+(business)");
    try expectUrl("www.google.com/search?q=(business))+ok", "www.google.com/search?q=(business))+ok");
    try expectUrl("www.google.com/search?q=commonmark&hl;", "www.google.com/search?q=commonmark");
    try expectUrl("www.commonmark.org/he<lp", "www.commonmark.org/he");
    try expectUrl("www.a_b.c_d", null);
    try expectUrl("https://encrypted.google.com/x", "https://encrypted.google.com/x");
    try expectUrl("ftp://foo.bar.baz.", "ftp://foo.bar.baz");
    try testing.expectEqual(null, url("awww.a.b", 1, &work));
}

test "e-mail addresses, read around their @" {
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "foo@bar.baz", "foo@bar.baz" },
        .{ "hello+xyz@mail.example", "hello+xyz@mail.example" },
        .{ "hello@mail+xyz.example", null },
        .{ "a.b-c_d@a.b.", "a.b-c_d@a.b" },
        .{ "a.b-c_d@a.b-", null },
        .{ "a.b-c_d@a.b_", null },
        .{ "@a.b", null },
    };
    for (cases) |c| {
        var work: u64 = 0;
        const f = email(c[0], 0, std.mem.findScalar(u8, c[0], '@').?, &work);
        if (c[1]) |l| try testing.expectEqualStrings(l, c[0][f.?.start..f.?.end]) else try testing.expectEqual(null, f);
    }
}
