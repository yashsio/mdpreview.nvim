-- Command entry points. Loaded automatically by Neovim's plugin loader.
if vim.g.loaded_mdpreview == 1 then
  return
end
vim.g.loaded_mdpreview = 1

local function mdpreview()
  return require("mdpreview")
end

vim.api.nvim_create_user_command("MarkdownPreview", function()
  mdpreview().open()
end, { desc = "Open the Markdown preview in a side-by-side split" })

vim.api.nvim_create_user_command("MarkdownPreviewClose", function()
  mdpreview().close()
end, { desc = "Close the Markdown preview and restore the layout" })

vim.api.nvim_create_user_command("MarkdownPreviewToggle", function()
  mdpreview().toggle()
end, { desc = "Toggle the Markdown preview" })
