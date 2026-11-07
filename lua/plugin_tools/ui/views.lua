local Style = require("plugin_tools.ui.style")
local Text = require("plugin_tools.ui.text")
local M = {}
local pad, milliseconds, error_text = Text.pad, Text.milliseconds, Text.error_text

function M.log(b, task)
  if not task or #task.events == 0 then
    b:line({ { "No operation recorded yet.", "PluginToolsMuted" } })
    return
  end
  for _, event in ipairs(task.events) do
    b:line({
      { ("%8.1f ms  "):format(event.elapsed_ms), "PluginToolsMuted" },
      { event.phase, Style.phase(event.phase) },
      { event.id and ("  " .. event.id) or "", "PluginToolsName" },
    })
    if event.command then
      b:wrap("$ " .. table.concat(event.command, " "), "    ", "PluginToolsMuted")
    end
    for _, field in ipairs({ "stdout", "stderr" }) do
      for _, line in ipairs(vim.split(event[field] or "", "\n", { plain = true, trimempty = true })) do
        b:wrap(line, "    ", field == "stderr" and event.exit_code ~= 0 and "PluginToolsError" or "PluginToolsName")
      end
    end
    if event.error then
      for _, line in ipairs(vim.split(error_text(event.error.message), "\n", { plain = true })) do
        b:wrap(line, "    ", "PluginToolsError")
      end
    end
  end
end

function M.help(b)
  local sections = {
    {
      "Navigate",
      {
        { "j / k", "Move between plugins" },
        { "/", "Filter names and directories" },
        { "Space", "Select or deselect a plugin" },
        { "Enter", "Show compact details" },
        { "o", "Show complete configuration and merge history" },
      },
    },
    {
      "Manage selection",
      {
        { "p", "Preview update commits and builds" },
        { "a", "Apply the reviewed plan" },
        { "I", "Show or hide inactive declarations" },
        { "x", "Cancel the active operation before publication" },
        { "u / i", "Update / install" },
        { "s / f", "Restore locked revisions / freeze current revisions" },
      },
    },
    {
      "Inspect & maintain",
      {
        { "P", "Switch plugins / startup profile" },
        { "t", "Sort profile by startup time / name" },
        { "l", "Switch plugins / operation log" },
        { "r", "Refresh status" },
        { "R", "Preview crash recovery" },
        { "c / C", "Preview / apply cleanup of all unused packages" },
        { "?", "Return to the previous view" },
        { "q / Esc", "Close the panel" },
      },
    },
  }
  for _, section in ipairs(sections) do
    b:line({ { section[1], "PluginToolsTitle" } })
    for _, entry in ipairs(section[2]) do
      b:detail(entry[1], entry[2])
    end
    b:line()
  end
end

function M.startup(b, view, t)
  if not t.enabled then
    b:wrap(
      t.enabled == false and "Profiling is disabled. Enable profile = true and restart Neovim to collect timings."
        or "Startup has not been measured. Start the manager to collect timings.",
      "",
      "PluginToolsMuted"
    )
    return
  end
  local stages = {
    { "Resolve declarations", t.resolve_ms },
    { "Mount runtimepath", t.mount_ms },
    { "Plugin initialization", t.config_ms },
    { "Native sourced scripts", t.native_ms },
    { "Other startup work", t.other_ms },
  }
  b:line({ { "Startup stages", "PluginToolsTitle" } })
  local bars = math.max(0, math.min(24, b.inner - 42))
  for _, stage in ipairs(stages) do
    local fraction = t.total_ms and t.total_ms > 0 and (stage[2] or 0) / t.total_ms or 0
    local filled = math.min(bars, math.floor(fraction * bars + 0.5))
    b:line({
      { pad(stage[1], math.min(24, math.max(1, b.inner - 14))), "PluginToolsMuted" },
      { "  " .. pad(milliseconds(stage[2]), 11), "PluginToolsTiming" },
      { "  " .. string.rep("━", filled), "PluginToolsActive" },
      { string.rep("─", bars - filled), "PluginToolsBorder" },
    })
  end
  b:wrap(
    t.scope == "startup" and "Scope: declaration resolution → VimEnter; earlier init is excluded."
      or "Scope: manager start only; Neovim had already entered.",
    "",
    "PluginToolsMuted"
  )
  b:wrap("Self times exclude nested plugin calls. LATER records activation after startup.", "", "PluginToolsMuted")
  if (t.incomplete_sources or 0) > 0 then
    b:wrap("Interrupted source samples were omitted: " .. t.incomplete_sources, "", "PluginToolsWarning")
  end
  b:line()
  b:line({
    { "Plugin timings", "PluginToolsTitle" },
    { "  ·  ", "PluginToolsMuted" },
    { "t ", "PluginToolsKey" },
    { view.sort == "name" and "sorted by name" or "slowest startup first", "PluginToolsMuted" },
  })
end

return M
