//! The bytes a destination, title or info string means: its backslash escapes and character
//! references resolved. Each run of what it means goes to the caller's `emit`, which writes it as
//! its output needs: as it is for a terminal, escaped for HTML or for a URL.
//!
//! This file is internal. `datapad.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");
const Link = @import("event.zig").Link;
const chars = @import("scan/chars.zig");
const inline_pass = @import("inline.zig");

const Writer = std.Io.Writer;

/// How a run of resolved bytes is written.
pub const Emit = fn (w: *Writer, bytes: []const u8) Writer.Error!void;

/// `bytes` resolved: each escape's character and each reference's code points in place of
/// what spells them.
pub fn bytes(w: *Writer, text: []const u8, comptime emit: Emit) Writer.Error!void {
    var at: usize = 0;
    var run: usize = 0;
    while (at < text.len) {
        const c = text[at];
        if (c == '\\' and at + 1 < text.len and chars.isAsciiPunctuation(text[at + 1])) {
            try emit(w, text[run..at]);
            try emit(w, text[at + 1 .. at + 2]);
            at += 2;
            run = at;
            continue;
        }
        // The writer's reading is not the parse's: its steps are not counted.
        var steps: u64 = 0;
        if (c == '&') if (inline_pass.reference.at(text, at, &steps)) |r| {
            try emit(w, text[run..at]);
            var buffer: [8]u8 = undefined;
            var len = std.unicode.utf8Encode(r.first, &buffer) catch aegis.assert.never("a reference's code point is a scalar value");
            if (r.second != 0) len += std.unicode.utf8Encode(r.second, buffer[len..]) catch aegis.assert.never("a reference's code point is a scalar value");
            try emit(w, buffer[0..len]);
            at = r.end;
            run = at;
            continue;
        };
        at += 1;
    }
    try emit(w, text[run..]);
}

/// `link`'s destination as written in `text`, resolved: the URL it means, `mailto:` before an
/// e-mail address and `http://` before a bare `www.` one. An autolink's, an address's and a
/// wikilink's destination has no escapes to resolve and is written as it stands.
pub fn destination(w: *Writer, text: []const u8, link: Link, comptime emit: Emit) Writer.Error!void {
    const written = link.destination.of(text);
    if (link.kind == .email) try w.writeAll("mailto:");
    if (link.kind == .extended and std.mem.startsWith(u8, written, "www.")) try w.writeAll("http://");
    if (link.kind == .autolink or link.kind == .email or link.kind == .extended or link.kind == .wiki) return w.writeAll(written);
    try bytes(w, written, emit);
}

/// The bytes as they are: what a terminal or a program reads.
pub fn plain(w: *Writer, run: []const u8) Writer.Error!void {
    try w.writeAll(run);
}
