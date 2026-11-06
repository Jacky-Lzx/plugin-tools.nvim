local Style = require("plugin_tools.ui.style")
local Tree = require("plugin_tools.ui.tree")
local M = {}
local width = vim.fn.strdisplaywidth

local function clean(value)
  return tostring(value):gsub("[%c]", " ")
end

local function error_text(value)
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" and type(value.message) == "string" then
    return value.message
  end
  return vim.inspect(value)
end

function M.fit(value, limit, suffix)
  value, limit = clean(value), math.max(0, limit)
  if width(value) <= limit then
    return value
  end
  suffix = suffix == nil and "…" or suffix
  if width(suffix) > limit then
    return ""
  end
  local low, high = 0, vim.fn.strchars(value)
  while low < high do
    local middle = math.ceil((low + high) / 2)
    if width(vim.fn.strcharpart(value, 0, middle)) + width(suffix) <= limit then
      low = middle
    else
      high = middle - 1
    end
  end
  return vim.fn.strcharpart(value, 0, low) .. suffix
end

local function pad(value, limit)
  value = M.fit(value, limit)
  return value .. string.rep(" ", math.max(0, limit - width(value)))
end

local function piece(value, available)
  local part = M.fit(value, available, "")
  if part == "" and value ~= "" then
    part = vim.fn.strcharpart(value, 0, 1)
  elseif #part < #value then
    local space = part:match("^.*()%s")
    if space and width(part:sub(1, space - 1)) >= available / 2 then
      return part:sub(1, space - 1), value:sub(space + 1)
    end
  end
  return part, value:sub(#part + 1)
end

local function home(path)
  local directory = vim.uv.os_homedir()
  return directory
      and (path == directory or vim.startswith(path, directory .. "/"))
      and ("~" .. path:sub(#directory + 1))
    or path
end

local function path_label(path, limit)
  path = home(path)
  if width(path) <= limit then
    return path
  end
  local tail = vim.fs.basename(path)
  if width(tail) + 3 < limit then
    return M.fit(path:sub(1, #path - #tail), limit - width(tail) - 1) .. "/" .. tail
  end
  return M.fit(path, limit)
end

local Builder = {}
Builder.__index = Builder

function Builder:line(parts)
  parts = type(parts) == "string" and { { parts } } or parts or {}
  local text, marks = "  ", {}
  for _, part in ipairs(parts) do
    local value = clean(part[1])
    if part[2] then
      marks[#marks + 1] = { start = #text, finish = #text + #value, group = part[2] }
    end
    text = text .. value
  end
  text = M.fit(text, math.max(1, self.window_width - 2), "")
  local row = #self.lines + 1
  self.lines[row] = text
  for _, mark in ipairs(marks) do
    if mark.start < #text then
      mark.row, mark.finish = row - 1, math.min(mark.finish, #text)
      self.marks[#self.marks + 1] = mark
    end
  end
  return row
end

function Builder:wrap(value, indent, group)
  value, indent = clean(value), indent or ""
  local available = math.max(1, self.inner - width(indent))
  repeat
    local part, rest = piece(value, available)
    self:line({ { indent .. part, group } })
    value = rest
  until value == ""
end

function Builder:detail(label, value, group)
  local size = self.inner < 50 and 10 or 15
  local prefix = "    " .. pad(label, size)
  local available = math.max(1, self.inner - width(prefix))
  value = clean(value)
  repeat
    local part, rest = piece(value, available)
    self:line({ { prefix, "PluginToolsMuted" }, { part, group or "PluginToolsName" } })
    value, prefix = rest, string.rep(" ", width(prefix))
  until value == ""
end

local function dependencies(map)
  local names = {}
  for id, optional in pairs(map) do
    names[#names + 1] = id .. (optional and " (optional)" or "")
  end
  table.sort(names)
  return #names > 0 and table.concat(names, ", ") or "None"
end

local function milliseconds(value)
  return value and ("%.3f ms"):format(value) or "—"
end

local function details(b, view, item, progress)
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
  if state.reason then
    b:detail("Trigger", state.reason)
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

local function plugins(b, view, items, task)
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
      { M.fit(prefix, c.name), selected and "PluginToolsSelected" or "PluginToolsMuted" },
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
        pad(item.managed and "managed" or "local", c.source),
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
    if view.expanded[item.id] then
      details(b, view, item, progress)
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

local function log(b, task)
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

local function help(b)
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

local function startup(b, view, t)
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

function M.render(view, window_width)
  local b = setmetatable({
    window_width = window_width,
    inner = math.max(1, window_width - 4),
    lines = {},
    marks = {},
    rows = {},
    owners = {},
    by_id = {},
    selected = {},
  }, Builder)
  local report = view.manager:profile()
  local items, task = report.plugins, view.manager.last_operation
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
  for _, phase in ipairs({ "failed", "missing", "ready", "mounted", "registered" }) do
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
    if task.error then
      b:wrap(
        "Error: " .. error_text(task.failure and task.failure.message or task.error):match("[^\n]+"),
        "",
        "PluginToolsError"
      )
    elseif task.result and task.result.restart_required then
      b:wrap("Restart Neovim to use changed plugin files.", "", "PluginToolsWarning")
    end
    if task.result and task.result.recovery_required then
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
    help(b)
  elseif view.mode == "log" then
    log(b, task)
  else
    if view.mode == "profile" then
      startup(b, view, timings)
    end
    plugins(b, view, items, task)
  end
  b:line()
  return b
end

return M
