-- Dependency-free test suite for mdpreview.nvim.
--
-- Run it with:
--     nvim --headless --clean -u test/minimal_init.lua -l test/render_spec.lua
--
-- It exercises the renderer and the pure helpers (no windows required) so it
-- works in any headless CI environment.

local render = require("mdpreview.render")
local layout = require("mdpreview.layout")
local sync = require("mdpreview.sync")

local total, failed = 0, 0

local function check(cond, msg)
  total = total + 1
  if cond then
    io.write("ok   - " .. msg .. "\n")
  else
    failed = failed + 1
    io.write("FAIL - " .. msg .. "\n")
  end
end

local function render_lines(lines, opts)
  return render.render(lines, opts or {})
end

---Index (1-based) of the first preview line containing `needle`.
local function row_of(result, needle)
  for i, line in ipairs(result.lines) do
    if line:find(needle, 1, true) then
      return i
    end
  end
  return nil
end

---True if any mark on `needle`'s row uses `hl`.
local function has_hl(result, needle, hl)
  local row = row_of(result, needle)
  if not row then
    return false
  end
  for _, m in ipairs(result.marks) do
    if m.row == row - 1 and m.hl == hl then
      return true
    end
  end
  return false
end

---True if `hl` covers exactly the span of `needle` on its row.
local function hl_covers(result, needle, hl)
  local row = row_of(result, needle)
  if not row then
    return false
  end
  local line = result.lines[row]
  local start = line:find(needle, 1, true) - 1
  local finish = start + #needle
  for _, m in ipairs(result.marks) do
    if m.row == row - 1 and m.hl == hl and m.col <= start and m.end_col >= finish then
      return true
    end
  end
  return false
end

----------------------------------------------------------------------
-- Headings
----------------------------------------------------------------------

do
  local r = render_lines({ "# Title", "text" })
  check(r.lines[1] == "Title", "ATX heading strips leading hashes")
  check(has_hl(r, "Title", "MdPreviewH1"), "ATX heading gets MdPreviewH1")

  local r2 = render_lines({ "### Three" })
  check(has_hl(r2, "Three", "MdPreviewH3"), "H3 uses MdPreviewH3")

  local r3 = render_lines({ "Setext", "======" })
  check(row_of(r3, "Setext") ~= nil, "setext heading renders text")
  check(has_hl(r3, "Setext", "MdPreviewH1"), "setext = is H1")

  local r4 = render_lines({ "Sub", "---" })
  check(has_hl(r4, "Sub", "MdPreviewH2"), "setext - is H2")
end

----------------------------------------------------------------------
-- Inline spans
----------------------------------------------------------------------

do
  local r = render_lines({ "a **bold** b *it* c `code` d ~~gone~~" })
  check(has_hl(r, "bold", "MdPreviewBold"), "bold span highlighted")
  check(has_hl(r, "it", "MdPreviewItalic"), "italic span highlighted")
  check(has_hl(r, "code", "MdPreviewCode"), "inline code highlighted")
  check(has_hl(r, "gone", "MdPreviewStrike"), "strikethrough highlighted")
  check(not r.lines[1]:find("%*"), "inline markers are concealed by default")
end

do
  local r = render_lines({ "a **b**" }, { conceal = false })
  check(r.lines[1] == "a **b**", "conceal=false keeps inline markers")
  check(not has_hl(r, "b", "MdPreviewBold"), "conceal=false adds no inline marks")
end

----------------------------------------------------------------------
-- Links and images
----------------------------------------------------------------------

do
  local r = render_lines({ "[text](https://example.com)" })
  check(r.lines[1]:find("text", 1, true) ~= nil, "link text kept")
  check(r.lines[1]:find("https://example.com", 1, true) ~= nil, "link URL shown by default")
  check(has_hl(r, "text", "MdPreviewLink"), "link highlighted")

  local r2 = render_lines({ "[text](https://example.com)" }, { show_urls = false })
  check(r2.lines[1] == "text", "show_urls=false hides the URL")

  local r3 = render_lines({ "![alt](img.png)" })
  check(r3.lines[1]:find("image", 1, true) ~= nil, "image rendered with label")
end

----------------------------------------------------------------------
-- Lists, quotes, code, rules
----------------------------------------------------------------------

do
  local r = render_lines({ "- one", "- [x] done", "- [ ] todo" })
  check(r.lines[1]:find("\u{2022}", 1, true) ~= nil, "unordered list uses a bullet")
  check(row_of(r, "[x] done") ~= nil, "checked task rendered")
  check(row_of(r, "[ ] todo") ~= nil, "unchecked task rendered")

  local ro = render_lines({ "1. first", "2. second" })
  check(ro.lines[1]:find("1.", 1, true) ~= nil, "ordered list keeps numbers")

  local rq = render_lines({ "> quoted" })
  check(rq.lines[1]:sub(1, #"\u{2502}") == "\u{2502}", "blockquote prefix added")
  check(has_hl(rq, "quoted", "MdPreviewQuote"), "blockquote highlighted")

  local rc = render_lines({ "```lua", "print('hi')", "```" })
  check(row_of(rc, "print('hi')") ~= nil, "code block body rendered")
  check(not row_of(rc, "```"), "code fences are hidden")
  check(has_hl(rc, "print('hi')", "MdPreviewCodeBlock"), "code block highlighted")

  local rh = render_lines({ "a", "", "---" })
  check(has_hl(rh, "\u{2500}", "MdPreviewHr"), "horizontal rule rendered")
end

----------------------------------------------------------------------
-- Tables
----------------------------------------------------------------------

do
  local r = render_lines({
    "| Name | Value |",
    "| ---- | ----- |",
    "| a    | 1     |",
    "| b    | 2     |",
  })
  check(row_of(r, "Name") ~= nil, "table header rendered")
  check(row_of(r, "Value") ~= nil, "table second column rendered")
  check(has_hl(r, "Name", "MdPreviewTableHeader"), "table header highlighted")
  check(has_hl(r, "\u{253C}", "MdPreviewTableBorder"), "table separator uses border highlight")
  check(row_of(r, "a") ~= nil and row_of(r, "2") ~= nil, "table body rendered")

  local ra = render_lines({
    "| l | c | r |",
    "| :--- | :---: | ---: |",
    "| a | b | c |",
  })
  check(
    ra.lines[1]:find("│ l   │  c  │   r │", 1, true) ~= nil,
    "table alignment is applied"
  )
  check(
    ra.lines[3]:find("│ a   │  b  │   c │", 1, true) ~= nil,
    "body cells honour alignment"
  )

  local re = render_lines({
    "| a \\| b | c |",
    "| --- | --- |",
    "| 1 | 2 |",
  })
  check(re.lines[1]:find("a | b", 1, true) ~= nil, "escaped pipes stay inside a cell")
  check(re.lines[1]:find("│ a | b │ c", 1, true) ~= nil, "escaped pipe does not split a column")

  local rl = render_lines({
    "| " .. string.rep("x", 200) .. " | b |",
    "| --- | --- |",
    "| 1 | 2 |",
  }, { columns = 40 })
  local widest = 0
  for _, line in ipairs(rl.lines) do
    widest = math.max(widest, vim.fn.strdisplaywidth(line))
  end
  check(widest <= 40, "a single long token cannot overflow the table window")
  check(#rl.lines > 3, "long table tokens are hard-wrapped")

  local rc = render_lines({ "| **a** | b |", "| --- | --- |", "| 1 | 2 |" }, { conceal = false })
  check(rc.lines[1]:find("**a**", 1, true) ~= nil, "conceal = false keeps table cell markup")
end

----------------------------------------------------------------------
-- Inline edge cases
----------------------------------------------------------------------

do
  local r = render_lines({ "a * b * c" })
  check(r.lines[1] == "a * b * c", "spaced asterisks are not emphasis")

  local r2 = render_lines({ "foo_bar_baz" })
  check(r2.lines[1] == "foo_bar_baz", "intraword underscores are literal")

  local r3 = render_lines({ "\\*not italic\\*" })
  check(r3.lines[1] == "*not italic*", "backslash escapes are honoured")

  local r4 = render_lines({ "**bold *and italic***" })
  check(r4.lines[1] == "bold and italic", "nested bold/italic is parsed")
  check(hl_covers(r4, "bold", "MdPreviewBold"), "outer bold covers its text")
  check(hl_covers(r4, "italic", "MdPreviewBoldItalic"), "inner italic inherits bold")
  check(
    hl_covers(r4, "italic", "MdPreviewItalic") == false,
    "nested emphasis uses the combined group"
  )

  local r4b = render_lines({ "***both***" })
  check(hl_covers(r4b, "both", "MdPreviewBoldItalic"), "triple emphasis uses MdPreviewBoldItalic")

  local r5 = render_lines({ "a < b > c" })
  check(r5.lines[1] == "a < b > c", "angle brackets in prose are preserved")

  local r6 = render_lines({ "AT&amp;T &copy; &#65;" })
  check(r6.lines[1] == "AT&T \u{00a9} A", "HTML entities are decoded")
end

----------------------------------------------------------------------
-- Block edge cases
----------------------------------------------------------------------

do
  local r = render_lines({ "# C#" })
  check(r.lines[1] == "C#", "trailing hash without a space is kept")

  local r2 = render_lines({ "# C #" })
  check(r2.lines[1] == "C", "a spaced closing sequence is stripped")

  local r3 = render_lines({ "a", "", "- - -" })
  check(has_hl(r3, "\u{2500}", "MdPreviewHr"), "spaced dashes are a horizontal rule")
  check(not row_of(r3, "\u{2022}"), "spaced dashes are not a list")

  local r4 = render_lines({ "- item one", "  continuation", "- item two" })
  check(r4.lines[2] == "  continuation", "lazy list continuation keeps its indent")

  local r5 = render_lines({ "> outer", ">> inner" })
  check(r5.lines[2] == "\u{2502} \u{2502} inner", "nested blockquotes keep both bars")

  local r6 = render_lines({ "one<br>two" })
  check(
    #r6.lines == 2 and r6.lines[1] == "one" and r6.lines[2] == "two",
    "<br> starts a new preview line"
  )

  local r7 = render_lines({ "- [x] done", "- [ ] todo" })
  check(has_hl(r7, "done", "MdPreviewTaskDone"), "completed tasks use MdPreviewTaskDone")
  check(has_hl(r7, "todo", "MdPreviewTaskTodo"), "open tasks use MdPreviewTaskTodo")
end

----------------------------------------------------------------------
-- Reference links
----------------------------------------------------------------------

do
  local r = render_lines({
    "see [docs][1] and [collapsed][]",
    "",
    "[1]: https://example.com",
    "[collapsed]: https://example.org",
  })
  check(r.lines[1]:find("docs (https://example.com)", 1, true) ~= nil, "reference link resolves")
  check(
    r.lines[1]:find("collapsed (https://example.org)", 1, true) ~= nil,
    "collapsed reference link resolves"
  )
  check(row_of(r, "[1]:") == nil, "reference definitions are hidden")

  local r2 = render_lines({ "see [docs][nope]" })
  check(r2.lines[1] == "see [docs][nope]", "unresolved reference stays literal")
end

----------------------------------------------------------------------
-- ASCII mode and code syntax highlighting
----------------------------------------------------------------------

do
  local r = render_lines({
    "# T",
    "",
    "> q",
    "",
    "---",
    "",
    "| a | b |",
    "| --- | --- |",
    "| 1 | 2 |",
  }, { ascii = true })
  check(row_of(r, "-----") ~= nil, "ascii mode uses dashes for rules")
  check(row_of(r, "| q") ~= nil, "ascii mode uses a pipe for quotes")
  check(row_of(r, "+-----+") ~= nil, "ascii mode uses + for table corners")

  local code = { "```lua", "local x = 1", "```" }
  local r2 = render_lines(code, { syntax = true })
  local has_ts = false
  for _, m in ipairs(r2.marks) do
    if m.hl:sub(1, 1) == "@" then
      has_ts = true
      break
    end
  end
  local parser_ok = #require("mdpreview.syntax").highlights({ "local x = 1" }, "lua") > 0
  if parser_ok then
    check(has_ts, "fenced code gets Treesitter captures")
  else
    check(not has_ts, "missing language parser degrades gracefully")
  end
  local r3 = render_lines(code, { syntax = false })
  local has_ts3 = false
  for _, m in ipairs(r3.marks) do
    if m.hl:sub(1, 1) == "@" then
      has_ts3 = true
    end
  end
  check(not has_ts3, "syntax = false disables Treesitter captures")
end

----------------------------------------------------------------------
-- Anchors
----------------------------------------------------------------------

do
  local r = render_lines({ "# One", "", "two", "", "## Three" })
  check(r.anchors[1] ~= nil, "anchor exists for heading source line")
  check(r.anchors[3] ~= nil, "anchor exists for paragraph source line")
  check(r.anchors[1] < r.anchors[3], "anchors are ordered")
end

----------------------------------------------------------------------
-- layout.resolve_size
----------------------------------------------------------------------

do
  check(layout.resolve_size(0.5, 100) == 49, "fraction width resolves to cells")
  check(layout.resolve_size(2, 100) == 2, "absolute width passes through")
  check(layout.resolve_size(0.5, 1) == 1, "tiny fraction clamps to at least 1")
end

----------------------------------------------------------------------
-- sync anchors
----------------------------------------------------------------------

do
  sync.set_anchors({ [1] = 0, [3] = 2, [4] = 3 }, 4)
  local s = sync._peek()
  check(s.anchors[1] == 1, "forward anchor is 1-based")
  check(s.anchors[3] == 3, "forward anchor maps third source line")
  check(s.rev[3] == 3, "reverse anchor maps preview line back to source")
  check(#s.fwd_keys == 3 and s.fwd_keys[2] == 3, "forward anchor keys are sorted for binary search")

  sync.set_anchors({ [2] = 0, [10] = 5, [20] = 9 }, 20)
  local sparse = sync._peek()
  check(#sparse.fwd_keys == 3 and sparse.fwd_keys[3] == 20, "sparse anchor keys are indexed")
end

----------------------------------------------------------------------
-- Module setup / highlights
----------------------------------------------------------------------

do
  local md = require("mdpreview")
  local cfg = require("mdpreview.config")
  local ok = pcall(md.setup, { debounce = 10 })
  check(ok, "setup() runs without error")
  check(cfg.get().debounce == 10, "setup options persist across get()")
  check(vim.fn.hlexists("MdPreviewH1") == 1, "highlight groups are defined")
  local ok2 = pcall(render_lines, {})
  check(ok2, "rendering empty input does not error")

  local merged = md.setup({ keymaps = {} })
  check(next(merged.keymaps) == nil, "keymaps = {} clears the default mappings")
  local coerced = md.setup({ split = "nope", position = "nowhere", focus = "elsewhere" })
  check(
    coerced.split == "vertical" and coerced.position == "right",
    "invalid split options are normalised"
  )
  check(coerced.focus == "source", "invalid focus option is normalised")
end

----------------------------------------------------------------------

io.write(("\n%d/%d checks passed\n"):format(total - failed, total))
os.exit(failed == 0 and 0 or 1)
