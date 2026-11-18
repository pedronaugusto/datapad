# Design

datapad reads CommonMark 0.31.2 and GitHub Flavored Markdown into a stream of
events, each with its exact span in the text, and writes them as HTML. It
depends on aegis and xenoglyph, does no I/O, and parses bytes it is given.

This describes the implementation in this repository. Change it with the code
whenever an owner, invariant or decision changes.

## Scope

In: CommonMark 0.31.2 whole; GFM's tables, task list items, strikethrough,
extended autolinks and tagfilter, each a flag (`.gfm` sets all); two opt-in
syntaxes, wikilinks (`[[target]]`, `[[target|label]]`) and front matter (a
leading `---` or `+++` block given as one event; datapad reads neither the YAML
nor the TOML); the HTML writer, CommonMark's reference HTML byte for byte, safe
by default (raw HTML omitted, `javascript:`, `vbscript:`, `file:` and non-image
`data:` destinations blanked), `unsafe` to pass raw HTML through.

Out, by decision:

- Footnotes, definition lists, math, superscript, heading attributes, smart
  punctuation, alerts: in neither spec. Each is a flag when a consumer asks; the
  block and inline layers take a construct without reshaping.
- A tree: events are the API. A consumer that wants a tree builds one from
  events with a stack, as every renderer does anyway.
- Other writers (round trip, man, LaTeX, a terminal), syntax highlighting of code
  blocks (datapad gives the info string) and heading slugs (a link checker's
  policy, not Markdown's).
- Reading files: datapad parses bytes it is given.

## Layers

[ci/layers.zig](../ci/layers.zig) checks the production import graph: imports
stay in their layer or go down.

| Layer | Files and what they hold |
|---|---|
| Vocabulary | `Span.zig` (`u32` offsets), `Limits.zig` (the limits and their diagnostic), `Options.zig` (`Extensions`). |
| Scan | `scan/chars.zig` (CommonMark's ASCII and Unicode classes, the Unicode ones through xenoglyph's General_Category), `scan/line.zig` (columns with tab stops of 4), `scan/entities.zig` (the 2125 HTML5 references, generated). |
| Blocks | `block/front_matter.zig`, `block/Block.zig` (the block table's record), `block/leaves.zig` (what a line starts), `block/references.zig` (definitions and the link scanners both passes share), `block/containers.zig` (the pass). |
| Document | `Document.zig`: the text it borrows and the block pass's tables. |
| Event vocabulary | `event.zig`: `Event`, `Node`, `Link`, checked at 32 bytes at compile time. |
| Inline parts | `inline/items.zig` (the leaf's item list), `inline/code.zig`, `inline/html.zig`, `inline/autolink.zig`, `inline/reference.zig`, `inline/extended.zig`. |
| Inline rules | `inline/delimiters.zig` (emphasis), `inline/links.zig` (brackets, tails, labels, wikilinks). |
| Inlines | `inline/Leaf.zig`: one leaf's inline pass and its events. |
| Events | `Events.zig`: the pull iterator over blocks and leaves. |
| Writers | `html.zig`. |
| Public | `datapad.zig`. |

`tools/generate.zig` writes `scan/entities.zig` from WHATWG's entities.json; the
tests write it again and compare it byte for byte.

## Two passes

The block pass (`Document.parse`) reads the text once, a line at a time, as
CommonMark's appendix A does: each line continues the open containers it can,
opens the blocks it starts, and goes to the open leaf, a lazy paragraph or a new
one. The open blocks are an explicit stack. It writes the block table (every
block in document order with its depth, span and content lines), the line table
and the label table of definitions, normalized by Unicode case folding and
sorted, the first of each label resolving. Front matter, where the extension is
on, is read before the first line as the table's first block.

The inline pass runs lazily, one leaf at a time, as `Events.next` reaches it: the
leaf's lines are joined into the iterator's memory and read once into an item
list (text, delimiter runs, brackets, code, HTML, references, breaks, links).
Emphasis is matched by the spec's delimiter algorithm and links by its bracket
stack. Then the items are given out as events.

Nothing recurses. `Events` allocates once, sized by the block pass from the
largest leaf, or takes the caller's buffer; `next` and the writer allocate
nothing.

## Positions

Every event's span is exact, and parts of an event carry spans of their own:
a link's destination and a code block's info string in the event, a link's title
and label in the leaf's side table, which `Events.title` and `Events.label` read
while the iterator is in that leaf. A link kept past its leaf is refused by a
check, never read against another link's parts. Text the spec rewrites (escapes,
references, a code span's stripped spaces) is given as its source span and its
meaning.

## Linear work

Every scan is bounded or remembers what it found, and the work is counted: the
block pass's steps (`Document.stats().work`) and the inline pass's
(`Events.work`), each scanner adding a step per byte or item it reads. The
pathological tests hold the sum to 48 steps per input byte. What keeps each
construct linear:

- Emphasis: the look back for an opener stops at `openers_bottom`, per character,
  can-open and length mod 3, compared by position on the stack, so a floor that a
  later match took off the stack still holds (cmark's issue #389).
- Links: once a link closes, every `[` below is out of play, kept as one floor
  index on the bracket stack, not by walking down to it. A destination's
  parentheses nest at most 32 deep, as cmark cuts them (the spec asks for 3).
- Code spans: the leaf's backtick runs are listed once, by length, and each
  opener finds its closer from where the last search of its length stopped.
- Raw HTML: a search for a comment's, a declaration's, a processing
  instruction's, CDATA's or an attribute value's end that missed is not made
  again in the leaf.
- Extended autolinks: a scan stops at the first byte the link cannot hold, and a
  link's parentheses are counted once while its trailing ones are trimmed.
- Wikilinks: the scan for `]]` stops at the first bracket, so each byte is read
  for one `[[` at most.
- Blank lines: a line whose rest is blank walks the open lists and items the same
  way whatever its bytes, so the walk is taken in one step while the open blocks
  are unchanged (a generation count says so); runs of blank lines under deep
  lists cost their length, not their length times the depth.

## Limits

The text arrives as `aegis.input.Untrusted` and every limit is checked by the
block pass with a named error and its offset: input length, container depth
(the stack is memory a document controls), blocks and definitions. The bytes
reference links reproduce in output cannot be known before the inline pass, so
`Events.next` counts them as each link resolves and refuses past
`Limits.expansion`, then on every later call.

`parse` takes no `Io`: its pass is linear and bounded by `Limits.input`.

## Readings where the specs leave room

- GFM tables: a delimiter row needs no pipe, as cmark-gfm reads it, since a row
  of hyphens alone under a paragraph is a setext underline, which is read first;
  a delimiter cell may have a line tabulation or form feed around it, CommonMark
  0.29's whitespace, which GFM's spec builds on.
- Wikilinks follow no spec: the target is literal and on one line, a label is a
  link's text, the first `]]` closes it, and no other bracket may come before it.
- Front matter must be closed to be front matter, and only at the text's start.
- The HTML writer leaves front matter out and writes a wikilink as a link to its
  target, percent-encoded.

## Proof

- Conformance: every example of the CommonMark 0.31.2 spec and every extension
  example of the GFM spec, read from the specs as published, byte for byte.
- Pathological inputs: cmark's and cmark-gfm's, and datapad's own, held to the
  work bound and to the HTML cmark's test expects.
- Properties: the block table's guarantees over generated Markdown; the stream's
  under every set of extensions; and a fuzz target over any bytes or mutated
  Markdown with the expansion limit checked against a recount. Each was checked
  against a planted fault. The release tier runs every property under Zig's
  fuzzer.
- Benchmarks: `bench/main.zig`, rows of parsing and writing over the spec, the
  spec at 16 MiB, any corpus given, and the pathological shapes at three sizes.
