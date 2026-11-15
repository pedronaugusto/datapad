# datapad

datapad is a CommonMark and GitHub Flavored Markdown parser for Zig: a pull parser whose every event, and every part
of one (a link's destination, title and label, a code block's info string, a table cell), carries its exact byte span,
and an HTML writer that gives CommonMark's reference output, safe by default.

It is being built: the block pass, the events with CommonMark's inlines, GitHub Flavored Markdown's extensions and the
HTML writer are in. The writer gives the CommonMark 0.31.2 spec's HTML for every one of its 652 examples, and the GFM
spec's for every one of its 24 extension examples.

## Licence

MIT. See [LICENSE](LICENSE).

src/scan/entities.zig is generated from the HTML Standard's table of named character references
(testdata/whatwg/entities.json), Copyright © WHATWG (Apple, Google, Mozilla, Microsoft), under the Creative Commons
Attribution 4.0 International License: see [LICENSES/whatwg-CC-BY-4.0.txt](LICENSES/whatwg-CC-BY-4.0.txt).

The tests read the CommonMark Spec 0.31.2 (testdata/commonmark), Copyright © 2014-16 John MacFarlane, and the GitHub
Flavored Markdown Spec 0.29 (testdata/gfm), as cmark-gfm 0.29.0.gfm.13 publishes it, each unmodified and under the
Creative Commons Attribution-ShareAlike 4.0 International License: see [LICENSES/CC-BY-SA-4.0.txt](LICENSES/CC-BY-SA-4.0.txt).
