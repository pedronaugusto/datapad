//! One leaf's inlines (CommonMark 0.31.2 §6): a paragraph's or a heading's
//! lines joined by line feeds, read once from left to right into a list of
//! items, emphasis matched at each link's end and at the leaf's end, then
//! given out as events with spans in the document's text.
//!
//! Everything the leaf needs lies in one block sized by its length
//! (`counts`), which `Events` sizes once for the largest leaf: reading a
//! leaf allocates nothing.
const Leaf = @This();
const std = @import("std");
const aegis = @import("aegis");
const Span = @import("../Span.zig");
const Block = @import("../block/Block.zig");
const Document = @import("../Document.zig");
const event = @import("../event.zig");
const chars = @import("../scan/chars.zig");
const items = @import("items.zig");
const delimiters = @import("delimiters.zig");
const links = @import("links.zig");
const code = @import("code.zig");
const html = @import("html.zig");
const autolink = @import("autolink.zig");
const reference = @import("reference.zig");
const extended = @import("extended.zig");

const none = items.none;

/// A link or an image the leaf holds.
pub const Record = struct {
    link: event.Link,
    image: bool,
    /// From its `[`, `![` or `<` to its last byte.
    span: Span,
    /// Its reference passed the expansion limit.
    over: bool = false,
    /// A GFM extended autolink, read bare in text: a link around it takes
    /// it back as text.
    bare: bool = false,
};

/// A link's title and label, which `Events.title` and `Events.label` give,
/// with the destination the link carries, which a lookup checks.
pub const Part = struct {
    destination: Span,
    title: ?Span,
    label: ?Span,
};

/// The bytes reference links have reproduced so far, against the limit.
pub const Expansion = struct {
    used: u64 = 0,
    limit: u64,
};

pub const Memory = aegis.parts.Block(struct {
    joined: []u8,
    line_joined: []u32,
    line_source: []u32,
    items: []items.Item,
    delimiters: []delimiters.Delimiter,
    brackets: []links.Bracket,
    records: []Record,
    parts: []Part,
    runs: []code.Run,
    run_next: []u32,
    run_heads: []u32,
    collapsed: []u8,
    folded: []u8,
});

/// What a leaf of `bytes` (its lines, a line feed counted after each)
/// needs. Each count bounds what one byte can make: an item per byte read,
/// one per delimiter character a match takes, and four per e-mail address
/// (of three bytes at least, `a@b.c` five); a link per three bytes (`[a]`),
/// a backtick run per two.
pub fn counts(bytes: usize) Memory.Counts {
    const runs = code.Table.bounds(bytes);
    return .{
        .joined = bytes,
        .line_joined = bytes + 1,
        .line_source = bytes + 1,
        .items = 3 * bytes + 8,
        .delimiters = bytes + 1,
        .brackets = bytes + 1,
        .records = bytes / 3 + 2,
        .parts = bytes / 3 + 2,
        .runs = runs.runs,
        .run_next = runs.runs,
        .run_heads = runs.lengths,
        .collapsed = links.Scratch.collapsed_len,
        .folded = links.Scratch.folded_len,
    };
}

/// The joined text.
s: []const u8,
/// Where each line starts in the joined text and in the document's.
line_joined: []const u32,
line_source: []const u32,
list: items.List,
records: []Record,
parts: []Part,
part_count: u32 = 0,
/// The next item to give out.
cursor: u32,
/// In a code span or raw HTML over lines: where its next piece starts.
piece: u32 = none,
/// A task list item's marker (GFM) this leaf begins with, given before its
/// content: whether it is checked, and its `[` to `]` in the joined text.
task: ?Task = null,

pub const Task = struct { done: bool, start: u32, end: u32 };

/// No leaf: nothing to give out, and no link's parts.
pub const empty: Leaf = .{
    .s = "",
    .line_joined = &.{},
    .line_source = &.{},
    .list = .{ .items = &.{} },
    .records = &.{},
    .parts = &.{},
    .cursor = none,
};

/// Reads the leaf whose content lines are `lines` into `memory`, laid out
/// by `counts` of at least its bytes. `item_start`: the leaf is the first
/// block of a list item, where GFM reads a task list item's marker.
pub fn read(memory: Memory, document: *const Document, lines: []const Block.Line, expansion: *Expansion, item_start: bool) Leaf {
    const m = memory.parts();
    const text = document.text();
    var n: usize = 0;
    for (lines, 0..) |l, i| {
        if (i != 0) {
            m.joined[n] = '\n';
            n += 1;
        }
        m.line_joined[i] = @intCast(n);
        m.line_source[i] = l.start;
        const bytes = l.of(text);
        @memcpy(m.joined[n..][0..bytes.len], bytes);
        n += bytes.len;
    }
    // A paragraph's final spaces and tabs are not its content.
    if (lines.len != 0) {
        const last = m.line_joined[lines.len - 1];
        while (n > last and chars.isSpaceOrTab(m.joined[n - 1])) n -= 1;
    }
    var leaf: Leaf = .{
        .s = m.joined[0..n],
        .line_joined = m.line_joined[0..lines.len],
        .line_source = m.line_source[0..lines.len],
        .list = .{ .items = m.items },
        .records = m.records[0..0],
        .parts = m.parts,
        .cursor = none,
    };
    var p: Parser = .{
        .leaf = &leaf,
        .document = document,
        .s = leaf.s,
        .delimiters = .{ .entries = m.delimiters },
        .brackets = .{ .entries = m.brackets },
        .runs = .build(leaf.s, m.runs, m.run_next, m.run_heads),
        .scratch = .{ .collapsed = m.collapsed, .folded = m.folded },
        .records = m.records,
        .expansion = expansion,
    };
    if (item_start and document.extensions.task_lists) leaf.task = taskMarker(leaf.s);
    if (leaf.task) |t| p.pos = t.end;
    p.run();
    leaf.records = m.records[0..p.record_count];
    leaf.cursor = leaf.list.head;
    return leaf;
}

/// A task list item's marker at the start of `s` (GFM): spaces, `[`, a
/// space, a tab or an `x` in either case, `]`, then whitespace before
/// anything else.
fn taskMarker(s: []const u8) ?Task {
    var i: usize = 0;
    while (i < s.len and s[i] == ' ') i += 1;
    if (s.len < i + 4 or s[i] != '[' or s[i + 2] != ']') return null;
    const done = switch (s[i + 1]) {
        ' ', '\t' => false,
        'x', 'X' => true,
        else => return null,
    };
    switch (s[i + 3]) {
        ' ', '\t', '\n' => {},
        else => return null,
    }
    return .{ .done = done, .start = @intCast(i), .end = @intCast(i + 3) };
}

/// Where the joined text's offset `j` lies in the document's text.
pub fn source(leaf: *const Leaf, j: usize) u32 {
    var low: usize = 0;
    var high: usize = leaf.line_joined.len;
    while (high - low > 1) {
        const mid = low + (high - low) / 2;
        if (leaf.line_joined[mid] <= j) low = mid else high = mid;
    }
    return leaf.line_source[low] + @as(u32, @intCast(j - leaf.line_joined[low]));
}

pub fn spanOf(leaf: *const Leaf, start: usize, end: usize) Span {
    return .init(leaf.source(start), leaf.source(end));
}

/// A link's title and label, checked to be this leaf's.
pub fn part(leaf: *const Leaf, link: event.Link) ?Part {
    if (link.parts == event.Link.none) return null;
    aegis.assert.invariant(link.parts < leaf.part_count and std.meta.eql(leaf.parts[link.parts].destination, link.destination), "a link's title and label are read while its leaf is");
    return leaf.parts[link.parts];
}

/// The next event of the leaf's content, or null at its end.
pub fn next(leaf: *Leaf) error{ExpansionTooLarge}!?event.Event {
    if (leaf.task) |t| {
        leaf.task = null;
        return .{ .span = leaf.spanOf(t.start, t.end), .kind = .{ .task = t.done } };
    }
    const list = &leaf.list;
    while (leaf.cursor != none) {
        const at = leaf.cursor;
        const it = list.items[at];
        switch (it.kind) {
            .text, .delimiter, .bracket => {
                // A run of text items is one event: they never cross a line.
                var end = it.end;
                var following = it.next;
                while (following != none and list.items[following].textual() and list.items[following].start == end) {
                    end = list.items[following].end;
                    following = list.items[following].next;
                }
                leaf.cursor = following;
                if (end == it.start) continue;
                return .{ .span = leaf.spanOf(it.start, end), .kind = .text };
            },
            .escape, .soft_break, .hard_break => {
                leaf.cursor = it.next;
                return .{ .span = leaf.spanOf(it.start, it.end), .kind = switch (it.kind) {
                    .escape => .escape,
                    .soft_break => .soft_break,
                    else => .hard_break,
                } };
            },
            .reference => {
                leaf.cursor = it.next;
                return .{ .span = leaf.spanOf(it.start, it.end), .kind = .{ .reference = .{ .first = @intCast(it.a), .second = @intCast(it.b) } } };
            },
            .code, .html => {
                // One piece per line: a code span's content, raw HTML whole.
                const from: u32 = if (leaf.piece != none) leaf.piece else if (it.kind == .code) it.a else it.start;
                const to: u32 = if (it.kind == .code) it.b else it.end;
                const piece_end = if (std.mem.findScalarPos(u8, leaf.s[0..to], from, '\n')) |nl| nl else to;
                if (piece_end < to) {
                    leaf.piece = @intCast(piece_end + 1);
                } else {
                    leaf.piece = none;
                    leaf.cursor = it.next;
                }
                const piece = leaf.spanOf(from, piece_end);
                const whole = leaf.spanOf(it.start, it.end);
                return .{ .span = whole, .kind = if (it.kind == .code) .{ .code = piece } else .{ .html = piece } };
            },
            .emphasis_open, .strong_open, .strike_open => {
                leaf.cursor = it.next;
                const node: event.Node = switch (it.kind) {
                    .strong_open => .strong,
                    .strike_open => .strikethrough,
                    else => .emphasis,
                };
                return .{ .span = leaf.spanOf(it.start, list.items[it.a].end), .kind = .{ .enter = node } };
            },
            .emphasis_close, .strong_close, .strike_close => {
                leaf.cursor = it.next;
                const node: event.Node = switch (it.kind) {
                    .strong_close => .strong,
                    .strike_close => .strikethrough,
                    else => .emphasis,
                };
                return .{ .span = leaf.spanOf(list.items[it.a].start, it.end), .kind = .{ .exit = node } };
            },
            .link_open, .link_close => {
                const r = leaf.records[it.a];
                if (it.kind == .link_open and r.over) return error.ExpansionTooLarge;
                leaf.cursor = it.next;
                const node: event.Node = if (r.image) .{ .image = r.link } else .{ .link = r.link };
                return .{ .span = r.span, .kind = if (it.kind == .link_open) .{ .enter = node } else .{ .exit = node } };
            },
        }
    }
    return null;
}

/// The record of the link whose enter `next` refused: where the limit was
/// passed.
pub fn refused(leaf: *const Leaf) Span {
    return leaf.records[leaf.list.items[leaf.cursor].a].span;
}

/// The bytes that start an inline construct; every other byte is text.
const special = blk: {
    var t: [256]bool = @splat(false);
    // `w`, `h` and `f` start GFM's extended www and URL autolinks.
    for ("\n\\`*_~[!]<&whf") |c| t[c] = true;
    break :blk t;
};

const Parser = struct {
    leaf: *Leaf,
    document: *const Document,
    s: []const u8,
    pos: usize = 0,
    text_start: usize = 0,
    delimiters: delimiters.Stack,
    brackets: links.Stack,
    runs: code.Table,
    html_scan: html.Scan = .{},
    scratch: links.Scratch,
    records: []Record,
    record_count: u32 = 0,
    expansion: *Expansion,

    /// The text read since the last item, up to `end`, as an item.
    fn flush(p: *Parser, end: usize) void {
        if (end > p.text_start) _ = p.leaf.list.append(.{ .start = @intCast(p.text_start), .end = @intCast(end), .kind = .text });
    }

    /// The text before it, then an item from `start` to `end`; reading goes
    /// on after it.
    fn add(p: *Parser, start: usize, end: usize, kind: items.Kind, a: u32, b: u32) u32 {
        p.flush(start);
        const at = p.leaf.list.append(.{ .start = @intCast(start), .end = @intCast(end), .kind = kind, .a = a, .b = b });
        p.pos = end;
        p.text_start = end;
        return at;
    }

    /// Reads from `pos`: the leaf's start, or past a task marker.
    fn run(p: *Parser) void {
        const s = p.s;
        while (p.pos < s.len and chars.isSpaceOrTab(s[p.pos])) p.pos += 1;
        p.text_start = p.pos;
        while (p.pos < s.len) {
            const c = s[p.pos];
            if (!special[c]) {
                p.pos += 1;
                continue;
            }
            switch (c) {
                '\n' => p.lineEnding(),
                '\\' => p.backslash(),
                '`' => p.backticks(),
                '*', '_' => p.delimiterRun(c),
                '~' => if (p.document.extensions.strikethrough) p.delimiterRun(c) else {
                    p.pos += 1;
                },
                '[' => p.openBracket(1, false),
                '!' => if (p.pos + 1 < s.len and s[p.pos + 1] == '[') p.openBracket(2, true) else {
                    p.pos += 1;
                },
                ']' => p.closeBracket(),
                '<' => p.angle(),
                'w', 'h', 'f' => if (p.document.extensions.autolinks) p.bareUrl() else {
                    p.pos += 1;
                },
                '&' => if (reference.at(s, p.pos)) |r| {
                    _ = p.add(p.pos, r.end, .reference, r.first, r.second);
                } else {
                    p.pos += 1;
                },
                else => aegis.assert.never("only a special byte stops the text"),
            }
        }
        p.flush(s.len);
        delimiters.process(&p.delimiters, &p.leaf.list, delimiters.none);
        if (p.document.extensions.autolinks) p.emails();
    }

    /// GFM's extended e-mail autolinks, found as cmark-gfm finds them: in
    /// the text emphasis left, a run of text items outside any link at a
    /// time. A run with an address becomes one text item, split around it.
    fn emails(p: *Parser) void {
        const list = &p.leaf.list;
        var inside: usize = 0;
        var at = list.head;
        while (at != none) {
            const it = list.items[at];
            switch (it.kind) {
                .link_open => if (!p.records[it.a].image) {
                    inside += 1;
                },
                .link_close => if (!p.records[it.a].image) {
                    inside -= 1;
                },
                else => {},
            }
            if (!it.textual() or inside != 0) {
                at = it.next;
                continue;
            }
            // The run: text items that touch, on one line.
            var last = at;
            while (list.items[last].next != none and list.items[list.items[last].next].textual() and list.items[list.items[last].next].start == list.items[last].end) last = list.items[last].next;
            const start = it.start;
            const end = list.items[last].end;
            const after = list.items[last].next;
            if (std.mem.findScalar(u8, p.s[start..end], '@') != null) {
                // One text item for the run, the others emptied at its end.
                var other = it.next;
                while (other != after) : (other = list.items[other].next) {
                    list.items[other] = .{ .start = @intCast(end), .end = @intCast(end), .prev = list.items[other].prev, .next = list.items[other].next, .kind = .text };
                }
                list.items[at].kind = .text;
                list.items[at].end = @intCast(end);
                p.splitEmails(at, end);
            }
            at = after;
        }
    }

    /// The text item `at`, up to `end`, split around each address in it.
    fn splitEmails(p: *Parser, first: u32, end: u32) void {
        const list = &p.leaf.list;
        var at = first;
        var scan: usize = list.items[at].start;
        while (std.mem.findScalarPos(u8, p.s[0..end], scan, '@')) |sign| {
            const from = list.items[at].start;
            const f = extended.email(p.s[0..end], from, sign) orelse {
                scan = sign + 1;
                continue;
            };
            const leaf = p.leaf;
            const r = p.record(.{
                .link = .{ .kind = .email, .destination = leaf.spanOf(f.start, f.end) },
                .image = false,
                .span = leaf.spanOf(f.start, f.end),
                .bare = true,
            }, 0);
            // [from, start) text, the link of [start, end), then [end, ..) text.
            list.items[at].end = @intCast(f.start);
            const open = list.insertAfter(at, .{ .start = @intCast(f.start), .end = @intCast(f.start), .kind = .link_open, .a = r });
            const text = list.insertAfter(open, .{ .start = @intCast(f.start), .end = @intCast(f.end), .kind = .text });
            const close = list.insertAfter(text, .{ .start = @intCast(f.end), .end = @intCast(f.end), .kind = .link_close, .a = r });
            at = list.insertAfter(close, .{ .start = @intCast(f.end), .end = end, .kind = .text });
            scan = f.end;
        }
    }

    /// Past the spaces and tabs that start the next line.
    fn skipIndent(p: *Parser, from: usize) usize {
        var at = from;
        while (at < p.s.len and chars.isSpaceOrTab(p.s[at])) at += 1;
        return at;
    }

    /// A line ending: hard after two spaces or more, else soft. The spaces
    /// and tabs either side of it are its, not the text's.
    fn lineEnding(p: *Parser) void {
        const s = p.s;
        var trail = p.pos;
        while (trail > p.text_start and chars.isSpaceOrTab(s[trail - 1])) trail -= 1;
        var spaces = p.pos;
        while (spaces > p.text_start and s[spaces - 1] == ' ') spaces -= 1;
        const hard = p.pos - spaces >= 2;
        _ = p.add(trail, p.skipIndent(p.pos + 1), if (hard) .hard_break else .soft_break, 0, 0);
    }

    fn backslash(p: *Parser) void {
        const s = p.s;
        const at = p.pos;
        if (at + 1 < s.len and s[at + 1] == '\n') {
            _ = p.add(at, p.skipIndent(at + 2), .hard_break, 0, 0);
        } else if (at + 1 < s.len and chars.isAsciiPunctuation(s[at + 1])) {
            _ = p.add(at, at + 2, .escape, 0, 0);
        } else p.pos += 1;
    }

    fn backticks(p: *Parser) void {
        const s = p.s;
        const start = p.pos;
        var after = start;
        while (after < s.len and s[after] == '`') after += 1;
        if (p.runs.closer(after - start, after)) |closer| {
            const content = code.strip(s, after, closer.start);
            _ = p.add(start, closer.end, .code, @intCast(content.start), @intCast(content.end));
        } else {
            // No closer: the whole string is text.
            p.pos = after;
        }
    }

    fn delimiterRun(p: *Parser, c: u8) void {
        const s = p.s;
        const start = p.pos;
        var end = start;
        while (end < s.len and s[end] == c) end += 1;
        // GFM's strikethrough takes one tilde or two; more are text.
        if (c == '~' and end - start > 2) {
            p.pos = end;
            return;
        }
        const f = delimiters.classify(s, start, end, c);
        const at = p.add(start, end, .delimiter, c, 0);
        if (f.can_open or f.can_close) p.delimiters.push(.{
            .item = at,
            .prev = undefined,
            .next = undefined,
            .char = c,
            .can_open = f.can_open,
            .can_close = f.can_close,
            .length = @intCast(end - start),
        });
    }

    fn openBracket(p: *Parser, len: usize, image: bool) void {
        const at = p.add(p.pos, p.pos + len, .bracket, 0, 0);
        p.brackets.push(.{ .item = at, .delimiters = p.delimiters.top, .image = image });
    }

    /// A `]`: a link or image if the bracket on top can make one here,
    /// else text.
    fn closeBracket(p: *Parser) void {
        const s = p.s;
        const at = p.pos;
        const top = p.brackets.top() orelse {
            p.pos += 1;
            return;
        };
        const opener = top.*;
        if (!opener.active) {
            p.brackets.pop();
            p.pos += 1;
            return;
        }
        const after = at + 1;
        if (after < s.len and s[after] == '(') {
            if (links.inlineTail(s, after)) |t| {
                const title: ?Span = if (t.title) |r| p.leaf.spanOf(r.start, r.end) else null;
                p.link(opener, at, t.end, .inline_, p.leaf.spanOf(t.destination.start, t.destination.end), title, null, 0);
                return;
            }
        }
        var kind: event.Link.Kind = .shortcut;
        var end = after;
        var label: ?links.Range = null;
        if (after < s.len and s[after] == '[') {
            if (links.labelAt(s, after)) |l| {
                end = l.end;
                if (l.inner.end > l.inner.start) {
                    kind = .reference;
                    label = l.inner;
                } else kind = .collapsed;
            }
        }
        if (label == null) {
            // A collapsed or shortcut reference's label is its text, which
            // a bracket read inside it rules out.
            if (opener.bracket_after) return p.noLink();
            label = .{ .start = p.leaf.list.items[opener.item].end, .end = at };
        }
        const l = label.?;
        const key = links.normalize(p.scratch, s[l.start..l.end]) orelse return p.noLink();
        const definition = p.document.find(key) orelse return p.noLink();
        const reproduced = @as(u64, definition.destination.len().raw()) + if (definition.title) |t| t.len().raw() else 0;
        p.link(opener, at, end, kind, definition.destination, definition.title, p.leaf.spanOf(l.start, l.end), reproduced);
    }

    fn noLink(p: *Parser) void {
        p.brackets.pop();
        p.pos += 1;
    }

    /// The bracket `opener` and the `]` at `close` make a link ending at
    /// `end`.
    fn link(p: *Parser, opener: links.Bracket, close: usize, end: usize, kind: event.Link.Kind, destination: Span, title: ?Span, label: ?Span, reproduced: u64) void {
        const leaf = p.leaf;
        var parts: u32 = event.Link.none;
        if (title != null or label != null) {
            parts = leaf.part_count;
            leaf.parts[parts] = .{ .destination = destination, .title = title, .label = label };
            leaf.part_count += 1;
        }
        const r = p.record(.{
            .link = .{ .kind = kind, .destination = destination, .parts = parts },
            .image = opener.image,
            .span = leaf.spanOf(leaf.list.items[opener.item].start, end),
        }, reproduced);
        leaf.list.items[opener.item].kind = .link_open;
        leaf.list.items[opener.item].a = r;
        const closing = p.add(close, end, .link_close, r, 0);
        // No link holds another: the bare links read in its text are text.
        var at = leaf.list.items[opener.item].next;
        while (at != closing) : (at = leaf.list.items[at].next) {
            const it = &leaf.list.items[at];
            if ((it.kind == .link_open or it.kind == .link_close) and p.records[it.a].bare) it.kind = .text;
        }
        delimiters.process(&p.delimiters, &leaf.list, opener.delimiters);
        p.brackets.pop();
        if (!opener.image) p.brackets.deactivate();
    }

    fn record(p: *Parser, r: Record, reproduced: u64) u32 {
        aegis.assert.invariant(p.record_count < p.records.len, "a leaf's links fit the memory sized for it");
        const at = p.record_count;
        p.records[at] = r;
        p.record_count += 1;
        if (reproduced != 0) {
            p.expansion.used += reproduced;
            if (p.expansion.used > p.expansion.limit) p.records[at].over = true;
        }
        return at;
    }

    fn bareUrl(p: *Parser) void {
        if (extended.url(p.s, p.pos)) |f| p.bare(f) else p.pos += 1;
    }

    /// A GFM extended autolink: its text, between an opening and a closing
    /// item of no bytes.
    fn bare(p: *Parser, f: extended.Found) void {
        const leaf = p.leaf;
        const r = p.record(.{
            .link = .{ .kind = if (f.email) .email else .extended, .destination = leaf.spanOf(f.start, f.end) },
            .image = false,
            .span = leaf.spanOf(f.start, f.end),
            .bare = true,
        }, 0);
        _ = p.add(f.start, f.start, .link_open, r, 0);
        _ = p.add(f.start, f.end, .text, 0, 0);
        _ = p.add(f.end, f.end, .link_close, r, 0);
    }

    /// A `<`: an autolink, raw HTML, or text.
    fn angle(p: *Parser) void {
        const s = p.s;
        const start = p.pos;
        if (autolink.at(s, start)) |a| {
            const leaf = p.leaf;
            const r = p.record(.{
                .link = .{ .kind = if (a.kind == .uri) .autolink else .email, .destination = leaf.spanOf(start + 1, a.end - 1) },
                .image = false,
                .span = leaf.spanOf(start, a.end),
            }, 0);
            _ = p.add(start, start + 1, .link_open, r, 0);
            _ = p.add(start + 1, a.end - 1, .text, 0, 0);
            _ = p.add(a.end - 1, a.end, .link_close, r, 0);
            return;
        }
        if (html.end(&p.html_scan, s, start)) |e| {
            _ = p.add(start, e, .html, 0, 0);
            return;
        }
        p.pos += 1;
    }
};
