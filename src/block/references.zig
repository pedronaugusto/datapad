//! Link reference definitions (CommonMark 0.31.2 §4.7), read from the start
//! of a paragraph's text, its lines joined by line feeds, and the
//! normalized labels they are matched by (§6.3).
const std = @import("std");
const xenoglyph = @import("xenoglyph");
const chars = @import("../scan/chars.zig");
const Span = @import("../Span.zig");

/// A definition in the document's label table: its parts in the text, and
/// its normalized label in the table's keys.
pub const Reference = struct {
    /// The label between its brackets.
    label: Span,
    /// The destination as written, its angle brackets taken off.
    destination: Span,
    /// The title between its quotes or parentheses.
    title: ?Span,
    key: Key,

    pub const Key = struct { start: u32, len: u32 };
};

/// Where a part of a definition lies in the joined text.
pub const Range = struct { start: usize, end: usize };

/// A definition at the start of the joined text.
pub const Definition = struct {
    /// The bytes it takes, through its last line's line feed where it has one.
    len: usize,
    /// The label between its brackets.
    label: Range,
    /// The destination as written, its angle brackets taken off.
    destination: Range,
    /// The title between its quotes or parentheses.
    title: ?Range,
};

/// The longest label: 999 characters between the brackets.
const most_label = 999;

/// The definition `s` starts with, or null.
pub fn parse(s: []const u8) ?Definition {
    const label = linkLabel(s) orelse return null;
    var at = label.end + 1;
    if (at >= s.len or s[at] != ':') return null;
    at = spaceAndLine(s, at + 1);
    const destination = linkDestination(s, at) orelse return null;
    at = destination.after;
    const before_title = at;
    const spaced = spaceAndLine(s, at);
    if (spaced != before_title) {
        if (linkTitle(s, spaced)) |title| {
            if (lineEnd(s, title.after)) |end| return .{ .len = end, .label = label.inner, .destination = destination.range, .title = title.range };
        }
    }
    // No title, or one with more after it on its line: the definition ends
    // with its destination, if nothing but spaces follows that.
    const end = lineEnd(s, before_title) orelse return null;
    return .{ .len = end, .label = label.inner, .destination = destination.range, .title = null };
}

/// Past spaces and tabs and then the end of the line, line feed included;
/// null where something else comes first.
fn lineEnd(s: []const u8, from: usize) ?usize {
    var at = from;
    while (at < s.len and chars.isSpaceOrTab(s[at])) at += 1;
    if (at == s.len) return at;
    if (s[at] == '\n') return at + 1;
    return null;
}

/// Past spaces and tabs, at most one line feed, and spaces and tabs after it.
fn spaceAndLine(s: []const u8, from: usize) usize {
    var at = from;
    while (at < s.len and chars.isSpaceOrTab(s[at])) at += 1;
    if (at < s.len and s[at] == '\n') {
        at += 1;
        while (at < s.len and chars.isSpaceOrTab(s[at])) at += 1;
    }
    return at;
}

const Label = struct { inner: Range, end: usize };

/// A link label (§6.3) at the start of `s`: `[`, up to 999 characters with
/// no bracket unless escaped, `]`. `end` is the closing bracket's index.
/// Whether it holds anything but whitespace is the normalized label's to
/// say.
fn linkLabel(s: []const u8) ?Label {
    if (s.len == 0 or s[0] != '[') return null;
    var at: usize = 1;
    while (at < s.len and at - 1 <= most_label) {
        switch (s[at]) {
            ']' => return .{ .inner = .{ .start = 1, .end = at }, .end = at },
            '[' => return null,
            '\\' => at += if (at + 1 < s.len) 2 else 1,
            else => at += 1,
        }
    }
    return null;
}

const Destination = struct { range: Range, after: usize };

/// A link destination (§6.6) at `from`: between `<` and `>` with no line
/// end and no unescaped angle bracket, or a nonempty run with no space or
/// ASCII control character and its unescaped parentheses balanced.
fn linkDestination(s: []const u8, from: usize) ?Destination {
    if (from >= s.len) return null;
    if (s[from] == '<') {
        var at = from + 1;
        while (at < s.len) {
            switch (s[at]) {
                '>' => return .{ .range = .{ .start = from + 1, .end = at }, .after = at + 1 },
                '<', '\n' => return null,
                '\\' => at += if (at + 1 < s.len and s[at + 1] != '\n') 2 else 1,
                else => at += 1,
            }
        }
        return null;
    }
    var at = from;
    var open: usize = 0;
    while (at < s.len) {
        const c = s[at];
        if (c <= ' ' or c == 0x7f) break;
        if (c == '\\' and at + 1 < s.len and chars.isAsciiPunctuation(s[at + 1])) {
            at += 2;
        } else if (c == '(') {
            open += 1;
            at += 1;
        } else if (c == ')') {
            if (open == 0) break;
            open -= 1;
            at += 1;
        } else at += 1;
    }
    if (at == from or open != 0) return null;
    return .{ .range = .{ .start = from, .end = at }, .after = at };
}

const Title = struct { range: Range, after: usize };

/// A link title (§6.6) at `from`: between `"` or `'` with that quote only
/// escaped inside, or between parentheses with neither unescaped inside.
/// It may run over lines, but a paragraph's text has no blank one.
fn linkTitle(s: []const u8, from: usize) ?Title {
    if (from >= s.len) return null;
    const close: u8 = switch (s[from]) {
        '"' => '"',
        '\'' => '\'',
        '(' => ')',
        else => return null,
    };
    var at = from + 1;
    while (at < s.len) {
        const c = s[at];
        if (c == '\\' and at + 1 < s.len and chars.isAsciiPunctuation(s[at + 1])) {
            at += 2;
        } else if (c == close) {
            return .{ .range = .{ .start = from + 1, .end = at }, .after = at + 1 };
        } else if (close == ')' and c == '(') {
            return null;
        } else at += 1;
    }
    return null;
}

/// A label as links are matched by it (§6.3): its whitespace runs (spaces,
/// tabs, line ends) each one space, none at either end, then Unicode case
/// folded. Empty for a label of whitespace alone, which defines nothing.
pub fn normalize(label: []const u8, w: *std.Io.Writer, scratch: *std.ArrayList(u8), gpa: std.mem.Allocator) (std.Io.Writer.Error || error{OutOfMemory})!void {
    scratch.clearRetainingCapacity();
    var space = false;
    for (label) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            space = scratch.items.len != 0;
            continue;
        }
        if (space) try scratch.append(gpa, ' ');
        space = false;
        try scratch.append(gpa, c);
    }
    try xenoglyph.case.write(.fold, scratch.items, w, .{});
}

const testing = std.testing;

fn expectDefinition(s: []const u8, label: []const u8, destination: []const u8, title: ?[]const u8, len: usize) !void {
    const d = parse(s) orelse return error.TestExpectedDefinition;
    try testing.expectEqualStrings(label, s[d.label.start..d.label.end]);
    try testing.expectEqualStrings(destination, s[d.destination.start..d.destination.end]);
    if (title) |t| {
        const r = d.title orelse return error.TestExpectedTitle;
        try testing.expectEqualStrings(t, s[r.start..r.end]);
    } else try testing.expectEqual(null, d.title);
    try testing.expectEqual(len, d.len);
}

test "definitions as §4.7 reads them" {
    try expectDefinition("[foo]: /url \"title\"", "foo", "/url", "title", 19);
    try expectDefinition("[Foo bar]:\n<my url>\n'title'\nrest", "Foo bar", "my url", "title", 28);
    try expectDefinition("[foo]: /url 'title\n\nline1\nline2\n'", "foo", "/url", "title\n\nline1\nline2\n", 33);
    try expectDefinition("[foo]:\n/url\n", "foo", "/url", null, 12);
    try expectDefinition("[foo]: <>", "foo", "", null, 9);
    try expectDefinition("[foo]: /url\\bar\\*baz \"foo\\\"bar\\baz\"", "foo", "/url\\bar\\*baz", "foo\\\"bar\\baz", 35);
    // A title with more after it on its line is no title; the definition
    // ends at the destination's line end where it can.
    try expectDefinition("[foo]: /url\n\"title\" ok", "foo", "/url", null, 12);
    try testing.expectEqual(null, parse("[foo]: /url \"title\" ok"));
    try testing.expectEqual(null, parse("[foo]:"));
    try testing.expectEqual(null, parse("[foo]: <bar>(baz)"));
    try expectDefinition("[foo]:/url\"title\"", "foo", "/url\"title\"", null, 17);
    try testing.expectEqual(null, parse("[foo]: <bar\n>"));
    try testing.expectEqual(null, parse("[f[o]o]: /url"));
    try expectDefinition("[f\\]o]: /url", "f\\]o", "/url", null, 12);
    // Unbalanced parentheses end no destination.
    try testing.expectEqual(null, parse("[foo]: /u(rl"));
    try expectDefinition("[foo]: /u(r)l", "foo", "/u(r)l", null, 13);
}

test "a label is at most 999 characters" {
    var buffer: [1006]u8 = undefined;
    buffer[0] = '[';
    @memset(buffer[1..1000], 'a');
    @memcpy(buffer[1000..1006], "]: /u\n");
    try testing.expect(parse(&buffer) != null);
    var longer: [1007]u8 = undefined;
    longer[0] = '[';
    @memset(longer[1..1001], 'a');
    @memcpy(longer[1001..1007], "]: /u\n");
    try testing.expectEqual(null, parse(&longer));
}

test "labels are matched collapsed and case folded" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    try normalize("  Foo \t\n  BAR ", &out.writer, &scratch, testing.allocator);
    try testing.expectEqualStrings("foo bar", out.written());
    out.clearRetainingCapacity();
    try normalize("ẞ", &out.writer, &scratch, testing.allocator);
    try testing.expectEqualStrings("ss", out.written());
    out.clearRetainingCapacity();
    try normalize(" \n ", &out.writer, &scratch, testing.allocator);
    try testing.expectEqualStrings("", out.written());
}
