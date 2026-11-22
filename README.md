# datapad

datapad is a CommonMark and GitHub Flavored Markdown parser for Zig: a pull parser whose every event, and every part
of one (a link's destination, title and label, a code block's info string, a table cell), carries its exact byte span,
and an HTML writer that gives CommonMark's reference output, safe by default.

Its first release is 0.1.0, which holds everything this page describes.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save git+https://github.com/pedronaugusto/datapad`, then obtain the
`datapad` module through `b.dependency` and add it to your executable's imports. datapad depends on aegis and
xenoglyph, and does no I/O: it parses bytes it is given.

## Usage

`Document.parse` reads a text's blocks once; `Events` gives the document as a stream of events, each with its span in
the text. A document borrows its text until `deinit`.

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const datapad = @import("datapad");

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
```
<!-- END GENERATED -->

The HTML writer takes the same events:

<!-- BEGIN GENERATED zig build docs -- html -->
```zig
const datapad = @import("datapad");

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
```
<!-- END GENERATED -->

## Events

An `Event` is 32 bytes: a `Span` (two `u32` offsets, `span.of(text)` its bytes) and what it is. Containers and leaves
are entered and exited around what they hold (`enter` and `exit` with a `Node`: paragraph, block quote, heading, list,
item, code block, HTML block, front matter, table, table head, row and cell, emphasis, strong, strikethrough, link,
image). Between them come `text` (never across a line: a paragraph's lines arrive as text, break, text), `escape`,
`reference` (an entity's or a numeric reference's code points), `code` (a code span's content after the spec's
stripping), `html`, `soft_break`, `hard_break`, `rule` and `task`. Text the spec rewrites is given as its source span
and its meaning, never as a copy, so every event maps back to the source.

A `Link` says how it was written (inline, reference, collapsed, shortcut, autolink, email, extended, wiki) and gives
its destination's span as written; `writeDestination` unescapes it and decodes its references. Its title and label
are `Events.title` and `Events.label`, read while the iterator is in the leaf that holds the link. A link kept past
its leaf is refused, never read against another's spans.

`Events.init` allocates once, the memory `Events.memory` gives; `Events.initBuffer` takes the caller's. `next` never
allocates, and returns after every event, so a caller on an `std.Io` cancels between events. `Document.lineOf` gives
an offset's line and column.

## Syntax

`Extensions.commonmark` reads CommonMark 0.31.2 alone; `Extensions.gfm`, the default, adds GitHub Flavored Markdown's
tables, task list items, strikethrough, extended autolinks and the tagfilter, each a field of its own. Two more are
off unless asked for:

- `wikilinks`: `[[target]]` and `[[target|label]]` (and `![[...]]` for an image) are links of kind `wiki` whose
  destination is the target as written. A target alone is the link's text, not read as Markdown; a label is read
  as a link's text is, over lines if it runs on. A wikilink runs to its first `]]` with no other bracket before it,
  its target on one line and not blank, its label not empty. It is read before the brackets around it, so no link
  holds one.
- `front_matter`: a text that starts with a `---` line closed by a `---` or `...` line (YAML), or a `+++` line
  closed by a `+++` line (TOML), has that block as its first, a `front_matter` node whose events are its body's
  lines. `Document.frontMatter` gives its format, its span and its body's. datapad reads neither language. An
  opening line never closed is Markdown.

## Limits

Markdown has no invalid document, so `parse` refuses only on a limit, each named, with its offset in a
`Limits.Diagnostic`: the text's length (`input`, 16 MiB by default), container nesting (`depth`, 128, at most 1024),
blocks and reference definitions. One limit the block pass cannot decide: the bytes reference links reproduce in
output (`expansion`, 64 MiB), which `next` counts as each resolves and refuses past with `ExpansionTooLarge`.

Nothing recurses, and the work is linear in the text: the block pass's steps (`Document.stats`) and the inline
pass's (`Events.work`), every scan's bytes counted, stay within a fixed number per input byte on the inputs that make
Markdown parsers slow.

## HTML

`html.write` gives CommonMark's reference HTML byte for byte. It is safe by default: raw HTML is written as `<!-- raw
HTML omitted -->`, and a destination that runs script (`javascript:`, `vbscript:`, `file:`, and `data:` other than a
PNG, GIF, JPEG or WebP image) is emptied; `Options.unsafe` writes both as they are. Ill-formed UTF-8 and U+0000 are
written as U+FFFD. `Options.soft_break` writes a soft break as a line ending, a space or `<br />`. Front matter is
left out.

## Scope

Out: footnotes, definition lists, math, heading attributes, smart punctuation and alerts (in neither spec; each can
be a flag when asked for), a tree (events are the API; a tree is a walk with a stack), writers other than HTML,
heading slugs, and reading files.

## Testing

`bay test` runs the suite and the usage example. The specs are the reference: every one of CommonMark 0.31.2's 652
examples, and every one of the GFM spec's 24 extension examples, read from the specs as they are published and
compared byte for byte.

cmark's and cmark-gfm's pathological inputs, 26 of them, and 10 shapes of datapad's own extensions are held to a
bound of 48 steps per input byte, and each to the HTML cmark's test expects. Properties over generated Markdown hold
the block table's and the stream's guarantees under every set of extensions, and a fuzz target over any bytes, or
Markdown mutated, holds every span, nesting, order, the work bound, and the expansion limit refusing exactly when a
recount of the stream passes it. Each property was checked against a planted fault. `bay bench` times parsing and
HTML over the CommonMark spec, the spec repeated to 16 MiB, any corpus given, and the pathological shapes at three
sizes.

The design is [docs/design.md](docs/design.md).

## Stability

datapad is 0.x and tracks Zig 0.17.x. A breaking change comes only in a minor release (0.1 to 0.2), with a
CHANGELOG entry saying what changed and what to write instead; a patch release never breaks.

## Licence

MIT. See [LICENSE](LICENSE).

src/scan/entities.zig is generated from the HTML Standard's table of named character references
(testdata/whatwg/entities.json), Copyright © WHATWG (Apple, Google, Mozilla, Microsoft), under the Creative Commons
Attribution 4.0 International License: see [LICENSES/whatwg-CC-BY-4.0.txt](LICENSES/whatwg-CC-BY-4.0.txt).

The tests read the CommonMark Spec 0.31.2 (testdata/commonmark), Copyright © 2014-16 John MacFarlane, and the GitHub
Flavored Markdown Spec 0.29 (testdata/gfm), as cmark-gfm 0.29.0.gfm.13 publishes it, each unmodified and under the
Creative Commons Attribution-ShareAlike 4.0 International License: see [LICENSES/CC-BY-SA-4.0.txt](LICENSES/CC-BY-SA-4.0.txt).

The pathological tests (src/pathological_test.zig) and benchmark shapes (bench/main.zig) are written from cmark's and
cmark-gfm's test/pathological_tests.py, Copyright © 2014 John MacFarlane, under the BSD 2-Clause License: see
[LICENSES/cmark-BSD-2-Clause.txt](LICENSES/cmark-BSD-2-Clause.txt).
