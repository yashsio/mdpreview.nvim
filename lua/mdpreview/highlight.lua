-- Default highlight groups for the rendered preview.
--
-- Groups whose appearance benefits from colour are linked to core built-in
-- groups so they adapt to the active colorscheme. Purely structural groups
-- (emphasis, headings) use attributes only, which keeps them readable on any
-- colorscheme. Every group is created with `default = true`, so a colorscheme
-- or user override always wins. Users can override them per call via
-- `require("mdpreview").setup({ highlights = { ... } })`.
local M = {}

M.defaults = {
  -- Headings: differentiated by attributes, colourscheme agnostic.
  MdPreviewH1 = { bold = true, underline = true },
  MdPreviewH2 = { bold = true },
  MdPreviewH3 = { bold = true, italic = true },
  MdPreviewH4 = { italic = true },
  MdPreviewH5 = { italic = true },
  MdPreviewH6 = { italic = true },

  -- Inline spans.
  MdPreviewBold = { bold = true },
  MdPreviewItalic = { italic = true },
  MdPreviewBoldItalic = { bold = true, italic = true },
  MdPreviewStrike = { strikethrough = true },
  MdPreviewCode = { link = "String" },
  MdPreviewLink = { link = "Underlined" },
  MdPreviewLinkUrl = { link = "Comment" },
  MdPreviewImage = { link = "Special" },

  -- Block elements.
  MdPreviewCodeBlock = { link = "String" },
  MdPreviewQuote = { link = "Comment" },
  MdPreviewBullet = { link = "Special" },
  MdPreviewTaskTodo = { link = "Comment" },
  MdPreviewTaskDone = { bold = true, link = "String" },
  MdPreviewHr = { link = "Comment" },
  MdPreviewTableHeader = { bold = true },
  MdPreviewTableBorder = { link = "Comment" },
  MdPreviewWinbar = { link = "Title" },
}

M.overrides = {}
M._watching = false

---Apply the default groups then any user overrides.
---@param overrides table<string, table>|nil
function M.setup(overrides)
  if overrides ~= nil then
    M.overrides = overrides
  end
  M.apply(M.overrides)
  if not M._watching then
    M._watching = true
    local group = vim.api.nvim_create_augroup("MdPreviewHighlights", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = group,
      callback = function()
        M.apply(M.overrides)
      end,
    })
  end
end

---@param overrides table<string, table>|nil
function M.apply(overrides)
  for name, spec in pairs(M.defaults) do
    local spec_copy = vim.deepcopy(spec)
    spec_copy.default = true
    vim.api.nvim_set_hl(0, name, spec_copy)
  end
  for name, spec in pairs(overrides or {}) do
    vim.api.nvim_set_hl(0, name, spec)
  end
end

return M
