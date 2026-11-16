//! Front matter: a block of YAML between `---` lines, or of TOML between
//! `+++` lines, at the very start of a text, as the static site tools and
//! tycho's book write it. Its opening line is the text's first; its closing
//! line is the first after it of the same three characters (YAML may close
//! with `...` too), spaces and tabs after either allowed. A text whose
//! opening line is never closed has no front matter, and its lines are
//! Markdown. datapad reads neither language: the body is handed over as its
//! lines.
const std = @import("std");

/// The language the body is written in, by its fence.
pub const Format = enum(u8) { yaml, toml };

/// Front matter found at a text's start: its format, where its body's
/// lines start and end, and where its closing line ends and the next line
/// starts.
pub const Found = struct {
    format: Format,
    /// The body: from the line after the opening one to the end of the
    /// line before the closing one, line ending left out; empty, at the
    /// closing line's start, where there is no line between.
    body_start: u32,
    body_end: u32,
    /// The closing line's start and its end, line ending left out.
    close_start: u32,
    close_end: u32,
    /// Where the line after the closing one starts: the text's length when
    /// there is none.
    next: u32,
};

/// The line starting at `at`: where it ends, line ending left out, and
/// where the next one starts.
fn lineAt(text: []const u8, at: usize) struct { end: usize, next: usize } {
    var end = at;
    while (end < text.len and text[end] != '\n' and text[end] != '\r') end += 1;
    var next = end;
    if (next < text.len) next += if (text[next] == '\r' and next + 1 < text.len and text[next + 1] == '\n') 2 else 1;
    return .{ .end = end, .next = next };
}

/// Whether `line` is `fence` followed by nothing but spaces and tabs.
fn isFence(line: []const u8, fence: []const u8) bool {
    if (!std.mem.startsWith(u8, line, fence)) return false;
    for (line[fence.len..]) |c| if (c != ' ' and c != '\t') return false;
    return true;
}

/// The front matter `text` starts with, or null. Reads each line once; a
/// text it is not found in costs a read to its end, which the block pass
/// reads too. `text.len` fits a `u32`, as the block pass has checked.
pub fn find(text: []const u8) ?Found {
    const first = lineAt(text, 0);
    const opening = text[0..first.end];
    const format: Format = if (isFence(opening, "---")) .yaml else if (isFence(opening, "+++")) .toml else return null;
    const fence = opening[0..3];
    // Each line moves `at` past it: a fence on the text's last line opens nothing.
    var at = first.next;
    while (at < text.len) {
        const l = lineAt(text, at);
        const line = text[at..l.end];
        if (isFence(line, fence) or (format == .yaml and isFence(line, "..."))) {
            const body_end = if (at == first.next) at else lastEnd(text, at);
            return .{
                .format = format,
                .body_start = @intCast(first.next),
                .body_end = @intCast(body_end),
                .close_start = @intCast(at),
                .close_end = @intCast(l.end),
                .next = @intCast(l.next),
            };
        }
        at = l.next;
    }
    return null;
}

/// The end of the line before the one starting at `at`, line ending left
/// out.
fn lastEnd(text: []const u8, at: usize) usize {
    var end = at;
    if (end > 0 and text[end - 1] == '\n') end -= 1;
    if (end > 0 and text[end - 1] == '\r') end -= 1;
    return end;
}

const testing = std.testing;

test "YAML closes on its fence or on `...`, TOML on its own fence" {
    const yaml = find("---\ntitle: x\n---\n# Heading\n").?;
    try testing.expectEqual(Format.yaml, yaml.format);
    try testing.expectEqualStrings("title: x", "---\ntitle: x\n---\n# Heading\n"[yaml.body_start..yaml.body_end]);
    try testing.expectEqual(@as(u32, 17), yaml.next);
    const dots = find("---\na: 1\n...\n").?;
    try testing.expectEqual(@as(u32, 9), dots.close_start);
    const toml = find("+++\na = 1\r\n+++  \r\nrest").?;
    try testing.expectEqual(Format.toml, toml.format);
    try testing.expectEqualStrings("a = 1", "+++\na = 1\r\n+++  \r\nrest"[toml.body_start..toml.body_end]);
    try testing.expectEqual(@as(u32, 18), toml.next);
    // TOML's block does not close on `...` or `---`.
    try testing.expect(find("+++\na = 1\n...\n---\n") == null);
}

test "an empty body, a closing line last, and no line ending at all" {
    const empty = find("---\n---\n").?;
    try testing.expectEqual(empty.body_start, empty.body_end);
    try testing.expectEqual(@as(u32, 4), empty.close_start);
    const last = find("---\na: 1\n---").?;
    try testing.expectEqual(@as(u32, 12), last.next);
}

test "no front matter: not at the start, unclosed, a fence on the last line, other characters" {
    try testing.expect(find("\n---\na\n---\n") == null);
    try testing.expect(find("---\na: 1\n") == null);
    try testing.expect(find("---") == null);
    try testing.expect(find("----\na\n----\n") == null);
    try testing.expect(find("--- x\na\n---\n") == null);
    try testing.expect(find("") == null);
}
