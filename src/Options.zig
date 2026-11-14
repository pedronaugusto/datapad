//! What a parse reads: CommonMark alone, or with GFM's extensions and the
//! two syntaxes tycho's consumers need, each a flag.

/// The constructs past CommonMark a parse reads.
pub const Extensions = packed struct {
    /// GFM: pipe tables.
    tables: bool = false,
    /// GFM: `[ ]` and `[x]` at a list item's start.
    task_lists: bool = false,
    /// GFM: `~text~` and `~~text~~`.
    strikethrough: bool = false,
    /// GFM: `www.`, `http://`, `https://` and e-mail addresses linked bare.
    autolinks: bool = false,
    /// GFM: raw HTML's disallowed tags filtered by the HTML writer.
    tagfilter: bool = false,
    /// `[[target]]` and `[[target|label]]`.
    wikilinks: bool = false,
    /// A leading `---` YAML or `+++` TOML block, given as one event.
    front_matter: bool = false,

    pub const commonmark: Extensions = .{};
    pub const gfm: Extensions = .{ .tables = true, .task_lists = true, .strikethrough = true, .autolinks = true, .tagfilter = true };
};

extensions: Extensions = .gfm,
