local Style = require("plugin_tools.ui.style")
local Text = require("plugin_tools.ui.text")
local M = {}
local Tree = require("plugin_tools.ui.tree")
local Details = require("plugin_tools.ui.details")
local width = vim.fn.strdisplaywidth
local pad, path_label, milliseconds = Text.pad, Text.path_label, Text.milliseconds

local function columns(inner, maximum, with_operation)
  if inner >= 106 then
    local name = math.min(34, math.max(26, maximum + 4))
    return {
      name = name,
      state = 11,
      source = 8,
      operation = with_operation and 13 or nil,
      path = inner - name - (with_operation and 40 or 25),
    }
  elseif inner >= 76 then
    local name = math.min(30, math.max(24, maximum + 4))
    return { name = name, state = 11, source = 8, path = inner - name - 25 }
  elseif inner >= 52 then
    return { name = inner - 23, state = 11, source = 8 }
  end
  local state = math.min(10, math.floor(inner * 0.35))
  return { name = math.max(1, inner - state - 2), state = state }
end

function M.render(b, view, items, task)
  local profiling = view.mode == "profile"
  local rows = Tree.layout(items, view.filter, profiling)
  local maximum = 0
  for _, row in ipairs(rows) do
    maximum = math.max(maximum, width(row.item.id) + width(row.branch))
  end
  if profiling then
    table.sort(rows, function(a, other)
      local left, right = a.item.state.startup_ms or -1, other.item.state.startup_ms or -1
      if view.sort ~= "name" and left ~= right then
        return left > right
      end
      return a.item.id < other.item.id
    end)
  end
  local c
  if profiling then
    c = { startup = 10 }
    local available = b.inner - 12
    if b.inner >= 76 then
      c.init, c.scripts = 10, 10
      available = available - 24
    end
    if b.inner >= 52 then
      c.later = 10
      available = available - 12
    end
    c.name = math.max(1, available)
  else
    local timed = view.manager.timings.enabled and b.inner >= 52
    c = columns(b.inner - (timed and 12 or 0), maximum, task ~= nil and task.total > 0)
    c.startup = timed and 10 or nil
  end
  local header = { { pad("    PLUGIN", c.name), "PluginToolsHeader" } }
  local column_order = { "state", "startup", "init", "scripts", "later", "source", "operation", "path" }
  for _, key in ipairs(column_order) do
    if c[key] then
      header[#header + 1] = { "  " }
      header[#header + 1] = { pad(key == "path" and "DIRECTORY" or key:upper(), c[key]), "PluginToolsHeader" }
    end
  end
  b:line(header)
  for _, entry in ipairs(rows) do
    local item = entry.item
    local progress = task and task.items[item.package]
    local selected = view.selected[item.id]
    local prefix = (selected and "●" or "○") .. " " .. (view.expanded[item.id] and "▾" or "▸") .. " "
    prefix = prefix .. entry.branch
    local state = not c.operation and task and not task.done and progress and progress.phase or item.state.phase
    local parts = {
      { Text.fit(prefix, c.name), selected and "PluginToolsSelected" or "PluginToolsMuted" },
      { pad(item.id, math.max(0, c.name - width(prefix))), selected and "PluginToolsSelected" or "PluginToolsName" },
    }
    if c.state then
      parts[#parts + 1] = { "  " }
      parts[#parts + 1] = { pad(state, c.state), Style.phase(state) }
    end
    for _, column in ipairs({
      { "startup", "startup_ms" },
      { "init", "startup_config_ms" },
      { "scripts", "scripts_ms" },
      { "later", "deferred_ms" },
    }) do
      if c[column[1]] then
        local value = item.state[column[2]]
        parts[#parts + 1] = { "  " }
        parts[#parts + 1] =
          { pad(milliseconds(value), c[column[1]]), value and "PluginToolsTiming" or "PluginToolsMuted" }
      end
    end
    if c.source then
      parts[#parts + 1] = { "  " }
      parts[#parts + 1] = {
        pad(item.selected == false and "inactive" or item.managed and "managed" or "local", c.source),
        item.managed and "PluginToolsPath" or "PluginToolsMuted",
      }
    end
    if c.operation then
      parts[#parts + 1] = { "  " }
      parts[#parts + 1] = {
        pad(progress and progress.phase or "—", c.operation),
        progress and Style.phase(progress.phase) or "PluginToolsMuted",
      }
    end
    if c.path then
      parts[#parts + 1] = { "  " }
      parts[#parts + 1] = { path_label(item.dir, c.path), "PluginToolsMuted" }
    end
    local row = b:line(parts)
    b.rows[row], b.by_id[item.id] = item.id, row
    if selected then
      b.selected[#b.selected + 1] = row - 1
    end
    if profiling and #(item.parents or {}) > 0 then
      b:wrap("↳ " .. table.concat(item.parents, ", "), "    ", "PluginToolsMuted")
    end
    if progress and task.action == "plan" and progress.after_commit then
      b:wrap(
        ("%s → %s  ·  build: %s"):format(
          (progress.before_commit or "missing"):sub(1, 12),
          progress.after_commit:sub(1, 12),
          progress.build and "required" or "none"
        ),
        "    ",
        "PluginToolsActive"
      )
    end
    if progress and task.action == "plan" and progress.changes then
      local change = progress.changes
      b:wrap(
        ("%s · %d ahead / %d behind · %d files +%d / -%d"):format(
          change.kind,
          change.ahead,
          change.behind,
          change.files_changed,
          change.insertions,
          change.deletions
        ),
        "    ",
        (change.kind == "rewind" or change.kind == "diverged") and "PluginToolsWarning" or "PluginToolsMuted"
      )
    end
    if view.expanded[item.id] then
      Details.render(b, view, item, progress)
    end
    for owned = row, #b.lines do
      b.owners[owned] = item.id
    end
  end
  if #rows == 0 then
    b:line()
    b:line({ { "No plugins match this filter.", "PluginToolsMuted" } })
    b:line({ { "/ ", "PluginToolsKey" }, { "Change or clear the filter to see plugins.", "PluginToolsMuted" } })
  end
end

return M
