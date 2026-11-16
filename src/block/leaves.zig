//! The block starts CommonMark 0.31.2 recognizes on a line, each read from
//! the line's rest after up to three spaces of indentation: thematic
//! breaks, ATX headings, setext underlines, code fences, HTML block starts
//! and ends, and list markers.
const std = @import("std");
const chars = @import("../scan/chars.zig");
const Block = @import("Block.zig");

fn blankFrom(s: []const u8, i: usize) bool {
    for (s[i..]) |c| if (!chars.isSpaceOrTab(c)) return false;
    return true;
}

pub fn isBlank(s: []const u8) bool {
    return blankFrom(s, 0);
}

/// Three or more `*`, `-` or `_`, alike, with only spaces and tabs between
/// and after (§4.1).
pub fn thematicBreak(s: []const u8) bool {
    if (s.len == 0) return false;
    const c = s[0];
    if (c != '*' and c != '-' and c != '_') return false;
    var count: usize = 0;
    for (s) |b| {
        if (b == c) {
            count += 1;
        } else if (!chars.isSpaceOrTab(b)) return false;
    }
    return count >= 3;
}

/// An ATX heading (§4.2): its level and its content, within `s`, with the
/// closing sequence taken off.
pub const Atx = struct { level: Block.Level, start: usize, end: usize };

pub fn atx(s: []const u8) ?Atx {
    var hashes: u8 = 0;
    while (hashes < s.len and hashes < 7 and s[hashes] == '#') hashes += 1;
    const level = Block.Level.init(hashes) catch return null;
    if (hashes < s.len and !chars.isSpaceOrTab(s[hashes])) return null;
    var start: usize = hashes;
    while (start < s.len and chars.isSpaceOrTab(s[start])) start += 1;
    var end = s.len;
    while (end > start and chars.isSpaceOrTab(s[end - 1])) end -= 1;
    // A closing run of `#`, preceded by a space or tab (or the whole content).
    var closing = end;
    while (closing > start and s[closing - 1] == '#') closing -= 1;
    if (closing < end and (closing == start or chars.isSpaceOrTab(s[closing - 1]))) {
        end = closing;
        while (end > start and chars.isSpaceOrTab(s[end - 1])) end -= 1;
    }
    return .{ .level = level, .start = start, .end = end };
}

/// A setext underline (§4.3): its heading's level.
pub fn setextUnderline(s: []const u8) ?Block.Level {
    if (s.len == 0 or (s[0] != '=' and s[0] != '-')) return null;
    var i: usize = 0;
    while (i < s.len and s[i] == s[0]) i += 1;
    if (!blankFrom(s, i)) return null;
    return if (s[0] == '=') .literal(1) else .literal(2);
}

/// A code fence's opening (§4.5): its character, its length, and its info
/// string, trimmed, within `s`.
pub const Fence = struct { char: u8, len: usize, info_start: usize, info_end: usize };

pub fn fenceOpen(s: []const u8) ?Fence {
    if (s.len < 3 or (s[0] != '`' and s[0] != '~')) return null;
    const c = s[0];
    var n: usize = 0;
    while (n < s.len and s[n] == c) n += 1;
    if (n < 3) return null;
    var start = n;
    while (start < s.len and chars.isSpaceOrTab(s[start])) start += 1;
    var end = s.len;
    while (end > start and chars.isSpaceOrTab(s[end - 1])) end -= 1;
    // A backtick fence's info string holds no backtick.
    if (c == '`' and std.mem.findScalar(u8, s[start..end], '`') != null) return null;
    return .{ .char = c, .len = n, .info_start = start, .info_end = end };
}

/// Whether `s` closes a fence of `char` at least `len` long.
pub fn fenceClose(s: []const u8, char: u8, len: usize) bool {
    var n: usize = 0;
    while (n < s.len and s[n] == char) n += 1;
    return n >= len and blankFrom(s, n);
}

/// A list item's marker (§5.2): bullet or ordered, its start number, the
/// delimiter or bullet character, and its width.
pub const Marker = struct { ordered: bool, start: u32, char: u8, width: usize };

pub fn listMarker(s: []const u8) ?Marker {
    if (s.len == 0) return null;
    if (s[0] == '-' or s[0] == '+' or s[0] == '*') {
        if (s.len > 1 and !chars.isSpaceOrTab(s[1])) return null;
        return .{ .ordered = false, .start = 0, .char = s[0], .width = 1 };
    }
    var n: usize = 0;
    var value: u32 = 0;
    while (n < s.len and n < 10 and std.ascii.isDigit(s[n])) : (n += 1) value = value * 10 + (s[n] - '0');
    if (n == 0 or n > 9 or n >= s.len) return null;
    if (s[n] != '.' and s[n] != ')') return null;
    if (n + 1 < s.len and !chars.isSpaceOrTab(s[n + 1])) return null;
    return .{ .ordered = true, .start = value, .char = s[n], .width = n + 1 };
}

/// The kind (1 to 7) of HTML block `s` starts (§4.6), or null; kind 7
/// cannot interrupt a paragraph, so `interrupting` leaves it out.
pub fn htmlStart(s: []const u8, interrupting: bool) ?Block.HtmlKind {
    if (s.len < 2 or s[0] != '<') return null;
    const raw = [_][]const u8{ "pre", "script", "style", "textarea" };
    for (raw) |name| if (tagAt(s, 1, name)) |after| {
        if (after == s.len or s[after] == '>' or chars.isSpaceOrTab(s[after])) return .literal(1);
    };
    if (std.mem.startsWith(u8, s, "<!--")) return .literal(2);
    if (std.mem.startsWith(u8, s, "<?")) return .literal(3);
    if (s.len > 2 and s[1] == '!' and std.ascii.isAlphabetic(s[2])) return .literal(4);
    if (std.mem.startsWith(u8, s, "<![CDATA[")) return .literal(5);
    const at: usize = if (s[1] == '/') 2 else 1;
    for (block_names) |name| if (tagAt(s, at, name)) |after| {
        if (after == s.len or s[after] == '>' or chars.isSpaceOrTab(s[after]) or std.mem.startsWith(u8, s[after..], "/>")) return .literal(6);
    };
    if (!interrupting) if (completeTag(s)) |end| if (blankFrom(s, end)) return .literal(7);
    return null;
}

/// Whether the line `s` ends an HTML block of `kind` (1 to 5; 6 and 7 end
/// at a blank line).
pub fn htmlEnd(kind: Block.HtmlKind, s: []const u8) bool {
    return switch (kind.widen(u8)) {
        1 => containsIgnoreCase(s, "</script>") or containsIgnoreCase(s, "</pre>") or containsIgnoreCase(s, "</style>") or containsIgnoreCase(s, "</textarea>"),
        2 => std.mem.find(u8, s, "-->") != null,
        3 => std.mem.find(u8, s, "?>") != null,
        4 => std.mem.findScalar(u8, s, '>') != null,
        5 => std.mem.find(u8, s, "]]>") != null,
        else => false,
    };
}

fn containsIgnoreCase(s: []const u8, needle: []const u8) bool {
    if (s.len < needle.len) return false;
    for (0..s.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(s[i..][0..needle.len], needle)) return true;
    return false;
}

/// Where `name`, matched without regard to case, ends after `at`.
fn tagAt(s: []const u8, at: usize, name: []const u8) ?usize {
    if (s.len < at + name.len) return null;
    if (!std.ascii.eqlIgnoreCase(s[at..][0..name.len], name)) return null;
    return at + name.len;
}

const block_names = [_][]const u8{
    "address",  "article",    "aside",  "base",    "basefont", "blockquote", "body",     "caption",  "center",
    "col",      "colgroup",   "dd",     "details", "dialog",   "dir",        "div",      "dl",       "dt",
    "fieldset", "figcaption", "figure", "footer",  "form",     "frame",      "frameset", "h1",       "h2",
    "h3",       "h4",         "h5",     "h6",      "head",     "header",     "hr",       "html",     "iframe",
    "legend",   "li",         "link",   "main",    "menu",     "menuitem",   "nav",      "noframes", "ol",
    "optgroup", "option",     "p",      "param",   "search",   "section",    "summary",  "table",    "tbody",
    "td",       "tfoot",      "th",     "thead",   "title",    "tr",         "track",    "ul",
};

/// A complete open tag or closing tag at the start of `s` (§6.6): where it
/// ends.
pub fn completeTag(s: []const u8) ?usize {
    if (s.len < 3 or s[0] != '<') return null;
    var i: usize = 1;
    const closing = s[i] == '/';
    if (closing) i += 1;
    if (i >= s.len or !std.ascii.isAlphabetic(s[i])) return null;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '-')) i += 1;
    if (closing) {
        while (i < s.len and isTagSpace(s[i])) i += 1;
        return if (i < s.len and s[i] == '>') i + 1 else null;
    }
    // Attributes, each after whitespace.
    while (true) {
        const before = i;
        while (i < s.len and isTagSpace(s[i])) i += 1;
        if (i >= s.len) return null;
        if (s[i] == '>') return i + 1;
        if (s[i] == '/') return if (i + 1 < s.len and s[i + 1] == '>') i + 2 else null;
        if (i == before) return null;
        // An attribute name.
        if (!(std.ascii.isAlphabetic(s[i]) or s[i] == '_' or s[i] == ':')) return null;
        while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_' or s[i] == '.' or s[i] == ':' or s[i] == '-')) i += 1;
        // An optional value.
        var j = i;
        while (j < s.len and isTagSpace(s[j])) j += 1;
        if (j < s.len and s[j] == '=') {
            j += 1;
            while (j < s.len and isTagSpace(s[j])) j += 1;
            if (j >= s.len) return null;
            if (s[j] == '"' or s[j] == '\'') {
                const end = std.mem.findScalarPos(u8, s, j + 1, s[j]) orelse return null;
                i = end + 1;
            } else {
                const start = j;
                while (j < s.len and !isTagSpace(s[j]) and std.mem.findScalar(u8, "\"'=<>`", s[j]) == null) j += 1;
                if (j == start) return null;
                i = j;
            }
        }
    }
}

fn isTagSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C;
}

/// A table cell's bytes in its row (GFM), spaces and tabs trimmed.
pub const Cell = struct { start: usize, end: usize };

/// The cells of a table row (GFM): split at each pipe no backslash
/// escapes, a leading and a trailing pipe taken off, each cell trimmed.
pub const Cells = struct {
    row: []const u8,
    at: usize,
    end: usize,
    done: bool = false,

    pub fn init(row: []const u8) Cells {
        var start: usize = 0;
        var end = row.len;
        while (start < end and chars.isSpaceOrTab(row[start])) start += 1;
        while (end > start and chars.isSpaceOrTab(row[end - 1])) end -= 1;
        if (start < end and row[start] == '|') start += 1;
        if (end > start and row[end - 1] == '|' and !escaped(row, end - 1)) end -= 1;
        return .{ .row = row, .at = start, .end = end };
    }

    pub fn next(c: *Cells) ?Cell {
        if (c.done) return null;
        var i = c.at;
        while (i < c.end) : (i += 1) {
            if (c.row[i] == '\\') {
                i += 1;
                continue;
            }
            if (c.row[i] == '|') break;
        }
        const pipe = @min(i, c.end);
        var start = c.at;
        var end = pipe;
        while (start < end and chars.isSpaceOrTab(c.row[start])) start += 1;
        while (end > start and chars.isSpaceOrTab(c.row[end - 1])) end -= 1;
        if (pipe >= c.end) c.done = true else c.at = pipe + 1;
        return .{ .start = start, .end = end };
    }

    /// How many cells the row has.
    pub fn count(row: []const u8) usize {
        var c: Cells = .init(row);
        var n: usize = 0;
        while (c.next()) |_| n += 1;
        return n;
    }
};

/// Whether the byte at `i` follows an odd run of backslashes.
fn escaped(s: []const u8, i: usize) bool {
    var n: usize = 0;
    while (n < i and s[i - 1 - n] == '\\') n += 1;
    return n % 2 == 1;
}

/// A table's delimiter row (GFM): cells of hyphens, each with a colon
/// before or after or both, and around them the whitespace of CommonMark
/// 0.29, which GFM's spec reads (a line tabulation and a form feed too).
/// No pipe is needed, as cmark-gfm reads it: a row of hyphens alone under
/// a paragraph is a setext heading's underline, which the block pass reads
/// first. Its cell count.
pub fn delimiterRow(row: []const u8) ?usize {
    var cells: Cells = .init(row);
    var n: usize = 0;
    while (cells.next()) |cell| {
        var body = std.mem.trim(u8, row[cell.start..cell.end], " \t\x0b\x0c");
        if (body.len != 0 and body[0] == ':') body = body[1..];
        if (body.len != 0 and body[body.len - 1] == ':') body = body[0 .. body.len - 1];
        if (body.len == 0) return null;
        for (body) |c| if (c != '-') return null;
        n += 1;
    }
    return if (n == 0) null else n;
}

const testing = std.testing;

test "a table row's cells and a delimiter row" {
    const row = "| a | b\\|c |  `x` |";
    var cells: Cells = .init(row);
    try testing.expectEqualStrings("a", row[cells.next().?.start..][0..1]);
    const second = cells.next().?;
    try testing.expectEqualStrings("b\\|c", row[second.start..second.end]);
    const third = cells.next().?;
    try testing.expectEqualStrings("`x`", row[third.start..third.end]);
    try testing.expectEqual(null, cells.next());
    try testing.expectEqual(2, Cells.count("abc | def"));
    try testing.expectEqual(2, delimiterRow(":-: | -----------:"));
    try testing.expectEqual(1, delimiterRow("| ------ |"));
    // Under a paragraph, `---` is a setext underline first; a row of one cell otherwise.
    try testing.expectEqual(1, delimiterRow("---"));
    try testing.expectEqual(1, delimiterRow("-\x0b"));
    try testing.expectEqual(null, delimiterRow("| -x- |"));
}

test "the block starts each recognizer reads" {
    try testing.expect(thematicBreak("***"));
    try testing.expect(thematicBreak("- - -"));
    try testing.expect(!thematicBreak("--"));
    try testing.expect(!thematicBreak("**-"));
    const h = atx("## Foo ##").?;
    try testing.expect(h.level.eql(.literal(2)));
    try testing.expectEqualStrings("Foo", "## Foo ##"[h.start..h.end]);
    try testing.expect(atx("#5 bolt") == null);
    try testing.expect(atx("####### foo") == null);
    const e = atx("### foo #bar").?;
    try testing.expectEqualStrings("foo #bar", "### foo #bar"[e.start..e.end]);
    try testing.expect(setextUnderline("===").?.eql(.literal(1)));
    try testing.expect(setextUnderline("= =") == null);
    const f = fenceOpen("```  zig  ").?;
    try testing.expectEqualStrings("zig", "```  zig  "[f.info_start..f.info_end]);
    try testing.expect(fenceOpen("``` a`b") == null);
    try testing.expect(fenceClose("````  ", '`', 3));
    try testing.expect(!fenceClose("``", '`', 3));
    try testing.expectEqual(3, listMarker("10. x").?.width);
    try testing.expect(listMarker("-x") == null);
    try testing.expect(listMarker("1234567890. x") == null);
    try testing.expect(htmlStart("<script>", false).?.eql(.literal(1)));
    try testing.expect(htmlStart("<div class=\"x\">", false).?.eql(.literal(6)));
    try testing.expect(htmlStart("<a href=\"x\">", false).?.eql(.literal(7)));
    try testing.expect(htmlStart("<a href=\"x\">", true) == null);
    try testing.expect(htmlStart("<a href=\"x\"> text", false) == null);
    try testing.expect(htmlEnd(.literal(2), "end -->"));
}
