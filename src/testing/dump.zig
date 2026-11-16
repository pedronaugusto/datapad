//! The block table written as text, for tests to compare: a row per block,
//! indented by its depth, its kind and what its record says, and a row per
//! content line under a leaf, `|` and the line (a tab's rest as spaces).
const std = @import("std");
const Document = @import("../Document.zig");

pub fn write(w: *std.Io.Writer, document: *const Document) std.Io.Writer.Error!void {
    const text = document.text();
    for (document.blocks()) |b| {
        try w.splatByteAll(' ', 2 * @as(usize, b.depth));
        switch (b.data) {
            .none => try w.writeAll(switch (b.kind) {
                .block_quote => "quote",
                .item => "item",
                .paragraph => "para",
                .thematic_break => "rule",
                else => @tagName(b.kind),
            }),
            .heading => |h| try w.print("h{d}{s}", .{ h.level.widen(u8), if (h.setext) " setext" else "" }),
            .list => |l| if (l.ordered)
                try w.print("list {d}{c} {s}", .{ l.start, l.marker, if (l.tight) "tight" else "loose" })
            else
                try w.print("list {c} {s}", .{ l.marker, if (l.tight) "tight" else "loose" }),
            .code => |c| if (c.fenced) try w.print("code `{s}`", .{c.info.of(text)}) else try w.writeAll("code"),
            .html => |h| try w.print("html {d}", .{h.widen(u8)}),
            .table => |n| try w.print("table {d}", .{n}),
            .front_matter => |f| try w.print("front matter {t}", .{f}),
        }
        try w.writeByte('\n');
        for (document.lines(b)) |l| {
            try w.splatByteAll(' ', 2 * @as(usize, b.depth) + 2);
            try w.writeByte('|');
            try w.splatByteAll(' ', l.spaces);
            try w.print("{s}\n", .{l.of(text)});
        }
    }
}

/// `text` parsed with `options` and dumped.
pub fn expect(text: []const u8, options: Document.Options, expected: []const u8) !void {
    const testing = std.testing;
    var document = try Document.parse(testing.allocator, .init(text), options);
    defer document.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, &document);
    try testing.expectEqualStrings(expected, out.written());
}
