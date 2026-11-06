local M = {}
local links = {
  Normal = "NormalFloat",
  Border = "FloatBorder",
  Title = "Title",
  Tab = "Comment",
  TabActive = "Special",
  Header = "Comment",
  Muted = "Comment",
  Path = "Directory",
  Key = "Special",
  Selected = "DiagnosticOk",
  SelectedLine = "Visual",
  CursorLine = "CursorLine",
  Ready = "DiagnosticOk",
  Pending = "Comment",
  Active = "DiagnosticInfo",
  Timing = "Number",
  Warning = "DiagnosticWarn",
  Error = "DiagnosticError",
}

function M.setup()
  local function apply()
    for name, target in pairs(links) do
      vim.api.nvim_set_hl(0, "PluginTools" .. name, { default = true, link = target })
    end
    local normal = vim.api.nvim_get_hl(0, { name = "PluginToolsNormal", link = false })
    if not normal.fg then
      normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    end
    vim.api.nvim_set_hl(0, "PluginToolsName", { default = true, fg = normal.fg })
  end
  apply()
  if not M.group then
    M.group = vim.api.nvim_create_augroup("PluginToolsHighlights", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", { group = M.group, callback = apply })
  end
end

function M.phase(phase)
  if vim.list_contains({ "failed", "error" }, phase) then
    return "PluginToolsError"
  elseif vim.list_contains({ "missing", "recovery_required", "recovery", "rolled_back", "rolling_back" }, phase) then
    return "PluginToolsWarning"
  elseif
    vim.list_contains({
      "ready",
      "done",
      "installed",
      "updated",
      "restored",
      "frozen",
      "planned",
      "unchanged",
      "kept",
      "recovered",
      "removed",
      "previewed",
    }, phase)
  then
    return "PluginToolsReady"
  elseif phase == "registered" or phase == "queued" then
    return "PluginToolsPending"
  end
  return "PluginToolsActive"
end

return M
