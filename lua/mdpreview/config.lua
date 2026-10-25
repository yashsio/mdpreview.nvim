-- Configuration defaults and merging for mdpreview.nvim.
local M = {}

---@class MdPreviewOpts
---@field split "vertical"|"horizontal"       Split direction of the preview.
---@field position "left"|"right"|"above"|"below" Where to place the preview.
---@field width number                       Fraction of columns (vertical) or columns when > 1.
---@field height number                      Fraction of rows (horizontal) or rows when > 1.
---@field debounce number                    Milliseconds to wait before re-rendering.
---@field syncscroll boolean                 Keep source/preview scroll in sync.
---@field sync_cursor boolean                Move preview cursor with source cursor.
---@field conceal boolean                    Strip inline markdown markers.
---@field show_urls boolean                  Append link/image URLs in the preview.
---@field spacing boolean                    Insert blank lines around block elements.
---@field wrap boolean                       Soft-wrap lines in the preview window.
---@field winbar boolean                     Show a bar with the file name on the preview.
---@field focus "source"|"preview"           Which window gets focus after opening.
---@field syntax boolean                     Highlight fenced code blocks with Treesitter.
---@field ascii boolean                      Use ASCII instead of box-drawing characters.
---@field highlights table<string, table>    Highlight group overrides.
---@field keymaps table<string, string>      Buffer-local preview keymaps.

M.defaults = {
  split = "vertical",
  position = "right",
  width = 0.5,
  height = 0.5,
  debounce = 120,
  syncscroll = true,
  sync_cursor = false,
  conceal = true,
  show_urls = true,
  spacing = true,
  wrap = true,
  winbar = true,
  focus = "source",
  syntax = true,
  ascii = false,
  highlights = {},
  keymaps = {
    q = "<cmd>MarkdownPreviewClose<cr>",
  },
}

M.options = vim.deepcopy(M.defaults)

---Coerce invalid or contradictory options into something usable.
---@param cfg MdPreviewOpts
---@return MdPreviewOpts
local function normalise(cfg)
  if cfg.split ~= "horizontal" then
    cfg.split = "vertical"
  end
  local positions = cfg.split == "horizontal" and { above = true, below = true }
    or { left = true, right = true }
  if not positions[cfg.position] then
    cfg.position = cfg.split == "horizontal" and "below" or "right"
  end
  if cfg.focus ~= "preview" then
    cfg.focus = "source"
  end
  if type(cfg.keymaps) ~= "table" then
    cfg.keymaps = {}
  end
  if type(cfg.highlights) ~= "table" then
    cfg.highlights = {}
  end
  return cfg
end

---Merge user options into the active configuration.
---@param opts MdPreviewOpts|nil
---@return MdPreviewOpts
function M.setup(opts)
  opts = opts or {}
  local cfg = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- `keymaps` is a map, not a settings tree: a user-supplied table must replace
  -- the defaults so that `keymaps = {}` can disable the built-in `q` mapping.
  if opts.keymaps ~= nil then
    cfg.keymaps = vim.deepcopy(opts.keymaps)
  end
  M.options = normalise(cfg)
  M._initialised = true
  return M.options
end

---Return the active configuration, initialising it on first use.
---@return MdPreviewOpts
function M.get()
  if not M._initialised then
    M.setup({})
  end
  return M.options
end

return M
