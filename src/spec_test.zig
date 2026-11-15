//! CommonMark 0.31.2's examples, read from the spec as it is published
//! (testdata/commonmark/spec.txt): each one's Markdown parsed, its events
//! written as HTML with raw HTML allowed, and compared with the spec's HTML
//! byte for byte.
const std = @import("std");
const Document = @import("Document.zig");
const Events = @import("Events.zig");
const html = @import("html.zig");

const spec = @embedFile("commonmark_spec");

const fence = "````````````````````````````````";

const Example = struct { number: usize, markdown: []const u8, html: []const u8 };

/// The spec's examples, in order, with each `→` a tab, as the spec
/// writes tabs.
fn examples(gpa: std.mem.Allocator) !std.ArrayList(Example) {
    var list: std.ArrayList(Example) = .empty;
    var lines = std.mem.splitScalar(u8, spec, '\n');
    var number: usize = 0;
    while (lines.next()) |line| {
        if (!std.mem.eql(u8, line, fence ++ " example")) continue;
        number += 1;
        var markdown: std.ArrayList(u8) = .empty;
        var out: std.ArrayList(u8) = .empty;
        var into = &markdown;
        while (lines.next()) |l| {
            if (std.mem.eql(u8, l, fence)) break;
            if (std.mem.eql(u8, l, ".")) {
                into = &out;
                continue;
            }
            try appendTabs(gpa, into, l);
            try into.append(gpa, '\n');
        }
        try list.append(gpa, .{ .number = number, .markdown = try markdown.toOwnedSlice(gpa), .html = try out.toOwnedSlice(gpa) });
    }
    return list;
}

fn appendTabs(gpa: std.mem.Allocator, to: *std.ArrayList(u8), line: []const u8) !void {
    var it = std.mem.splitSequence(u8, line, "\u{2192}");
    var first = true;
    while (it.next()) |part| {
        if (!first) try to.append(gpa, '\t');
        first = false;
        try to.appendSlice(gpa, part);
    }
}

fn render(gpa: std.mem.Allocator, markdown: []const u8) ![]u8 {
    var document = try Document.parse(gpa, .init(markdown), .{ .extensions = .commonmark });
    defer document.deinit();
    var events = try Events.init(gpa, &document);
    defer events.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try html.write(&out.writer, &events, .{ .unsafe = true });
    return out.toOwnedSlice();
}

test "every CommonMark 0.31.2 example gives the spec's HTML" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = try examples(a);
    try std.testing.expectEqual(652, all.items.len);
    var failed: usize = 0;
    for (all.items) |e| {
        const got = try render(a, e.markdown);
        if (std.mem.eql(u8, got, e.html)) continue;
        failed += 1;
        if (failed <= 30) std.log.err("example {d}:\n{s}--- want\n{s}--- got\n{s}", .{ e.number, e.markdown, e.html, got });
    }
    if (failed != 0) std.log.err("{d} of {d} examples differ", .{ failed, all.items.len });
    try std.testing.expectEqual(0, failed);
}

fn renderSafe(gpa: std.mem.Allocator, markdown: []const u8) ![]u8 {
    var document = try Document.parse(gpa, .init(markdown), .{ .extensions = .commonmark });
    defer document.deinit();
    var events = try Events.init(gpa, &document);
    defer events.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try html.write(&out.writer, &events, .{});
    return out.toOwnedSlice();
}

test "safe by default: raw HTML is left out, and a destination that runs script is emptied" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "<div>\n*x*\n</div>\n", "<!-- raw HTML omitted -->\n" },
        .{ "a <b>c</b>\n", "<p>a <!-- raw HTML omitted -->c<!-- raw HTML omitted --></p>\n" },
        .{ "[a](javascript:alert(1))\n", "<p><a href=\"\">a</a></p>\n" },
        .{ "[a](JAVASCRIPT:x) [b](vbscript:x) [c](file:///etc) [d](data:text/html,x)\n", "<p><a href=\"\">a</a> <a href=\"\">b</a> <a href=\"\">c</a> <a href=\"\">d</a></p>\n" },
        .{ "![a](data:image/png;base64,AA==)\n", "<p><img src=\"data:image/png;base64,AA==\" alt=\"a\" /></p>\n" },
        .{ "<javascript:x>\n", "<p><a href=\"\">javascript:x</a></p>\n" },
        .{ "a\x00b &#0;\n", "<p>a\u{FFFD}b \u{FFFD}</p>\n" },
    };
    for (cases) |c| {
        const got = try renderSafe(gpa, c[0]);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
}
