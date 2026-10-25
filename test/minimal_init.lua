-- Minimal init used by the test suite. Adds the plugin to the runtimepath so
-- `require("mdpreview...")` works without a plugin manager.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
