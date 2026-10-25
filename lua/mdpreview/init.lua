-- mdpreview.nvim -- public API.
--
-- A nvimdiff-inspired side-by-side Markdown preview. The source buffer is left
-- untouched and rendered into a read-only scratch buffer in an adjacent split.
-- There are no external dependencies: rendering and synchronisation are pure
-- Lua using Neovim's built-in APIs.
local config = require("mdpreview.config")
local highlight = require("mdpreview.highlight")
local layout = require("mdpreview.layout")
local render = require("mdpreview.render")
local sync = require("mdpreview.sync")

local uv = vim.uv or vim.loop
local ns = vim.api.nvim_create_namespace("mdpreview")

local M = {}

local state = {
  configured = false,
  win = nil,
  buf = nil,
  src_win = nil,
  src_buf = nil,
  augroup = nil,
  timer = nil,
  layout = nil,
  keymaps = nil,
  gen = 0,
  opening = false,
}

M._state = state

local md_exts = { md = true, markdown = true, mkd = true, mdx = true }

local function notify(msg, level)
  vim.notify("[mdpreview] " .. msg, level or vim.log.levels.INFO)
end

---@param buf integer
---@return boolean
local function is_markdown_buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local ft = vim.bo[buf].filetype
  if ft == "markdown" or ft == "markdown.mdx" then
    return true
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local ext = name:match("%.([%w_]+)$")
  return ext ~= nil and md_exts[ext:lower()] == true
end

---Idempotent configuration; safe to call from `setup()` or lazily.
local function ensure()
  if not state.configured then
    M.setup({})
  end
end

local function stop_timer()
  state.gen = state.gen + 1
  if state.timer then
    state.timer:stop()
    if not state.timer:is_closing() then
      state.timer:close()
    end
    state.timer = nil
  end
end

----------------------------------------------------------------------
-- Rendering
----------------------------------------------------------------------

local function update()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end
  if not (state.src_buf and vim.api.nvim_buf_is_valid(state.src_buf)) then
    return
  end
  local cfg = config.get()
  local src_lines = vim.api.nvim_buf_get_lines(state.src_buf, 0, -1, false)
  local win_width = (state.win and vim.api.nvim_win_is_valid(state.win))
      and vim.api.nvim_win_get_width(state.win)
    or 80

  local result = render.render(src_lines, {
    conceal = cfg.conceal,
    show_urls = cfg.show_urls,
    spacing = cfg.spacing,
    columns = win_width,
    ascii = cfg.ascii,
    syntax = cfg.syntax,
  })

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, result.lines)
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, m in ipairs(result.marks) do
    local text = result.lines[m.row + 1] or ""
    -- Extmark columns are byte offsets: clamp them so a renderer bug can
    -- never make the whole update fail silently.
    local start_col = math.max(0, math.min(m.col, #text))
    local end_col = math.max(start_col, math.min(m.end_col, #text))
    if end_col > start_col then
      pcall(vim.api.nvim_buf_set_extmark, state.buf, ns, m.row, start_col, {
        end_col = end_col,
        hl_group = m.hl,
        priority = m.priority or 100,
      })
    end
  end
  vim.bo[state.buf].modifiable = false

  sync.set_anchors(result.anchors, #src_lines)
end

local function get_timer()
  if not state.timer then
    state.timer = uv.new_timer()
  end
  return state.timer
end

local function debounced_update()
  local cfg = config.get()
  local timer = get_timer()
  -- Restart the same timer instead of destroying/recreating it on every
  -- keystroke. `stop_timer()` (which closes the handle) is only used on close.
  timer:stop()
  state.gen = state.gen + 1
  local gen = state.gen
  timer:start(
    cfg.debounce,
    0,
    vim.schedule_wrap(function()
      if state.gen ~= gen then
        return
      end
      update()
    end)
  )
end

----------------------------------------------------------------------
-- Window / buffer plumbing
----------------------------------------------------------------------

local function apply_window_options(win)
  local cfg = config.get()
  local o = vim.wo[win]
  o.number = false
  o.relativenumber = false
  o.cursorline = false
  o.signcolumn = "no"
  o.foldcolumn = "0"
  o.spell = false
  o.list = false
  o.wrap = cfg.wrap
  o.linebreak = true
  o.breakindent = true
  o.scrolloff = 0
  o.sidescrolloff = 0
  o.foldenable = false
  o.winfixwidth = cfg.split == "vertical"
  o.winfixheight = cfg.split == "horizontal"
  if cfg.winbar then
    local short = ""
    if state.src_buf and vim.api.nvim_buf_is_valid(state.src_buf) then
      local name = vim.api.nvim_buf_get_name(state.src_buf)
      short = name ~= "" and vim.fn.fnamemodify(name, ":t") or "[No Name]"
    end
    o.winbar = "%#MdPreviewWinbar# Markdown Preview %*%="
      .. (short ~= "" and ("%#MdPreviewWinbar# " .. short .. " %*") or "")
  else
    o.winbar = ""
  end
end

---Resize the preview relative to the source/preview window pair so that nested
---splits use half of *their* space rather than half of the whole editor.
local function apply_size()
  local cfg = config.get()
  local win = state.win
  local src = state.src_win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  if not (src and vim.api.nvim_win_is_valid(src)) then
    return
  end
  pcall(function()
    if cfg.split == "horizontal" then
      local base = vim.api.nvim_win_get_height(src) + vim.api.nvim_win_get_height(win)
      local target = layout.resolve_size(cfg.height, base)
      vim.api.nvim_win_set_height(src, math.max(1, base - target))
      vim.api.nvim_win_set_height(win, target)
    else
      local base = vim.api.nvim_win_get_width(src) + vim.api.nvim_win_get_width(win)
      local target = layout.resolve_size(cfg.width, base)
      vim.api.nvim_win_set_width(src, math.max(1, base - target))
      vim.api.nvim_win_set_width(win, target)
    end
  end)
end

local function apply_keymaps()
  local buf = state.buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local cfg = config.get()
  for lhs in pairs(state.keymaps or {}) do
    if (cfg.keymaps or {})[lhs] == nil then
      pcall(vim.keymap.del, "n", lhs, { buffer = buf })
    end
  end
  for lhs, rhs in pairs(cfg.keymaps or {}) do
    vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, nowait = true })
  end
  state.keymaps = vim.deepcopy(cfg.keymaps or {})
end

local function focus_source()
  local cfg = config.get()
  if cfg.focus ~= "preview" and state.src_win and vim.api.nvim_win_is_valid(state.src_win) then
    pcall(vim.api.nvim_set_current_win, state.src_win)
  end
end

local function detach()
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
end

local function attach(src_buf, group)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group = group,
    buffer = src_buf,
    callback = debounced_update,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = src_buf,
    callback = sync.on_cursor_moved,
  })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function(args)
      local win = tonumber(args.match) or vim.api.nvim_get_current_win()
      sync.on_scrolled(win)
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      update()
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    buffer = src_buf,
    callback = function()
      vim.schedule(M.close)
    end,
  })
  -- Follow the source window when the user edits a different buffer in it.
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(args)
      if state.opening or not M.is_open() then
        return
      end
      if vim.api.nvim_get_current_win() ~= state.src_win then
        return
      end
      if args.buf == state.src_buf then
        return
      end
      local target = args.buf
      vim.schedule(function()
        if state.opening or not M.is_open() then
          return
        end
        if vim.api.nvim_get_current_win() ~= state.src_win then
          return
        end
        if vim.api.nvim_get_current_buf() ~= target then
          return
        end
        if
          is_markdown_buf(target)
          and vim.api.nvim_buf_is_loaded(target)
          and vim.bo[target].buftype == ""
        then
          M.open()
        else
          M.close()
        end
      end)
    end,
  })
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

---@param opts MdPreviewOpts|nil
function M.setup(opts)
  local cfg = config.setup(opts)
  highlight.setup(cfg.highlights)
  local was_configured = state.configured
  state.configured = true
  if was_configured and M.is_open() then
    apply_window_options(state.win)
    apply_size()
    apply_keymaps()
    update()
  end
  return cfg
end

---@return boolean
function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

local function do_open()
  local cfg = config.get()
  local src_buf = vim.api.nvim_get_current_buf()

  -- If the preview window was closed behind our back, restore the old layout
  -- before taking a fresh snapshot so it is not lost.
  if state.layout ~= nil and not M.is_open() then
    local stale = state.layout
    stop_timer()
    detach()
    sync.detach()
    state.win = nil
    state.buf = nil
    state.src_buf = nil
    state.src_win = nil
    state.layout = nil
    state.keymaps = nil
    layout.restore(stale)
  end

  if not is_markdown_buf(src_buf) then
    notify(
      "current buffer is not Markdown; set 'filetype=markdown' or open a .md file",
      vim.log.levels.WARN
    )
    return
  end
  if not vim.api.nvim_buf_is_loaded(src_buf) then
    notify("source buffer is not loaded", vim.log.levels.WARN)
    return
  end
  if vim.bo[src_buf].buftype ~= "" then
    notify(
      "cannot preview a special buffer (buftype=" .. vim.bo[src_buf].buftype .. ")",
      vim.log.levels.WARN
    )
    return
  end

  if M.is_open() then
    if state.src_buf == src_buf then
      if cfg.focus == "preview" then
        vim.api.nvim_set_current_win(state.win)
      else
        focus_source()
      end
      update()
      return
    end
    M.close() -- switching to a different Markdown buffer
  end

  state.src_buf = src_buf
  state.src_win = vim.api.nvim_get_current_win()
  state.layout = layout.save()

  local group = vim.api.nvim_create_augroup("MdPreview", { clear = true })
  state.augroup = group

  local buf = vim.api.nvim_create_buf(false, true)
  state.buf = buf
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].undolevels = -1
  vim.bo[buf].filetype = "mdpreview"
  vim.bo[buf].modifiable = false

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(M.close)
    end,
  })

  local cmd
  if cfg.split == "horizontal" then
    cmd = (cfg.position == "above") and "aboveleft split" or "belowright split"
  else
    cmd = (cfg.position == "left") and "aboveleft vsplit" or "belowright vsplit"
  end
  vim.cmd(cmd)

  local win = vim.api.nvim_get_current_win()
  state.win = win
  vim.api.nvim_win_set_buf(win, buf)
  apply_window_options(win)

  -- Split exactly half of the source window's pre-split size, then put the
  -- neighbouring windows back where they were. `'equalalways'` otherwise
  -- shrinks every other window in the tab page when the preview is created.
  local function initial_size()
    local saved = state.layout
    local base = saved and saved.wins[state.src_win]
    if not base then
      return
    end
    -- Restore the neighbouring windows first: under `'equalalways'`, resizing
    -- them after the preview would steal space back from the new pair.
    for other, info in pairs(saved.wins) do
      if other ~= state.src_win and other ~= win and vim.api.nvim_win_is_valid(other) then
        pcall(function()
          if cfg.split == "horizontal" then
            vim.api.nvim_win_set_height(other, info.height)
          else
            vim.api.nvim_win_set_width(other, info.width)
          end
        end)
      end
    end
    if cfg.split == "horizontal" then
      local target = layout.resolve_size(cfg.height, base.height)
      pcall(function()
        vim.api.nvim_win_set_height(state.src_win, math.max(1, base.height - target))
        vim.api.nvim_win_set_height(win, target)
      end)
    else
      local target = layout.resolve_size(cfg.width, base.width)
      pcall(function()
        vim.api.nvim_win_set_width(state.src_win, math.max(1, base.width - target))
        vim.api.nvim_win_set_width(win, target)
      end)
    end
  end
  initial_size()
  apply_keymaps()

  update()
  attach(src_buf, group)
  sync.attach(state.src_win, win, {
    sync_cursor = cfg.sync_cursor,
    syncscroll = cfg.syncscroll,
  })

  if cfg.on_open then
    pcall(cfg.on_open, buf, win)
  end
  focus_source()
  -- Focusing the source window can make `'equalalways'` redistribute space
  -- again; re-apply the intended sizes once things have settled.
  initial_size()
end

---Open (or focus) the preview for the current buffer.
function M.open()
  ensure()
  if state.opening then
    return
  end
  state.opening = true
  local ok, err = pcall(do_open)
  state.opening = false
  if not ok then
    notify("failed to open preview: " .. tostring(err), vim.log.levels.ERROR)
    M.close()
  end
end

---Close the preview and restore the previous layout.
function M.close()
  local was_open = state.win ~= nil or state.buf ~= nil or state.layout ~= nil
  stop_timer()
  detach()
  sync.detach()

  local win = state.win
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end

  local saved = state.layout
  state.win = nil
  state.buf = nil
  state.src_buf = nil
  state.src_win = nil
  state.layout = nil
  state.keymaps = nil

  if saved then
    layout.restore(saved)
  end

  local cfg = config.get()
  if was_open and cfg.on_close then
    pcall(cfg.on_close)
  end
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

---Force a re-render (useful after a manual change).
function M.refresh()
  update()
end

return M
