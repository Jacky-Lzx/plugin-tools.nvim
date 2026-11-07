local Style = require("plugin_tools.ui.style")
local Text = require("plugin_tools.ui.text")
local M = {}
local Plugins = require("plugin_tools.ui.plugins")
local Views = require("plugin_tools.ui.views")
local width = vim.fn.strdisplaywidth
local milliseconds, error_text = Text.milliseconds, Text.error_text
M.fit = Text.fit

function M.render(view, window_width)
  local b = Text.new(window_width)
  local report = view.manager:profile()
  local items, task = report.plugins, view.manager.last_operation
  if view.include_inactive and view.mode ~= "profile" then
    items = view.manager:status({ include_inactive = true })
  end
  b:line()
  b:line({
    { "Plugins", view.mode == "status" and "PluginToolsTabActive" or "PluginToolsTab" },
    { "   /   ", "PluginToolsMuted" },
    { "Startup", view.mode == "profile" and "PluginToolsTabActive" or "PluginToolsTab" },
    { "   /   ", "PluginToolsMuted" },
    { "Operation log", view.mode == "log" and "PluginToolsTabActive" or "PluginToolsTab" },
    { view.mode == "help" and "   /   Help" or "", "PluginToolsTabActive" },
  })
  local counts, summary = {}, { { #items .. (#items == 1 and " plugin" or " plugins"), "PluginToolsTitle" } }
  for _, item in ipairs(items) do
    counts[item.state.phase] = (counts[item.state.phase] or 0) + 1
  end
  for _, phase in ipairs({ "failed", "missing", "ready", "mounted", "registered", "disabled", "unselected" }) do
    if counts[phase] then
      summary[#summary + 1] = { "  ·  ", "PluginToolsMuted" }
      summary[#summary + 1] = { counts[phase] .. " " .. phase, Style.phase(phase) }
    end
  end
  b:line(summary)
  local timings = report.timings
  if timings.enabled then
    b:wrap(
      (timings.scope == "startup" and "Managed startup " or "Manager startup ")
        .. milliseconds(timings.total_ms)
        .. (timings.complete and "" or "  ·  collecting until VimEnter")
        .. (timings.boundary == "failed" and "  ·  failed" or ""),
      "",
      "PluginToolsTiming"
    )
  end
  local selected = vim.tbl_count(view.selected) .. " selected"
  local filter = M.fit(
    "Filter: " .. (view.filter ~= "" and view.filter or "all plugins"),
    math.max(1, b.inner - width(selected) - 2)
  )
  b:line({
    { filter, "PluginToolsMuted" },
    { string.rep(" ", math.max(2, b.inner - width(filter) - width(selected))) },
    { selected, next(view.selected) and "PluginToolsSelected" or "PluginToolsMuted" },
  })
  if view.mode ~= "help" then
    if b.inner >= 76 then
      b:line({
        { "p ", "PluginToolsKey" },
        { "Plan    ", "PluginToolsMuted" },
        { "u ", "PluginToolsKey" },
        { "Update    ", "PluginToolsMuted" },
        { "/ ", "PluginToolsKey" },
        { "Filter    ", "PluginToolsMuted" },
        { "Space ", "PluginToolsKey" },
        { "Select    ", "PluginToolsMuted" },
        { "Enter ", "PluginToolsKey" },
        { "Details    ", "PluginToolsMuted" },
        { "? ", "PluginToolsKey" },
        { "Help", "PluginToolsMuted" },
      })
    else
      b:line({
        { "/ ", "PluginToolsKey" },
        { "Filter   ", "PluginToolsMuted" },
        { "Space ", "PluginToolsKey" },
        { "Select   ", "PluginToolsMuted" },
        { "? ", "PluginToolsKey" },
        { "Help", "PluginToolsMuted" },
      })
    end
  end
  if task then
    b:line()
    local elapsed = (task.finished_at or vim.uv.hrtime()) - task.started_at
    b:line({
      { task.action:upper() .. "  ", "PluginToolsTitle" },
      { task.phase, Style.phase(task.phase) },
      { ("  ·  %d/%d packages  ·  %.1fs"):format(task.completed, task.total, elapsed / 1e9), "PluginToolsMuted" },
    })
    if task.cancelled then
      b:wrap("Operation cancelled; staged work rolled back.", "", "PluginToolsWarning")
    elseif task.error then
      b:wrap(
        "Error: " .. error_text(task.failure and task.failure.message or task.error):match("[^\n]+"),
        "",
        "PluginToolsError"
      )
    elseif task.result and task.result.restart_required then
      b:wrap("Restart Neovim to use changed plugin files.", "", "PluginToolsWarning")
    end
    if task.recovery_required or task.result and task.result.recovery_required then
      b:wrap("Cleanup needs recovery: :PluginTools recover", "", "PluginToolsWarning")
    end
    if task.action == "recover" and task.result then
      if #task.result.steps == 0 then
        b:wrap("No package recovery steps pending.", "", "PluginToolsMuted")
      end
      for _, step in ipairs(task.result.steps) do
        b:wrap("Recovery " .. step.action .. ": " .. step.dir, "", "PluginToolsWarning")
      end
    elseif task.action == "clean" and task.result then
      b:wrap(
        "Cleanup " .. (task.result.dry_run and "preview: " or "removed: ") .. table.concat(task.result.packages, ", "),
        "",
        "PluginToolsMuted"
      )
    end
  end
  if view.manager.last_plan then
    b:wrap("Reviewed plan available  ·  a Apply exact commits", "", "PluginToolsActive")
  end
  b:line({ { string.rep("─", math.max(1, math.floor(b.inner / width("─")))), "PluginToolsBorder" } })
  b.content_start = #b.lines + 1
  if view.mode == "help" then
    Views.help(b)
  elseif view.mode == "log" then
    Views.log(b, task)
  else
    if view.mode == "profile" then
      Views.startup(b, view, timings)
    end
    Plugins.render(b, view, items, task)
  end
  b:line()
  return b
end

return M
