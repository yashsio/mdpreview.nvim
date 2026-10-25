-- Window-layout snapshot and restore.
--
-- Before the preview split is created we record the size and scroll position
-- of every open window. When the preview closes we restore them so the user's
-- layout is exactly as it was.
local M = {}

---@return table snapshot
function M.save()
  local snapshot = {
    current = vim.api.nvim_get_current_win(),
    wins = {},
  }
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok, view = pcall(vim.api.nvim_win_call, win, vim.fn.winsaveview)
    snapshot.wins[win] = {
      width = vim.api.nvim_win_get_width(win),
      height = vim.api.nvim_win_get_height(win),
      view = ok and view or nil,
    }
  end
  return snapshot
end

---@param snapshot table
function M.restore(snapshot)
  if not snapshot then
    return
  end

  -- `nvim_win_set_width/height` are explicit resizes: they stick even when
  -- 'equalalways' is on, whereas toggling 'equalalways' back on would
  -- immediately re-equalise and clobber the sizes we just restored.
  for win, info in pairs(snapshot.wins) do
    if vim.api.nvim_win_is_valid(win) then
      if info.width and info.width > 0 then
        pcall(vim.api.nvim_win_set_width, win, info.width)
      end
      if info.height and info.height > 0 then
        pcall(vim.api.nvim_win_set_height, win, info.height)
      end
      if info.view then
        pcall(vim.api.nvim_win_call, win, function()
          vim.fn.winrestview(info.view)
        end)
      end
    end
  end

  if snapshot.current and vim.api.nvim_win_is_valid(snapshot.current) then
    vim.api.nvim_set_current_win(snapshot.current)
  end
end

---Convert a width/height option (fraction in (0,1) or absolute cells) to cells.
---@param value number
---@param total integer
---@return integer
function M.resolve_size(value, total)
  if value > 1 then
    return math.floor(value)
  end
  return math.max(1, math.floor(total * value) - 1)
end

return M
