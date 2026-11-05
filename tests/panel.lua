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
  assert(text():find("referenced_by", 1, true))
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
H.finish()
