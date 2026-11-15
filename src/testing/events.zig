//! A document's events written as text, for tests to compare: a row per
//! event, indented by how many nodes are open, `<` and `>` for a node's
//! enter and exit, the bytes of a text, code piece or HTML piece quoted.
const std = @import("std");
const Document = @import("../Document.zig");
const Events = @import("../Events.zig");

fn quoted(w: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (bytes) |c| switch (c) {
        '\n' => try w.writeAll("\\n"),
        '"' => try w.writeAll("\\\""),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn node(w: *std.Io.Writer, events: *const Events, text: []const u8, n: Events.Node) std.Io.Writer.Error!void {
    switch (n) {
        .paragraph => try w.writeAll("para"),
        .block_quote => try w.writeAll("quote"),
        .heading => |h| try w.print("h{d}", .{h.level.widen(u8)}),
        .list => |l| if (l.ordered) try w.print("list {d}{c}", .{ l.start, l.marker }) else try w.print("list {c}", .{l.marker}),
        .item => try w.writeAll("item"),
        .code_block => |c| try w.print("code `{s}`", .{c.info.of(text)}),
        .html_block => try w.writeAll("html"),
        .emphasis => try w.writeAll("em"),
        .strong => try w.writeAll("strong"),
        .link, .image => |l| {
            try w.print("{s} {s} ", .{ if (n == .link) "link" else "image", @tagName(l.kind) });
            try quoted(w, l.destination.of(text));
            if (events.title(l)) |t| {
                try w.writeAll(" title ");
                try quoted(w, t.of(text));
            }
            if (events.label(l)) |t| {
                try w.writeAll(" label ");
                try quoted(w, t.of(text));
            }
        },
        else => try w.writeAll(@tagName(n)),
    }
}

pub fn write(w: *std.Io.Writer, events: *Events, text: []const u8) (std.Io.Writer.Error || error{ExpansionTooLarge})!void {
    var depth: usize = 0;
    while (try events.next()) |e| {
        if (e.kind == .exit) depth -= 1;
        try w.splatByteAll(' ', 2 * depth);
        switch (e.kind) {
            .enter => |n| {
                try w.writeByte('<');
                try node(w, events, text, n);
                depth += 1;
            },
            .exit => |n| {
                try w.writeByte('>');
                try node(w, events, text, n);
            },
            .text => try quoted(w, e.span.of(text)),
            .escape => try w.print("\\{c}", .{e.span.of(text)[1]}),
            .reference => |r| if (r.second != 0) try w.print("&U+{X:0>4} U+{X:0>4}", .{ r.first, r.second }) else try w.print("&U+{X:0>4}", .{r.first}),
            .code => |piece| {
                try w.writeAll("code ");
                try quoted(w, piece.of(text));
            },
            .html => |piece| {
                try w.writeAll("raw ");
                try quoted(w, piece.of(text));
            },
            .spaces => |n| try w.print("spaces {d}", .{n}),
            .task => |done| try w.print("task {}", .{done}),
            else => try w.writeAll(@tagName(e.kind)),
        }
        try w.writeByte('\n');
    }
}

/// `text` parsed with `options`, its events dumped.
pub fn expect(text: []const u8, options: Document.Options, expected: []const u8) !void {
    const testing = std.testing;
    var document = try Document.parse(testing.allocator, .init(text), options);
    defer document.deinit();
    var events = try Events.init(testing.allocator, &document);
    defer events.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, &events, text);
    try testing.expectEqualStrings(expected, out.written());
}
