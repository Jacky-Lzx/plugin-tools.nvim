local H = dofile("tests/helpers.lua")
local resolve = require("plugin_tools.graph").resolve
local Tools = require("plugin_tools")

H.case("unselected declarations omit packages and do not inspect checkout directories", function()
  local U = require("plugin_tools.util")
  local directory = U.directory
  U.directory = function(path)
    assert(not path:find("uninstalled", 1, true), "Dormant checkout was inspected")
    return directory(path)
  end
  local m = Tools.new({
    profile = false,
    dev = { path = H.root .. "/uninstalled", fallback = false },
    specs = {
      {
        id = "dormant",
        source = "author/dormant",
        dev = true,
        optional = true,
        config = function()
          error("Dormant configuration ran")
        end,
        children = {
          {
            id = "hidden",
            enabled = function()
              error("Dormant child was evaluated")
            end,
          },
        },
      },
    },
  }):start()
  U.directory = directory
  H.eq(m.graph.order, {})
  H.eq(m.graph.package_order, {})
  H.eq(m.states, {})
  H.eq(m:has("dormant"), false)
end)

H.case("project selection retains defaults and merges options in declaration order", function()
  local configure = function() end
  local template = {
    id = "notes",
    dir = H.root,
    optional = true,
    origin = "global",
    config = configure,
    opts = { ui = { border = "rounded", width = 30 }, list = { 1, 2 } },
    children = { { id = "notes.child", opts = { enabled = true } } },
  }
  local project = { id = "notes", origin = "/vault/.nvim-plugins.lua", opts = { ui = { width = 50 }, list = { 3 } } }
  local g = resolve({ template, project })
  H.eq(g.nodes.notes.opts, { ui = { border = "rounded", width = 50 }, list = { 3 } })
  H.eq(g.nodes.notes.config, configure)
  H.eq(g.nodes["notes.child"].owner, "notes")
  H.eq(g.nodes.notes.declarations[1].optional, true)
  H.eq(g.nodes.notes.option_history[#g.nodes.notes.option_history].origin, project.origin)
  H.eq(template.opts.ui.width, 30)
  local reversed = resolve({ project, template })
  H.eq(reversed.nodes.notes.opts.ui.width, 30)
  H.eq(reversed.nodes.notes.declarations[2].origin, "global")
end)

H.case("enabled predicates run once and disabled selectors do not select templates", function()
  local calls = 0
  local template = {
    id = "notes",
    dir = H.root,
    optional = true,
    enabled = function()
      calls = calls + 1
      return true
    end,
  }
  H.eq(resolve({ template, { id = "notes", enabled = false } }).order, {})
  H.eq(calls, 1)
  local g = resolve({
    template,
    {
      id = "notes",
      enabled = function()
        calls = calls + 1
        return true
      end,
    },
  })
  H.eq(g.order, { "notes" })
  H.eq(calls, 3)
  H.raises(function()
    resolve({ { id = "bad", optional = "yes" } })
  end, "optional must be boolean")
end)

H.case("selected subtrees can select other templates without waking dormant parents", function()
  local g = resolve({
    { id = "second", dir = H.root, optional = true, opts = { answer = 42 } },
    { id = "first", dir = H.root, optional = true, children = { { id = "second", dir = H.root } } },
    { id = "first" },
    { id = "off", optional = true, children = { { id = "unrelated", dir = H.root } } },
    { id = "unrelated", dir = H.root, optional = true },
    { id = "disabled", enabled = false, children = { { id = "unrelated" } } },
  })
  H.eq(g.nodes.second.opts.answer, 42)
  H.eq(g.nodes.off, nil)
  H.eq(g.nodes.unrelated, nil)
  local cycle = resolve({
    { id = "a", optional = true, children = { { id = "b" } } },
    { id = "b", optional = true, children = { { id = "a" } } },
  })
  H.eq(cycle.order, {})
end)

H.case("dependency and after references cannot select a template", function()
  local dormant = { id = "notes", dir = H.root, optional = true }
  H.raises(function()
    resolve({ dormant, { id = "front", dir = H.root, dependencies = { "notes" } } })
  end, "notes is optional and not selected")
  H.raises(function()
    resolve({ dormant, { id = "front", dir = H.root, after = { "notes" } } })
  end, "after references undeclared or disabled plugin notes")
  local g = resolve({ dormant, { id = "front", dir = H.root, dependencies = { { id = "notes", optional = true } } } })
  H.eq(g.order, { "front" })
  H.eq(g.packages.notes, nil)
end)

H.case("explicitly disabled defaults are not revived by an optional selector", function()
  local g = resolve({
    { id = "off", dir = H.root, enabled = false, opts = { disabled = true } },
    { id = "off", dir = H.root, optional = true },
  })
  H.eq(g.order, {})
  local selected = resolve({
    { id = "off", dir = H.root, enabled = false, opts = { disabled = true } },
    { id = "off", dir = H.root, optional = true, opts = { selected = true } },
    { id = "off" },
  })
  H.eq(selected.nodes.off.opts, { selected = true })
end)

H.finish()
