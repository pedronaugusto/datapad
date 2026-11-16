//! The fuzz targets: any bytes, or Markdown mutated, under any set of
//! extensions and any expansion limit, parsed, drained and written as HTML,
//! and every guarantee of the stream held: spans inside the text, nodes
//! entered and exited in order, siblings in order and apart, text never
//! crossing a line, a link's title and label inside its span (a reference
//! link's title is its definition's), the work bound, and the expansion
//! limit refusing exactly when the bytes reference links reproduce pass it,
//! against a recount over the stream run without the limit. `bay dev test`
//! runs a few cases of each; the fuzz job runs them for its minutes.
const std = @import("std");
const shakedown = @import("shakedown");
const Document = @import("Document.zig");
const Events = @import("Events.zig");
const Span = @import("Span.zig");
const Limits = @import("Limits.zig");
const Extensions = @import("Options.zig").Extensions;
const html = @import("html.zig");

const testing = std.testing;
const gen = shakedown.gen;

/// Markdown for the mutations to start from: a piece of every construct.
const examples = [_][]const u8{
    "# h\n\npara *em* **strong** `code` [l](/u \"t\") ![i](/i) <a@b.c> <http://x>\n",
    "> quote\n> - item\n>   1. nested\n\n    code\n\n```zig\nfenced\n```\n",
    "[x]: /u 't'\n[x] [x][] [y][x] &amp; &#35; \\* <b>html</b> <!-- c -->\n",
    "| a | b |\n|:-|-:|\n| c | d |\n\n- [ ] task\n- [x] done\n\n~~gone~~ www.a.b https://c.d e@f.g\n",
    "---\ntitle: x\n---\n[[Home]] [[t|*l*]] ![[i.png]]\n",
    "+++\na = 1\n+++\n<div>\n*x*\n</div>\n\nsetext\n===\n***\n",
    "*a **a b a** a* _a_ __b__ a_b_ [ (]( [a](<b ![[]() [a](b ```",
};

fn extensionsFrom(s: *shakedown.Source) Extensions {
    return .{
        .tables = gen.boolean(s),
        .task_lists = gen.boolean(s),
        .strikethrough = gen.boolean(s),
        .autolinks = gen.boolean(s),
        .tagfilter = gen.boolean(s),
        .wikilinks = gen.boolean(s),
        .front_matter = gen.boolean(s),
    };
}

fn inside(inner: Span, outer: Span) bool {
    return outer.start.compare(inner.start) != .gt and inner.end.compare(outer.end) != .gt;
}

/// What a drain saw: the bytes reference links reproduced, and the work.
const Drained = struct { reproduced: u64, work: u64, refused: bool };

/// Drains `document`'s events through every check, writing them as HTML
/// on the way: the writer reads the same stream.
fn drain(document: *const Document, text: []const u8) !Drained {
    const gpa = testing.allocator;
    var events = try Events.init(gpa, document);
    defer events.deinit();
    var open: [2048]Events.Event = undefined;
    // The end of the last node closed at each depth: its next sibling starts at or after it.
    var sibling_end: [2049]u32 = @splat(0);
    var depth: usize = 0;
    var last_start: u32 = 0;
    var reproduced: u64 = 0;
    var refused = false;
    while (true) {
        const next = events.next() catch |err| switch (err) {
            error.ExpansionTooLarge => {
                refused = true;
                // Every later call refuses too.
                try testing.expectError(error.ExpansionTooLarge, events.next());
                break;
            },
        };
        const e = next orelse break;
        try testing.expect(e.span.start.compare(e.span.end) != .gt);
        try testing.expect(e.span.end.raw() <= text.len);
        if (depth > 0) try testing.expect(inside(e.span, open[depth - 1].span));
        switch (e.kind) {
            .enter => |n| {
                try testing.expect(e.span.start.raw() >= last_start);
                try testing.expect(e.span.start.raw() >= sibling_end[depth]);
                last_start = e.span.start.raw();
                switch (n) {
                    .link, .image => |l| {
                        const by_reference = l.kind == .reference or l.kind == .collapsed or l.kind == .shortcut;
                        if (!by_reference) try testing.expect(inside(l.destination, e.span));
                        if (events.label(l)) |t| try testing.expect(inside(t, e.span));
                        if (events.title(l)) |t| {
                            try testing.expect(t.end.raw() <= text.len);
                            if (!by_reference) try testing.expect(inside(t, e.span));
                        }
                        if (by_reference) reproduced += l.destination.len().raw() + if (events.title(l)) |t| t.len().raw() else 0;
                    },
                    else => {},
                }
                open[depth] = e;
                depth += 1;
                sibling_end[depth] = e.span.start.raw();
            },
            .exit => |n| {
                try testing.expect(depth > 0);
                depth -= 1;
                const entered = open[depth];
                try testing.expect(std.meta.eql(entered.span, e.span));
                try testing.expect(std.meta.eql(entered.kind.enter, n));
                sibling_end[depth] = e.span.end.raw();
            },
            else => {
                try testing.expect(e.span.start.raw() >= last_start);
                last_start = e.span.start.raw();
                if (e.kind == .text) for (e.span.of(text)) |c| try testing.expect(c != '\n' and c != '\r');
            },
        }
    }
    if (!refused) try testing.expectEqual(0, depth);
    return .{ .reproduced = reproduced, .work = events.work(), .refused = refused };
}

/// Writes `document` as HTML, safe and unsafe: neither may fail but at
/// the expansion limit.
fn write(document: *const Document) !void {
    const gpa = testing.allocator;
    for ([_]bool{ false, true }) |unsafe| {
        var events = try Events.init(gpa, document);
        defer events.deinit();
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        html.write(&out.writer, &events, .{ .unsafe = unsafe }) catch |err| switch (err) {
            error.ExpansionTooLarge => {},
            else => |e| return e,
        };
    }
}

/// Every check over `text` under `extensions`, with the expansion limit
/// off and at `limit`.
fn check(text: []const u8, extensions: Extensions, limit: u32) !void {
    const gpa = testing.allocator;
    const open_limits: Limits = .{ .depth = .literal(1024), .expansion = .fromRaw(std.math.maxInt(u32)) };
    var document = Document.parse(gpa, .init(text), .{ .extensions = extensions, .limits = open_limits }) catch |err| switch (err) {
        // Only a limit refuses, and these inputs pass none but depth.
        error.TooDeep => return,
        else => |e| return e,
    };
    defer document.deinit();
    const free = try drain(&document, text);
    try testing.expect(!free.refused);
    const work = document.stats().work + free.work;
    if (work > 48 * text.len + 1024) {
        std.log.err("{d} steps over {d} bytes", .{ work, text.len });
        return error.TestWorkNotLinear;
    }
    try write(&document);

    var limits = open_limits;
    limits.expansion = .fromRaw(limit);
    var diagnostic: Limits.Diagnostic = undefined;
    var limited = try Document.parse(gpa, .init(text), .{ .extensions = extensions, .limits = limits, .diagnostics = &diagnostic });
    defer limited.deinit();
    const bounded = try drain(&limited, text);
    try testing.expectEqual(free.reproduced > limit, bounded.refused);
    if (bounded.refused) try testing.expectEqual(Limits.Limit.expansion, diagnostic.limit);
}

fn one(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    var buffer: [512]u8 = undefined;
    const text = if (gen.boolean(s)) gen.bytesInto(s, &buffer) else gen.mutated(s, &buffer, &examples);
    try check(text, extensionsFrom(s), gen.intRange(s, u32, 0, 64));
}

test "fuzz: any bytes, or Markdown mutated, parse, drain and write with every guarantee held" {
    try shakedown.check(testing.allocator, {}, one, .{ .cases = 2000 });
}
