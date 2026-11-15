//! Raw inline HTML (CommonMark 0.31.2 §6.6): an open tag, a closing tag, a
//! comment, a processing instruction, a declaration or a CDATA section, at
//! a `<` of a leaf's joined text.
//!
//! Each kind but the tags ends at a fixed string (`-->`, `?>`, `]]>`, `>`),
//! and a quoted attribute value at its quote. A search that finds none has
//! shown that none follows where it began, so `Scan` remembers it and any
//! later search from as far on fails at once: a leaf of many openers and no
//! closer costs its length, not its length times its openers.
const std = @import("std");
const aegis = @import("aegis");

/// What the searches of one leaf have shown: past these offsets, the
/// string named is nowhere in the text.
pub const Scan = struct {
    comment: usize = std.math.maxInt(usize),
    instruction: usize = std.math.maxInt(usize),
    cdata: usize = std.math.maxInt(usize),
    declaration: usize = std.math.maxInt(usize),
    double_quote: usize = std.math.maxInt(usize),
    single_quote: usize = std.math.maxInt(usize),

    /// Where `needle` next starts at or after `from`, remembering a miss
    /// in `none_after`.
    fn find(s: []const u8, from: usize, needle: []const u8, none_after: *usize) ?usize {
        if (from >= none_after.*) return null;
        if (std.mem.find(u8, s[from..], needle)) |at| return from + at;
        none_after.* = from;
        return null;
    }
};

/// Where the raw HTML starting at `s[at]` (a `<`) ends, or null.
pub fn end(scan: *Scan, s: []const u8, at: usize) ?usize {
    aegis.assert.invariant(s[at] == '<', "raw HTML starts at a `<`");
    const rest = s[at + 1 ..];
    if (rest.len == 0) return null;
    switch (rest[0]) {
        '!' => {
            if (std.mem.startsWith(u8, rest, "!--")) {
                // `<!-->` and `<!--->` are comments, as HTML reads them.
                if (std.mem.startsWith(u8, rest, "!-->")) return at + 5;
                if (std.mem.startsWith(u8, rest, "!--->")) return at + 6;
                const close = Scan.find(s, at + 4, "-->", &scan.comment) orelse return null;
                return close + 3;
            }
            if (std.mem.startsWith(u8, rest, "![CDATA[")) {
                const close = Scan.find(s, at + 9, "]]>", &scan.cdata) orelse return null;
                return close + 3;
            }
            if (rest.len > 1 and std.ascii.isAlphabetic(rest[1])) {
                const close = Scan.find(s, at + 2, ">", &scan.declaration) orelse return null;
                return close + 1;
            }
            return null;
        },
        '?' => {
            const close = Scan.find(s, at + 2, "?>", &scan.instruction) orelse return null;
            return close + 2;
        },
        '/' => {
            var i = at + 2;
            if (i >= s.len or !std.ascii.isAlphabetic(s[i])) return null;
            while (i < s.len and isNameByte(s[i])) i += 1;
            i = space(s, i);
            return if (i < s.len and s[i] == '>') i + 1 else null;
        },
        else => return openTag(scan, s, at),
    }
}

fn isNameByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-';
}

/// Whitespace in a tag: spaces, tabs and line feeds (a paragraph's text
/// has no blank line, so never two line endings with nothing between).
fn space(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n')) i += 1;
    return i;
}

fn openTag(scan: *Scan, s: []const u8, at: usize) ?usize {
    var i = at + 1;
    if (i >= s.len or !std.ascii.isAlphabetic(s[i])) return null;
    while (i < s.len and isNameByte(s[i])) i += 1;
    while (true) {
        const before = i;
        i = space(s, i);
        if (i >= s.len) return null;
        if (s[i] == '>') return i + 1;
        if (s[i] == '/') return if (i + 1 < s.len and s[i + 1] == '>') i + 2 else null;
        // An attribute starts after whitespace.
        if (i == before) return null;
        if (!(std.ascii.isAlphabetic(s[i]) or s[i] == '_' or s[i] == ':')) return null;
        while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_' or s[i] == '.' or s[i] == ':' or s[i] == '-')) i += 1;
        // An optional value: whitespace, `=`, whitespace, the value.
        var j = space(s, i);
        if (j >= s.len or s[j] != '=') continue;
        j = space(s, j + 1);
        if (j >= s.len) return null;
        switch (s[j]) {
            '"' => i = (Scan.find(s, j + 1, "\"", &scan.double_quote) orelse return null) + 1,
            '\'' => i = (Scan.find(s, j + 1, "'", &scan.single_quote) orelse return null) + 1,
            else => {
                const start = j;
                while (j < s.len and !(s[j] == ' ' or s[j] == '\t' or s[j] == '\n') and std.mem.findScalar(u8, "\"'=<>`", s[j]) == null) j += 1;
                if (j == start) return null;
                i = j;
            },
        }
    }
}

const testing = std.testing;

fn expectEnd(s: []const u8, expected: ?usize) !void {
    var scan: Scan = .{};
    try testing.expectEqual(expected, end(&scan, s, 0));
}

test "the six kinds of raw HTML, and what each refuses" {
    try expectEnd("<a><bab><c2c>", 3);
    try expectEnd("<a/>", 4);
    try expectEnd("<a  /><b2\ndata=\"foo\" >", 6);
    try expectEnd("<a foo=\"bar\" bam = 'baz <em>\"</em>'\n_boolean zoop:33=zoop:33 />", 63);
    try expectEnd("<responsive-image src=\"foo.jpg\" />", 34);
    try expectEnd("<33>", null);
    try expectEnd("<__>", null);
    try expectEnd("<a h*#ref=\"hi\">", null);
    try expectEnd("<a href=\"hi'>", null);
    try expectEnd("<a href=hi'>", null);
    try expectEnd("<a href='bar'title=title>", null);
    try expectEnd("</a></foo >", 4);
    try expectEnd("</a href=\"foo\">", null);
    try expectEnd("<!-- this is a --\ncomment - with hyphens -->", 44);
    try expectEnd("<!-->", 5);
    try expectEnd("<!--->", 6);
    try expectEnd("<?php echo $a; ?>", 17);
    try expectEnd("<!ELEMENT br EMPTY>", 19);
    try expectEnd("<![CDATA[>&<]]>", 15);
    try expectEnd("<!>", null);
}

test "a search that missed is not made again" {
    var scan: Scan = .{};
    const s = "<!-- a <!-- b";
    try testing.expectEqual(null, end(&scan, s, 0));
    try testing.expectEqual(4, scan.comment);
    try testing.expectEqual(null, end(&scan, s, 7));
}
