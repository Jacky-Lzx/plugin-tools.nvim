local Style = require("plugin_tools.ui.style")
local Text = require("plugin_tools.ui.text")
local M = {}
local home, milliseconds, error_text = Text.home, Text.milliseconds, Text.error_text

local function dependencies(map)
  local names = {}
  for id, optional in pairs(map) do
    names[#names + 1] = id .. (optional and " (optional)" or "")
  end
  table.sort(names)
  return #names > 0 and table.concat(names, ", ") or "None"
end

function M.render(b, view, item, progress)
  local info = view.manager:explain(item.id)
  local state = item.state
  if view.manager.timings.enabled then
    b:detail("Startup", milliseconds(state.startup_ms), "PluginToolsActive")
    if state.duration_ms then
      b:detail(
        "Initialization",
        milliseconds(state.self_ms) .. " self / " .. milliseconds(state.duration_ms) .. " inclusive"
      )
      b:detail("Activated", state.activation)
    end
    b:detail("Native scripts", milliseconds(state.scripts_ms))
    if state.deferred_ms then
      b:detail("On demand", milliseconds(state.deferred_ms))
    end
    for _, script in ipairs(state.scripts or {}) do
      b:detail("Script", home(script.file) .. "  ·  " .. milliseconds(script.self_ms))
    end
  end
  b:detail("Mount policy", info.mount)
  if state.mount_ms then
    b:detail("Mount", milliseconds(state.mount_ms))
  end
  if #info.ft > 0 then
    b:detail("Filetypes", table.concat(info.ft, ", "))
  end
  if state.reason or state.mount_reason then
    b:detail("Trigger", state.reason or state.mount_reason)
  end
  if state.trigger and #state.trigger.chain > 1 then
    b:detail("Trigger chain", table.concat(state.trigger.chain, " → "))
  end
  b:detail("Directory", home(info.dir), "PluginToolsPath")
  if info.package ~= info.id then
    b:detail("Package", info.package)
  end
  b:detail("Source", info.source or "Local checkout")
  if #info.parents > 0 then
    b:detail("Parents", table.concat(info.parents, ", "))
  end
  b:detail("Dependencies", dependencies(info.dependencies))
  b:detail("Referenced by", #info.referenced_by > 0 and table.concat(info.referenced_by, ", ") or "None")
  if #info.after > 0 then
    b:detail("Starts after", table.concat(info.after, ", "))
  end
  for index, declaration in ipairs(info.declarations or {}) do
    b:detail(
      index == 1 and "Declared in" or "",
      declaration.origin .. "  ·  " .. declaration.position .. (declaration.enabled and "" or "  [disabled]")
    )
  end
  if progress then
    b:detail("Operation", progress.phase, Style.phase(progress.phase))
    if progress.before_commit then
      b:detail("Before", progress.before_commit)
    end
    if progress.after_commit then
      b:detail("After", progress.after_commit)
    end
    local changes = progress.changes
    if changes then
      b:detail(
        "History",
        ("%s · %d ahead / %d behind"):format(changes.kind, changes.ahead, changes.behind),
        (changes.kind == "rewind" or changes.kind == "diverged") and "PluginToolsWarning" or "PluginToolsName"
      )
      b:detail(
        "Changes",
        ("%d files · +%d / -%d · %d binary"):format(
          changes.files_changed,
          changes.insertions,
          changes.deletions,
          changes.binary_files
        )
      )
      for _, commit in ipairs(changes.commits) do
        b:detail("Commit", commit.commit:sub(1, 12) .. " " .. commit.subject)
      end
      if changes.commits_truncated then
        b:detail("", "More commits omitted (showing 20)")
      end
      for _, file in ipairs(changes.files) do
        b:detail("File", file.path .. (file.binary and " (binary)" or (" +%d / -%d"):format(file.added, file.removed)))
      end
      if changes.files_truncated then
        b:detail("", "More files omitted (showing 50)")
      end
    end
  end
  local error_message = item.state.error or (progress and progress.error and progress.error.message)
  if error_message then
    error_message = error_text(error_message)
    local first = error_message:match("[^\n]+") or error_message
    local location, message = first:match("^(.-:%d+):%s*(.*)$")
    b:detail("Error", message or first, "PluginToolsError")
    if location then
      b:detail("Location", home(location), "PluginToolsMuted")
    end
  end
  b:line({
    { "    o ", "PluginToolsKey" },
    { view.full[item.id] and "Hide full configuration" or "Full configuration & merge history", "PluginToolsMuted" },
  })
  if view.full[item.id] then
    for _, line in ipairs(vim.split(vim.inspect(info), "\n", { plain = true })) do
      b:wrap(line, "    ", "PluginToolsName")
    end
  end
  b:line()
end

return M
