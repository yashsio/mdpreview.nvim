-- Integration tests for mdpreview.nvim: real windows, splits, scrolling.
--
-- Run with:
--     nvim --headless --clean -u test/minimal_init.lua -l test/integration_spec.lua
--
-- Headless Neovim still maintains a full window/buffer tree, so these tests
-- verify open/close behaviour, guard options, layout restoration and scroll
-- synchronisation without needing a terminal UI. All fixtures are generated in
-- a temporary directory so the suite is self-contained.

local md = require("mdpreview")
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

local function win_count()
  return #vim.api.nvim_list_wins()
end

----------------------------------------------------------------------
-- Fixtures
----------------------------------------------------------------------

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local sample = tmp .. "/sample.md"
vim.fn.writefile({
  "# Hello",
  "",
  "Some **bold** text and a [link](https://example.com).",
  "",
  "- one",
  "- two",
  "",
  "```lua",
  'print("hi")',
  "```",
  "",
  "| a | b |",
  "| - | - |",
  "| 1 | 2 |",
}, sample)

local long = tmp .. "/long.md"
local long_lines = {}
for i = 1, 40 do
  long_lines[#long_lines + 1] = ("Paragraph line %d with some **bold** text."):format(i)
  if i % 5 == 0 then
    long_lines[#long_lines + 1] = ""
    long_lines[#long_lines + 1] = ("## Section at %d"):format(i)
    long_lines[#long_lines + 1] = ""
  end
end
vim.fn.writefile(long_lines, long)

md.setup({ debounce = 5, syncscroll = true, sync_cursor = false })

----------------------------------------------------------------------
-- Open / close
----------------------------------------------------------------------

do
  vim.cmd("edit " .. vim.fn.fnameescape(sample))
  local before = win_count()
  md.open()
  check(md.is_open(), "open() opens the preview")
  check(win_count() == before + 1, "open() adds exactly one window")

  local st = md._state
  check(vim.bo[st.buf].buftype == "nofile", "preview buffer is buftype=nofile")
  check(vim.bo[st.buf].bufhidden == "wipe", "preview buffer is bufhidden=wipe")
  check(vim.bo[st.buf].modifiable == false, "preview buffer is not modifiable")
  check(vim.bo[st.buf].swapfile == false, "preview buffer has no swapfile")
  check(vim.bo[st.buf].filetype == "mdpreview", "preview buffer has the mdpreview filetype")

  local lines = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
  check(lines[1] == "Hello", "preview rendered the heading text")

  md.close()
  check(not md.is_open(), "close() closes the preview")
  check(win_count() == before, "close() restores the window count")
end

----------------------------------------------------------------------
-- Unsaved Markdown buffer
----------------------------------------------------------------------

do
  vim.cmd("enew")
  vim.bo.filetype = "markdown"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "# Unsaved", "", "content" })
  md.open()
  check(md.is_open(), "preview opens for an unsaved Markdown buffer")
  local lines = vim.api.nvim_buf_get_lines(md._state.buf, 0, -1, false)
  check(lines[1] == "Unsaved", "unsaved buffer content is rendered")
  md.close()
end

----------------------------------------------------------------------
-- Non-Markdown buffer
----------------------------------------------------------------------

do
  vim.cmd("enew")
  vim.bo.filetype = "lua"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "print(1)" })
  local before = win_count()
  md.open()
  check(not md.is_open(), "non-Markdown buffer does not open a preview")
  check(win_count() == before, "no window created for a non-Markdown buffer")
end

----------------------------------------------------------------------
-- Focus behaviour
----------------------------------------------------------------------

do
  md.setup({ debounce = 5, focus = "source", keymaps = { q = "<cmd>MarkdownPreviewClose<cr>" } })
  vim.cmd("edit " .. vim.fn.fnameescape(sample))
  md.open()
  check(
    vim.api.nvim_get_current_win() == md._state.src_win,
    "focus = source keeps the cursor in the Markdown buffer"
  )
  md.close()

  md.setup({ debounce = 5, focus = "preview" })
  md.open()
  check(
    vim.api.nvim_get_current_win() == md._state.win,
    "focus = preview focuses the preview window"
  )
  md.close()
  md.setup({ debounce = 5, focus = "source" })
end

----------------------------------------------------------------------
-- Nested splits
----------------------------------------------------------------------

do
  md.setup({ debounce = 5, width = 0.5 })
  vim.cmd("edit " .. vim.fn.fnameescape(sample))
  vim.cmd("vsplit")
  vim.cmd("vsplit")
  local src = vim.api.nvim_get_current_win()
  local base = vim.api.nvim_win_get_width(src)
  local before = win_count()

  md.open()
  local preview_width = vim.api.nvim_win_get_width(md._state.win)
  local source_width = vim.api.nvim_win_get_width(src)
  check(
    preview_width <= math.ceil(base / 2),
    "preview takes half of the source window, not the editor"
  )
  check(source_width < base, "nested source window is actually split")
  md.close()
  check(win_count() == before, "closing a nested preview restores the window count")
  vim.cmd("only")
end

----------------------------------------------------------------------
-- syncscroll = false
----------------------------------------------------------------------

do
  md.setup({ debounce = 5, syncscroll = false })
  vim.cmd("edit " .. vim.fn.fnameescape(long))
  md.open()
  local st = md._state
  local anchors = sync._peek().anchors

  local src_line
  for l = 25, 40 do
    if anchors[l] then
      src_line = l
      break
    end
  end
  check(src_line ~= nil, "anchor exists for sync-disabled check")
  if src_line then
    vim.api.nvim_win_call(st.src_win, function()
      local view = vim.fn.winsaveview()
      view.topline = src_line
      view.lnum = src_line
      vim.fn.winrestview(view)
    end)
    sync.on_scrolled(st.src_win)
    check(
      vim.fn.line("w0", st.win) ~= anchors[src_line],
      "syncscroll = false disables scroll synchronisation"
    )
  end
  md.close()
  md.setup({ debounce = 5, syncscroll = true })
end

----------------------------------------------------------------------
-- Reconfiguration while open
----------------------------------------------------------------------

do
  md.setup({
    debounce = 5,
    width = 0.5,
    keymaps = { q = "<cmd>echo 'custom'<cr>" },
  })
  vim.cmd("edit " .. vim.fn.fnameescape(sample))
  md.open()
  local st = md._state
  local wide = vim.api.nvim_win_get_width(st.win)
  local function preview_map()
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(st.buf, "n")) do
      if m.lhs == "q" then
        return m
      end
    end
    return nil
  end
  local mapping = preview_map()
  check(mapping ~= nil and mapping.rhs:find("custom", 1, true) ~= nil, "custom keymap is installed")

  md.setup({ width = 0.25, keymaps = {} })
  local narrow = vim.api.nvim_win_get_width(st.win)
  check(narrow < wide, "setup() while open resizes the preview")
  check(preview_map() == nil, "setup() while open removes deleted keymaps")
  md.close()
  md.setup({
    debounce = 5,
    width = 0.5,
    keymaps = { q = "<cmd>MarkdownPreviewClose<cr>" },
  })
end

----------------------------------------------------------------------
-- Debounce timer reuse
----------------------------------------------------------------------

do
  md.setup({ debounce = 20 })
  vim.cmd("edit " .. vim.fn.fnameescape(sample))
  md.open()
  local st = md._state

  vim.api.nvim_exec_autocmds("TextChanged", { buffer = st.src_buf })
  vim.wait(80)
  local timer = st.timer
  check(timer ~= nil, "a debounce timer is created")
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = st.src_buf })
  check(st.timer == timer, "the debounce timer handle is reused")
  md.close()
  check(st.timer == nil, "closing the preview destroys the timer")
end

----------------------------------------------------------------------
-- Retargeting and preview extmarks
----------------------------------------------------------------------

do
  md.setup({ debounce = 5 })
  vim.cmd("edit " .. vim.fn.fnameescape(sample))
  md.open()
  local st = md._state

  local marks = vim.api.nvim_buf_get_extmarks(st.buf, -1, 0, -1, {})
  local in_bounds = true
  for _, mark in ipairs(marks) do
    local row, col = mark[2], mark[3]
    local line = vim.api.nvim_buf_get_lines(st.buf, row, row + 1, false)[1] or ""
    if col > #line then
      in_bounds = false
    end
  end
  check(in_bounds, "every extmark column is inside its preview line")

  vim.api.nvim_set_current_win(st.src_win)
  vim.cmd("edit " .. vim.fn.fnameescape(long))
  vim.wait(200, function()
    return md._state.src_buf == vim.fn.bufnr(long)
  end)
  check(md.is_open(), "preview stays open when the source window changes file")
  check(md._state.src_buf == vim.fn.bufnr(long), "preview retargets to the new source buffer")

  vim.cmd("enew")
  vim.bo.filetype = "lua"
  vim.wait(200, function()
    return not md.is_open()
  end)
  check(not md.is_open(), "switching to a non-Markdown buffer closes the preview")
  md.close()
end

----------------------------------------------------------------------
-- Multiple Markdown buffers
----------------------------------------------------------------------

do
  local base = win_count()
  vim.cmd("edit " .. vim.fn.fnameescape(sample))
  md.open()
  local first = md._state.src_buf

  -- Go back to the source window and open a different Markdown file there.
  vim.api.nvim_set_current_win(md._state.src_win)
  vim.cmd("edit " .. vim.fn.fnameescape(long))
  md.open()
  check(md.is_open(), "second Markdown buffer opens a preview")
  check(md._state.src_buf ~= first, "preview retargets to the new buffer")
  check(win_count() == base + 1, "only one preview window is kept at a time")
  md.close()
end

----------------------------------------------------------------------
-- Scroll synchronisation
----------------------------------------------------------------------

do
  vim.cmd("edit " .. vim.fn.fnameescape(long))
  md.open()
  local st = md._state
  local anchors = sync._peek().anchors

  local function set_topline(win, top)
    vim.api.nvim_win_call(win, function()
      local v = vim.fn.winsaveview()
      v.topline = top
      v.lnum = top
      vim.fn.winrestview(v)
    end)
  end

  local src1
  for l = 25, 40 do
    if anchors[l] then
      src1 = l
      break
    end
  end
  check(src1 ~= nil, "anchor exists for a lower source line")
  if src1 then
    set_topline(st.src_win, src1)
    sync.on_scrolled(st.src_win)
    check(vim.fn.line("w0", st.win) == anchors[src1], "scrolling source moves preview topline")
  end

  local src2
  for l = 5, 20 do
    if anchors[l] then
      src2 = l
      break
    end
  end
  if src2 then
    set_topline(st.win, anchors[src2])
    sync.on_scrolled(st.win)
    check(vim.fn.line("w0", st.src_win) == src2, "scrolling preview moves source topline")
  end

  md.close()
end

----------------------------------------------------------------------
-- Layout preservation
----------------------------------------------------------------------

do
  vim.cmd("edit " .. vim.fn.fnameescape(sample))
  vim.cmd("vsplit")
  local wins = vim.api.nvim_list_wins()
  local anchor = wins[1]
  vim.api.nvim_win_set_width(anchor, 30)
  local width = vim.api.nvim_win_get_width(anchor)
  local count = win_count()

  md.open()
  md.close()
  check(win_count() == count, "layout: window count preserved")
  check(vim.api.nvim_win_get_width(anchor) == width, "layout: window width preserved")
end

----------------------------------------------------------------------

vim.fn.delete(tmp, "rf")

io.write(("\n%d/%d checks passed\n"):format(total - failed, total))
os.exit(failed == 0 and 0 or 1)
