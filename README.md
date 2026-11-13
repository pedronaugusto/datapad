# datapad

datapad is a CommonMark and GitHub Flavored Markdown parser for Zig: a pull parser whose every event, and every part
of one (a link's destination, title and label, a code block's info string, a table cell), carries its exact byte span,
and an HTML writer that gives CommonMark's reference output, safe by default.

It is being built: nothing here parses yet.

## Licence

MIT. See [LICENSE](LICENSE).

src/scan/entities.zig is generated from the HTML Standard's table of named character references
(testdata/whatwg/entities.json), Copyright © WHATWG (Apple, Google, Mozilla, Microsoft), under the Creative Commons
Attribution 4.0 International License: see [LICENSES/whatwg-CC-BY-4.0.txt](LICENSES/whatwg-CC-BY-4.0.txt).
