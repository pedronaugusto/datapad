//! What a project that depends on datapad and nothing else writes. Built by
//! `zig build check-consumer` with no packages to fetch beyond aegis and
//! xenoglyph, so datapad's build.zig must work without any of its own CI
//! dependencies.
const std = @import("std");
const datapad = @import("datapad");

pub fn main(init: std.process.Init) !void {
    const page = "# Notes\n\nSee [the spec](https://spec.commonmark.org/).\n";
    var document = try datapad.Document.parse(init.gpa, .init(page), .{});
    defer document.deinit();
    var events = try datapad.Events.init(init.gpa, &document);
    defer events.deinit();
    while (try events.next()) |_| {}
}
