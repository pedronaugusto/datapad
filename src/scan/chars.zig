//! Character classes as CommonMark 0.31.2 §2.1 defines them, the Unicode
//! ones through xenoglyph's General_Category, and the code points either
//! side of an offset, which emphasis's flanking rules read.
const std = @import("std");
const xenoglyph = @import("xenoglyph");

/// `!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~`.
pub fn isAsciiPunctuation(c: u8) bool {
    return switch (c) {
        '!'...'/', ':'...'@', '['...'`', '{'...'~' => true,
        else => false,
    };
}

/// A Unicode punctuation character: General_Category P (punctuation) or S
/// (symbol), ASCII punctuation among them.
pub fn isUnicodePunctuation(cp: u21) bool {
    if (cp < 0x80) return isAsciiPunctuation(@intCast(cp));
    return switch (xenoglyph.properties.generalCategory(cp)) {
        .connector_punctuation, .dash_punctuation, .open_punctuation, .close_punctuation, .initial_punctuation, .final_punctuation, .other_punctuation => true,
        .math_symbol, .currency_symbol, .modifier_symbol, .other_symbol => true,
        else => false,
    };
}

/// A Unicode whitespace character: General_Category Zs, or tab, line
/// feed, form feed or carriage return.
pub fn isUnicodeWhitespace(cp: u21) bool {
    return switch (cp) {
        '\t', '\n', 0x0C, '\r', ' ' => true,
        else => cp >= 0x80 and xenoglyph.properties.generalCategory(cp) == .space_separator,
    };
}

pub fn isSpaceOrTab(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// The code point that ends just before `offset`; a line end for the
/// text's start (the flanking rules read the start as whitespace). An
/// ill-formed sequence reads as U+FFFD.
pub fn before(text: []const u8, offset: usize) u21 {
    if (offset == 0) return '\n';
    var start = offset - 1;
    // Back over at most three continuation bytes to a lead.
    var back: usize = 0;
    while (back < 3 and start > 0 and text[start] & 0xC0 == 0x80) : (back += 1) start -= 1;
    const d = xenoglyph.utf8.decode(text[start..offset]);
    return if (start + d.len == offset) d.code_point else xenoglyph.utf8.replacement;
}

/// The code point that starts at `offset`; a line end past the text's end.
pub fn after(text: []const u8, offset: usize) u21 {
    if (offset >= text.len) return '\n';
    return xenoglyph.utf8.decode(text[offset..]).code_point;
}

const testing = std.testing;

test "CommonMark's character classes" {
    for ("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~") |c| try testing.expect(isAsciiPunctuation(c));
    for ("az09 \t") |c| try testing.expect(!isAsciiPunctuation(c));
    try testing.expect(isUnicodePunctuation(0x00A1)); // ¡ Po
    try testing.expect(isUnicodePunctuation(0x20AC)); // € Sc
    try testing.expect(isUnicodePunctuation(0x2014)); // — Pd
    try testing.expect(!isUnicodePunctuation(0x00E9)); // é Ll
    try testing.expect(isUnicodeWhitespace(0x00A0)); // no-break space, Zs
    try testing.expect(isUnicodeWhitespace(0x3000)); // ideographic space, Zs
    try testing.expect(!isUnicodeWhitespace(0x200B)); // zero width space, Cf
    try testing.expect(!isUnicodeWhitespace(0x2028)); // line separator, Zl
}

test "the code points either side of an offset" {
    const text = "a\u{e9}\u{20ac}b";
    try testing.expectEqual('\n', before(text, 0));
    try testing.expectEqual('a', before(text, 1));
    try testing.expectEqual(0xE9, before(text, 3));
    try testing.expectEqual(0x20AC, before(text, 6));
    try testing.expectEqual(0x20AC, after(text, 3));
    try testing.expectEqual('\n', after(text, text.len));
    // A continuation byte with no lead reads as U+FFFD.
    try testing.expectEqual(xenoglyph.utf8.replacement, before("a\x80", 2));
}
