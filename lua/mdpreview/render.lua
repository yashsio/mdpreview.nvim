-- Markdown -> preview lines renderer.
--
-- The renderer is intentionally self-contained (no external Markdown parser):
-- it turns an array of source lines into
--   * `lines`   : the buffer lines to display,
--   * `marks`   : extmark specs `{ row, col, end_col, hl, priority }`,
--   * `anchors` : a map `source_line (1-based) -> preview_row (0-based)`.
--
-- `anchors` is what powers scroll synchronisation between the two windows.
--
-- Supported block elements: ATX + setext headings, paragraphs, blockquotes,
-- ordered/unordered/task lists, fenced code blocks, horizontal rules and
-- pipe tables. Supported inline spans: bold, italic, nested bold/italic,
-- strikethrough, inline code, inline and reference links, images, autolinks,
-- HTML entities and backslash escapes.
local syntax = require("mdpreview.syntax")

local M = {}

local MAX_INLINE_DEPTH = 8
local ENTITIES = {
  amp = "&",
  lt = "<",
  gt = ">",
  quot = '"',
  apos = "'",
  nbsp = "\u{00a0}",
  copy = "\u{00a9}",
  reg = "\u{00ae}",
  trade = "\u{2122}",
  hellip = "\u{2026}",
  mdash = "\u{2014}",
  ndash = "\u{2013}",
}

local function display_width(s)
  local ok, w = pcall(vim.fn.strdisplaywidth, s)
  return ok and w or #s
end

local function charset(ascii)
  if ascii then
    return {
      bullet = "*",
      quote = "| ",
      v = "|",
      h = "-",
      cross = "+",
      tee = "+",
      right = "+",
    }
  end
  return {
    bullet = "\u{2022}", -- •
    quote = "\u{2502} ", -- │
    v = "\u{2502}", -- │
    h = "\u{2500}", -- ─
    cross = "\u{253C}", -- ┼
    tee = "\u{251C}", -- ├
    right = "\u{2524}", -- ┤
  }
end

local function normalise_ref(s)
  return (vim.trim(s):lower():gsub("%s+", " "))
end

----------------------------------------------------------------------
-- Inline parsing
----------------------------------------------------------------------

local function decode_entity(ent)
  local named = ENTITIES[ent:lower()]
  if named then
    return named
  end
  local code
  if ent:match("^#[xX]") then
    code = tonumber(ent:sub(3), 16)
  elseif ent:match("^#") then
    code = tonumber(ent:sub(2), 10)
  end
  if code and code > 0 and code <= 0x10FFFF then
    local ok, char = pcall(vim.fn.nr2char, code)
    if ok then
      return char
    end
  end
  return nil
end

local function count_run(text, i, ch)
  local j = i
  while text:sub(j, j) == ch do
    j = j + 1
  end
  return j - i
end

---Find the end of a code span whose opening backtick run is `run`.
local function find_code_close(text, from, run)
  local at = from
  while true do
    local a, b = text:find(run, at, true)
    if not a then
      return nil
    end
    -- A closing run must be exactly as long as the opening run.
    if text:sub(a - 1, a - 1) ~= "`" and text:sub(b + 1, b + 1) ~= "`" then
      return a, b
    end
    at = b + 1
  end
end

---Find a balanced closing delimiter, honouring escapes and nesting.
local function find_matching(text, from, open, close)
  local depth = 0
  local i = from
  local n = #text
  while i <= n do
    local ch = text:sub(i, i)
    if ch == "\\" then
      i = i + 2
    elseif ch == open then
      depth = depth + 1
      i = i + 1
    elseif ch == close then
      depth = depth - 1
      if depth == 0 then
        return i
      end
      i = i + 1
    else
      i = i + 1
    end
  end
  return nil
end

---Find a closing emphasis run. Prefers an exact-length run, then falls back to
---a longer run (whose extra delimiters are folded into the content).
local function find_emphasis_close(text, from, marker, run)
  local n = #text
  local j = from
  local fallback = nil
  while j <= n do
    local ch = text:sub(j, j)
    if ch == "\\" then
      j = j + 2
    elseif ch == "`" then
      local r = text:match("^(`+)", j)
      local _, b = find_code_close(text, j + #r, r)
      j = b and (b + 1) or (j + #r)
    elseif ch == marker then
      local k = count_run(text, j, marker)
      local before = text:sub(j - 1, j - 1)
      local after = text:sub(j + k, j + k)
      local close_ok = before ~= "" and not before:match("%s")
      if marker == "_" and after:match("[%w_]") then
        close_ok = false
      end
      if close_ok then
        if k == run then
          return j, k
        elseif k > run and not fallback then
          fallback = { j, k }
        end
      end
      j = j + k
    else
      j = j + 1
    end
  end
  if fallback then
    return fallback[1], fallback[2]
  end
  return nil
end

local function parse_dest(inner)
  inner = vim.trim(inner)
  if inner == "" then
    return ""
  end
  local angle = inner:match("^<([^>]*)>")
  if angle then
    return angle
  end
  return inner:match("^(%S+)") or inner
end

---Resolve the destination of a link starting just after its `]`.
---@return string|nil url, integer|nil next_index
local function resolve_link(text, after_label, label, ctx)
  local ch = text:sub(after_label, after_label)
  if ch == "(" then
    local close = find_matching(text, after_label, "(", ")")
    if close then
      return parse_dest(text:sub(after_label + 1, close - 1)), close + 1
    end
  elseif ch == "[" then
    local close = find_matching(text, after_label, "[", "]")
    if close then
      local ref = text:sub(after_label + 1, close - 1)
      if ref == "" then
        ref = label
      end
      local url = ctx.refs and ctx.refs[normalise_ref(ref)]
      if url then
        return url, close + 1
      end
    end
  else
    local url = ctx.refs and ctx.refs[normalise_ref(label)]
    if url then
      return url, after_label
    end
  end
  return nil, nil
end

---Collapse overlapping bold+italic spans into the dedicated group, so users
---who override `MdPreviewBoldItalic` see their style applied.
---@param hls string[]|nil
---@return string[]
local function normalise_hls(hls)
  local bold, italic = false, false
  local rest = {}
  for _, hl in ipairs(hls or {}) do
    if hl == "MdPreviewBold" then
      bold = true
    elseif hl == "MdPreviewItalic" then
      italic = true
    else
      rest[#rest + 1] = hl
    end
  end
  local out = {}
  if bold and italic then
    out[#out + 1] = "MdPreviewBoldItalic"
  elseif bold then
    out[#out + 1] = "MdPreviewBold"
  elseif italic then
    out[#out + 1] = "MdPreviewItalic"
  end
  for _, hl in ipairs(rest) do
    out[#out + 1] = hl
  end
  return out
end

---Flatten a parsed inline tree into `{ text, hls }` segments.
local function flatten(nodes, inherited, out)
  for _, node in ipairs(nodes) do
    local hls = inherited
    if node.hls and #node.hls > 0 then
      hls = {}
      for _, hl in ipairs(inherited or {}) do
        hls[#hls + 1] = hl
      end
      for _, hl in ipairs(node.hls) do
        hls[#hls + 1] = hl
      end
    end
    if node.kind == "text" then
      if node.text ~= "" then
        out[#out + 1] = { text = node.text, hls = normalise_hls(hls) }
      end
    elseif node.kind == "atom" then
      if node.text ~= "" then
        out[#out + 1] = { text = node.text, hls = normalise_hls(hls) }
      end
    elseif node.kind == "span" then
      flatten(node.children, hls, out)
    end
  end
  return out
end

---Text-only projection of a node list (used for link labels).
local function nodes_text(nodes)
  local segments = flatten(nodes, {}, {})
  local out = {}
  for _, segment in ipairs(segments) do
    out[#out + 1] = segment.text
  end
  return table.concat(out)
end

---@param text string
---@param ctx table
---@param depth integer|nil
---@return table[] nodes
local function parse(text, ctx, depth)
  depth = depth or 0
  local nodes = {}
  local i = 1
  local n = #text

  local function add_text(raw)
    if raw == "" then
      return
    end
    local last = nodes[#nodes]
    if last and last.kind == "text" then
      last.raw = last.raw .. raw
      last.text = last.text .. raw
    else
      nodes[#nodes + 1] = { kind = "text", raw = raw, text = raw, hls = {} }
    end
  end

  local function add_atom(raw, rendered, hls)
    nodes[#nodes + 1] = { kind = "atom", raw = raw, text = rendered, hls = hls or {} }
  end

  while i <= n do
    local c = text:sub(i, i)
    local rest = text:sub(i)

    if c == "\\" then
      local nx = text:sub(i + 1, i + 1)
      if nx ~= "" and nx:match("%p") then
        add_atom("\\" .. nx, nx, {})
        i = i + 2
      else
        add_text("\\")
        i = i + 1
      end
    elseif c == "`" then
      local run = rest:match("^(`+)")
      local a, b = find_code_close(text, i + #run, run)
      if a then
        local code = text:sub(i + #run, a - 1):gsub("\n", " ")
        if code:match("^ ") and code:match(" $") and code:match("%S") then
          code = code:sub(2, -2)
        end
        add_atom(text:sub(i, b), code, { "MdPreviewCode" })
        i = b + 1
      else
        add_text(run)
        i = i + #run
      end
    elseif c == "!" and text:sub(i + 1, i + 1) == "[" then
      local close = find_matching(text, i + 1, "[", "]")
      if close then
        local label = text:sub(i + 2, close - 1)
        local url, nexti = resolve_link(text, close + 1, label, ctx)
        if url then
          local alt = nodes_text(parse(label, ctx, depth + 1))
          local children = {
            {
              kind = "atom",
              text = "[image: " .. (alt ~= "" and alt or url) .. "]",
              raw = "",
              hls = { "MdPreviewImage" },
            },
          }
          if ctx.show_urls and url ~= "" and (alt == "" or url ~= alt) then
            children[#children + 1] = {
              kind = "atom",
              text = " (" .. url .. ")",
              raw = "",
              hls = { "MdPreviewLinkUrl" },
            }
          end
          nodes[#nodes + 1] = {
            kind = "span",
            raw = text:sub(i, nexti - 1),
            hls = {},
            children = children,
          }
          i = nexti
        else
          add_text("!")
          i = i + 1
        end
      else
        add_text("!")
        i = i + 1
      end
    elseif c == "[" then
      local close = find_matching(text, i, "[", "]")
      if close then
        local label = text:sub(i + 1, close - 1)
        local url, nexti = resolve_link(text, close + 1, label, ctx)
        if url then
          local label_text = nodes_text(parse(label, ctx, depth + 1))
          if label_text == "" then
            label_text = url
          end
          local children = {
            { kind = "atom", text = label_text, raw = "", hls = { "MdPreviewLink" } },
          }
          if ctx.show_urls and url ~= "" and (label == "" or url ~= label) then
            children[#children + 1] = {
              kind = "atom",
              text = " (" .. url .. ")",
              raw = "",
              hls = { "MdPreviewLinkUrl" },
            }
          end
          nodes[#nodes + 1] = {
            kind = "span",
            raw = text:sub(i, nexti - 1),
            hls = {},
            children = children,
          }
          i = nexti
        else
          add_text("[")
          i = i + 1
        end
      else
        add_text("[")
        i = i + 1
      end
    elseif c == "<" then
      local close = text:find(">", i + 1, true)
      if close then
        local inner = text:sub(i + 1, close - 1)
        if inner:match("^%s*[%w+.-]+://") or inner:match("^[%w.+-]+@[%w.-]+%.[%a]+$") then
          add_atom(text:sub(i, close), inner, { "MdPreviewLink" })
          i = close + 1
        elseif inner:match("^[/!]?[%a][%w%-]*") then
          -- Known-looking HTML tag: stripped from the text preview.
          i = close + 1
        else
          -- A bare `<` (e.g. `a < b > c`) must not eat the comparison.
          add_text("<")
          i = i + 1
        end
      else
        add_text("<")
        i = i + 1
      end
    elseif c == "*" or c == "_" then
      local run = count_run(text, i, c)
      local before = text:sub(i - 1, i - 1)
      local after = text:sub(i + run, i + run)
      local open_ok = run <= 3 and after ~= "" and not after:match("%s")
      if c == "_" and before:match("[%w_]") then
        open_ok = false
      end
      local openspan = false
      if open_ok and depth < MAX_INLINE_DEPTH then
        local j, k = find_emphasis_close(text, i + run, c, run)
        if j then
          local extra = k - run
          local closing_start = j + extra
          local content = text:sub(i + run, closing_start - 1)
          if content ~= "" and not content:match("^%s") and not content:match("%s$") then
            local hls
            if run == 1 then
              hls = { "MdPreviewItalic" }
            elseif run == 2 then
              hls = { "MdPreviewBold" }
            else
              hls = { "MdPreviewBold", "MdPreviewItalic" }
            end
            nodes[#nodes + 1] = {
              kind = "span",
              raw = text:sub(i, j + k - 1),
              hls = hls,
              children = parse(content, ctx, depth + 1),
            }
            i = j + k
            openspan = true
          end
        end
      end
      if not openspan then
        add_text(text:sub(i, i + run - 1))
        i = i + run
      end
    elseif c == "~" and text:sub(i + 1, i + 1) == "~" then
      local after = text:sub(i + 2, i + 2)
      local openspan = false
      if after ~= "" and not after:match("%s") and depth < MAX_INLINE_DEPTH then
        local j, k = find_emphasis_close(text, i + 2, "~", 2)
        if j then
          local content = text:sub(i + 2, j - 1)
          if content ~= "" and not content:match("^%s") and not content:match("%s$") then
            nodes[#nodes + 1] = {
              kind = "span",
              raw = text:sub(i, j + k - 1),
              hls = { "MdPreviewStrike" },
              children = parse(content, ctx, depth + 1),
            }
            i = j + k
            openspan = true
          end
        end
      end
      if not openspan then
        add_text("~~")
        i = i + 2
      end
    elseif c == "&" then
      local ent = rest:match("^&(#?[%w]+);")
      local decoded = ent and decode_entity(ent)
      if decoded then
        add_atom(text:sub(i, i + #ent + 1), decoded, {})
        i = i + #ent + 2
      else
        add_text("&")
        i = i + 1
      end
    elseif c == "!" then
      add_text("!")
      i = i + 1
    else
      local special = text:find("[\\`*_~!%[<&]", i + 1)
      local chunk = special and text:sub(i, special - 1) or rest
      add_text(chunk)
      i = i + #chunk
    end
  end

  return nodes
end

---Render a single line of inline Markdown, adding extmark specs to `marks`.
---@param text string
---@param row integer 0-based preview row
---@param marks table[]
---@param ctx table { conceal: boolean, show_urls: boolean, refs: table }
---@return string
local function render_inline(text, row, marks, ctx)
  if not ctx.conceal or text == "" then
    return text
  end
  local segments = flatten(parse(text, ctx, 0), {}, {})
  local out = {}
  local col = 0
  for _, segment in ipairs(segments) do
    local chunk = segment.text
    if chunk ~= "" then
      local start = col
      out[#out + 1] = chunk
      col = col + #chunk
      for _, hl in ipairs(segment.hls or {}) do
        marks[#marks + 1] = {
          row = row,
          col = start,
          end_col = col,
          hl = hl,
          priority = 200,
        }
      end
    end
  end
  return table.concat(out)
end

---Rendered display width of a line of inline Markdown, without adding marks.
---Split raw inline text into atoms that must not be broken by wrapping.
---Each atom carries the source (`raw`), its rendered text and width, plus the
---highlight used if the atom is eventually hard-split.
---@return table[]
local function tokenize(text, ctx)
  local atoms = {}
  if not ctx.conceal then
    for word in text:gmatch("%S+") do
      atoms[#atoms + 1] = {
        raw = word,
        text = word,
        width = display_width(word),
        hls = {},
        literal = false,
        plain = true,
      }
    end
    return atoms
  end
  local nodes = parse(text, ctx, 0)
  for _, node in ipairs(nodes) do
    if node.kind == "text" then
      for word in node.raw:gmatch("%S+") do
        atoms[#atoms + 1] = {
          raw = word,
          text = word,
          width = display_width(word),
          hls = {},
          literal = false,
          plain = true,
        }
      end
    else
      local segments = flatten({ node }, {}, {})
      local out = {}
      for _, segment in ipairs(segments) do
        out[#out + 1] = segment.text
      end
      local rendered = table.concat(out)
      atoms[#atoms + 1] = {
        raw = node.raw,
        text = rendered,
        width = display_width(rendered),
        hls = (segments[1] and segments[1].hls) or {},
        literal = false,
        plain = false,
      }
    end
  end
  return atoms
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function split_row(line)
  local s = line:gsub("^%s*|", "")
  local cells, cur = {}, {}
  local i, n = 1, #s
  local code_run = nil
  local ended_pipe = false

  local function flush()
    cells[#cells + 1] = vim.trim(table.concat(cur))
    cur = {}
  end

  while i <= n do
    local c = s:sub(i, i)
    if c == "\\" and i < n then
      local nx = s:sub(i + 1, i + 1)
      if nx == "|" then
        cur[#cur + 1] = "|"
      else
        cur[#cur + 1] = "\\" .. nx
      end
      ended_pipe = false
      i = i + 2
    elseif c == "`" then
      local run = s:match("^(`+)", i)
      if code_run then
        if run == code_run then
          code_run = nil
        end
      else
        code_run = run
      end
      cur[#cur + 1] = run
      ended_pipe = false
      i = i + #run
    elseif c == "|" and not code_run then
      flush()
      ended_pipe = true
      i = i + 1
    else
      cur[#cur + 1] = c
      ended_pipe = false
      i = i + 1
    end
  end
  if #cur > 0 or not ended_pipe then
    flush()
  end
  if ended_pipe and cells[#cells] == "" then
    table.remove(cells)
  end
  if #cells == 0 then
    cells = { "" }
  end
  return cells
end

local function is_table_sep(line)
  if not line:find("|", 1, true) and not line:match("^%s*:?%-+") then
    return false
  end
  local cells = split_row(line)
  if #cells == 0 then
    return false
  end
  for _, cell in ipairs(cells) do
    if not cell:match("^:?%-+:?$") then
      return false
    end
  end
  return true
end

local function table_aligns(line)
  local aligns = {}
  for c, cell in ipairs(split_row(line)) do
    if cell:match("^:%-+:$") then
      aligns[c] = "center"
    elseif cell:match("^:%-+") then
      aligns[c] = "left"
    elseif cell:match("%-+:$") then
      aligns[c] = "right"
    else
      aligns[c] = "left"
    end
  end
  return aligns
end

local function cell_br_lines(cell)
  local normalized = cell:gsub("<[bB][rR]%s*/?%s*>", "\n")
  local lines = {}
  for piece in (normalized .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = vim.trim(piece)
  end
  if #lines == 0 then
    lines = { "" }
  end
  return lines
end

local function split_br(line)
  local parts = {}
  local last = 1
  local from = 1
  while true do
    local a, b = line:find("<[bB][rR]%s*/?%s*>", from)
    if not a then
      break
    end
    parts[#parts + 1] = line:sub(last, a - 1)
    last = b + 1
    from = b + 1
  end
  parts[#parts + 1] = line:sub(last)
  return parts
end

local function is_horizontal_rule(line)
  local s = line:gsub("%s", "")
  if #s < 3 then
    return false
  end
  return s:match("^%-+$") ~= nil or s:match("^%*+$") ~= nil or s:match("^_+$") ~= nil
end

---Parse an opening code fence, returning char, run length and info string.
local function parse_fence(line)
  local run, rest = line:match("^%s*(`+)%s*(.*)$")
  if not run then
    run, rest = line:match("^%s*(~+)%s*(.*)$")
  end
  if not run or #run < 3 then
    return nil
  end
  return run:sub(1, 1), #run, vim.trim(rest)
end

local function is_closing_fence(line, char, len)
  local run = line:match("^%s*(`+)%s*$")
  if not run then
    run = line:match("^%s*(~+)%s*$")
  end
  return run ~= nil and run:sub(1, 1) == char and #run >= len
end

---Count and strip nested blockquote markers, returning level and inner text.
local function parse_quote(line)
  local rest = line:gsub("^%s*", "")
  local level = 0
  while rest:sub(1, 1) == ">" do
    level = level + 1
    rest = rest:sub(2):gsub("^%s*", "")
  end
  if level == 0 then
    return nil
  end
  return level, rest
end

local function add_full_line(marks, row, text, hl, priority)
  if text == "" then
    return
  end
  marks[#marks + 1] = {
    row = row,
    col = 0,
    end_col = #text,
    hl = hl,
    priority = priority or 100,
  }
end

---Shift the columns of every mark added after `from` by `delta` bytes.
local function shift_marks(marks, from, delta)
  if delta == 0 then
    return
  end
  for k = from + 1, #marks do
    marks[k].col = marks[k].col + delta
    marks[k].end_col = marks[k].end_col + delta
  end
end

---Display width of the line formed by joining `atoms` with single spaces.
local function atoms_line_width(atoms)
  local w = 0
  for _, a in ipairs(atoms) do
    w = w + a.width
  end
  if #atoms > 1 then
    w = w + (#atoms - 1)
  end
  return w
end

---Break an oversized atom into display-width-sized pieces. Plain words are
---split as source text; Markdown constructs are split on their *rendered*
---text and then emitted literally, so a long link or bold phrase degrades to
---readable text instead of broken syntax.
---@return table[]
local function split_long_atom(atom, width)
  width = math.max(1, width)
  if atom.width <= width then
    return { atom }
  end
  local pieces = {}
  local source = atom.text
  local total = vim.fn.strchars(source)
  local i = 1
  while i <= total do
    local take = width
    local piece = vim.fn.strcharpart(source, i - 1, take)
    while take > 1 and display_width(piece) > width do
      take = take - 1
      piece = vim.fn.strcharpart(source, i - 1, take)
    end
    pieces[#pieces + 1] = {
      raw = piece,
      text = piece,
      width = display_width(piece),
      hls = atom.hls,
      literal = not atom.plain,
      plain = atom.plain,
    }
    i = i + take
  end
  return pieces
end

---Greedily wrap atoms into lines of at most `width` display cells. Each result
---line is a list of atoms; the caller renders the atoms and joins them with a
---single space.
---@return table[]
local function wrap_atoms(atoms, width)
  width = math.max(1, width)
  local lines, cur, curw = {}, {}, 0
  local function flush()
    if #cur > 0 then
      lines[#lines + 1] = cur
      cur, curw = {}, 0
    end
  end
  for _, atom in ipairs(atoms) do
    for _, a in ipairs(split_long_atom(atom, width)) do
      if curw == 0 then
        cur, curw = { a }, a.width
      elseif curw + 1 + a.width <= width then
        cur[#cur + 1] = a
        curw = curw + 1 + a.width
      else
        flush()
        cur, curw = { a }, a.width
      end
    end
  end
  flush()
  if #lines == 0 then
    lines = { {} }
  end
  return lines
end

----------------------------------------------------------------------
-- Main renderer
----------------------------------------------------------------------

---@param lines string[]
---@param opts table
---@return { lines: string[], marks: table[], anchors: table<integer, integer> }
function M.render(lines, opts)
  opts = opts or {}
  local cs = charset(opts.ascii)
  local refs = {}
  for _, line in ipairs(lines) do
    local label, url = line:match("^%s*%[([^%]]+)%]:%s*(%S+)")
    if label and url then
      url = url:gsub("^<", ""):gsub(">$", "")
      refs[normalise_ref(label)] = url
    end
  end
  local ctx = {
    conceal = opts.conceal ~= false,
    show_urls = opts.show_urls ~= false,
    refs = refs,
  }
  local spacing = opts.spacing ~= false
  local hr_width = math.max(3, math.min(opts.columns or 80, 80))
  local syntax_enabled = opts.syntax ~= false

  local out = {}
  local marks = {}
  local anchors = {}
  local n = #lines
  local in_list = false
  local list_pad = ""

  local function is_blank()
    return #out == 0 or out[#out] == ""
  end

  local function blank()
    if spacing and not is_blank() then
      out[#out + 1] = ""
    end
  end

  local function push(text)
    out[#out + 1] = text
    return #out - 1
  end

  local function push_prefixed(prefix, text, bullet_hl)
    local row = #out
    local m0 = #marks
    local rendered = render_inline(text, row, marks, ctx)
    shift_marks(marks, m0, #prefix)
    out[#out + 1] = prefix .. rendered
    if bullet_hl then
      marks[#marks + 1] = {
        row = row,
        col = 0,
        end_col = #prefix,
        hl = bullet_hl,
        priority = 100,
      }
    end
    return row
  end

  local i = 1
  while i <= n do
    local line = lines[i]

    -- Reference definitions are metadata, never preview content. ----------
    if line:match("^%s*%[[^%]]+%]:%s*%S+") then
      anchors[i] = #out
      i = i + 1
      goto continue
    end

    -- Fenced code block ------------------------------------------------
    do
      local fence_char, fence_run, info = parse_fence(line)
      if fence_char then
        local body = {}
        local j = i + 1
        while j <= n and not is_closing_fence(lines[j], fence_char, fence_run) do
          body[#body + 1] = lines[j]
          j = j + 1
        end
        blank()
        in_list = false
        local block_start = #out
        local body_start = i + 1
        for k, code_line in ipairs(body) do
          anchors[body_start + k - 1] = block_start + k - 1
          local row = block_start + k - 1
          local text = "  " .. code_line
          out[#out + 1] = text
          add_full_line(marks, row, text, "MdPreviewCodeBlock", 100)
        end
        anchors[i] = block_start
        local lang = (info or ""):match("^([%w_+.#%-]+)") or ""
        if syntax_enabled and lang ~= "" and #body > 0 then
          for _, m in ipairs(syntax.highlights(body, lang)) do
            local row = block_start + m.row
            local text = out[row + 1] or ""
            local start_col = math.min(m.col + 2, #text)
            local end_col = math.min(m.end_col + 2, #text)
            if end_col > start_col then
              marks[#marks + 1] = {
                row = row,
                col = start_col,
                end_col = end_col,
                hl = m.hl,
                priority = 150,
              }
            end
          end
        end
        i = (j <= n) and (j + 1) or (n + 1)
        goto continue
      end
    end

    -- Blank line -------------------------------------------------------
    if line:match("^%s*$") then
      out[#out + 1] = ""
      in_list = false
      i = i + 1
      goto continue
    end

    -- Setext heading (checked before HR so `---` under text is a heading)
    if
      i < n
      and not line:match("^%s*>")
      and (lines[i + 1]:match("^%s*=+%s*$") or lines[i + 1]:match("^%s*%-+%s*$"))
    then
      local level = lines[i + 1]:match("^%s*=+%s*$") and 1 or 2
      blank()
      in_list = false
      anchors[i] = #out
      local row = #out
      local rendered = render_inline(line, row, marks, ctx)
      out[#out + 1] = rendered
      add_full_line(marks, row, rendered, "MdPreviewH" .. level, 100)
      anchors[i + 1] = row
      i = i + 2
      goto continue
    end

    -- ATX heading ------------------------------------------------------
    do
      local hashes, text = line:match("^%s*(#+)%s+(.*)$")
      if not hashes then
        hashes, text = line:match("^%s*(#+)%s*$"), ""
      end
      if hashes and #hashes <= 6 then
        -- A closing sequence is only valid when separated by whitespace, so
        -- `# C#` keeps its trailing hash.
        text = text:gsub("%s+#+%s*$", "")
        blank()
        in_list = false
        anchors[i] = #out
        local row = #out
        local rendered = render_inline(text, row, marks, ctx)
        out[#out + 1] = rendered
        add_full_line(marks, row, rendered, "MdPreviewH" .. #hashes, 100)
        i = i + 1
        goto continue
      end
    end

    -- Horizontal rule --------------------------------------------------
    if is_horizontal_rule(line) then
      blank()
      in_list = false
      anchors[i] = #out
      local rule = string.rep(cs.h, hr_width)
      local row = push(rule)
      add_full_line(marks, row, rule, "MdPreviewHr", 100)
      i = i + 1
      goto continue
    end

    -- Blockquote -------------------------------------------------------
    do
      local level, text = parse_quote(line)
      if level then
        anchors[i] = #out
        in_list = false
        local quote = string.rep(cs.quote, math.max(1, level))
        local row = push_prefixed(quote, text, "MdPreviewQuote")
        add_full_line(marks, row, out[row + 1], "MdPreviewQuote", 100)
        i = i + 1
        goto continue
      end
    end

    -- Table ------------------------------------------------------------
    if line:find("|", 1, true) and i < n and is_table_sep(lines[i + 1]) then
      blank()
      in_list = false
      local header = split_row(line)
      local aligns = table_aligns(lines[i + 1])
      local body = {}
      local j = i + 2
      while j <= n and lines[j]:find("|", 1, true) and not lines[j]:match("^%s*$") do
        body[#body + 1] = split_row(lines[j])
        j = j + 1
      end

      local ncols = #header
      for _, r in ipairs(body) do
        ncols = math.max(ncols, #r)
      end

      local header_cells = {}
      for c = 1, ncols do
        header_cells[c] = cell_br_lines(header[c] or "")
      end
      local body_cells = {}
      for k, r in ipairs(body) do
        local cells = {}
        for c = 1, ncols do
          cells[c] = cell_br_lines(r[c] or "")
        end
        body_cells[k] = cells
      end

      -- Natural width = widest rendered cell line in each column.
      local natural = {}
      for c = 1, ncols do
        natural[c] = 3
      end
      local function measure(cells)
        for c = 1, ncols do
          for _, raw in ipairs(cells[c]) do
            natural[c] = math.max(natural[c], atoms_line_width(tokenize(raw, ctx)))
          end
        end
      end
      measure(header_cells)
      for _, cells in ipairs(body_cells) do
        measure(cells)
      end

      -- Shrink proportionally so the table fits the window. Never let a
      -- single unbreakable token push the table past the window: oversized
      -- atoms are hard-split during cell layout instead.
      local table_max = math.max(20, opts.columns or 80)
      local budget = math.max(ncols, table_max - 1 - 3 * ncols)
      local total_natural = 0
      for c = 1, ncols do
        total_natural = total_natural + natural[c]
      end
      local widths = {}
      if total_natural <= budget then
        for c = 1, ncols do
          widths[c] = natural[c]
        end
      else
        -- Reserve a minimum of three cells per column, then distribute the
        -- rest proportionally to how much each column wants. The result
        -- always sums to at most the budget (unless even the borders do not
        -- fit, in which case the table is unavoidably wider than the window).
        local min_width = (budget >= ncols * 3) and 3 or 1
        local extra_budget = math.max(0, budget - ncols * min_width)
        local extra_natural = 0
        for c = 1, ncols do
          extra_natural = extra_natural + math.max(0, natural[c] - min_width)
        end
        local used = 0
        for c = 1, ncols do
          local share = 0
          if extra_natural > 0 then
            share = math.floor(extra_budget * math.max(0, natural[c] - min_width) / extra_natural)
          end
          widths[c] = min_width + share
          used = used + widths[c]
        end
        local c = 1
        while used < budget do
          widths[c] = widths[c] + 1
          used = used + 1
          c = c % ncols + 1
        end
      end

      local function layout_cell(raw_lines, width)
        local out_lines = {}
        for _, raw in ipairs(raw_lines) do
          for _, piece in ipairs(wrap_atoms(tokenize(raw, ctx), width)) do
            out_lines[#out_lines + 1] = piece
          end
        end
        if #out_lines == 0 then
          out_lines = { {} }
        end
        return out_lines
      end

      local header_layout = {}
      for c = 1, ncols do
        header_layout[c] = layout_cell(header_cells[c], widths[c])
      end
      local body_layout = {}
      for k, cells in ipairs(body_cells) do
        local l = {}
        for c = 1, ncols do
          l[c] = layout_cell(cells[c], widths[c])
        end
        body_layout[k] = l
      end

      local function row_height(layout)
        local h = 1
        for c = 1, ncols do
          h = math.max(h, #layout[c])
        end
        return h
      end

      local function emit_row(layout, base_hl)
        local first = #out
        local h = row_height(layout)
        for v = 1, h do
          local row = #out
          out[#out + 1] = ""
          local parts = {}
          local col = 0
          local function put(t, hl, prio)
            if t == "" then
              return
            end
            parts[#parts + 1] = t
            if hl then
              marks[#marks + 1] = {
                row = row,
                col = col,
                end_col = col + #t,
                hl = hl,
                priority = prio or 200,
              }
            end
            col = col + #t
          end
          put(cs.v, "MdPreviewTableBorder") -- │
          for c = 1, ncols do
            local atoms = layout[c][v] or {}
            local line_width = 0
            for ai, atom in ipairs(atoms) do
              line_width = line_width + atom.width + (ai > 1 and 1 or 0)
            end
            local pad = math.max(0, widths[c] - line_width)
            local align = aligns[c] or "left"
            local left_pad, right_pad = 0, pad
            if align == "right" then
              left_pad, right_pad = pad, 0
            elseif align == "center" then
              left_pad = math.floor(pad / 2)
              right_pad = pad - left_pad
            end
            put(" ")
            put(string.rep(" ", left_pad))
            for ai, atom in ipairs(atoms) do
              if ai > 1 then
                put(" ")
              end
              local before = col
              if atom.literal then
                local text = atom.text
                for _, hl in ipairs(atom.hls or {}) do
                  if text ~= "" then
                    marks[#marks + 1] = {
                      row = row,
                      col = before,
                      end_col = before + #text,
                      hl = hl,
                      priority = 200,
                    }
                  end
                end
                put(text, base_hl, 100)
              else
                local m0 = #marks
                local rendered = render_inline(atom.raw, row, marks, ctx)
                shift_marks(marks, m0, before)
                put(rendered, base_hl, 100)
              end
            end
            put(string.rep(" ", right_pad))
            put(" ")
            put(cs.v, "MdPreviewTableBorder")
          end
          out[row + 1] = table.concat(parts)
        end
        return first
      end

      local function emit_sep()
        local row = #out
        out[#out + 1] = ""
        local parts = { cs.tee }
        for c = 1, ncols do
          parts[#parts + 1] = string.rep(cs.h, widths[c] + 2)
          parts[#parts + 1] = c < ncols and cs.cross or cs.right
        end
        local text = table.concat(parts)
        out[row + 1] = text
        add_full_line(marks, row, text, "MdPreviewTableBorder", 200)
        return row
      end

      anchors[i] = #out
      emit_row(header_layout, "MdPreviewTableHeader")
      anchors[i + 1] = emit_sep()
      for k, layout in ipairs(body_layout) do
        anchors[i + 1 + k] = emit_row(layout, nil)
      end
      blank()

      i = j
      goto continue
    end

    -- Ordered list -----------------------------------------------------
    do
      local indent, num, rest = line:match("^(%s*)(%d+)[%.%)]%s+(.*)$")
      if num then
        local pad = indent:gsub("\t", "  ")
        local marker = num .. ". "
        anchors[i] = #out
        in_list = true
        list_pad = pad .. string.rep(" ", display_width(marker))
        push_prefixed(pad .. marker, rest, "MdPreviewBullet")
        i = i + 1
        goto continue
      end
    end

    -- Unordered / task list --------------------------------------------
    do
      local indent, rest = line:match("^(%s*)[%-%+%*]%s+(.*)$")
      if rest then
        local pad = indent:gsub("\t", "  ")
        local box, task_text = rest:match("^%[([ xX])%]%s*(.*)$")
        local marker, marker_hl
        if box then
          rest = task_text
          marker = (box == " " and "[ ]" or "[x]") .. " "
          marker_hl = box == " " and "MdPreviewTaskTodo" or "MdPreviewTaskDone"
        else
          marker = cs.bullet .. " "
          marker_hl = "MdPreviewBullet"
        end
        anchors[i] = #out
        in_list = true
        list_pad = pad .. string.rep(" ", display_width(marker))
        push_prefixed(pad .. marker, rest, marker_hl)
        i = i + 1
        goto continue
      end
    end

    -- Paragraph (including list continuation lines and <br> breaks) ----
    do
      local parts = split_br(line)
      local first = true
      for _, part in ipairs(parts) do
        local text = part:gsub("^%s*", "")
        if first then
          anchors[i] = #out
          first = false
        end
        if in_list then
          push_prefixed(list_pad, text)
        else
          local row = #out
          local rendered = render_inline(text, row, marks, ctx)
          out[#out + 1] = rendered:match("^%s*$") and "" or rendered
        end
      end
      i = i + 1
    end

    ::continue::
  end

  while #out > 0 and out[#out] == "" do
    table.remove(out)
  end

  return { lines = out, marks = marks, anchors = anchors }
end

return M
