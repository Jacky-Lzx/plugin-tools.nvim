local H = dofile("tests/helpers.lua")
local Tools = require("plugin_tools")
local specs = {
  {
    id = "shared",
    dir = H.root,
    origin = "plugins.base",
    opts = { ui = { border = "single", width = 30 }, list = { 1 }, clear = { old = true } },
  },
  { id = "shared", origin = "languages.lua", opts = { ui = { border = "rounded" }, list = { 2, 3 } } },
  { id = "shared", origin = "/project/.nvim-plugins.lua", opts = { ui = { width = 50 }, clear = {} } },
  { id = "shared", enabled = false, origin = "disabled-profile", opts = { ui = false } },
}
local manager = Tools.new({ specs = specs })
H.case("explain preserves declaration order and option replacement paths", function()
  local info = manager:explain("shared")
  H.eq(#info.declarations, 4)
  H.eq(info.declarations[2].origin, "languages.lua")
  H.eq(info.declarations[3].position, "specs[3]")
  H.eq(info.declarations[4].enabled, false)
  H.eq(info.opts.ui, { border = "rounded", width = 50 })
  local border, width, clear
  for _, change in ipairs(info.option_history) do
    if vim.deep_equal(change.path, { "ui", "border" }) then
      border = change
    end
    if vim.deep_equal(change.path, { "ui", "width" }) then
      width = change
    end
    if vim.deep_equal(change.path, { "clear" }) then
      clear = change
    end
  end
  H.eq(border.origin, "languages.lua")
  H.eq(width.origin, "/project/.nvim-plugins.lua")
  H.eq(clear.operation, "clear")
  assert(not vim.iter(info.option_history):any(function(change)
    return change.origin == "disabled-profile"
  end))
  info.declarations[1].origin = "mutated"
  specs[1].opts.ui.border = "changed"
  H.eq(manager:explain("shared").declarations[1].origin, "plugins.base")
  H.eq(manager:explain("shared").opts.ui.border, "rounded")
end)

H.case("scalar conflicts name both declaration sources", function()
  local ok, err = pcall(Tools.new, {
    specs = {
      { id = "a", dir = H.root, origin = "plugins.one" },
      { id = "a", dir = "/elsewhere", origin = "plugins.two" },
    },
  })
  assert(not ok and err:find("plugins.one", 1, true) and err:find("plugins.two", 1, true))
end)

H.case("nested contributions inherit their own declaring module", function()
  local m = Tools.new({
    specs = {
      { id = "parent", dir = H.root, origin = "first", children = { { id = "child" } } },
      { id = "parent", origin = "second", children = { { id = "child", opts = { enabled = true } } } },
    },
  })
  local info = m:explain("child")
  H.eq(info.declarations[1].origin, "first")
  H.eq(info.declarations[2].origin, "second")
  H.eq(info.declarations[2].parent, "parent")
end)
H.finish()
