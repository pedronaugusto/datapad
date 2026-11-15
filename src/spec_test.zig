//! CommonMark 0.31.2's examples and GFM 0.29's extension examples, read
//! from the specs as they are published (testdata/commonmark,
//! testdata/gfm): each one's Markdown parsed, its events written as HTML
//! with raw HTML allowed, and compared with the spec's HTML byte for byte.
const std = @import("std");
const Document = @import("Document.zig");
const Events = @import("Events.zig");
const html = @import("html.zig");

const spec = @embedFile("commonmark_spec");
const gfm_spec = @embedFile("gfm_spec");

const fence = "````````````````````````````````";

const Example = struct { number: usize, markdown: []const u8, html: []const u8 };

/// A spec's examples whose tag is one of `tags` (`""` for an untagged
/// one), in order, numbered among all of the spec's examples, with each
/// `→` a tab, as the specs write tabs.
fn examples(gpa: std.mem.Allocator, text: []const u8, tags: []const []const u8) !std.ArrayList(Example) {
    var list: std.ArrayList(Example) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, fence ++ " example")) continue;
        number += 1;
        const tag = std.mem.trim(u8, line[fence.len + " example".len ..], " ");
        const wanted = for (tags) |t| {
            if (std.mem.eql(u8, t, tag)) break true;
        } else false;
        if (!wanted) continue;
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

fn render(gpa: std.mem.Allocator, markdown: []const u8, extensions: @import("Options.zig").Extensions) ![]u8 {
    var document = try Document.parse(gpa, .init(markdown), .{ .extensions = extensions });
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
    const all = try examples(a, spec, &.{""});
    try std.testing.expectEqual(652, all.items.len);
    try expectAll(a, all.items, .commonmark);
}

test "every GFM 0.29 extension example gives the spec's HTML" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Task list items' examples are tagged `disabled`, as cmark-gfm's runner skips them.
    const all = try examples(a, gfm_spec, &.{ "table", "disabled", "strikethrough", "autolink", "tagfilter" });
    try std.testing.expectEqual(24, all.items.len);
    try expectAll(a, all.items, .gfm);
}

fn expectAll(a: std.mem.Allocator, all: []const Example, extensions: @import("Options.zig").Extensions) !void {
    var failed: usize = 0;
    for (all) |e| {
        const got = try render(a, e.markdown, extensions);
        if (std.mem.eql(u8, got, e.html)) continue;
        failed += 1;
        if (failed <= 30) std.log.err("example {d}:\n{s}--- want\n{s}--- got\n{s}", .{ e.number, e.markdown, e.html, got });
    }
    if (failed != 0) std.log.err("{d} of {d} examples differ", .{ failed, all.len });
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
