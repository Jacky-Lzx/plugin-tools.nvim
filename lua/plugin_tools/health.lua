local M = {}

function M.check()
  vim.health.start("plugin-tools.nvim")
  if vim.fn.has("nvim-0.11") == 0 then
    vim.health.error("Neovim 0.11+ is required", { "Upgrade Neovim" })
    return
  end
  local issues = {}
  local function problem(level, message, advice)
    issues[#issues + 1] = { level = level, message = message, advice = advice }
  end
  local plugin = package.loaded.plugin_tools
  local ok, status = false, nil
  if plugin then
    ok, status = pcall(plugin.status)
  end
  -- A manager may not have been configured, including when used via new().
  if not ok then
    vim.health.info("No default manager configured; manager checks skipped.")
    return
  end
  if vim.fn.executable("git") == 0 then
    problem("warn", "Git is unavailable; package operations are disabled.", { "Install Git" })
  end
  for _, item in ipairs(status) do
    if item.state.phase == "missing" or item.state.phase == "failed" then
      problem(
        "error",
        item.id .. ": " .. item.state.phase .. "; " .. tostring(item.state.error or item.dir),
        { "Inspect :PluginTools and install missing packages or repair the reported configuration" }
      )
    end
  end

  table.sort(issues, function(a, b)
    if a.level ~= b.level then
      return a.level == "error"
    end
    return a.message < b.message
  end)
  for _, issue in ipairs(issues) do
    vim.health[issue.level](issue.message, issue.advice)
  end
  if #issues == 0 then
    vim.health.ok("Configured plugin packages and loading state are valid.")
  end
  vim.health.info("Details: :PluginTools")
end

return M
