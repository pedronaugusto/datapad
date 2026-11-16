//! The inputs that make Markdown parsers slow, held to a bound on work, not
//! on time, so the gate is deterministic: the block pass's steps and the
//! inline pass's (`Document.stats`, `Events.work`), every scan's bytes
//! counted, stay within a fixed number per input byte. A construct that
//! rescans what it read grows past the bound as its input grows.
//!
//! The cases are cmark's and cmark-gfm's pathological tests
//! (test/pathological_tests.py; Copyright (c) 2014, John MacFarlane, under
//! the BSD 2-Clause licence, LICENSES/cmark-BSD-2-Clause.txt), rewritten in
//! Zig at a quarter of their sizes or less, each with the HTML cmark's test
//! expects, and datapad's own shapes for its extensions after them. Where
//! cmark nests 25,000 deep, datapad refuses past `Limits.depth` (at most
//! 1024), and the case is run at the limit and refused past it.
const std = @import("std");
const Document = @import("Document.zig");
const Events = @import("Events.zig");
const Limits = @import("Limits.zig");
const Extensions = @import("Options.zig").Extensions;
const html = @import("html.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;

/// The most steps per input byte. The heaviest shape, `[a](b` repeated, reads
/// each destination up to its 33rd `(`: about 39.
const per_byte = 48;

const deepest: Limits = .{ .depth = .literal(1024) };

/// `piece` `n` times, then `tail`.
fn repeat(gpa: Allocator, piece: []const u8, n: usize, tail: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, piece.len * n + tail.len);
    for (0..n) |i| @memcpy(out[i * piece.len ..][0..piece.len], piece);
    @memcpy(out[piece.len * n ..], tail);
    return out;
}

/// The pieces, each repeated as many times as given, joined.
fn join(gpa: Allocator, parts: []const struct { []const u8, usize }) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (parts) |p| for (0..p[1]) |_| try out.appendSlice(gpa, p[0]);
    return out.toOwnedSlice(gpa);
}

/// Parses `text`, writes its HTML, and holds the work to the bound and the
/// HTML to `want` (null: unchecked). Shows where the HTML first differs.
fn expectCase(name: []const u8, text: []const u8, extensions: Extensions, limits: Limits, want: ?[]const u8) !void {
    const gpa = testing.allocator;
    var document = try Document.parse(gpa, .init(text), .{ .extensions = extensions, .limits = limits });
    defer document.deinit();
    var events = try Events.init(gpa, &document);
    defer events.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try html.write(&out.writer, &events, .{});
    const work = document.stats().work + events.work();
    if (work > per_byte * text.len + 1024) {
        std.log.err("{s}: {d} steps over {d} bytes", .{ name, work, text.len });
        return error.TestWorkNotLinear;
    }
    const w = want orelse return;
    const got = out.written();
    if (std.mem.eql(u8, w, got)) return;
    const at = std.mem.findDiff(u8, w, got) orelse @min(w.len, got.len);
    const from = at -| 40;
    std.log.err("{s}: the HTML differs at byte {d}\n--- want\n{f}\n--- got\n{f}", .{ name, at, std.zig.fmtString(w[from..@min(w.len, at + 40)]), std.zig.fmtString(got[from..@min(got.len, at + 40)]) });
    return error.TestExpectedEqual;
}

/// A paragraph of `inner`.
fn para(gpa: Allocator, inner: []const u8) ![]u8 {
    return std.mem.concat(gpa, u8, &.{ "<p>", inner, "</p>\n" });
}

test "emphasis: nested, unmatched, mismatched, and the rule of 3" {
    const gpa = testing.allocator;
    const n = 8000;
    {
        const text = try join(gpa, &.{ .{ "*a **a ", n }, .{ "b", 1 }, .{ " a** a*", n } });
        defer gpa.free(text);
        const inner = try join(gpa, &.{ .{ "<em>a <strong>a ", n }, .{ "b", 1 }, .{ " a</strong> a</em>", n } });
        defer gpa.free(inner);
        const want = try para(gpa, inner);
        defer gpa.free(want);
        try expectCase("nested strong emph", text, .commonmark, .{}, want);
    }
    // The paragraph's last space is not its content.
    const runs = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "many emph closers with no openers", "a_ ", "a_" },
        .{ "many emph openers with no closers", "_a ", "_a" },
        .{ "mismatched openers and closers", "*a_ ", "*a_" },
    };
    for (runs) |r| {
        const text = try repeat(gpa, r[1], n, "");
        defer gpa.free(text);
        const inner = try repeat(gpa, r[1], n - 1, r[2]);
        defer gpa.free(inner);
        const want = try para(gpa, inner);
        defer gpa.free(want);
        try expectCase(r[0], text, .commonmark, .{}, want);
    }
    {
        const text = try join(gpa, &.{ .{ "*a ", 5000 }, .{ "_a*_ ", 5000 } });
        defer gpa.free(text);
        const inner = try join(gpa, &.{ .{ "<em>a ", 5000 }, .{ "_a</em>_ ", 4999 }, .{ "_a</em>_", 1 } });
        defer gpa.free(inner);
        const want = try para(gpa, inner);
        defer gpa.free(want);
        try expectCase("issue #389", text, .commonmark, .{}, want);
    }
    {
        const text = try join(gpa, &.{ .{ "a**b", 1 }, .{ "c* ", n } });
        defer gpa.free(text);
        const inner = try join(gpa, &.{ .{ "a**b", 1 }, .{ "c* ", n - 1 }, .{ "c*", 1 } });
        defer gpa.free(inner);
        const want = try para(gpa, inner);
        defer gpa.free(want);
        try expectCase("openers and closers multiple of 3", text, .commonmark, .{}, want);
    }
    {
        // Nested 20,000 deep: cmark's test of its CommonMark writer; datapad reads it as text and emphasis.
        const text = try join(gpa, &.{ .{ "*", 5000 }, .{ "a", 1 }, .{ "*", 5000 } });
        defer gpa.free(text);
        try expectCase("nested inlines", text, .commonmark, .{}, null);
    }
}

test "links: brackets and tails unmatched, unclosed, nested, and an image's" {
    const gpa = testing.allocator;
    const n = 8000;
    const literal = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "many link closers with no openers", "a]", "a]" },
        .{ "many link openers with no closers", "[a", "[a" },
        .{ "link openers and emph closers", "[ a_", "[ a_" },
        .{ "pattern [ (]( repeated", "[ (](", "[ (](" },
        .{ "unclosed links A", "[a](<b", "[a](&lt;b" },
        .{ "unclosed links B", "[a](b", "[a](b" },
        .{ "pattern ![[]() repeated", "![[]()", "![<a href=\"\"></a>" },
    };
    for (literal) |l| {
        const text = try repeat(gpa, l[1], n, "");
        defer gpa.free(text);
        const inner = try repeat(gpa, l[2], n, "");
        defer gpa.free(inner);
        const want = try para(gpa, inner);
        defer gpa.free(want);
        try expectCase(l[0], text, .commonmark, .{}, want);
    }
    try expectCase("hard link/emph case", "**x [a*b**c*](d)", .commonmark, .{}, "<p>**x <a href=\"d\">a<em>b**c</em></a></p>\n");
    {
        const text = try join(gpa, &.{ .{ "[", 6000 }, .{ "a", 1 }, .{ "]", 6000 } });
        defer gpa.free(text);
        const want = try para(gpa, text);
        defer gpa.free(want);
        try expectCase("nested brackets", text, .commonmark, .{}, want);
    }
    {
        // Each definition is used by a label no definition has: cmark's hash collisions, here a sorted table.
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        var want: std.ArrayList(u8) = .empty;
        defer want.deinit(gpa);
        for (1..6000) |i| {
            try text.print(gpa, "[x{d}]: /url\n\n[x0]\n\n", .{i});
            try want.appendSlice(gpa, "<p>[x0]</p>\n");
        }
        try expectCase("reference collisions", text.items, .commonmark, .{}, want.items);
    }
}

test "blocks nested as deep as the limit allows, and refused past it" {
    const gpa = testing.allocator;
    const depth = 1000;
    {
        const text = try repeat(gpa, "> ", depth, "a");
        defer gpa.free(text);
        const want = try join(gpa, &.{ .{ "<blockquote>\n", depth }, .{ "<p>a</p>\n", 1 }, .{ "</blockquote>\n", depth } });
        defer gpa.free(want);
        try expectCase("nested block quotes", text, .commonmark, deepest, want);
        // cmark's 25,000 is past any limit datapad takes: refused, at the quote past the limit.
        const deeper = try repeat(gpa, "> ", 25000, "a");
        defer gpa.free(deeper);
        var diagnostic: Limits.Diagnostic = undefined;
        try testing.expectError(error.TooDeep, Document.parse(gpa, .init(deeper), .{ .limits = deepest, .diagnostics = &diagnostic }));
        try testing.expectEqual(Limits.Limit.depth, diagnostic.limit);
        try testing.expectEqual(@as(u32, 2048), diagnostic.offset.raw());
    }
    {
        // A list and its item each count: 500 levels are 1000 containers.
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        for (0..500) |x| {
            try text.appendNTimes(gpa, ' ', 2 * x);
            try text.appendSlice(gpa, "* a\n");
        }
        const want = try join(gpa, &.{ .{ "<ul>\n", 1 }, .{ "<li>a\n<ul>\n", 499 }, .{ "<li>a</li>\n</ul>\n", 1 }, .{ "</li>\n</ul>\n", 499 } });
        defer gpa.free(want);
        try expectCase("deeply nested lists", text.items, .commonmark, deepest, want);
    }
    {
        const text = try join(gpa, &.{ .{ "- ", 500 }, .{ "x", 1 }, .{ "\n", 30000 } });
        defer gpa.free(text);
        // A list that starts an item starts a line of its own, as cmark writes it.
        const want = try join(gpa, &.{ .{ "<ul>\n<li>\n", 499 }, .{ "<ul>\n<li>x</li>\n</ul>\n", 1 }, .{ "</li>\n</ul>\n", 499 } });
        defer gpa.free(want);
        try expectCase("empty lines in deeply nested lists", text, .commonmark, deepest, want);
    }
    {
        const text = try join(gpa, &.{ .{ "> ", 1 }, .{ "- ", 500 }, .{ "x\n", 1 }, .{ ">\n", 30000 } });
        defer gpa.free(text);
        const want = try join(gpa, &.{ .{ "<blockquote>\n", 1 }, .{ "<ul>\n<li>\n", 499 }, .{ "<ul>\n<li>x</li>\n</ul>\n", 1 }, .{ "</li>\n</ul>\n", 499 }, .{ "</blockquote>\n", 1 } });
        defer gpa.free(want);
        try expectCase("empty lines in deeply nested lists in blockquote", text, .commonmark, deepest, want);
    }
    {
        const text = try join(gpa, &.{ .{ ">", 1000 }, .{ "a*", 25000 } });
        defer gpa.free(text);
        // `*` between letters opens and closes: every two make emphasis.
        const inner = try repeat(gpa, "a<em>a</em>", 12500, "");
        defer gpa.free(inner);
        const want = try join(gpa, &.{ .{ "<blockquote>\n", 1000 }, .{ "<p>", 1 }, .{ inner, 1 }, .{ "</p>\n", 1 }, .{ "</blockquote>\n", 1000 } });
        defer gpa.free(want);
        try expectCase("emph in deep blockquote", text, .commonmark, deepest, want);
    }
}

test "code spans, raw HTML and NUL" {
    const gpa = testing.allocator;
    try expectCase("U+0000 in input", "abc\x00de\x00", .commonmark, .{}, "<p>abc\u{FFFD}de\u{FFFD}</p>\n");
    {
        // Runs of every length, none closed by another of its length.
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        for (1..600) |x| {
            try text.append(gpa, 'e');
            try text.appendNTimes(gpa, '`', x);
        }
        const want = try para(gpa, text.items);
        defer gpa.free(want);
        try expectCase("backticks", text.items, .commonmark, .{}, want);
    }
    {
        const text = try repeat(gpa, "<!--", 75000, "");
        defer gpa.free(text);
        const full = try std.mem.concat(gpa, u8, &.{ "</", text });
        defer gpa.free(full);
        const inner = try repeat(gpa, "&lt;!--", 75000, "");
        defer gpa.free(inner);
        const want = try std.mem.concat(gpa, u8, &.{ "<p>&lt;/", inner, "</p>\n" });
        defer gpa.free(want);
        try expectCase("unclosed <!--", full, .commonmark, .{}, want);
    }
}

test "GFM tables: rows that each read against the header once" {
    const gpa = testing.allocator;
    const n = 8000;
    const text = try repeat(gpa, "aaa\rbbb\n-\x0b\n", n, "");
    defer gpa.free(text);
    const want = try join(gpa, &.{
        .{ "<p>aaa</p>\n<table>\n<thead>\n<tr>\n<th>bbb</th>\n</tr>\n</thead>\n<tbody>\n", 1 },
        .{ "<tr>\n<td>aaa</td>\n</tr>\n<tr>\n<td>bbb</td>\n</tr>\n<tr>\n<td>-\x0b</td>\n</tr>\n", n - 1 },
        .{ "</tbody>\n</table>\n", 1 },
    });
    defer gpa.free(want);
    try expectCase("tables", text, .{ .tables = true }, .{}, want);
}

test "datapad's own shapes: wikilinks, extended autolinks, front matter" {
    const gpa = testing.allocator;
    const n = 8000;
    const all: Extensions = .{ .tables = true, .task_lists = true, .strikethrough = true, .autolinks = true, .tagfilter = true, .wikilinks = true, .front_matter = true };
    const shapes = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "wikilinks never closed", "[[a", "" },
        .{ "wikilink labels never closed", "[[a|b ", "" },
        .{ "wikilinks inside brackets", "[[[a]]", "]" },
        .{ "a URL's trailing parentheses", "www.a.b", "" },
        .{ "addresses back to back", "a@b.c@", "" },
        .{ "strikethrough runs unmatched", "~a ~~", "" },
        .{ "attribute values never closed", "<a b='", "\"" },
        .{ "titles never closed", "[a](b \"", "" },
    };
    for (shapes) |sh| {
        const text = try repeat(gpa, sh[1], n, sh[2]);
        defer gpa.free(text);
        try expectCase(sh[0], text, all, .{}, null);
    }
    {
        // One link, its trailing `)` trimmed one at a time.
        const text = try join(gpa, &.{ .{ "www.a.b", 1 }, .{ ")", 30000 } });
        defer gpa.free(text);
        const tail = try repeat(gpa, ")", 30000, "");
        defer gpa.free(tail);
        const want = try std.mem.concat(gpa, u8, &.{ "<p><a href=\"http://www.a.b\">www.a.b</a>", tail, "</p>\n" });
        defer gpa.free(want);
        try expectCase("a URL's many trailing parentheses", text, all, .{}, want);
    }
    {
        // Front matter opened and never closed: Markdown, read once.
        const text = try join(gpa, &.{ .{ "---\n", 1 }, .{ "a: 1\n", 30000 } });
        defer gpa.free(text);
        try expectCase("front matter never closed", text, all, .{}, null);
    }
}
