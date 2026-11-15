//! The events' guarantees over generated text: Markdown drawn from the
//! pieces of every inline construct and the block markers around them,
//! parsed, and every event held to what the stream promises its readers.
const std = @import("std");
const shakedown = @import("shakedown");
const Document = @import("../Document.zig");
const Events = @import("../Events.zig");
const Span = @import("../Span.zig");

const testing = std.testing;
const gen = shakedown.gen;

const prefixes = [_][]const u8{ "", "", "", "", "> ", "- ", "1. ", "    ", "# ", "\t" };
const pieces = [_][]const u8{
    "a",     "b c",   " ",    "  ",     "\t",    "*",        "**",        "***",          "_",       "__",
    "`",     "``",    "[",    "]",      "](/u)", "](<a b>)", "](/u 't')", "[x]",          "[x][]",   "[y][x]",
    "![",    "<",     ">",    "<a>",    "</a>",  "<a b='",   "<!--",      "-->",          "<?",      "?>",
    "&amp;", "&#35;", "&#x;", "&ngE;",  "\\",    "\\*",      "\\[",       "<http://a.b>", "<a@b.c>", "(",
    ")",     "\"t\"", "'",    "\u{e9}", "\xff",  "\x00",     "x*y",       "_a_",          "!",       "&",
};
const definitions = [_][]const u8{ "[x]: /u 't'\n", "[y]: <v w>\n", "" };

fn draw(s: *shakedown.Source, buffer: []u8) []const u8 {
    var len: usize = 0;
    len += put(buffer[len..], definitions[gen.intRange(s, usize, 0, definitions.len - 1)]);
    const lines = gen.intRange(s, usize, 1, 6);
    for (0..lines) |_| {
        len += put(buffer[len..], prefixes[gen.intRange(s, usize, 0, prefixes.len - 1)]);
        const count = gen.intRange(s, usize, 0, 10);
        for (0..count) |_| len += put(buffer[len..], pieces[gen.intRange(s, usize, 0, pieces.len - 1)]);
        len += put(buffer[len..], if (gen.intRange(s, u8, 0, 5) == 0) "\n\n" else "\n");
    }
    return buffer[0..len];
}

fn put(to: []u8, bytes: []const u8) usize {
    const n = @min(to.len, bytes.len);
    @memcpy(to[0..n], bytes[0..n]);
    return n;
}

fn inside(inner: Span, outer: Span) bool {
    return outer.start.compare(inner.start) != .gt and inner.end.compare(outer.end) != .gt;
}

/// Every guarantee of the events over `text`.
fn check(text: []const u8) !void {
    var document = try Document.parse(testing.allocator, .init(text), .{});
    defer document.deinit();
    var events = try Events.init(testing.allocator, &document);
    defer events.deinit();
    // The nodes open: their events.
    var open: [64]Events.Event = undefined;
    var depth: usize = 0;
    var last_start: u32 = 0;
    while (try events.next()) |e| {
        try testing.expect(e.span.start.compare(e.span.end) != .gt);
        try testing.expect(e.span.end.raw() <= text.len);
        if (depth > 0) try testing.expect(inside(e.span, open[depth - 1].span));
        switch (e.kind) {
            .enter => |n| {
                try testing.expect(e.span.start.raw() >= last_start);
                last_start = e.span.start.raw();
                switch (n) {
                    .link, .image => |l| {
                        if (l.kind != .reference and l.kind != .collapsed and l.kind != .shortcut) try testing.expect(inside(l.destination, e.span));
                        if (events.title(l)) |t| try testing.expect(t.end.raw() <= text.len);
                        if (events.label(l)) |t| try testing.expect(inside(t, e.span));
                    },
                    else => {},
                }
                open[depth] = e;
                depth += 1;
            },
            .exit => |n| {
                // An exit closes the last node entered, with its span.
                try testing.expect(depth > 0);
                depth -= 1;
                const entered = open[depth];
                try testing.expectEqual(std.meta.activeTag(entered.kind.enter), std.meta.activeTag(n));
                try testing.expect(std.meta.eql(entered.span, e.span));
                try testing.expect(std.meta.eql(entered.kind.enter, n));
            },
            else => {
                try testing.expect(e.span.start.raw() >= last_start);
                last_start = e.span.start.raw();
                const bytes = e.span.of(text);
                switch (e.kind) {
                    // Text never crosses a line.
                    .text => for (bytes) |c| try testing.expect(c != '\n' and c != '\r'),
                    .escape => try testing.expect(bytes.len == 2 and bytes[0] == '\\'),
                    .reference => try testing.expect(bytes[0] == '&' and bytes[bytes.len - 1] == ';'),
                    .code => |piece| {
                        try testing.expect(bytes[0] == '`' and bytes[bytes.len - 1] == '`');
                        try testing.expect(inside(piece, e.span));
                        for (piece.of(text)) |c| try testing.expect(c != '\n' and c != '\r');
                    },
                    .html => |piece| {
                        try testing.expect(inside(piece, e.span));
                        for (piece.of(text)) |c| try testing.expect(c != '\n' and c != '\r');
                    },
                    else => {},
                }
            },
        }
    }
    try testing.expectEqual(0, depth);
}

test "the events' guarantees hold on generated text" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var buffer: [1024]u8 = undefined;
            try check(draw(case.source, &buffer));
        }
    }.one, .{ .cases = 3000 });
}
