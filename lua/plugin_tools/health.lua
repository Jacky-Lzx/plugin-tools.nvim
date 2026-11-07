local M = {}

function M.check()
  vim.health.start("plugin-tools.nvim")
  if vim.fn.has("nvim-0.11") == 0 then
    vim.health.error("Neovim 0.11+ is required", { "Upgrade Neovim" })
    return
  end
  local plugin = package.loaded.plugin_tools
  local ok, issues = false, nil
  if plugin then
    ok = pcall(plugin.status)
  end
  if not ok then
    vim.health.info("No default manager configured; manager checks skipped.")
    return
  end
  ok, issues = pcall(plugin.diagnostics)
  if not ok then
    vim.health.error(
      "Package diagnostics failed: " .. tostring(issues),
      { "Inspect :PluginTools and the reported path" }
    )
    return
  end
  for _, issue in ipairs(issues) do
    vim.health[issue.level](issue.message, issue.advice)
  end
  if #issues == 0 then
    vim.health.ok("Configured plugin packages and loading state are valid.")
  end
  vim.health.info("Details: :PluginTools")
end

return M
