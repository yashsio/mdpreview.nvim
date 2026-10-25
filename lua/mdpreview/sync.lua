-- Scroll/cursor synchronisation between the source and preview windows.
--
-- Neovim's `scrollbind` keeps the *same* line number at the top of both
-- windows, which is wrong here because the rendering changes line counts.
-- Instead we keep a source-line -> preview-line anchor table produced by the
-- renderer and translate the other window's top line through it. A small
-- "expected topline" guard breaks the feedback loop caused by `WinScrolled`
-- firing for our own programmatic scrolls.
local M = {}

local S = {
  enabled = false,
  syncscroll = true,
  src_win = nil,
  dst_win = nil,
  anchors = {},
  rev = {},
  fwd_keys = {},
  rev_keys = {},
  expected = {},
  sync_cursor = false,
}

---Largest key `<= key` in a sorted array of integers (binary search).
---@param keys integer[]
---@param key integer
---@return integer|nil
local function nearest_key(keys, key)
  local lo, hi = 1, #keys
  local best = nil
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if keys[mid] <= key then
      best = keys[mid]
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return best
end

---Resolve a line number through an anchor map.
---@param map table<integer, integer>
---@param keys integer[] sorted keys of `map`
---@param line integer
---@return integer|nil
local function nearest(map, keys, line)
  local key = nearest_key(keys, line)
  return key and map[key] or nil
end

---Rebuild the forward/backward maps from a renderer anchor table
---(0-based preview rows) into 1-based preview line numbers.
---@param anchors table<integer, integer>
---@param src_total integer
function M.set_anchors(anchors, src_total)
  local fwd = {}
  local rev = {}
  for src = 1, src_total do
    local row = anchors[src]
    if row ~= nil then
      fwd[src] = row + 1
      rev[row + 1] = src
    end
  end
  local fwd_keys = {}
  for key in pairs(fwd) do
    fwd_keys[#fwd_keys + 1] = key
  end
  table.sort(fwd_keys)
  local rev_keys = {}
  for key in pairs(rev) do
    rev_keys[#rev_keys + 1] = key
  end
  table.sort(rev_keys)
  S.anchors = fwd
  S.rev = rev
  S.fwd_keys = fwd_keys
  S.rev_keys = rev_keys
end

---@param src_win integer
---@param dst_win integer
---@param opts { sync_cursor: boolean, syncscroll: boolean }
function M.attach(src_win, dst_win, opts)
  S.src_win = src_win
  S.dst_win = dst_win
  S.sync_cursor = opts and opts.sync_cursor or false
  S.syncscroll = opts == nil or opts.syncscroll ~= false
  S.expected = {}
  S.enabled = true
end

function M.detach()
  S.enabled = false
  S.src_win = nil
  S.dst_win = nil
  S.anchors = {}
  S.rev = {}
  S.fwd_keys = {}
  S.rev_keys = {}
  S.expected = {}
end

---Expose internal state for tests.
function M._peek()
  return S
end

---Scroll `win` so `top` is the first visible line.
---@param win integer
---@param top integer
function M._set_topline(win, top)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local height = vim.api.nvim_win_get_height(win)
  local total = vim.api.nvim_buf_line_count(buf)
  top = math.max(1, math.min(top, math.max(1, total - height + 1)))
  S.expected[win] = top
  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    -- `winrestview` clamps `topline` to keep the cursor visible *and on the
    -- same screen row*, which fights an explicit scroll. Re-anchor the cursor
    -- to the same row within the new viewport so the requested topline sticks.
    local offset = math.max(0, math.min(view.lnum - view.topline, height - 1))
    view.topline = top
    view.leftcol = 0
    view.lnum = math.min(top + offset, total)
    vim.fn.winrestview(view)
  end)
end

---Handle a `WinScrolled` event for one window.
---@param win integer
function M.on_scrolled(win)
  if not S.enabled or not S.syncscroll then
    return
  end

  local expected = S.expected[win]
  if expected ~= nil then
    S.expected[win] = nil
    if vim.api.nvim_win_is_valid(win) and vim.fn.line("w0", win) == expected then
      return -- this scroll was ours; don't echo it back
    end
  end

  if win == S.src_win and vim.api.nvim_win_is_valid(S.dst_win) then
    local preview_line = nearest(S.anchors, S.fwd_keys, vim.fn.line("w0", win))
    if preview_line then
      M._set_topline(S.dst_win, preview_line)
    end
  elseif win == S.dst_win and vim.api.nvim_win_is_valid(S.src_win) then
    local src_line = nearest(S.rev, S.rev_keys, vim.fn.line("w0", win))
    if src_line then
      M._set_topline(S.src_win, src_line)
    end
  end
end

---Follow the source cursor in the preview (optional).
function M.on_cursor_moved()
  if not S.enabled or not S.sync_cursor then
    return
  end
  if vim.api.nvim_get_current_win() ~= S.src_win then
    return
  end
  if not vim.api.nvim_win_is_valid(S.dst_win) then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(S.src_win)[1]
  local preview_line = nearest(S.anchors, S.fwd_keys, lnum)
  if not preview_line then
    return
  end
  local buf = vim.api.nvim_win_get_buf(S.dst_win)
  local last = vim.api.nvim_buf_line_count(buf)
  pcall(vim.api.nvim_win_set_cursor, S.dst_win, { math.min(preview_line, last), 0 })
  M._set_topline(S.dst_win, preview_line)
end

return M
