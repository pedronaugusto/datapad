//! A run of the text by byte offsets: where an event, or a part of one, lies.
//! Offsets are `u32`, so a text is at most 4 GiB less one byte, and an event
//! stays small.
const Span = @This();
const aegis = @import("aegis");

pub const Offset = aegis.units.Bytes(u32);

start: Offset,
end: Offset,

pub fn init(start: u32, end: u32) Span {
    aegis.assert.invariant(start <= end, "a span ends at or after its start");
    return .{ .start = .fromRaw(start), .end = .fromRaw(end) };
}

/// The bytes it covers in `text`, the text it was taken from.
pub fn of(s: Span, text: []const u8) []const u8 {
    return text[s.start.raw()..s.end.raw()];
}

pub fn len(s: Span) u32 {
    return s.end.raw() - s.start.raw();
}

test "a span is the bytes between its offsets" {
    const s: Span = .init(2, 5);
    try @import("std").testing.expectEqualStrings("cde", s.of("abcdefg"));
    try @import("std").testing.expectEqual(3, s.len());
}
