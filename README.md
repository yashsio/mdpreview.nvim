# mdpreview.nvim

A pure-Lua, side-by-side Markdown preview for Neovim, laid out like `nvimdiff`:
your Markdown source in one split and a rendered preview in the other. The preview is just a read-only scratch buffer that re-renders as you type.

- No required external dependencies (no Node, no Pandoc, no web renderer).
- Works with Neovim **0.9+** (built-in Lua/extmark APIs only).
- Synchronised scrolling: moving one split follows in the other.
- Fenced code blocks are highlighted with Treesitter when a parser is available.
- Saves and restores your existing window layout.
- Optional ASCII fallback for terminals without box-drawing glyphs.

## Requirements

- Neovim 0.9 or newer.
- Optional: the Nix flake for a reproducible dev/test environment.

## Installation

### Try it without installing

From a checkout of this repository:

```sh
nvim -u test/minimal_init.lua example.md
```

Then run `:MarkdownPreview`. The minimal init only adds this checkout to
`runtimepath`; your normal Neovim configuration is skipped. To try it with your
own configuration instead:

```sh
nvim --cmd 'set runtimepath^=/path/to/mdpreview.md' example.md
```

### lazy.nvim

```lua
{
  "yashsio/mdpreview.nvim",
  ft = { "markdown" },
  opts = {},
  keys = {
    { "<leader>mp", "<cmd>MarkdownPreview<cr>", desc = "Markdown preview" },
    { "<leader>mc", "<cmd>MarkdownPreviewClose<cr>", desc = "Close markdown preview" },
    { "<leader>mt", "<cmd>MarkdownPreviewToggle<cr>", desc = "Toggle markdown preview" },
  },
}
```

## Usage

| Command                    | Description                                  |
| -------------------------- | -------------------------------------------- |
| `:MarkdownPreview`         | Open (or focus) the preview for the current buffer. |
| `:MarkdownPreviewClose`    | Close the preview and restore the layout.    |
| `:MarkdownPreviewToggle`   | Toggle the preview.                          |

The preview window is buffer-local and `q` closes it by default. By default
focus stays in the Markdown buffer after opening (`focus = "source"`); set
`focus = "preview"` to land in the preview instead. The command works on
unsaved buffers as long as the filetype is `markdown` (or the file has
a `.md`/`.markdown`/`.mkd`/`.mdx` extension) — no need to save first.

Example mapping:

```lua
vim.keymap.set("n", "<leader>mp", "<cmd>MarkdownPreview<cr>")
vim.keymap.set("n", "<leader>mc", "<cmd>MarkdownPreviewClose<cr>")
```

## Configuration

```lua
require("mdpreview").setup({
  split = "vertical",      -- "vertical" | "horizontal"
  position = "right",      -- "right" | "left" (vertical) / "above" | "below" (horizontal)
  width = 0.5,             -- fraction of the source window, or cells when > 1
  height = 0.5,            -- fraction of the source window, or cells when > 1
  debounce = 120,          -- ms to wait after a change before re-rendering
  syncscroll = true,       -- keep source/preview scroll positions in sync
  sync_cursor = false,     -- also move the preview cursor with the source cursor
  conceal = true,          -- strip inline markdown markers (**bold** -> bold)
  show_urls = true,        -- append link/image URLs in the preview
  spacing = true,          -- insert blank lines around block elements
  wrap = true,             -- soft-wrap the preview
  winbar = true,           -- show a "Markdown Preview" winbar
  focus = "source",        -- "source" | "preview" after opening
  syntax = true,           -- Treesitter-highlight fenced code blocks
  ascii = false,           -- use - | + instead of box-drawing characters
  keymaps = { q = "<cmd>MarkdownPreviewClose<cr>" },
  highlights = {
    -- any group from the table below, e.g.:
    -- MdPreviewH1 = { bold = true, underline = true, fg = "#ff8800" },
  },
  on_open = nil,           -- function(buf, win) called after opening
  on_close = nil,          -- function() called after closing
})
```

`width`/`height` fractions are relative to the source window, so opening a
preview inside a nested split takes half of that split rather than half of the
whole editor. `setup()` can be called again while the preview is open; the
window options, size, keymaps and content are re-applied.

`keymaps` is replaced rather than merged, so `keymaps = {}` disables the
built-in `q` mapping.

### Highlight groups

All groups are defined with `default = true`, so colorschemes and your overrides
win. Override them via the `highlights` option or with `:highlight`.

| Group | Used for | Default |
| ----- | -------- | ------- |
| `MdPreviewH1`…`MdPreviewH6` | Headings | attributes only |
| `MdPreviewBold` / `MdPreviewItalic` / `MdPreviewBoldItalic` | Emphasis | attributes only |
| `MdPreviewStrike` | `~~strikethrough~~` | attributes only |
| `MdPreviewCode` | Inline code | link `String` |
| `MdPreviewCodeBlock` | Fenced code blocks | link `String` |
| `MdPreviewLink` | Link text | link `Underlined` |
| `MdPreviewLinkUrl` | Link/image URLs | link `Comment` |
| `MdPreviewImage` | Images | link `Special` |
| `MdPreviewQuote` | Blockquotes | link `Comment` |
| `MdPreviewBullet` | List bullets / numbers | link `Special` |
| `MdPreviewTaskTodo` | `[ ]` task markers | link `Comment` |
| `MdPreviewTaskDone` | `[x]` task markers | bold, link `String` |
| `MdPreviewHr` | Horizontal rules | link `Comment` |
| `MdPreviewTableHeader` | Table header cells | bold |
| `MdPreviewTableBorder` | Table borders | link `Comment` |
| `MdPreviewWinbar` | Preview winbar | link `Title` |

Only attributes (no colours) are used for headings and emphasis so they remain
readable across every colorscheme; the rest link to core groups for colour.
Bold and italic nested inside each other use the combined
`MdPreviewBoldItalic` group, so overriding it affects both `***text***` and
nested `**bold *and italic***` spans.

## What is rendered

- ATX (`#`) and setext (`===`/`---`) headings.
- Paragraphs with inline **bold**, *italic*, ***bold italic***, `code`,
  ~~strikethrough~~, [links](https://example.com), images and autolinks.
- Inline and reference links (`[text](url)`, `[text][ref]`, `[text][]`), with
  reference definitions hidden from the preview.
- Backslash escapes (`\*literal\*`) and common HTML entities (`&amp;`, `&copy;`,
  numeric entities).
- Ordered, unordered, nested and task lists (`- [ ]` / `- [x]`), including
  lazy continuation lines.
- Blockquotes (`>`), including nested quotes (`>>`).
- Fenced code blocks (```` ``` ```` / `~~~`), shown without the fences and
  highlighted with Treesitter when a parser is installed.
- Horizontal rules.
- Pipe tables with aligned columns (`:---`, `:---:`, `---:`), escaped pipes,
  `<br>` line breaks, and box-drawing or ASCII borders.

## Architecture and tradeoffs

The plugin renders Markdown to **text plus extmarks** rather than HTML or an
image. This keeps it dependency-free, fast, and identical in every terminal, at
the cost of full fidelity (no images, HTML, math, or footnotes). The tradeoff is
deliberate: the goal is a clean, always-available preview that feels like a diff
view.

- `lua/mdpreview/render.lua` — a small, dependency-free Markdown parser. As it
  builds the preview lines it also records a `source line -> preview line`
  **anchor table** and a list of extmarks (highlight spans). Inline content is
  parsed into a small node tree so emphasis can nest; tables use
  `strdisplaywidth` so wide characters line up.
- `lua/mdpreview/syntax.lua` — optional Treesitter highlighting for fenced code
  blocks. Code is parsed as a string and highlight-query captures are
  translated into extmarks. Results are cached and missing parsers are a
  no-op.
- `lua/mdpreview/sync.lua` — scroll synchronisation. Neovim's `scrollbind` is
  unsuitable because rendered line counts differ from the source. Instead the
  anchor table translates the top line between windows, with a binary search
  over sparse anchors. A small "expected topline" guard breaks the
  `WinScrolled` feedback loop caused by our own programmatic scrolls.
- `lua/mdpreview/layout.lua` — snapshots every window's size and view before
  opening and restores them on close. Widths are reapplied with explicit
  resizes (which survive `'equalalways'`), not by toggling `'equalalways'`.
- `lua/mdpreview/highlight.lua` — default highlight groups, re-applied on
  `ColorScheme`.
- `lua/mdpreview/init.lua` — public API, window/buffer plumbing, debounce,
  autocmds, scheduling and error messages.
- `lua/mdpreview/config.lua` — defaults, validation and option merging.
- `lua/mdpreview/health.lua` — `:checkhealth mdpreview`.
- `plugin/mdpreview.lua` — command definitions.

Rendering runs on a **debounced timer** (`TextChanged`/`TextChangedI`/
`InsertLeave`), so rapid typing does not redraw on every keystroke. The timer is
reused between keystrokes and the preview keeps the cursor in the source window
by default.

## Testing

The test suite is dependency-free (no plenary/busted) and runs headless. All
fixtures are generated at runtime.

```sh
bash test/run.sh
```

This runs two specs:

- `test/render_spec.lua` — renderer output, highlights, anchors, options,
  inline edge cases, tables, references, ASCII mode and code highlighting.
- `test/integration_spec.lua` — real windows: open/close, buffer guards, unsaved
  and multiple buffers, focus, nested splits, `syncscroll`, reconfiguration,
  retargeting, extmark bounds, scroll sync, and layout restoration.

You can also run a single spec directly:

```sh
nvim --headless --clean -u test/minimal_init.lua -l test/render_spec.lua
```

### Health check

```vim
:checkhealth mdpreview
```

Reports the loaded version, active options, whether a preview is open, and
which Treesitter parsers are available.

### With Nix (optional)

A `flake.nix` provides a reproducible dev shell and runs the suite as a check:

```sh
nix develop            # enter the dev shell (neovim, luajit, lua-ls, stylua)
bash test/run.sh       # run the tests inside it
nix flake check        # run the suite as a sandboxed check
```

Nix is not required. If you do not use Nix, ignore `flake.nix` and use
`bash test/run.sh`.

### Manual test checklist

1. Open a Markdown file and run `:MarkdownPreview` — a split appears with the
   rendered document; the source is untouched.
2. Type in the source — the preview updates after the debounce.
3. Scroll the source — the preview follows; scroll the preview — the source
   follows.
4. Press `q` in the preview — it closes and your previous window sizes return.
5. Open a preview, then delete the source buffer (`:bdelete`) — the preview
   closes cleanly.
6. Run `:MarkdownPreview` on a non-Markdown buffer — you get a warning, no
   split.
7. Start editing an unsaved buffer and run `:MarkdownPreview` — it previews the
   in-memory contents.
8. Try `:w` in the preview — it fails because the buffer is `nofile` and not
   modifiable.

## Limitations

- One preview window per Neovim instance. Opening the preview for a different
  Markdown buffer re-targets the existing preview.
- Text-only rendering: no images, embedded HTML, math, or footnotes. HTML tags
  are stripped; `<br>` becomes a line break.
- Inline emphasis uses a pragmatic delimiter parser. Common nesting works
  (`**bold *and italic***`), but exotic delimiter runs can render literally.
- Tables support escaped pipes, `<br>` and `:---:` alignment, but not nested
  block content or multiline cells beyond `<br>`.
- Line-anchor scroll sync is approximate for very long single blocks (code
  blocks, tables) and for wrapped lines, because there is no 1:1 line mapping.
- Treesitter code highlighting depends on the parser for the fence language
  being installed. Missing parsers simply fall back to a single colour.

## License

MIT — see [LICENSE](LICENSE).
