//! datapad's benchmark rows, measured through shakedown; each unit is one
//! whole document:
//!
//! - `parse/<corpus>`: the block pass and every event drained;
//! - `html/<corpus>`: the same, written as HTML;
//! - `pathological/<shape>/<size>`: a shape that makes Markdown parsers
//!   slow, parsed and written at three sizes, a quarter, a half and all of
//!   the largest, so the rows show the time per byte stays flat.
//!
//! The corpora are the CommonMark spec (testdata/commonmark) and the spec
//! repeated to 16 MiB, and any the harness names, each one file:
//!
//!   datapad-bench [--smoke] [--row <prefix>] [--corpus <name>=<file>]...
//!
//! A corpus of many pages is given concatenated into one file. `bay bench`
//! runs it; CI only compiles it, and `bay test` runs each row once.
const std = @import("std");
const Io = std.Io;
const aegis = @import("aegis");
const datapad = @import("datapad");
const shakedown = @import("shakedown");
const provenance = @import("preflight_bench_options");

const spec = @embedFile("commonmark_spec");

const Error = datapad.Document.ParseError || error{ExpansionTooLarge} || Io.Writer.Error;

/// Every extension on: what the corpora and the shapes may hold.
const all: datapad.Extensions = .{ .tables = true, .task_lists = true, .strikethrough = true, .autolinks = true, .tagfilter = true, .wikilinks = true, .front_matter = true };

/// One row's document and what it does with it.
const Context = struct {
    gpa: std.mem.Allocator,
    text: []const u8,
    html: bool,
    /// What every unit read, kept so no unit is optimized away.
    seen: u64 = 0,

    fn run(c: *Context, units: u64) Error!void {
        for (0..units) |_| {
            var document = try datapad.Document.parse(c.gpa, .init(c.text), .{ .extensions = all, .limits = .{ .depth = .literal(1024) } });
            defer document.deinit();
            var events = try datapad.Events.init(c.gpa, &document);
            defer events.deinit();
            if (c.html) {
                var buffer: [4096]u8 = undefined;
                var sink: Io.Writer.Discarding = .init(&buffer);
                try datapad.html.write(&sink.writer, &events, .{});
                c.seen +%= sink.fullCount();
            } else {
                while (try events.next()) |e| c.seen +%= e.span.end.raw();
            }
        }
    }
};

/// The shapes, each a piece repeated: cmark's pathological cases and
/// datapad's own, at the largest size's count of pieces.
const shapes = [_]struct { name: []const u8, piece: []const u8, count: usize }{
    .{ .name = "nested-emphasis", .piece = "*a **a ", .count = 32500 },
    .{ .name = "emphasis-closers", .piece = "a_ ", .count = 65000 },
    .{ .name = "link-openers", .piece = "[a", .count = 65000 },
    .{ .name = "link-closers", .piece = "a]", .count = 65000 },
    .{ .name = "unclosed-links", .piece = "[a](b", .count = 30000 },
    .{ .name = "image-links", .piece = "![[]()", .count = 160000 },
    .{ .name = "unclosed-comments", .piece = "<!--", .count = 300000 },
    .{ .name = "backtick-runs", .piece = "e``", .count = 100000 },
    .{ .name = "unclosed-wikilinks", .piece = "[[a", .count = 65000 },
    .{ .name = "table-rows", .piece = "aaa\rbbb\n-\x0b\n", .count = 30000 },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var named: std.ArrayList(struct { name: []const u8, text: []const u8 }) = .empty;
    var rest: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--corpus") and i + 1 < args.len) {
            i += 1;
            const eq = std.mem.findScalar(u8, args[i], '=') orelse return error.InvalidOptions;
            const text = try aegis.own.readFile(init.io, Io.Dir.cwd(), args[i][eq + 1 ..], arena, .literal("1GiB"));
            try named.append(arena, .{ .name = args[i][0..eq], .text = text });
        } else try rest.append(arena, args[i]);
    }
    const options = try shakedown.bench.Options.fromArguments(rest.items);

    // The spec, and the spec repeated to 16 MiB (one copy in a smoke run).
    const copies = if (options.smoke) 1 else (16 << 20) / spec.len + 1;
    const large = try arena.alloc(u8, spec.len * copies);
    for (0..copies) |c| @memcpy(large[c * spec.len ..][0..spec.len], spec);
    try named.append(arena, .{ .name = "spec", .text = spec });
    try named.append(arena, .{ .name = "spec-16MiB", .text = large });

    var contexts: std.ArrayList(Context) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    for (named.items) |corpus| for ([_]bool{ false, true }) |html| {
        try contexts.append(arena, .{ .gpa = init.gpa, .text = corpus.text, .html = html });
        try names.append(arena, try arena.print("{s}/{s}", .{ if (html) "html" else "parse", corpus.name }));
    };
    for (shapes) |shape| for ([_]usize{ 4, 2, 1 }) |part| {
        const count = if (options.smoke) 8 else shape.count / part;
        const text = try arena.alloc(u8, shape.piece.len * count);
        for (0..count) |c| @memcpy(text[c * shape.piece.len ..][0..shape.piece.len], shape.piece);
        try contexts.append(arena, .{ .gpa = init.gpa, .text = text, .html = true });
        try names.append(arena, try arena.print("pathological/{s}/{d}", .{ shape.name, text.len }));
    };

    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &buffer);
    for (contexts.items, names.items) |*ctx, name| {
        const row: shakedown.bench.Row(Context, Error) = .{ .name = name, .unit = "document", .run = Context.run };
        try shakedown.bench.run(Error, init.gpa, init.io, &stdout.interface, ctx, &.{row}, .{
            .commit = provenance.commit,
            .cpu = provenance.cpu,
            .os = provenance.os,
        }, options);
    }
    try stdout.interface.flush();
}
