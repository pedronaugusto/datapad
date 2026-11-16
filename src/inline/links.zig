//! Links and images (CommonMark 0.31.2 §6.3, §6.4): `[` and `![` go on a
//! bracket stack as the leaf is read; a `]` looks at the top one and tries,
//! in the spec's order, an inline link's `(destination "title")`, a full
//! reference `[label]`, a collapsed `[]` and a shortcut. A link takes the
//! brackets before it out of play, so no link holds another.
//!
//! A label is matched by its normalized form, written into fixed memory:
//! a label holds at most 999 bytes, and case folding writes at most three
//! bytes for each one it reads, so matching never allocates.
const std = @import("std");
const aegis = @import("aegis");
const xenoglyph = @import("xenoglyph");
const references = @import("../block/references.zig");

pub const none = std.math.maxInt(u32);

pub const Bracket = struct {
    /// The `[` or `![` item.
    item: u32,
    /// The delimiter stack's top when it was read: emphasis inside the
    /// link's text is matched above it.
    delimiters: u32,
    image: bool,
    /// A bracket was read after it: its text is no label, so it makes no
    /// collapsed or shortcut reference.
    bracket_after: bool = false,
    /// A wikilink's `[[target|`: it closes at the `]]` found when it was
    /// read, and at no other `]`.
    wiki: ?Wiki = null,
};

/// The brackets still open, last on top.
pub const Stack = struct {
    entries: []Bracket,
    len: u32 = 0,
    /// Every `[` below this index is out of play: a link closed after it,
    /// and no link holds another. An image's `![` stays in play.
    floor: u32 = 0,

    pub fn push(s: *Stack, b: Bracket) void {
        aegis.assert.invariant(s.len < s.entries.len, "a leaf's brackets fit the memory sized for it");
        if (s.len != 0) s.entries[s.len - 1].bracket_after = true;
        s.entries[s.len] = b;
        s.len += 1;
    }

    pub fn top(s: *Stack) ?*Bracket {
        return if (s.len == 0) null else &s.entries[s.len - 1];
    }

    pub fn pop(s: *Stack) void {
        s.len -= 1;
        s.floor = @min(s.floor, s.len);
    }

    /// A link closed: every `[` below takes no part in one. One step,
    /// however many images' `![` lie between, where walking down to them
    /// made a run of images quadratic.
    pub fn deactivate(s: *Stack) void {
        s.floor = s.len;
    }

    /// Whether the bracket on top can still make a link or image.
    pub fn topActive(s: *const Stack) bool {
        const i = s.len - 1;
        return s.entries[i].image or i >= s.floor;
    }
};

pub const Range = references.Range;

/// An inline link's tail: `(`, a destination, a title, `)`.
pub const Tail = struct {
    /// The destination as written, its angle brackets taken off; empty
    /// where there is none.
    destination: Range,
    title: ?Range,
    /// Past the `)`.
    end: usize,
};

/// The inline link tail at `s[at]` (a `(`), or null.
pub fn inlineTail(s: []const u8, at: usize, work: *u64) ?Tail {
    aegis.assert.invariant(s[at] == '(', "an inline link's tail starts at a `(`");
    var i = references.spaceAndLine(s, at + 1, work);
    if (i < s.len and s[i] == ')') return .{ .destination = .{ .start = i, .end = i }, .title = null, .end = i + 1 };
    const destination = references.linkDestination(s, i, work) orelse return null;
    i = destination.after;
    var title: ?Range = null;
    const spaced = references.spaceAndLine(s, i, work);
    if (spaced != i) {
        if (references.linkTitle(s, spaced, work)) |t| {
            title = t.range;
            i = references.spaceAndLine(s, t.after, work);
        } else i = spaced;
    }
    if (i >= s.len or s[i] != ')') return null;
    return .{ .destination = destination.range, .title = title, .end = i + 1 };
}

/// A label after a link's text, at `s[at]` (a `[`): its content, spaces
/// and tabs at either end taken off (empty for `[]`), and past its `]`.
pub const Label = struct { inner: Range, end: usize };

/// A wikilink after its `[[` (or `![[`): its target, where its label starts
/// when it has one, and where its `]]` is.
pub const Wiki = struct { target: Range, label: ?usize, close: usize };

/// The wikilink whose `[[` ends at `at`: up to the first `]]`, with no other
/// bracket before it; its target, up to a `|` or the `]]`, on one line and
/// not blank; its label, after the `|`, not empty. Stops at the first
/// bracket, so each byte is read for one `[[` at most.
pub fn wikiAt(s: []const u8, at: usize, work: *u64) ?Wiki {
    var bar: ?usize = null;
    var i = at;
    while (i < s.len) : ({
        i += 1;
        work.* += 1;
    }) switch (s[i]) {
        '[' => return null,
        ']' => if (i + 1 < s.len and s[i + 1] == ']') break else return null,
        '|' => if (bar == null) {
            bar = i;
        },
        '\n' => if (bar == null) return null,
        else => {},
    };
    if (i >= s.len) return null;
    const target_end = bar orelse i;
    if (std.mem.trim(u8, s[at..target_end], " \t").len == 0) return null;
    if (bar) |b| if (b + 1 == i) return null;
    return .{ .target = .{ .start = at, .end = target_end }, .label = if (bar) |b| b + 1 else null, .close = i };
}

pub fn labelAt(s: []const u8, at: usize, work: *u64) ?Label {
    const l = references.linkLabel(s[at..], work) orelse return null;
    var start = at + l.inner.start;
    var end = at + l.inner.end;
    while (start < end and isSpace(s[start])) : (work.* += 1) start += 1;
    while (end > start and isSpace(s[end - 1])) : (work.* += 1) end -= 1;
    return .{ .inner = .{ .start = start, .end = end }, .end = at + l.end + 1 };
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

/// Fixed memory for one normalized label.
pub const Scratch = struct {
    /// The label, its whitespace runs each one space.
    collapsed: []u8,
    /// Then case folded.
    folded: []u8,

    pub const collapsed_len = references.most_label + 1;
    pub const folded_len = 3 * collapsed_len;
};

/// `label` normalized as definitions are (§6.3), or null where it is too
/// long to be a label or normalizes to nothing.
pub fn normalize(scratch: Scratch, label: []const u8) ?[]const u8 {
    if (label.len > references.most_label) return null;
    var len: usize = 0;
    var space = false;
    for (label) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            space = len != 0;
            continue;
        }
        if (space) {
            scratch.collapsed[len] = ' ';
            len += 1;
        }
        space = false;
        scratch.collapsed[len] = c;
        len += 1;
    }
    if (len == 0) return null;
    var w: std.Io.Writer = .fixed(scratch.folded);
    xenoglyph.case.write(.fold, scratch.collapsed[0..len], &w, .{}) catch return null;
    return w.buffered();
}

const testing = std.testing;

test "inline link tails as §6.3 reads them" {
    const Case = struct { []const u8, ?[]const u8, ?[]const u8 };
    const cases = [_]Case{
        .{ "(/uri \"title\")", "/uri", "title" },
        .{ "(/uri)", "/uri", null },
        .{ "()", "", null },
        .{ "(<>)", "", null },
        .{ "(<my uri>)", "my uri", null },
        .{ "(/my uri)", null, null },
        .{ "(foo(and(bar)))", "foo(and(bar))", null },
        .{ "(   /uri\n  \"title\"  )", "/uri", "title" },
        .{ "(/url \"title \"and\" title\")", null, null },
        .{ "(/url 'title \"and\" title')", "/url", "title \"and\" title" },
        .{ "(<b)c>)", "b)c", null },
    };
    for (cases) |c| {
        var work: u64 = 0;
        const t = inlineTail(c[0], 0, &work);
        if (c[1]) |d| {
            const got = t.?;
            try testing.expectEqualStrings(d, c[0][got.destination.start..got.destination.end]);
            if (c[2]) |title| try testing.expectEqualStrings(title, c[0][got.title.?.start..got.title.?.end]) else try testing.expectEqual(null, got.title);
            try testing.expectEqual(c[0].len, got.end);
        } else try testing.expectEqual(null, t);
    }
}

test "labels normalize without allocating, and a long one is none" {
    var collapsed: [Scratch.collapsed_len]u8 = undefined;
    var folded: [Scratch.folded_len]u8 = undefined;
    const scratch: Scratch = .{ .collapsed = &collapsed, .folded = &folded };
    try testing.expectEqualStrings("foo bar", normalize(scratch, "  Foo \n\t BAR ").?);
    try testing.expectEqualStrings("ss", normalize(scratch, "\u{1E9E}").?);
    try testing.expectEqual(null, normalize(scratch, " \n "));
    const long: [1000]u8 = @splat('a');
    try testing.expectEqual(null, normalize(scratch, &long));
    // U+0390 folds to three code points, six bytes for its two: the most
    // a label's bytes grow.
    var widest: [998]u8 = undefined;
    var i: usize = 0;
    while (i < widest.len) : (i += 2) @memcpy(widest[i..][0..2], "\u{390}");
    try testing.expectEqual(3 * widest.len, normalize(scratch, &widest).?.len);
}
