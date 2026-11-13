//! Writes src/scan/entities.zig from WHATWG's entities.json: the named
//! character references CommonMark reads (`&name;`, the semicolon required),
//! sorted by name, behind a minimal perfect hash (hash and displace: a
//! bucket's seed sends each of its names to a slot no other name takes).
//! With `--check` it writes nothing: it compares what it would write with
//! the file, and fails on any difference.
//!
//! generate <entities.json> <entities.zig> [--check]
const std = @import("std");

/// The hash both this generator and the generated lookup use; the
/// generated file carries the same text.
const hash_source =
    \\/// FNV-1a over `name`, its start moved by `seed`.
    \\pub fn hash(name: []const u8, seed: u32) u64 {
    \\    var h: u64 = 0xcbf29ce484222325 ^ (@as(u64, seed) *% 0x9e3779b97f4a7c15);
    \\    for (name) |b| {
    \\        h ^= b;
    \\        h *%= 0x100000001b3;
    \\    }
    \\    return h;
    \\}
;

pub fn hash(name: []const u8, seed: u32) u64 {
    var h: u64 = 0xcbf29ce484222325 ^ (@as(u64, seed) *% 0x9e3779b97f4a7c15);
    for (name) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

const Entity = struct { name: []const u8, first: u21, second: u21 };

fn byName(_: void, a: Entity, b: Entity) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    var paths: [2][]const u8 = undefined;
    var given: usize = 0;
    var check = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            check = true;
        } else if (given < 2) {
            paths[given] = arg;
            given += 1;
        } else return usage();
    }
    if (given != 2) return usage();
    const cwd = std.Io.Dir.cwd();
    const source = try cwd.readFileAlloc(io, paths[0], gpa, .limited(1 << 22));
    const written = try generate(gpa, source);
    if (!check) {
        try cwd.writeFile(io, .{ .sub_path = paths[1], .data = written });
        return;
    }
    const current = cwd.readFileAlloc(io, paths[1], gpa, .limited(1 << 22)) catch |err| {
        std.log.err("{s}: {t}", .{ paths[1], err });
        return error.Stale;
    };
    if (!std.mem.eql(u8, current, written)) {
        std.log.err("{s} is not what tools/generate.zig writes from {s}: run `bay dev entities`", .{ paths[1], paths[0] });
        return error.Stale;
    }
}

fn usage() error{Usage} {
    std.log.err("usage: generate <entities.json> <entities.zig> [--check]", .{});
    return error.Usage;
}

fn generate(gpa: std.mem.Allocator, source: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, gpa, source, .{});
    var list: std.ArrayList(Entity) = .empty;
    var it = parsed.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        // CommonMark reads a reference only with its semicolon.
        if (key.len < 3 or key[0] != '&' or key[key.len - 1] != ';') continue;
        const points = entry.value_ptr.object.get("codepoints").?.array.items;
        try list.append(gpa, .{
            .name = key[1 .. key.len - 1],
            .first = @intCast(points[0].integer),
            .second = if (points.len > 1) @intCast(points[1].integer) else 0,
        });
    }
    std.mem.sort(Entity, list.items, {}, byName);
    const entities = list.items;
    const n = entities.len;
    // Hash and displace: buckets of about four names, the largest placed
    // first, each given the first seed that sends all its names to free slots.
    const buckets = (n + 3) / 4;
    var members = try gpa.alloc(std.ArrayList(u32), buckets);
    for (members) |*m| m.* = .empty;
    for (entities, 0..) |e, i| try members[hash(e.name, 0) % buckets].append(gpa, @intCast(i));
    const order = try gpa.alloc(u32, buckets);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u32, order, members, struct {
        fn larger(m: []std.ArrayList(u32), a: u32, b: u32) bool {
            if (m[a].items.len != m[b].items.len) return m[a].items.len > m[b].items.len;
            return a < b;
        }
    }.larger);
    const seeds = try gpa.alloc(u32, buckets);
    @memset(seeds, 0);
    const slots = try gpa.alloc(?u32, n);
    @memset(slots, null);
    var trial = try gpa.alloc(u32, 8);
    for (order) |bucket| {
        const names = members[bucket].items;
        if (names.len == 0) continue;
        if (names.len > trial.len) trial = try gpa.alloc(u32, names.len);
        var seed: u32 = 1;
        search: while (seed < 1 << 20) : (seed += 1) {
            for (names, 0..) |index, k| {
                const slot: u32 = @intCast(hash(entities[index].name, seed) % n);
                if (slots[slot] != null) continue :search;
                for (trial[0..k]) |t| if (t == slot) continue :search;
                trial[k] = slot;
            }
            break;
        } else return error.NoSeed;
        seeds[bucket] = seed;
        for (names, trial[0..names.len]) |index, slot| slots[slot] = index;
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;
    try w.writeAll(
        \\//! The HTML5 named character references CommonMark reads (`&name;`), sorted
        \\//! by name, behind a minimal perfect hash. Written by tools/generate.zig from
        \\//! WHATWG's entities.json (testdata/whatwg/entities.json); `bay dev test`
        \\//! fails unless writing it again gives these bytes. Do not edit.
        \\//!
        \\//! The data is the HTML Standard's: Copyright © WHATWG (Apple, Google,
        \\//! Mozilla, Microsoft), licensed under the Creative Commons Attribution 4.0
        \\//! International License (LICENSES/whatwg-CC-BY-4.0.txt).
        \\
        \\/// A reference's name (without `&` and `;`) and its one or two code
        \\/// points, `second` 0 for one.
        \\pub const Entity = struct { name: []const u8, first: u21, second: u21 };
        \\
        \\/// The longest name.
        \\
    );
    var longest: usize = 0;
    for (entities) |e| longest = @max(longest, e.name.len);
    try w.print("pub const longest = {d};\n\n/// Every reference, sorted by name.\npub const entities = [_]Entity{{\n", .{longest});
    for (entities) |e| try w.print("    .{{ .name = \"{s}\", .first = 0x{X}, .second = 0x{X} }},\n", .{ e.name, e.first, e.second });
    try w.writeAll("};\n\n/// Each bucket's seed.\nconst seeds = [_]u32{\n");
    // One a line: zig fmt aligns the columns of a row of several.
    for (seeds) |seed| try w.print("    {d},\n", .{seed});
    try w.writeAll("};\n\n/// Each slot's entity, an index into `entities`.\nconst slots = [_]u16{\n");
    for (slots) |slot| try w.print("    {d},\n", .{slot.?});
    try w.writeAll(
        \\};
        \\
        \\/// The reference named `name` (without `&` and `;`), or null.
        \\pub fn lookup(name: []const u8) ?Entity {
        \\    if (name.len == 0 or name.len > longest) return null;
        \\    const seed = seeds[hash(name, 0) % seeds.len];
        \\    const entity = entities[slots[hash(name, seed) % slots.len]];
        \\    for (entity.name, 0..) |c, i| {
        \\        if (i >= name.len or name[i] != c) return null;
        \\    }
        \\    return if (entity.name.len == name.len) entity else null;
        \\}
        \\
        \\
    );
    try w.writeAll(hash_source);
    try w.writeByte('\n');
    return out.written();
}
