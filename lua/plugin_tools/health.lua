local M = {}

function M.check()
  vim.health.start("plugin-tools.nvim")
  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim 0.11+")
  else
    vim.health.error("Neovim 0.11+ is required")
  end
  if vim.fn.executable("git") == 1 then
    vim.health.ok("Git is available (only needed for package operations)")
  else
    vim.health.warn("Git not found")
  end
  local ok, status = pcall(require("plugin_tools").status)
  if not ok then
    vim.health.info("No default manager configured")
    return
  end
  for _, item in ipairs(status) do
    if item.state.phase == "missing" or item.state.phase == "failed" then
      vim.health.error(item.id .. ": " .. item.state.phase .. ": " .. tostring(item.state.error or item.dir))
    end
  end
  vim.health.ok("Inspected manager state without loading managed plugin modules")
end

return M
