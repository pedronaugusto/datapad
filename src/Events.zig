//! The pull iterator: a document's blocks in order, each container entered
//! and exited around what it holds, each leaf's content between its enter
//! and exit (a paragraph's and a heading's inlines, a code block's and an
//! HTML block's lines).
//!
//! It runs in memory sized once from the document (`memory`): the stack of
//! containers open, and one leaf's inline pass sized for the largest leaf.
//! `next` never allocates, and returns after every event, so a caller on
//! an `Io` cancels between events.
const Events = @This();
const std = @import("std");
const aegis = @import("aegis");
const Span = @import("Span.zig");
const Document = @import("Document.zig");
const Block = @import("block/Block.zig");
const event = @import("event.zig");
const Leaf = @import("inline.zig").Leaf;

pub const Event = event.Event;
pub const Node = event.Node;
pub const Link = event.Link;

document: *const Document,
/// Set when `init` allocated the memory, which `deinit` frees.
gpa: ?std.mem.Allocator,
buffer: []u8,
/// The containers open, by block index.
stack: []u32,
depth: u32 = 0,
/// The next block of the table.
block: u32 = 0,
/// The leaf being given out, by block index.
current: u32 = 0,
state: State = .blocks,
/// A code or HTML block's next line, and whether its tab's columns were
/// given yet.
line: u32 = 0,
spaced: bool = false,
scratch: []align(Leaf.Memory.alignment) u8,
leaf: Leaf = .empty,
expansion: Leaf.Expansion,
failed: bool = false,

/// What `next` gives out next: blocks, a leaf's inlines, a code or HTML
/// block's lines, or the leaf's exit.
pub const State = enum { blocks, inlines, lines, exit_leaf };

/// The containers open, by block index, as deep as the document nests.
const Stack = aegis.parts.Block(struct { stack: []u32 });

fn deepest(document: *const Document) u32 {
    var most: u32 = 0;
    for (document.blocks()) |b| most = @max(most, b.depth);
    return most + 1;
}

/// The bytes `initBuffer` needs for `document`: the container stack and a
/// leaf's inline pass, sized by the largest leaf the block pass measured.
/// `maxInt(usize)` when they pass the address space.
pub fn memory(document: *const Document) usize {
    const plan = Leaf.Memory.plan(Leaf.counts(document.stats().largest_leaf));
    const leaf = (plan.size() catch return std.math.maxInt(usize)).raw();
    const stack = (Stack.plan(.{ .stack = deepest(document) }).size() catch return std.math.maxInt(usize)).raw();
    return std.math.add(usize, leaf, stack + Stack.alignment - 1 + Leaf.Memory.alignment - 1) catch std.math.maxInt(usize);
}

/// The events of `document`, in memory from `gpa`.
pub fn init(gpa: std.mem.Allocator, document: *const Document) error{OutOfMemory}!Events {
    const buffer = try gpa.alloc(u8, memory(document));
    var e = initBuffer(document, buffer);
    e.gpa = gpa;
    return e;
}

/// The events of `document`, in the caller's memory: `buffer.len >=
/// memory(document)`, checked in every build.
pub fn initBuffer(document: *const Document, buffer: []u8) Events {
    aegis.assert.invariant(buffer.len >= memory(document), "the buffer holds memory(document) bytes");
    const words = std.mem.alignInSlice(buffer, Stack.alignment) orelse aegis.assert.never("memory(document) leaves room to align");
    const plan = Stack.plan(.{ .stack = deepest(document) });
    const stack_bytes = (plan.size() catch aegis.assert.never("memory(document) measured the stack")).raw();
    const stack = plan.fit(words) catch aegis.assert.never("memory(document) holds the stack");
    const scratch = std.mem.alignInSlice(words[stack_bytes..], Leaf.Memory.alignment) orelse aegis.assert.never("memory(document) leaves room to align");
    return .{
        .document = document,
        .gpa = null,
        .buffer = buffer,
        .stack = stack.parts().stack,
        .scratch = scratch,
        .expansion = .{ .limit = document.limits.expansion.raw() },
    };
}

pub fn deinit(e: *Events) void {
    if (e.gpa) |gpa| gpa.free(e.buffer);
    e.* = undefined;
}

/// The next event, or null after the last. Fails only on
/// `Limits.expansion`: the bytes resolved reference links reproduce (each
/// one's definition's destination and title) passed it, which the block
/// pass cannot know. The offset goes to the document's diagnostics, and
/// every later call fails too.
pub fn next(e: *Events) error{ExpansionTooLarge}!?Event {
    if (e.failed) return error.ExpansionTooLarge;
    return e.step() catch |err| {
        e.failed = true;
        if (e.document.diagnostics) |d| d.* = .{ .offset = e.leaf.refused().start, .limit = .expansion };
        return err;
    };
}

/// A link's title (an inline link's, or its definition's), while `next`
/// is in the leaf that holds the link.
pub fn title(e: *const Events, link: Link) ?Span {
    const p = e.leaf.part(link) orelse return null;
    return p.title;
}

/// A reference link's label as written, while `next` is in the leaf that
/// holds the link.
pub fn label(e: *const Events, link: Link) ?Span {
    const p = e.leaf.part(link) orelse return null;
    return p.label;
}

fn nodeOf(b: Block) Node {
    return switch (b.kind) {
        .block_quote => .block_quote,
        .list => switch (b.data) {
            .list => |l| .{ .list = .{ .ordered = l.ordered, .start = l.start, .tight = l.tight, .marker = l.marker } },
            else => aegis.assert.never("a list's record holds its list"),
        },
        .item => .item,
        .paragraph => .paragraph,
        .heading => switch (b.data) {
            .heading => |h| .{ .heading = .{ .level = h.level, .setext = h.setext } },
            else => aegis.assert.never("a heading's record holds its level"),
        },
        .code_block => switch (b.data) {
            .code => |c| .{ .code_block = .{ .fenced = c.fenced, .info = c.info } },
            else => aegis.assert.never("a code block's record holds its fence"),
        },
        .html_block => .html_block,
        .thematic_break => aegis.assert.never("a thematic break is one event"),
    };
}

fn step(e: *Events) error{ExpansionTooLarge}!?Event {
    const blocks = e.document.blocks();
    while (true) switch (e.state) {
        .inlines => {
            if (try e.leaf.next()) |ev| return ev;
            e.state = .exit_leaf;
        },
        .lines => {
            const b = blocks[e.current];
            const lines = e.document.lines(b);
            if (e.line >= lines.len) {
                e.state = .exit_leaf;
                continue;
            }
            const l = lines[e.line];
            if (l.spaces != 0 and !e.spaced) {
                e.spaced = true;
                return .{ .span = .init(l.start - 1, l.start), .kind = .{ .spaces = l.spaces } };
            }
            e.spaced = false;
            e.line += 1;
            const span: Span = .init(l.start, l.end);
            return .{ .span = span, .kind = if (b.kind == .code_block) .text else .{ .html = span } };
        },
        .exit_leaf => {
            e.state = .blocks;
            // A leaf's links are refused once it is left.
            e.leaf.part_count = 0;
            const b = blocks[e.current];
            return .{ .span = b.span, .kind = .{ .exit = nodeOf(b) } };
        },
        .blocks => {
            if (e.depth > 0) {
                const open = blocks[e.stack[e.depth - 1]];
                if (e.block >= blocks.len or open.depth >= blocks[e.block].depth) {
                    e.depth -= 1;
                    return .{ .span = open.span, .kind = .{ .exit = nodeOf(open) } };
                }
            }
            if (e.block >= blocks.len) return null;
            const at = e.block;
            e.block += 1;
            const b = blocks[at];
            switch (b.kind) {
                .block_quote, .list, .item => {
                    e.stack[e.depth] = at;
                    e.depth += 1;
                },
                .thematic_break => return .{ .span = b.span, .kind = .rule },
                .paragraph, .heading => {
                    e.current = at;
                    const lines = e.document.lines(b);
                    var bytes: usize = 0;
                    for (lines) |l| bytes += l.end - l.start + 1;
                    const block = Leaf.Memory.plan(Leaf.counts(bytes)).fit(e.scratch) catch aegis.assert.never("the scratch is sized for the largest leaf");
                    e.leaf = Leaf.read(block, e.document, lines, &e.expansion);
                    e.state = .inlines;
                },
                .code_block, .html_block => {
                    e.current = at;
                    e.line = 0;
                    e.spaced = false;
                    e.state = .lines;
                },
            }
            return .{ .span = b.span, .kind = .{ .enter = nodeOf(b) } };
        },
    };
}

test {
    _ = event;
    _ = @import("inline.zig");
}
