//! The generated entity table against WHATWG's: every reference CommonMark
//! reads is found by its name with its code points, and nothing else is.
const std = @import("std");
const shakedown = @import("shakedown");
const entities = @import("entities.zig");

const testing = std.testing;

test "every reference is found by its name, and its neighbours are not" {
    for (entities.entities) |e| {
        const found = entities.lookup(e.name).?;
        try testing.expectEqualStrings(e.name, found.name);
        try testing.expectEqual(e.first, found.first);
        try testing.expectEqual(e.second, found.second);
        // A prefix or an extension of a name is another name or none.
        if (entities.lookup(e.name[0 .. e.name.len - 1])) |p| try testing.expectEqualStrings(e.name[0 .. e.name.len - 1], p.name);
    }
    try testing.expectEqual(0x26, entities.lookup("amp").?.first);
    try testing.expectEqual(0xC6, entities.lookup("AElig").?.first);
    // Two code points: `&NotEqualTilde;` is U+2242 U+0338.
    try testing.expectEqual(0x2242, entities.lookup("NotEqualTilde").?.first);
    try testing.expectEqual(0x338, entities.lookup("NotEqualTilde").?.second);
    try testing.expect(entities.lookup("") == null);
    try testing.expect(entities.lookup("ampx") == null);
    try testing.expect(entities.lookup("AMP;") == null);
    try testing.expectEqual(2125, entities.entities.len);
}

test "any string: found exactly when the sorted table holds it" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var buffer: [12]u8 = undefined;
            const name = shakedown.gen.mutated(case.source, &buffer, &.{ "amp", "lt", "AElig", "NotEqualTilde", "zwnj", "frac12" });
            const held = for (entities.entities) |e| {
                if (std.mem.eql(u8, e.name, name)) break true;
            } else false;
            try testing.expectEqual(held, entities.lookup(name) != null);
        }
    }.one, .{ .cases = 5000, .seed = 0xe7 });
}
