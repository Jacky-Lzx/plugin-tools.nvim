local H = dofile("tests/helpers.lua")
local Tools = require("plugin_tools")
local source = H.repo("panel")
local manager = Tools.new({
  root = H.root .. "/packages",
  lockfile = H.root .. "/lock.json",
  specs = {
    { id = "panel", source = source, build = { "sh", "-c", "printf panel-build" } },
    { id = "external", dir = H.root },
  },
})
H.wait(manager:install())
manager:start()
local view = manager:open()
local function text()
  return table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")
end
local function press(key)
  local mapping = vim.fn.maparg(key, "n", false, true)
  assert(mapping.callback, key)
  mapping.callback()
end
local function cursor(id)
  for row, name in pairs(view.rows) do
    if name == id then
      vim.api.nvim_win_set_cursor(0, { row, 0 })
      return
    end
  end
  error("Missing row " .. id)
end

H.case("panel is searchable, preserves selection and exposes configuration details", function()
  H.eq(vim.bo.filetype, "plugin-tools")
  assert(text():find("managed", 1, true) and text():find("external", 1, true))
  cursor("panel")
  press(" ")
  assert(view.selected.panel)
  press("<CR>")
  assert(text():find("Referenced by", 1, true))
  assert(not text():find("referenced_by", 1, true), "Compact details exposed the raw configuration dump")
  press("o")
  assert(text():find("referenced_by", 1, true), "Full configuration is no longer accessible")
  press("o")
  local input = vim.ui.input
  vim.ui.input = function(_, callback)
    callback("panel")
  end
  press("/")
  vim.ui.input = input
  H.eq(view.filter, "panel")
  assert(view.selected.panel)
  -- Directory filtering is also supported; this fixture's root contains panel.
  H.eq(manager:open().buf, view.buf)
  local completed = require("plugin_tools.command").complete(manager, "pa", "PluginTools update pa", 21)
  H.eq(completed, { "panel" })
end)

H.case("selected updates render live progress and the operation log", function()
  press("u")
  local task = manager.last_operation
  H.wait(task)
  assert(vim.wait(1000, function()
    return text():find("updated", 1, true) ~= nil
  end))
  H.eq(task.result.packages, { "panel" })
  press("l")
  assert(text():find("Operation log", 1, true) and text():find("panel-build", 1, true))
  press("l")
  cursor("panel")
  press("p")
  H.wait(manager.last_operation)
  assert(vim.wait(1000, function()
    return text():find("Reviewed plan available", 1, true) ~= nil
  end))
  assert(text():find("build: required", 1, true))
  press("a")
  H.wait(manager.last_operation)
  H.eq(manager.last_plan, nil)
  press("u")
  local pending = manager.last_operation
  press("q")
  H.eq(vim.api.nvim_buf_is_valid(view.buf), false)
  H.eq(next(pending.observers), nil)
  H.wait(pending)
end)

H.case("floating layout adapts to Unicode paths, themes and narrow windows", function()
  local path = H.root .. "/带空格的插件目录, 中文"
  vim.fn.mkdir(path, "p")
  local visual = Tools.new({
    strict = false,
    specs = {
      { id = "ready-with-a-long-plugin-name", dir = path, origin = "配置.模块" },
      { id = "missing", dir = H.root .. "/missing" },
      {
        id = "broken",
        dir = H.root,
        start = false,
        config = function()
          error({ message = "visible failure" })
        end,
      },
    },
  }):start()
  pcall(visual.activate, visual, "broken")
  local panel = visual:open()
  H.eq(vim.api.nvim_win_get_config(panel.win).relative, "editor")
  H.eq(panel:current(), "ready-with-a-long-plugin-name")
  press(" ")
  press("<CR>")
  for _, size in ipairs({ 132, 88, 60, 38 }) do
    vim.api.nvim_win_set_width(panel.win, size)
    panel:render()
    for _, line in ipairs(vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)) do
      assert(vim.fn.strdisplaywidth(line) <= size - 2, "Panel overflow at width " .. size .. ": " .. line)
    end
    H.eq(panel:current(), "ready-with-a-long-plugin-name")
    assert(panel.selected[panel:current()])
  end
  local namespace = vim.api.nvim_get_namespaces()["plugin-tools-panel"]
  local groups = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(panel.buf, namespace, 0, -1, { details = true })) do
    local detail = mark[4]
    groups[detail.hl_group or detail.line_hl_group] = true
  end
  assert(
    groups.PluginToolsReady and groups.PluginToolsWarning and groups.PluginToolsError and groups.PluginToolsSelectedLine
  )
  panel.filter = "no matching plugin"
  panel:render()
  assert(table.concat(vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false), "\n"):find("No plugins match", 1, true))
  assert(panel.selected["ready-with-a-long-plugin-name"])
  panel.filter = ""
  panel:render()
  press("j")
  H.eq(panel:current(), "missing")
  press("j")
  H.eq(panel:current(), "broken")
  press("<CR>")
  assert(table.concat(vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false), "\n"):find("visible failure", 1, true))
  press("?")
  H.eq(panel.mode, "help")
  press("?")
  H.eq(panel:current(), "broken")
  vim.api.nvim_set_hl(0, "PluginToolsReady", { fg = 0x123456 })
  vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "panel-test" })
  H.eq(vim.api.nvim_get_hl(0, { name = "PluginToolsReady", link = false }).fg, 0x123456)
  vim.cmd("colorscheme default")
  H.eq(vim.api.nvim_get_hl(0, { name = "PluginToolsReady" }).link, "DiagnosticOk")
  local group = panel.group
  press("<Esc>")
  H.eq(vim.api.nvim_buf_is_valid(panel.buf), false)
  H.eq(pcall(vim.api.nvim_get_autocmds, { group = group }), false)
end)

H.case("startup profile sorts timings, keeps focus and adapts to narrow windows", function()
  local m = Tools.new({
    specs = {
      { id = "alpha", dir = H.root },
      { id = "slow", dir = H.root },
      { id = "uninitialized", dir = H.root, start = false },
    },
  }):start()
  m.states.alpha.startup_ms, m.states.slow.startup_ms = 1, 42
  m.states.slow.startup_config_ms, m.states.slow.scripts_ms = 30, 12
  m.states.slow.deferred_ms = 2
  m.states.slow.scripts = { { file = H.root .. "/plugin/slow.lua", self_ms = 12, duration_ms = 12 } }
  local panel = m:open()
  press("P")
  H.eq(panel.mode, "profile")
  H.eq(panel:current(), "slow")
  press(" ")
  local function contents()
    return table.concat(vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false), "\n")
  end
  assert(contents():find("Startup stages", 1, true))
  assert(contents():find("42.000 ms", 1, true))
  assert(contents():find("slowest startup first", 1, true))
  press("t")
  assert(panel.by_id.alpha < panel.by_id.slow)
  H.eq(panel:current(), "slow")
  assert(panel.selected.slow)
  press("<CR>")
  assert(contents():find("plugin/slow.lua", 1, true))
  for _, size in ipairs({ 132, 88, 60, 38 }) do
    vim.api.nvim_win_set_width(panel.win, size)
    panel:render()
    for _, line in ipairs(vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)) do
      assert(vim.fn.strdisplaywidth(line) <= size - 2, "Profile overflow: " .. line)
    end
    assert(contents():find("42.000 ms", 1, true))
    H.eq(panel:current(), "slow")
  end
  press("?")
  press("?")
  H.eq(panel.mode, "profile")
  H.eq(panel:current(), "slow")
  press("P")
  H.eq(panel.mode, "status")
  press("q")
  local disabled = Tools.new({ profile = false }):start():open()
  press("P")
  assert(
    table.concat(vim.api.nvim_buf_get_lines(disabled.buf, 0, -1, false), "\n"):find("Profiling is disabled", 1, true)
  )
  press("q")
end)
H.case("declared children form a tree while profiles keep parents and independent sorting", function()
  local child_dir = H.root .. "/independent"
  vim.fn.mkdir(child_dir, "p")
  local m = Tools.new({
    specs = {
      {
        id = "parent-a",
        dir = H.root,
        children = {
          { id = "independent", dir = child_dir },
          { id = "component" },
        },
      },
      { id = "parent-b", dir = H.root, children = { { id = "independent", dir = child_dir } } },
      { id = "dependent", dir = H.root, dependencies = { "parent-a" } },
    },
  }):start()
  m.states.independent.startup_ms = 90
  local panel = m:open()
  local function lines()
    return vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)
  end
  assert(panel.by_id["parent-a"] < panel.by_id.independent)
  assert(panel.by_id.independent < panel.by_id.component)
  assert(panel.by_id.component < panel.by_id["parent-b"])
  H.eq(vim.tbl_count(panel.by_id), 5)
  assert(lines()[panel.by_id.independent]:find("├─ independent", 1, true))
  assert(lines()[panel.by_id.component]:find("└─ component", 1, true))
  assert(not lines()[panel.by_id.dependent]:find("─", 1, true))
  vim.api.nvim_win_set_cursor(panel.win, { panel.by_id.independent, 0 })
  press(" ")
  press("<CR>")
  assert(table.concat(lines(), "\n"):find("parent-a, parent-b", 1, true))
  local snapshot = m:status()
  H.eq(snapshot[2].parents, { "parent-a", "parent-b" })
  snapshot[2].parents[1] = "changed"
  assert(m.graph.nodes.independent.parents["parent-a"])
  press("P")
  H.eq(panel:current(), "independent")
  H.eq(panel.owners[panel.by_id.independent + 1], "independent")
  assert(lines()[panel.by_id.independent + 1]:find("↳ parent-a, parent-b", 1, true))
  vim.api.nvim_win_set_cursor(panel.win, { panel.by_id.independent + 1, 0 })
  press(" ")
  H.eq(panel.selected.independent, nil)
  panel.filter = "independent"
  panel:render()
  H.eq(vim.tbl_count(panel.by_id), 1)
  press("P")
  H.eq(vim.tbl_count(panel.by_id), 3)
  assert(panel.by_id["parent-a"] and panel.by_id["parent-b"])
  assert(lines()[panel.by_id.independent]:find("└─ independent", 1, true))
  for _, mode in ipairs({ "status", "profile" }) do
    panel.mode = mode
    for _, size in ipairs({ 132, 88, 60, 38 }) do
      vim.api.nvim_win_set_width(panel.win, size)
      panel:render()
      for _, line in ipairs(lines()) do
        assert(vim.fn.strdisplaywidth(line) <= size - 2, "Hierarchy overflow: " .. line)
      end
    end
  end
  press("q")
  local layout = require("plugin_tools.ui.tree").layout({
    { id = "a", dir = "/a", parents = { "b" } },
    { id = "b", dir = "/b", parents = { "a" } },
  }, "", false)
  H.eq(#layout, 2)
  assert(layout[1].item.id ~= layout[2].item.id)
end)
H.finish()
