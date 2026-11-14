//! The block pass against CommonMark 0.31.2's block structure: containers,
//! every leaf kind, lists tight and loose, definitions, tabs, spans and
//! lines, the limits, and linear work on the shapes that make block
//! parsers quadratic.
const std = @import("std");
const Document = @import("../Document.zig");
const Limits = @import("../Limits.zig");
const dump = @import("../testing/dump.zig");

const testing = std.testing;
const expect = dump.expect;

test "lists: a blank line between items, or between two blocks an item holds, makes them loose" {
    try expect("- a\n- b\n\n- c\n", .{},
        \\list - loose
        \\  item
        \\    para
        \\      |a
        \\  item
        \\    para
        \\      |b
        \\  item
        \\    para
        \\      |c
        \\
    );
    // §5.3: the inner list is loose, the outer tight.
    try expect("- a\n  - b\n\n    c\n- d\n", .{},
        \\list - tight
        \\  item
        \\    para
        \\      |a
        \\    list - loose
        \\      item
        \\        para
        \\          |b
        \\        para
        \\          |c
        \\  item
        \\    para
        \\      |d
        \\
    );
    // A definition is a block: the blank line before it loosens the list.
    try expect("- a\n- b\n\n  [ref]: /url\n- d\n", .{},
        \\list - loose
        \\  item
        \\    para
        \\      |a
        \\  item
        \\    para
        \\      |b
        \\  item
        \\    para
        \\      |d
        \\
    );
    // A line of `>` alone inside an item is no blank line of the item's.
    try expect("* a\n  > b\n  >\n* c\n", .{},
        \\list * tight
        \\  item
        \\    para
        \\      |a
        \\    quote
        \\      para
        \\        |b
        \\  item
        \\    para
        \\      |c
        \\
    );
    // A fenced block's blank lines are its own.
    try expect("- ```\n  b\n\n\n  ```\n- c\n", .{},
        \\list - tight
        \\  item
        \\    code ``
        \\      |b
        \\      |
        \\      |
        \\  item
        \\    para
        \\      |c
        \\
    );
}

test "list items: markers, starts, interruptions and their content's indentation" {
    try expect("1. a\n2. b\n3) c\n", .{},
        \\list 1. tight
        \\  item
        \\    para
        \\      |a
        \\  item
        \\    para
        \\      |b
        \\list 3) tight
        \\  item
        \\    para
        \\      |c
        \\
    );
    // Only an item starting at 1 interrupts a paragraph.
    try expect("a\n2. b\n", .{},
        \\para
        \\  |a
        \\  |2. b
        \\
    );
    try expect("a\n1. b\n", .{},
        \\para
        \\  |a
        \\list 1. tight
        \\  item
        \\    para
        \\      |b
        \\
    );
    // An item begins with one blank line at most.
    try expect("-\n\n  foo\n", .{},
        \\list - tight
        \\  item
        \\para
        \\  |foo
        \\
    );
    // Five spaces after the marker: the content is indented code.
    try expect("-      code\n", .{},
        \\list - tight
        \\  item
        \\    code
        \\      | code
        \\
    );
    // §2.2: the tabs after the marker; the code keeps the rest of one.
    try expect("-\t\tfoo\n", .{},
        \\list - tight
        \\  item
        \\    code
        \\      |  foo
        \\
    );
    // A thematic break wins over a bullet.
    try expect("* * *\n- a\n", .{},
        \\rule
        \\list - tight
        \\  item
        \\    para
        \\      |a
        \\
    );
}

test "block quotes and lazy continuation" {
    try expect("> a\nb\n> c\n", .{},
        \\quote
        \\  para
        \\    |a
        \\    |b
        \\    |c
        \\
    );
    try expect(">>> a\n> b\n", .{},
        \\quote
        \\  quote
        \\    quote
        \\      para
        \\        |a
        \\        |b
        \\
    );
    // A lazy line continues only a paragraph.
    try expect("> - a\n- b\n", .{},
        \\quote
        \\  list - tight
        \\    item
        \\      para
        \\        |a
        \\list - tight
        \\  item
        \\    para
        \\      |b
        \\
    );
}

test "leaves: headings, breaks, code and HTML" {
    try expect("# foo ##\n## bar\nbaz\n===\n---\n", .{},
        \\h1
        \\  |foo
        \\h2
        \\  |bar
        \\h1 setext
        \\  |baz
        \\rule
        \\
    );
    try expect("    a\n\n    b\n\n\n", .{},
        \\code
        \\  |a
        \\  |
        \\  |b
        \\
    );
    // Indented code cannot interrupt a paragraph.
    try expect("a\n    b\n", .{},
        \\para
        \\  |a
        \\  |b
        \\
    );
    try expect("~~~ zig  \nx\n~~~~\nafter\n", .{},
        \\code `zig`
        \\  |x
        \\para
        \\  |after
        \\
    );
    // A fence indented two spaces takes two from each line.
    try expect("  ```\n   a\n  b\nc\n  ```\n", .{},
        \\code ``
        \\  | a
        \\  |b
        \\  |c
        \\
    );
    try expect("<div>\n*hi*\n\n</div>\n\n<!-- a\n\nb -->\nc\n", .{},
        \\html 6
        \\  |<div>
        \\  |*hi*
        \\html 6
        \\  |</div>
        \\html 2
        \\  |<!-- a
        \\  |
        \\  |b -->
        \\para
        \\  |c
        \\
    );
    // Kind 7 cannot interrupt a paragraph.
    try expect("a\n<b>\n", .{},
        \\para
        \\  |a
        \\  |<b>
        \\
    );
}

test "definitions: taken from paragraphs into the label table" {
    var document = try Document.parse(testing.allocator, .init("[Foo  Bar]: /u 't'\n[foo bar]: /second\n[x]:\n<y>\npara\n"), .{});
    defer document.deinit();
    try testing.expectEqual(1, document.blocks().len);
    try testing.expectEqualStrings("para", document.lines(document.blocks()[0])[0].of(document.text()));
    try testing.expectEqual(3, document.definitions().len);
    // The first of a label is the one links resolve to.
    const foo = document.find("foo bar").?;
    try testing.expectEqualStrings("/u", foo.destination.of(document.text()));
    try testing.expectEqualStrings("t", foo.title.?.of(document.text()));
    try testing.expectEqualStrings("Foo  Bar", foo.label.of(document.text()));
    try testing.expectEqualStrings("y", document.find("x").?.destination.of(document.text()));
    try testing.expectEqual(null, document.find("nothing"));
    // A setext underline after definitions alone is a paragraph's text.
    try expect("[foo]: /url\n===\n", .{},
        \\para
        \\  |===
        \\
    );
    try expect("[foo]: /url\nbar\n===\n", .{},
        \\h1 setext
        \\  |bar
        \\
    );
    // Inside a block quote, the definition's spans are the text's.
    var quoted = try Document.parse(testing.allocator, .init("> [a]: </b c>\n"), .{});
    defer quoted.deinit();
    try testing.expectEqualStrings("/b c", quoted.find("a").?.destination.of(quoted.text()));
    try testing.expectEqual(1, quoted.blocks().len);
}

test "spans: from the first marker to the last byte" {
    const text = "> - a\n>   b\n\n```x\ny\n```\n";
    var document = try Document.parse(testing.allocator, .init(text), .{});
    defer document.deinit();
    const want = [_][]const u8{ "> - a\n>   b", "- a\n>   b", "- a\n>   b", "a\n>   b", "```x\ny\n```" };
    try testing.expectEqual(want.len, document.blocks().len);
    for (want, document.blocks()) |w, b| try testing.expectEqualStrings(w, b.span.of(text));
}

test "lines: an offset's line and column, every line ending" {
    var document = try Document.parse(testing.allocator, .init("a\nbc\r\nd\re\n"), .{});
    defer document.deinit();
    const cases = [_]struct { offset: u32, line: u32, column: u32 }{
        .{ .offset = 0, .line = 1, .column = 1 },
        .{ .offset = 1, .line = 1, .column = 2 },
        .{ .offset = 2, .line = 2, .column = 1 },
        .{ .offset = 4, .line = 2, .column = 3 },
        .{ .offset = 6, .line = 3, .column = 1 },
        .{ .offset = 8, .line = 4, .column = 1 },
        .{ .offset = 10, .line = 5, .column = 1 },
    };
    for (cases) |c| {
        const at = document.lineOf(.fromRaw(c.offset));
        try testing.expectEqual(c.line, at.line);
        try testing.expectEqual(c.column, at.column);
    }
}

test "limits: each refusal named, at its offset" {
    var diagnostic: Limits.Diagnostic = .{};
    try testing.expectError(error.TooDeep, Document.parse(testing.allocator, .init("a\n>>>> b\n"), .{ .limits = .{ .depth = .literal(3) }, .diagnostics = &diagnostic }));
    try testing.expectEqual(.depth, diagnostic.limit);
    try testing.expectEqual(5, diagnostic.offset.raw());
    try testing.expectError(error.TooManyBlocks, Document.parse(testing.allocator, .init("a\n\nb\n\nc\n"), .{ .limits = .{ .blocks = .fromRaw(2) }, .diagnostics = &diagnostic }));
    try testing.expectEqual(.blocks, diagnostic.limit);
    try testing.expectEqual(6, diagnostic.offset.raw());
    try testing.expectError(error.TooManyReferences, Document.parse(testing.allocator, .init("[a]: /a\n[b]: /b\n"), .{ .limits = .{ .references = .fromRaw(1) }, .diagnostics = &diagnostic }));
    try testing.expectEqual(.references, diagnostic.limit);
    try testing.expectEqual(8, diagnostic.offset.raw());
    try testing.expectError(error.InputTooLong, Document.parse(testing.allocator, .init("abcdef"), .{ .limits = .{ .input = .fromRaw(5) }, .diagnostics = &diagnostic }));
    try testing.expectEqual(.input, diagnostic.limit);
    // At the limits, the same texts parse.
    var at_limit = try Document.parse(testing.allocator, .init("abcde"), .{ .limits = .{ .input = .fromRaw(5) } });
    at_limit.deinit();
}

/// The work the pass took on `text`, held to a constant per byte.
fn expectLinear(gpa: std.mem.Allocator, text: []const u8, limits: Limits) !void {
    var document = try Document.parse(gpa, .init(text), .{ .limits = limits });
    defer document.deinit();
    const work = document.stats().work;
    if (work > 4 * text.len + 16) {
        std.debug.print("work {d} over {d} bytes\n", .{ work, text.len });
        return error.TestWorkNotLinear;
    }
}

test "work: linear on the shapes that make block parsers quadratic" {
    const gpa = testing.allocator;
    const n = 20_000;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    const deep: Limits = .{ .depth = .literal(1024) };

    // Nested block quotes, and lazy lines under them.
    try text.appendNTimes(gpa, '>', 1000);
    try text.appendSlice(gpa, " a\n");
    for (0..n) |_| try text.appendSlice(gpa, "b\n");
    try expectLinear(gpa, text.items, deep);

    // Nested list items, each line continuing them all.
    text.clearRetainingCapacity();
    for (0..400) |i| {
        try text.appendNTimes(gpa, ' ', 2 * i);
        try text.appendSlice(gpa, "- a\n");
    }
    for (0..n) |_| try text.appendSlice(gpa, "c\n");
    try expectLinear(gpa, text.items, deep);

    // Definitions whose titles run to the next definition's quote.
    text.clearRetainingCapacity();
    for (0..n) |_| try text.appendSlice(gpa, "[a]: /b \"\n");
    try expectLinear(gpa, text.items, .{});

    // A paragraph that starts like a definition and runs on.
    text.clearRetainingCapacity();
    try text.appendSlice(gpa, "[a]: /b '");
    for (0..n) |_| try text.appendSlice(gpa, "xx\n");
    try expectLinear(gpa, text.items, .{});

    // Fences of either kind, opened and never closed by the other.
    text.clearRetainingCapacity();
    for (0..n) |i| try text.appendSlice(gpa, if (i % 2 == 0) "```\n" else "~~~\n");
    try expectLinear(gpa, text.items, .{});

    // Lists alternating markers, each a new list.
    text.clearRetainingCapacity();
    for (0..n) |i| try text.appendSlice(gpa, if (i % 2 == 0) "- a\n" else "* a\n");
    try expectLinear(gpa, text.items, .{});
}
