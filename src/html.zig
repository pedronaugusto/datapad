//! The HTML writer over events: CommonMark's reference output, as cmark
//! writes it. Safe by default: raw HTML is written as a comment saying it
//! was left out, and a link or image whose destination runs script
//! (`javascript:`, `vbscript:`, `file:`, or `data:` other than an image
//! type) gets an empty one. `unsafe` writes both as they are.
const std = @import("std");
const aegis = @import("aegis");
const xenoglyph = @import("xenoglyph");
const Document = @import("Document.zig");
const Events = @import("Events.zig");
const Span = @import("Span.zig");
const chars = @import("scan/chars.zig");
const inline_pass = @import("inline.zig");

const Writer = std.Io.Writer;

pub const Options = struct {
    unsafe: bool = false,
    /// How a soft line break is written.
    soft_break: enum { newline, space, br } = .newline,
};

pub const Error = Writer.Error || error{ExpansionTooLarge};

/// How deep the writer tracks containers: the deepest nesting a
/// document's limits allow.
const most_depth = 1024;

const Container = enum(u8) { quote, list, tight_list, item };

const State = struct {
    w: *Writer,
    document: *const Document,
    events: *const Events,
    options: Options,
    /// Whether anything was written, and whether it ended a line.
    started: bool = false,
    at_line_start: bool = true,
    containers: [most_depth]Container = undefined,
    depth: usize = 0,
    /// Inside an image: its alt text is plain, and nested images count.
    plain: usize = 0,
    /// A code span or raw HTML whose pieces are being joined: its span.
    joining: ?Span = null,
    joining_code: bool = false,
    in_code_block: bool = false,
    in_html_block: bool = false,

    fn put(s: *State, bytes: []const u8) Writer.Error!void {
        if (bytes.len == 0) return;
        try s.w.writeAll(bytes);
        s.started = true;
        s.at_line_start = bytes[bytes.len - 1] == '\n';
    }

    /// A line ending unless one was just written.
    fn cr(s: *State) Writer.Error!void {
        if (s.started and !s.at_line_start) try s.put("\n");
    }

    fn text(s: *State, bytes: []const u8) Writer.Error!void {
        try escape(s.w, bytes);
        if (bytes.len != 0) {
            s.started = true;
            s.at_line_start = false;
        }
    }

    fn endJoin(s: *State) Writer.Error!void {
        if (s.joining == null) return;
        if (s.joining_code and s.plain == 0) try s.put("</code>");
        s.joining = null;
    }
};

/// Writes `events` as HTML.
pub fn write(w: *Writer, events: *Events, options: Options) Error!void {
    var s: State = .{ .w = w, .document = events.document, .events = events, .options = options };
    const text = events.document.text();
    while (try events.next()) |e| {
        const piece_of_joined = switch (e.kind) {
            .code, .html => s.joining != null and std.meta.eql(s.joining.?, e.span),
            else => false,
        };
        if (!piece_of_joined) try s.endJoin();
        switch (e.kind) {
            .enter => |n| try enter(&s, e, n),
            .exit => |n| try exit(&s, n),
            .text => {
                try s.text(e.span.of(text));
                if (s.in_code_block) try s.put("\n");
            },
            .spaces => |n| {
                if (s.in_html_block and !s.options.unsafe) continue;
                try s.w.splatByteAll(' ', n);
                s.started = true;
                s.at_line_start = false;
            },
            .escape => try s.text(e.span.of(text)[1..2]),
            .reference => |r| {
                var buffer: [8]u8 = undefined;
                var len = std.unicode.utf8Encode(r.first, &buffer) catch aegis.assert.never("a reference's code point is a scalar value");
                if (r.second != 0) len += std.unicode.utf8Encode(r.second, buffer[len..]) catch aegis.assert.never("a reference's code point is a scalar value");
                try s.text(buffer[0..len]);
            },
            .code => |piece| {
                if (piece_of_joined) {
                    try s.text(" ");
                } else {
                    if (s.plain == 0) try s.put("<code>");
                    s.joining = e.span;
                    s.joining_code = true;
                }
                try s.text(piece.of(text));
            },
            .html => |piece| {
                if (s.in_html_block) {
                    if (s.options.unsafe) {
                        try s.put(piece.of(text));
                        try s.put("\n");
                    }
                    continue;
                }
                if (s.plain != 0) {
                    if (piece_of_joined) try s.text("\n");
                    try s.text(piece.of(text));
                } else if (s.options.unsafe) {
                    if (piece_of_joined) try s.put("\n");
                    try s.put(piece.of(text));
                } else if (!piece_of_joined) try s.put("<!-- raw HTML omitted -->");
                s.joining = e.span;
                s.joining_code = false;
            },
            .soft_break => if (s.plain != 0) try s.text(" ") else switch (s.options.soft_break) {
                .newline => try s.put("\n"),
                .space => try s.put(" "),
                .br => try s.put("<br />\n"),
            },
            .hard_break => if (s.plain != 0) try s.text(" ") else try s.put("<br />\n"),
            .rule => {
                try s.cr();
                try s.put("<hr />\n");
            },
            // Task list items are GFM's, written by a later writer.
            .task => {},
        }
    }
    try s.endJoin();
}

fn push(s: *State, c: Container) void {
    aegis.assert.invariant(s.depth < most_depth, "containers nest no deeper than the depth limit allows");
    s.containers[s.depth] = c;
    s.depth += 1;
}

/// Whether a paragraph here is in an item of a tight list.
fn inTightItem(s: *const State) bool {
    return s.depth >= 2 and s.containers[s.depth - 1] == .item and s.containers[s.depth - 2] == .tight_list;
}

fn enter(s: *State, e: Events.Event, n: Events.Node) Error!void {
    const text = s.document.text();
    if (s.plain != 0) {
        // Inside an image's alt text only text counts.
        if (n == .image) s.plain += 1;
        return;
    }
    switch (n) {
        .block_quote => {
            try s.cr();
            try s.put("<blockquote>\n");
            push(s, .quote);
        },
        .list => |l| {
            try s.cr();
            if (!l.ordered) {
                try s.put("<ul>\n");
            } else if (l.start == 1) {
                try s.put("<ol>\n");
            } else try s.w.print("<ol start=\"{d}\">\n", .{l.start});
            s.at_line_start = true;
            s.started = true;
            push(s, if (l.tight) .tight_list else .list);
        },
        .item => {
            try s.cr();
            try s.put("<li>");
            push(s, .item);
        },
        .paragraph => if (!inTightItem(s)) {
            try s.cr();
            try s.put("<p>");
        },
        .heading => |h| {
            try s.cr();
            try s.w.print("<h{d}>", .{h.level.widen(u8)});
            s.started = true;
            s.at_line_start = false;
        },
        .code_block => |c| {
            try s.cr();
            try s.put("<pre><code");
            const info = c.info.of(text);
            var word_end: usize = 0;
            while (word_end < info.len and info[word_end] != ' ' and info[word_end] != '\t') word_end += 1;
            if (word_end != 0) {
                try s.put(" class=\"language-");
                try unescaped(s.w, info[0..word_end], .html);
                try s.put("\"");
            }
            try s.put(">");
            s.in_code_block = true;
        },
        .html_block => {
            try s.cr();
            if (!s.options.unsafe) try s.put("<!-- raw HTML omitted -->");
            s.in_html_block = true;
        },
        .emphasis => try s.put("<em>"),
        .strong => try s.put("<strong>"),
        .link => |l| {
            try s.put("<a href=\"");
            try destination(s, l);
            try s.put("\"");
            if (s.events.title(l)) |t| {
                try s.put(" title=\"");
                try unescaped(s.w, t.of(text), .html);
                try s.put("\"");
            }
            try s.put(">");
        },
        .image => |l| {
            try s.put("<img src=\"");
            try destination(s, l);
            try s.put("\" alt=\"");
            s.plain = 1;
        },
        else => {},
    }
    _ = e;
}

fn exit(s: *State, n: Events.Node) Error!void {
    const text = s.document.text();
    if (s.plain != 0) {
        if (n != .image) return;
        s.plain -= 1;
        if (s.plain != 0) return;
        try s.put("\"");
        if (s.events.title(n.image)) |t| {
            try s.put(" title=\"");
            try unescaped(s.w, t.of(text), .html);
            try s.put("\"");
        }
        try s.put(" />");
        return;
    }
    switch (n) {
        .block_quote => {
            s.depth -= 1;
            try s.cr();
            try s.put("</blockquote>\n");
        },
        .list => |l| {
            s.depth -= 1;
            try s.cr();
            try s.put(if (l.ordered) "</ol>\n" else "</ul>\n");
        },
        .item => {
            s.depth -= 1;
            try s.put("</li>\n");
        },
        .paragraph => if (!inTightItem(s)) try s.put("</p>\n"),
        .heading => |h| {
            try s.w.print("</h{d}>\n", .{h.level.widen(u8)});
            s.at_line_start = true;
        },
        .code_block => {
            s.in_code_block = false;
            try s.put("</code></pre>\n");
        },
        .html_block => {
            s.in_html_block = false;
            try s.cr();
        },
        .emphasis => try s.put("</em>"),
        .strong => try s.put("</strong>"),
        .link => try s.put("</a>"),
        else => {},
    }
}

/// Text escaped for HTML: `&`, `<`, `>` and `"` as references, U+0000 and
/// ill-formed UTF-8 as U+FFFD.
pub fn escape(w: *Writer, bytes: []const u8) Writer.Error!void {
    var at: usize = 0;
    var run: usize = 0;
    while (at < bytes.len) {
        const c = bytes[at];
        const replacement: ?[]const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            0 => "\u{FFFD}",
            else => null,
        };
        if (replacement) |r| {
            try w.writeAll(bytes[run..at]);
            try w.writeAll(r);
            at += 1;
            run = at;
            continue;
        }
        if (c < 0x80) {
            at += 1;
            continue;
        }
        const d = xenoglyph.utf8.decode(bytes[at..]);
        if (d.code_point == xenoglyph.utf8.replacement and !std.mem.startsWith(u8, bytes[at..], "\u{FFFD}")) {
            try w.writeAll(bytes[run..at]);
            try w.writeAll("\u{FFFD}");
            at += @max(d.len, 1);
            run = at;
            continue;
        }
        at += d.len;
    }
    try w.writeAll(bytes[run..]);
}

/// The bytes a destination, title or info string means: its backslash
/// escapes and character references resolved.
const Sink = enum { html, href };

fn emit(w: *Writer, sink: Sink, bytes: []const u8) Writer.Error!void {
    switch (sink) {
        .html => try escape(w, bytes),
        .href => try escapeHref(w, bytes),
    }
}

fn unescaped(w: *Writer, bytes: []const u8, sink: Sink) Writer.Error!void {
    var at: usize = 0;
    var run: usize = 0;
    while (at < bytes.len) {
        const c = bytes[at];
        if (c == '\\' and at + 1 < bytes.len and chars.isAsciiPunctuation(bytes[at + 1])) {
            try emit(w, sink, bytes[run..at]);
            try emit(w, sink, bytes[at + 1 .. at + 2]);
            at += 2;
            run = at;
            continue;
        }
        if (c == '&') if (inline_pass.reference.at(bytes, at)) |r| {
            try emit(w, sink, bytes[run..at]);
            var buffer: [8]u8 = undefined;
            var len = std.unicode.utf8Encode(r.first, &buffer) catch aegis.assert.never("a reference's code point is a scalar value");
            if (r.second != 0) len += std.unicode.utf8Encode(r.second, buffer[len..]) catch aegis.assert.never("a reference's code point is a scalar value");
            try emit(w, sink, buffer[0..len]);
            at = r.end;
            run = at;
            continue;
        };
        at += 1;
    }
    try emit(w, sink, bytes[run..]);
}

/// A destination as written, unescaped and its references decoded: the
/// URL it means.
pub fn writeDestination(w: *Writer, document: *const Document, link: Events.Link) Writer.Error!void {
    if (link.kind == .email) try w.writeAll("mailto:");
    if (link.kind == .autolink or link.kind == .email) return w.writeAll(link.destination.of(document.text()));
    try unescaped(w, link.destination.of(document.text()), .html);
}

/// The bytes a URL keeps as they are; every other is percent-encoded, but
/// `&` and `'`, which HTML escapes.
fn hrefSafe(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        '!', '#', '$', '%', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '=', '?', '@', '_', '~' => true,
        else => false,
    };
}

fn escapeHref(w: *Writer, bytes: []const u8) Writer.Error!void {
    var run: usize = 0;
    for (bytes, 0..) |c, at| {
        if (hrefSafe(c)) continue;
        try w.writeAll(bytes[run..at]);
        switch (c) {
            '&' => try w.writeAll("&amp;"),
            '\'' => try w.writeAll("&#x27;"),
            else => try w.print("%{X:0>2}", .{c}),
        }
        run = at + 1;
    }
    try w.writeAll(bytes[run..]);
}

/// A destination that runs script, which the safe writer leaves out.
fn dangerous(url: []const u8) bool {
    const lower = struct {
        fn starts(u: []const u8, prefix: []const u8) bool {
            return u.len >= prefix.len and std.ascii.eqlIgnoreCase(u[0..prefix.len], prefix);
        }
    };
    if (lower.starts(url, "data:")) {
        for ([_][]const u8{ "data:image/png", "data:image/gif", "data:image/jpeg", "data:image/webp" }) |ok| if (lower.starts(url, ok)) return false;
        return true;
    }
    return lower.starts(url, "javascript:") or lower.starts(url, "vbscript:") or lower.starts(url, "file:");
}

fn destination(s: *State, l: Events.Link) Writer.Error!void {
    const raw = l.destination.of(s.document.text());
    if (!s.options.unsafe and dangerous(raw)) return;
    switch (l.kind) {
        .email => {
            try s.put("mailto:");
            try escapeHref(s.w, raw);
        },
        .autolink, .extended => try escapeHref(s.w, raw),
        else => try unescaped(s.w, raw, .href),
    }
}

const testing = std.testing;

test "text escapes as HTML's, a NUL and ill-formed UTF-8 as U+FFFD" {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try escape(&w, "a<b>&\"c\"\x00\xff\u{e9}");
    try testing.expectEqualStrings("a&lt;b&gt;&amp;&quot;c&quot;\u{FFFD}\u{FFFD}\u{e9}", w.buffered());
}

test "a URL percent-encodes what it may not hold" {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try escapeHref(&w, "foo%20b\u{e4} [x]&'");
    try testing.expectEqualStrings("foo%20b%C3%A4%20%5Bx%5D&amp;&#x27;", w.buffered());
}
