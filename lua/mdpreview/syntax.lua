-- Optional Treesitter highlighting for fenced code blocks.
--
-- The preview buffer is plain text, so instead of attaching a highlighter we
-- parse each code block as a string and translate the highlight-query captures
-- into extmark specs. Everything is wrapped in `pcall` and cached: a missing
-- parser or query is never an error, it just means "no extra highlighting".
local M = {}

local aliases = {
  sh = "bash",
  shell = "bash",
  zsh = "bash",
  js = "javascript",
  jsx = "javascript",
  ts = "typescript",
  tsx = "typescript",
  py = "python",
  rs = "rust",
  md = "markdown",
  yml = "yaml",
  ["c++"] = "cpp",
  cxx = "cpp",
  hpp = "cpp",
  golang = "go",
}

local MAX_CACHE = 64
local cache = {}
local cache_order = {}

local function cache_get(key)
  return cache[key]
end

local function cache_put(key, value)
  if cache[key] == nil then
    cache_order[#cache_order + 1] = key
  end
  cache[key] = value
  while #cache_order > MAX_CACHE do
    local old = table.remove(cache_order, 1)
    cache[old] = nil
  end
end

---@param lines string[]
---@param lang string
---@return table[]
local function compute(lines, lang)
  local code = table.concat(lines, "\n")
  local ok, parser = pcall(vim.treesitter.get_string_parser, code, lang)
  if not ok or not parser then
    return {}
  end
  local parsed, trees = pcall(parser.parse, parser)
  if not parsed or not trees or not trees[1] then
    return {}
  end
  local okq, query = pcall(vim.treesitter.query.get, lang, "highlights")
  if not okq or not query then
    return {}
  end

  local lengths = {}
  for i, line in ipairs(lines) do
    lengths[i - 1] = #line
  end

  local marks = {}
  local function push(row, col, end_col, hl)
    if row < 0 or row >= #lines or end_col <= col then
      return
    end
    marks[#marks + 1] = { row = row, col = col, end_col = end_col, hl = hl }
  end

  local iter_ok, iter = pcall(query.iter_captures, query, trees[1]:root(), code)
  if not iter_ok or not iter then
    return {}
  end

  local count = 0
  for id, node in iter do
    local name = query.captures[id]
    -- `spell`/`nospell` are semantic captures with no colour; skip them.
    if name and name ~= "spell" and name ~= "nospell" then
      local hl = "@" .. name
      local sr, sc, er, ec = node:range()
      if sr == er then
        push(sr, sc, math.min(ec, lengths[sr] or ec), hl)
      else
        push(sr, sc, lengths[sr] or sc, hl)
        for row = sr + 1, er - 1 do
          push(row, 0, lengths[row] or 0, hl)
        end
        if er ~= sr then
          push(er, 0, math.min(ec, lengths[er] or ec), hl)
        end
      end
    end
    count = count + 1
    if count > 5000 then
      break
    end
  end

  return marks
end

---Highlight captures for a code block, relative to its first line.
---@param lines string[] raw code lines
---@param lang string|nil fence info string
---@return table[] { row, col, end_col, hl }
function M.highlights(lines, lang)
  if not lang or lang == "" or not lines or #lines == 0 then
    return {}
  end
  if not (vim.treesitter and vim.treesitter.get_string_parser) then
    return {}
  end
  local resolved = aliases[lang:lower()] or lang:lower()
  local key = resolved .. "\0" .. table.concat(lines, "\n")
  local cached = cache_get(key)
  if cached then
    return cached
  end
  local ok, marks = pcall(compute, lines, resolved)
  if not ok then
    marks = {}
  end
  cache_put(key, marks)
  return marks
end

return M
