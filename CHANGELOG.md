# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- The package: its build, the `datapad` module on aegis and xenoglyph, and its development under preflight's gate.
- Its vocabulary: `Span` (`u32` offsets, `of` its text), `Limits` (input, depth, blocks, references, expansion) and `Options` with `Extensions` (`commonmark`, `gfm`, wikilinks, front matter).
- Character scanning (`scan`): CommonMark's ASCII and Unicode punctuation and whitespace, the Unicode classes by xenoglyph's General_Category; the code points either side of an offset; columns with tab stops of 4, a tab taken in part leaving the rest; and the 2125 HTML5 named character references CommonMark reads, a table `tools/generate.zig` writes from WHATWG's entities.json behind a minimal perfect hash, which the tests write again and compare byte for byte.
