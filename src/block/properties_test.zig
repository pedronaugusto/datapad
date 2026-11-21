//! The block table's guarantees over generated text: Markdown drawn from
//! the pieces that start, continue and end blocks (markers, indentation,
//! tabs, fences, definitions, HTML, every line ending), parsed and held to
//! what the table promises its readers.
const std = @import("std");
const shakedown = @import("shakedown");
const Document = @import("../Document.zig");
const Span = @import("../Span.zig");
const Block = Document.Block;

const testing = std.testing;
const gen = shakedown.gen;

/// A line's start: container markers and indentation.
const prefixes = [_][]const u8{ "", "", "", "> ", ">", "- ", "* ", "+ ", "1. ", "2) ", "10. ", "  ", "   ", "    ", "\t", " \t", "-\t", ">\t", ">  ", "-   " };
/// What follows on the line.
const bodies = [_][]const u8{
    "",       "a",     "b c",    "# h",            "## h ##", "###### h", "####### h", "===",     "---",
    "***",    "- - -", "```",    "```zig",         "~~~",     "````",     "``` a`b",   "[a]: /u", "[B  b]:",
    "/u 't'", "<x>",   "\"t",    "[a]",            "<div>",   "</div>",   "<!--",      "-->",     "<?p",
    "?>",     "<pre>", "</pre>", "<a href=\"x\">", "<!X",     ">",        "<![CDATA[", "]]>",     "  ",
    "\t",     "x\ty",  "1",      "\x00",           "\xff",
    "é",
};
const endings = [_][]const u8{ "\n", "\n", "\n", "\r\n", "\r" };

fn draw(s: *shakedown.Source, buffer: []u8) []const u8 {
    var len: usize = 0;
    const lines = gen.intRange(s, usize, 0, 12);
    for (0..lines) |_| {
        const depth = gen.intRange(s, usize, 0, 3);
        for (0..depth) |_| len += put(buffer[len..], prefixes[gen.intRange(s, usize, 0, prefixes.len - 1)]);
        len += put(buffer[len..], bodies[gen.intRange(s, usize, 0, bodies.len - 1)]);
        if (gen.intRange(s, u8, 0, 7) != 0) len += put(buffer[len..], endings[gen.intRange(s, usize, 0, endings.len - 1)]);
    }
    return buffer[0..len];
}

fn put(to: []u8, bytes: []const u8) usize {
    const n = @min(to.len, bytes.len);
    @memcpy(to[0..n], bytes[0..n]);
    return n;
}

fn isContainer(k: Block.Kind) bool {
    return k == .block_quote or k == .list or k == .item;
}

/// Every guarantee of the table over `text`.
fn check(text: []const u8) !void {
    var document = try Document.parse(testing.allocator, .init(text), .{});
    defer document.deinit();
    const length: Span.Offset = .fromRaw(@intCast(text.len));
    const blocks = document.blocks();
    // The open ancestors of the block being read: their indexes.
    var ancestors: [64]usize = undefined;
    var last_child: [65]?usize = @splat(null);
    for (blocks, 0..) |b, i| {
        try testing.expect(b.span.start.compare(b.span.end) != .gt);
        try testing.expect(b.span.end.compare(length) != .gt);
        // Depths nest: one deeper than a container before it, or back out.
        if (i == 0) try testing.expectEqual(0, b.depth) else {
            const before = blocks[i - 1];
            try testing.expect(b.depth <= before.depth + 1);
            if (b.depth == before.depth + 1) try testing.expect(isContainer(before.kind));
        }
        if (b.depth > 0) {
            const parent = blocks[ancestors[b.depth - 1]];
            // Inside its parent; a list holds items and only items.
            try testing.expect(parent.span.start.compare(b.span.start) != .gt);
            try testing.expect(b.span.end.compare(parent.span.end) != .gt);
            try testing.expectEqual(parent.kind == .list, b.kind == .item);
        } else try testing.expect(b.kind != .item);
        // After the sibling before it.
        if (last_child[b.depth]) |sibling| try testing.expect(blocks[sibling].span.end.compare(b.span.start) != .gt);
        last_child[b.depth] = i;
        last_child[b.depth + 1] = null;
        if (b.depth < ancestors.len) ancestors[b.depth] = i;
        // A container's record holds no lines; a leaf's lie in its span, in
        // order, each inside one line of the text.
        if (isContainer(b.kind)) try testing.expectEqual(0, b.line_count);
        var previous_end: u32 = b.span.start.raw();
        for (document.lines(b)) |l| {
            try testing.expect(l.start <= l.end);
            try testing.expect(l.start - @intFromBool(l.spaces != 0) >= previous_end);
            try testing.expect(Span.Offset.fromRaw(l.end).compare(b.span.end) != .gt);
            for (text[l.start..l.end]) |c| try testing.expect(c != '\n' and c != '\r');
            if (l.spaces != 0) try testing.expectEqual('\t', text[l.start - 1]);
            previous_end = l.end;
        }
        switch (b.kind) {
            // An ATX heading is one line; a setext heading's paragraph may
            // be several.
            .heading => if (b.data.heading.setext) try testing.expect(b.line_count >= 1) else try testing.expectEqual(1, b.line_count),
            .thematic_break => try testing.expectEqual(0, b.line_count),
            .paragraph => try testing.expect(b.line_count > 0),
            else => {},
        }
    }
    // The label table: each definition's label resolves to the first
    // definition of it.
    const definitions = document.definitions();
    for (definitions) |d| {
        try testing.expect(d.destination.end.compare(length) != .gt);
        const key = document.keyOf(d);
        try testing.expect(key.len > 0);
        const found = document.find(key) orelse return error.TestLabelNotFound;
        const first = for (definitions) |e| {
            if (std.mem.eql(u8, document.keyOf(e), key)) break e;
        } else return error.TestLabelNotFound;
        try testing.expect(std.meta.eql(first, found));
    }
    try testing.expect(document.stats().work <= 4 * text.len + 16);
    // Every offset of the text is on a line that contains it.
    var at: u32 = 0;
    while (at <= text.len) : (at += 1) {
        const p = document.lineOf(.fromRaw(at));
        try testing.expect(p.line >= 1 and p.column >= 1);
    }
}

test "the block table's guarantees hold on generated text" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var buffer: [512]u8 = undefined;
            try check(draw(case.source, &buffer));
        }
    }.one, .{ .cases = 3000 });
}

test "the guarantees on the spec's block shapes" {
    const texts = [_][]const u8{
        "- a\n- b\n\n- c\n",
        "> - a\n>   b\n\n```x\ny\n```\n",
        "<!--\n\n",
        "-\t\tfoo\n",
        "[a]: /u 't'\n[a]: /v\n",
        "> ```\n> a\n\nb\n",
        "1. a\n\n   b\n2. c\n",
    };
    for (texts) |t| try check(t);
}
