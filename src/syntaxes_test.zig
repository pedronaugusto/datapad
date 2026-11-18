//! The two syntaxes past GFM tycho's consumers read, each off unless asked
//! for: wikilinks (`[[target]]`, `[[target|label]]`) and front matter (a
//! leading `---` YAML or `+++` TOML block). Their events, their spans, what
//! the HTML writer makes of them, and the shapes that are neither.
const std = @import("std");
const Document = @import("Document.zig");
const Events = @import("Events.zig");
const html = @import("html.zig");
const dump = @import("testing/events.zig");
const blocks = @import("testing/dump.zig");

const testing = std.testing;
const wiki: Document.Options = .{ .extensions = .{ .wikilinks = true } };
const matter: Document.Options = .{ .extensions = .{ .front_matter = true } };

fn expectHtml(markdown: []const u8, options: Document.Options, want: []const u8) !void {
    const gpa = testing.allocator;
    var document = try Document.parse(gpa, .init(markdown), options);
    defer document.deinit();
    var events = try Events.init(gpa, &document);
    defer events.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try html.write(&out.writer, &events, .{});
    try testing.expectEqualStrings(want, out.written());
}

test "a wikilink's target is its destination and, with no label, its text as written" {
    try dump.expect("See [[Home Page]] and ![[diagram.png]].", wiki,
        \\<para
        \\  "See "
        \\  <link wiki "Home Page"
        \\    "Home Page"
        \\  >link wiki "Home Page"
        \\  " and "
        \\  <image wiki "diagram.png"
        \\    "diagram.png"
        \\  >image wiki "diagram.png"
        \\  "."
        \\>para
        \\
    );
    // The target is not Markdown: no emphasis, no escapes, no references.
    try dump.expect("[[a *b* \\c &amp;]]", wiki,
        \\<para
        \\  <link wiki "a *b* \c &amp;"
        \\    "a *b* \c &amp;"
        \\  >link wiki "a *b* \c &amp;"
        \\>para
        \\
    );
}

test "a label is read as a link's text, and may run over lines" {
    try dump.expect("[[packages|the *packages* road\nplan]]", wiki,
        \\<para
        \\  <link wiki "packages"
        \\    "the "
        \\    <em
        \\      "packages"
        \\    >em
        \\    " road"
        \\    soft_break
        \\    "plan"
        \\  >link wiki "packages"
        \\>para
        \\
    );
    // The first bar ends the target; later ones are the label's.
    try dump.expect("[[a|b|c]]", wiki,
        \\<para
        \\  <link wiki "a"
        \\    "b|c"
        \\  >link wiki "a"
        \\>para
        \\
    );
}

test "a wikilink's spans: the link from `[[` to `]]`, its target inside" {
    const text = "x [[t|l]] ![[i]]";
    var document = try Document.parse(testing.allocator, .init(text), wiki);
    defer document.deinit();
    var events = try Events.init(testing.allocator, &document);
    defer events.deinit();
    var links: usize = 0;
    while (try events.next()) |e| switch (e.kind) {
        .enter => |n| switch (n) {
            .link => |l| {
                try testing.expectEqualStrings("[[t|l]]", e.span.of(text));
                try testing.expectEqualStrings("t", l.destination.of(text));
                try testing.expect(events.title(l) == null and events.label(l) == null);
                links += 1;
            },
            .image => |l| {
                try testing.expectEqualStrings("![[i]]", e.span.of(text));
                try testing.expectEqualStrings("i", l.destination.of(text));
                links += 1;
            },
            else => {},
        },
        else => {},
    };
    try testing.expectEqual(2, links);
}

test "not a wikilink: the extension off, an empty or blank target, a target over lines, another bracket, no `]]`" {
    // Off, `[[x]]` is brackets around a shortcut reference that resolves to nothing.
    try dump.expect("[[x]]", .{},
        \\<para
        \\  "[[x]]"
        \\>para
        \\
    );
    for ([_][]const u8{ "[[]]", "[[ ]]", "[[a\nb]]", "[[a|]]", "[[a[b]]", "[[a]b]]", "[[a", "[[a] ]" }) |text| {
        var document = try Document.parse(testing.allocator, .init(text), wiki);
        defer document.deinit();
        var events = try Events.init(testing.allocator, &document);
        defer events.deinit();
        while (try events.next()) |e| switch (e.kind) {
            .enter => |n| if (n == .link or n == .image) {
                std.log.err("{s}: read as a link", .{text});
                return error.TestUnexpectedResult;
            },
            else => {},
        };
    }
}

test "precedence: a code span or raw HTML in a label that runs past its `]]` leaves it text; no link holds a wikilink" {
    try dump.expect("[[a|`b]]`", wiki,
        \\<para
        \\  "[[a|"
        \\  code "b]]"
        \\>para
        \\
    );
    try dump.expect("[x [[y]] z](/u)", wiki,
        \\<para
        \\  "[x "
        \\  <link wiki "y"
        \\    "y"
        \\  >link wiki "y"
        \\  " z](/u)"
        \\>para
        \\
    );
    // A wikilink wins over a reference definition of the same label.
    try dump.expect("[[x]]\n\n[x]: /defined\n", wiki,
        \\<para
        \\  <link wiki "x"
        \\    "x"
        \\  >link wiki "x"
        \\>para
        \\
    );
}

test "the HTML writer: a wikilink is a link to its target, percent-encoded, a script target emptied" {
    try expectHtml("[[Home Page]] [[p|*the* page]] ![[a b.png|A]]", wiki,
        \\<p><a href="Home%20Page">Home Page</a> <a href="p"><em>the</em> page</a> <img src="a%20b.png" alt="A" /></p>
        \\
    );
    try expectHtml("[[javascript:alert(1)|x]]", wiki, "<p><a href=\"\">x</a></p>\n");
}

test "front matter: one block, its body's lines its content, the rest Markdown" {
    try blocks.expect("---\ntitle: x\ntags: [a]\n---\n# Page\n", matter,
        \\front matter yaml
        \\  |title: x
        \\  |tags: [a]
        \\h1
        \\  |Page
        \\
    );
    try dump.expect("+++\na = 1\n+++\ntext\n", matter,
        \\<front_matter
        \\  "a = 1"
        \\>front_matter
        \\<para
        \\  "text"
        \\>para
        \\
    );
}

test "front matter's spans, its body and its language through Document.frontMatter" {
    const text = "---\r\nat: 2026-11-16\r\nabout: [x]\r\n...\r\nBody\r\n";
    var document = try Document.parse(testing.allocator, .init(text), matter);
    defer document.deinit();
    const f = document.frontMatter().?;
    try testing.expectEqual(.yaml, f.format);
    try testing.expectEqualStrings("---\r\nat: 2026-11-16\r\nabout: [x]\r\n...", f.span.of(text));
    try testing.expectEqualStrings("at: 2026-11-16\r\nabout: [x]", f.body.of(text));
    // Lines are counted through it: the paragraph is on line 5.
    try testing.expectEqual(Document.Position{ .line = 5, .column = 1 }, document.lineOf(document.blocks()[1].span.start));

    var empty = try Document.parse(testing.allocator, .init("---\n---\nx\n"), matter);
    defer empty.deinit();
    const e = empty.frontMatter().?;
    try testing.expectEqual(@as(u32, 4), e.body.start.raw());
    try testing.expectEqual(@as(u32, 4), e.body.end.raw());
}

test "no front matter: the extension off, unclosed, or not at the start" {
    // Off, the fences are a thematic break and a setext heading's underline.
    try blocks.expect("---\ntitle: x\n---\n", .{},
        \\rule
        \\h2 setext
        \\  |title: x
        \\
    );
    try blocks.expect("---\ntitle: x\n", matter,
        \\rule
        \\para
        \\  |title: x
        \\
    );
    try blocks.expect("\n---\na\n---\n", matter,
        \\rule
        \\h2 setext
        \\  |a
        \\
    );
    var document = try Document.parse(testing.allocator, .init("# x\n"), matter);
    defer document.deinit();
    try testing.expect(document.frontMatter() == null);
}

test "the HTML writer leaves front matter out" {
    try expectHtml("---\ntitle: <b>x</b>\n---\n*Page*\n", matter, "<p><em>Page</em></p>\n");
}

test "a destination is written as the URL it means: escapes and references resolved, nothing escaped for HTML" {
    const text = "[a](/q?x=1&amp;y=\\*2) <me@example.com> www.example.com/p\n";
    var document = try Document.parse(testing.allocator, .init(text), .{});
    defer document.deinit();
    var events = try Events.init(testing.allocator, &document);
    defer events.deinit();
    var plain: std.Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    var page: std.Io.Writer.Allocating = .init(testing.allocator);
    defer page.deinit();
    while (try events.next()) |event| switch (event.kind) {
        .enter => |node| if (node == .link) {
            try events.writeDestination(&plain.writer, node.link);
            try plain.writer.writeByte(' ');
            try html.writeDestination(&page.writer, &document, node.link);
            try page.writer.writeByte(' ');
        },
        else => {},
    };
    try testing.expectEqualStrings("/q?x=1&y=*2 mailto:me@example.com http://www.example.com/p ", plain.written());
    try testing.expectEqualStrings("/q?x=1&amp;y=*2 mailto:me@example.com http://www.example.com/p ", page.written());
}
