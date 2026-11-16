const std = @import("std");
const datapad = @import("datapad");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    // --- README:usage ---
    // A page with front matter, a wikilink and a link.
    const page = "---\ntitle: Notes\n---\n# Notes\n\nSee [[ideas]] and [the spec](https://spec.commonmark.org/).\n";
    var document = try datapad.Document.parse(gpa, .init(page), .{ .extensions = .{ .wikilinks = true, .front_matter = true } });
    defer document.deinit();
    const front = document.frontMatter().?;
    std.debug.assert(front.format == .yaml);
    std.debug.assert(std.mem.eql(u8, front.body.of(page), "title: Notes"));
    var events = try datapad.Events.init(gpa, &document);
    defer events.deinit();
    var targets: [2][]const u8 = undefined;
    var found: usize = 0;
    while (try events.next()) |event| switch (event.kind) {
        .enter => |node| if (node == .link) {
            // Every event carries its span: here the line a link is on.
            std.debug.assert(document.lineOf(event.span.start).line == 6);
            targets[found] = node.link.destination.of(page);
            found += 1;
        },
        else => {},
    };
    std.debug.assert(found == 2);
    std.debug.assert(std.mem.eql(u8, targets[0], "ideas"));
    std.debug.assert(std.mem.eql(u8, targets[1], "https://spec.commonmark.org/"));
    // --- README:usage ---
    try writing(gpa);
}

fn writing(gpa: std.mem.Allocator) !void {
    // --- README:html ---
    const text = "*Hello* <b>world</b>, [click](javascript:alert(1))\n";
    var document = try datapad.Document.parse(gpa, .init(text), .{});
    defer document.deinit();
    var events = try datapad.Events.init(gpa, &document);
    defer events.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // Safe by default: raw HTML left out, a destination that runs script emptied.
    try datapad.html.write(&out.writer, &events, .{});
    std.debug.assert(std.mem.eql(u8, out.written(), "<p><em>Hello</em> <!-- raw HTML omitted -->world<!-- raw HTML omitted -->, <a href=\"\">click</a></p>\n"));
    // --- README:html ---
}
