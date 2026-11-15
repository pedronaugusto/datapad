//! The events against CommonMark 0.31.2's inlines (§6): every construct,
//! its precedence, the spans the events carry, and the tables a leaf's
//! links read.
const dump = @import("../testing/events.zig");

const expect = dump.expect;

test "blocks enter and exit around what they hold" {
    try expect("> a\n> b\n\n- c\n- d\n\n---\n", .{},
        \\<quote
        \\  <para
        \\    "a"
        \\    soft_break
        \\    "b"
        \\  >para
        \\>quote
        \\<list -
        \\  <item
        \\    <para
        \\      "c"
        \\    >para
        \\  >item
        \\  <item
        \\    <para
        \\      "d"
        \\    >para
        \\  >item
        \\>list -
        \\rule
        \\
    );
    try expect("# A *b*\n\n```zig\nx\n\n  y\n```\n", .{},
        \\<h1
        \\  "A "
        \\  <em
        \\    "b"
        \\  >em
        \\>h1
        \\<code `zig`
        \\  "x"
        \\  ""
        \\  "  y"
        \\>code `zig`
        \\
    );
}

test "emphasis as §6.2 matches it" {
    try expect("*foo bar*", .{},
        \\<para
        \\  <em
        \\    "foo bar"
        \\  >em
        \\>para
        \\
    );
    try expect("a * foo bar*", .{},
        \\<para
        \\  "a * foo bar*"
        \\>para
        \\
    );
    try expect("foo*bar*", .{},
        \\<para
        \\  "foo"
        \\  <em
        \\    "bar"
        \\  >em
        \\>para
        \\
    );
    try expect("foo_bar_", .{},
        \\<para
        \\  "foo_bar_"
        \\>para
        \\
    );
    try expect("***strong emph***", .{},
        \\<para
        \\  <em
        \\    <strong
        \\      "strong emph"
        \\    >strong
        \\  >em
        \\>para
        \\
    );
    // The rule of 3.
    try expect("*foo**bar**baz*", .{},
        \\<para
        \\  <em
        \\    "foo"
        \\    <strong
        \\      "bar"
        \\    >strong
        \\    "baz"
        \\  >em
        \\>para
        \\
    );
    try expect("*foo**bar*", .{},
        \\<para
        \\  <em
        \\    "foo**bar"
        \\  >em
        \\>para
        \\
    );
    try expect("**foo*", .{},
        \\<para
        \\  "*"
        \\  <em
        \\    "foo"
        \\  >em
        \\>para
        \\
    );
}

test "code spans, escapes, references, breaks" {
    try expect("`` foo ` bar ``", .{},
        \\<para
        \\  code "foo ` bar"
        \\>para
        \\
    );
    try expect("`foo\nbar  \nbaz`", .{},
        \\<para
        \\  code "foo"
        \\  code "bar  "
        \\  code "baz"
        \\>para
        \\
    );
    try expect("```foo``", .{},
        \\<para
        \\  "```foo``"
        \\>para
        \\
    );
    try expect("\\*not emphasized* &amp; &#35; \\a", .{},
        \\<para
        \\  \*
        \\  "not emphasized* "
        \\  &U+0026
        \\  " "
        \\  &U+0023
        \\  " \a"
        \\>para
        \\
    );
    try expect("foo  \n   bar\\\nbaz \nqux", .{},
        \\<para
        \\  "foo"
        \\  hard_break
        \\  "bar"
        \\  hard_break
        \\  "baz"
        \\  soft_break
        \\  "qux"
        \\>para
        \\
    );
}

test "links and images in all four forms" {
    try expect("[link](/uri \"title\")", .{},
        \\<para
        \\  <link inline_ "/uri" title "title"
        \\    "link"
        \\  >link inline_ "/uri" title "title"
        \\>para
        \\
    );
    try expect("[foo][bar] [bar][] [bar] ![bar]\n\n[bar]: /url 't'\n", .{},
        \\<para
        \\  <link reference "/url" title "t" label "bar"
        \\    "foo"
        \\  >link reference "/url" title "t" label "bar"
        \\  " "
        \\  <link collapsed "/url" title "t" label "bar"
        \\    "bar"
        \\  >link collapsed "/url" title "t" label "bar"
        \\  " "
        \\  <link shortcut "/url" title "t" label "bar"
        \\    "bar"
        \\  >link shortcut "/url" title "t" label "bar"
        \\  " "
        \\  <image shortcut "/url" title "t" label "bar"
        \\    "bar"
        \\  >image shortcut "/url" title "t" label "bar"
        \\>para
        \\
    );
    // No link holds another.
    try expect("[foo [bar](/uri)](/uri)", .{},
        \\<para
        \\  "[foo "
        \\  <link inline_ "/uri"
        \\    "bar"
        \\  >link inline_ "/uri"
        \\  "](/uri)"
        \\>para
        \\
    );
    try expect("*[foo*](/uri)", .{},
        \\<para
        \\  "*"
        \\  <link inline_ "/uri"
        \\    "foo*"
        \\  >link inline_ "/uri"
        \\>para
        \\
    );
}

test "autolinks and raw HTML" {
    try expect("<http://a.b/c> <a@b.c> <span a=\"x\">x</span>", .{},
        \\<para
        \\  <link autolink "http://a.b/c"
        \\    "http://a.b/c"
        \\  >link autolink "http://a.b/c"
        \\  " "
        \\  <link email "a@b.c"
        \\    "a@b.c"
        \\  >link email "a@b.c"
        \\  " "
        \\  raw "<span a=\"x\">"
        \\  "x"
        \\  raw "</span>"
        \\>para
        \\
    );
    try expect("<a\nb=\"c\">", .{},
        \\<para
        \\  raw "<a"
        \\  raw "b=\"c\">"
        \\>para
        \\
    );
}

const std = @import("std");
const Document = @import("../Document.zig");
const Events = @import("../Events.zig");
const Limits = @import("../Limits.zig");

test "a definition reproduced past the expansion limit stops the events, there and after" {
    const text = "[a] [a] [a]\n\n[a]: /0123456789 't'\n";
    var diagnostic: Limits.Diagnostic = .{};
    var document = try Document.parse(std.testing.allocator, .init(text), .{ .limits = .{ .expansion = .fromRaw(25) }, .diagnostics = &diagnostic });
    defer document.deinit();
    var events = try Events.init(std.testing.allocator, &document);
    defer events.deinit();
    var links: usize = 0;
    while (events.next()) |maybe| {
        const e = maybe orelse return error.TestExpectedRefusal;
        if (e.kind == .enter and e.kind.enter == .link) links += 1;
    } else |err| try std.testing.expectEqual(error.ExpansionTooLarge, err);
    // Each use reproduces 12 bytes: the third passes 25.
    try std.testing.expectEqual(2, links);
    try std.testing.expectEqual(.expansion, diagnostic.limit);
    try std.testing.expectEqual(8, diagnostic.offset.raw());
    try std.testing.expectError(error.ExpansionTooLarge, events.next());
}

/// `text`'s events, counted, in memory exactly `Events.memory` bytes.
fn countEvents(text: []const u8) !usize {
    var document = try Document.parse(std.testing.allocator, .init(text), .{});
    defer document.deinit();
    const buffer = try std.testing.allocator.alloc(u8, Events.memory(&document));
    defer std.testing.allocator.free(buffer);
    var events = Events.initBuffer(&document, buffer);
    var n: usize = 0;
    while (try events.next()) |_| n += 1;
    return n;
}

fn repeat(buffer: []u8, piece: []const u8) []const u8 {
    var len: usize = 0;
    while (len + piece.len <= buffer.len) : (len += piece.len) @memcpy(buffer[len..][0..piece.len], piece);
    return buffer[0..len];
}

test "the shapes that fill a leaf's memory, and those that make inline parsers quadratic, fit and finish" {
    const buffer = try std.testing.allocator.alloc(u8, 60_000);
    defer std.testing.allocator.free(buffer);
    // Each read once, in the memory sized for the leaf: emphasis on every
    // other byte, a link per four bytes, a bracket per byte, and the
    // openers that find no closer (backticks, comments, quotes, brackets).
    const shapes = [_][]const u8{ "*a", "a*", "*", "_a_", "[]()", "[a]", "[", "![", "]", "`", "` ``", "<!--", "<a b='", "<?", "<![CDATA[", "*a **a ", "a_ ", "&#", "\\", "<a@" };
    for (shapes) |shape| _ = try countEvents(repeat(buffer, shape));
    // Nested brackets and emphasis.
    var len: usize = 0;
    while (len < 20_000) : (len += 1) buffer[len] = '[';
    buffer[len] = 'a';
    len += 1;
    while (len < 40_001) : (len += 1) buffer[len] = ']';
    _ = try countEvents(buffer[0..len]);
}

test "precedence: code spans, raw HTML and autolinks before link brackets; an image holds a link" {
    try expect("[not a `link](/foo`)", .{},
        \\<para
        \\  "[not a "
        \\  code "link](/foo"
        \\  ")"
        \\>para
        \\
    );
    try expect("[foo <bar attr=\"](baz)\">", .{},
        \\<para
        \\  "[foo "
        \\  raw "<bar attr=\"](baz)\">"
        \\>para
        \\
    );
    try expect("[foo<https://example.com/?search=](uri)>", .{},
        \\<para
        \\  "[foo"
        \\  <link autolink "https://example.com/?search=](uri)"
        \\    "https://example.com/?search=](uri)"
        \\  >link autolink "https://example.com/?search=](uri)"
        \\>para
        \\
    );
    try expect("[foo][bar][baz]\n\n[baz]: /url1\n", .{},
        \\<para
        \\  "[foo]"
        \\  <link reference "/url1" label "baz"
        \\    "bar"
        \\  >link reference "/url1" label "baz"
        \\>para
        \\
    );
    try expect("![foo [bar](/u)](/v)", .{},
        \\<para
        \\  <image inline_ "/v"
        \\    "foo "
        \\    <link inline_ "/u"
        \\      "bar"
        \\    >link inline_ "/u"
        \\  >image inline_ "/v"
        \\>para
        \\
    );
}
