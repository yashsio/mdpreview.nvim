-- `:checkhealth mdpreview` support.
local M = {}

local function yes(cond)
  return cond and "yes" or "no"
end

function M.check()
  local health = vim.health
  if not health then
    local ok, mod = pcall(require, "vim.health")
    health = ok and mod or nil
  end
  if not health then
    vim.notify("[markdown-preview] checkhealth is unavailable in this Neovim", vim.log.levels.WARN)
    return
  end
  if not health.start then
    -- Neovim < 0.10 used `report_*` names.
    health = {
      start = health.report_start,
      ok = health.report_ok,
      warn = health.report_warn,
      error = health.report_error,
      info = health.report_info,
    }
  end
  health.start("markdown-preview.nvim")

  local ok, md = pcall(require, "mdpreview")
  if not ok then
    health.error("could not load `mdpreview`: " .. tostring(md))
    return
  end
  health.ok("plugin loads")

  local version = vim.version()
  if version.major > 0 or version.minor >= 9 then
    health.ok(("Neovim %d.%d.%d"):format(version.major, version.minor, version.patch))
  else
    health.warn(
      ("Neovim %d.%d.%d is older than the supported 0.9"):format(
        version.major,
        version.minor,
        version.patch
      )
    )
  end

  local cfg = require("mdpreview.config").get()
  health.info(
    ("split=%s position=%s width=%s height=%s"):format(
      cfg.split,
      cfg.position,
      tostring(cfg.width),
      tostring(cfg.height)
    )
  )
  health.info(
    ("debounce=%dms syncscroll=%s sync_cursor=%s focus=%s"):format(
      cfg.debounce,
      tostring(cfg.syncscroll),
      tostring(cfg.sync_cursor),
      cfg.focus
    )
  )
  health.info(
    ("conceal=%s show_urls=%s spacing=%s wrap=%s ascii=%s syntax=%s"):format(
      tostring(cfg.conceal),
      tostring(cfg.show_urls),
      tostring(cfg.spacing),
      tostring(cfg.wrap),
      tostring(cfg.ascii),
      tostring(cfg.syntax)
    )
  )
  health.info(("preview open: %s"):format(yes(md.is_open())))
  if vim.fn.hlexists("MdPreviewH1") == 1 then
    health.ok("preview highlight groups are defined")
  else
    health.info("preview highlight groups are not defined yet (call setup() or open the preview)")
  end

  if not cfg.syntax then
    health.info("Treesitter code highlighting is disabled (`syntax = false`)")
  elseif not (vim.treesitter and vim.treesitter.get_string_parser) then
    health.warn("Treesitter is unavailable; code blocks fall back to a single colour")
  else
    local available = {}
    for _, lang in ipairs({ "lua", "python", "javascript", "rust", "bash", "c", "cpp" }) do
      if pcall(vim.treesitter.get_string_parser, "x = 1", lang) then
        available[#available + 1] = lang
      end
    end
    if #available == 0 then
      health.warn(
        "no sampled Treesitter parsers are installed; install parsers for the languages you preview"
      )
    else
      health.ok("Treesitter parsers available: " .. table.concat(available, ", "))
    end
  end
end

return M
