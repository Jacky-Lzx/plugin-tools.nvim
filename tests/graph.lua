local H = dofile("tests/helpers.lua")
local resolve = require("plugin_tools.graph").resolve
local base = { id = "a", dir = H.root }

H.case("components and independent child packages", function()
  local g = resolve({
    {
      id = "parent",
      dir = H.root,
      children = {
        { id = "component", path = "components/one", children = { { id = "nested", path = "components/two" } } },
        { id = "other", source = "author/other", children = { { id = "other.feature" } } },
      },
    },
  })
  H.eq(g.package_order, { "parent", "other" })
  H.eq(g.nodes.component.dir, H.root .. "/components/one")
  H.eq(g.nodes.nested.dir, H.root .. "/components/two")
  H.eq(g.nodes["other.feature"].owner, "other")
  H.eq(g.nodes.component.start, false)
  H.eq(g.nodes.parent.start, true)
end)

H.case("shared children deduplicate; configuration merges and lists replace", function()
  local g = resolve({
    {
      id = "a",
      dir = H.root,
      children = { { id = "shared", source = "a/shared", opts = { x = { a = 1 }, list = { 1, 2 } } } },
    },
    {
      id = "b",
      dir = H.root,
      children = { { id = "shared", source = "a/shared", opts = { x = { b = 2 }, list = { 3 } } } },
    },
  })
  H.eq(#g.order, 3)
  H.eq(g.nodes.shared.opts, { x = { a = 1, b = 2 }, list = { 3 } })
  H.eq(g.nodes.shared.parents, { a = true, b = true })
end)

H.case("dependencies do not impose initialization order", function()
  local g =
    resolve({ { id = "a", dir = H.root, dependencies = { "b" } }, { id = "b", dir = H.root, dependencies = { "a" } } })
  H.eq(g.activation_order, { "a", "b" })
  local ordered = resolve({ { id = "a", dir = H.root, after = { "b" } }, { id = "b", dir = H.root } })
  H.eq(ordered.activation_order, { "b", "a" })
end)

H.case("initialization cycles and invalid references report useful errors", function()
  H.raises(function()
    resolve({ { id = "a", dir = H.root, after = { "b" } }, { id = "b", dir = H.root, after = { "a" } } })
  end, "a -> b -> a")
  H.raises(function()
    resolve({ { id = "a", dir = H.root, dependencies = { "b" } } })
  end, "required dependency b is undeclared")
  H.raises(function()
    resolve({ { id = "a", dir = H.root, dependencies = { "b" } }, { id = "b", enabled = false } })
  end, "b is disabled")
end)

H.case("optional absent dependencies and disabled subtrees", function()
  local g = resolve({
    { id = "off", enabled = false, children = { { id = "hidden" } } },
    { id = "a", dir = H.root, dependencies = { { id = "hidden", optional = true } } },
  })
  H.eq(g.order, { "a" })
  H.eq(g.nodes.a.dependencies.hidden, true)
end)

H.case("required reference wins over optional duplicate", function()
  local g = resolve({
    { id = "a", dir = H.root, dependencies = { { id = "b", optional = true }, "b", { id = "b", optional = true } } },
    { id = "b", dir = H.root },
  })
  H.eq(g.nodes.a.dependencies.b, false)
end)

H.case("conflicting declarations and unsafe paths fail", function()
  for _, specs in ipairs({
    { base, { id = "a", dir = "/elsewhere" } },
    { { id = "../bad", dir = H.root } },
    { { id = "a", dir = H.root, event = "VeryLazy" } },
    { { id = "a", dir = H.root, bootstrap = function() end } },
    { { id = "a", dir = H.root, children = { { id = "child", path = "../../escape" } } } },
    { { id = "a", dir = H.root, children = { { id = "child", version = "main" } } } },
  }) do
    H.raises(function()
      resolve(specs)
    end, "plugin-tools:")
  end
end)

H.case("local development preference and remote fallback", function()
  vim.fn.mkdir(H.root .. "/dev/a", "p")
  local opts = { root = H.root .. "/packages", dev = { path = H.root .. "/dev", fallback = true } }
  local g =
    resolve({ { id = "a", source = "author/a", dev = true }, { id = "b", source = "author/b", dev = true } }, opts)
  H.eq(g.packages.a.managed, false)
  H.eq(g.packages.a.dir, H.root .. "/dev/a")
  H.eq(g.packages.b.managed, true)
  H.eq(g.packages.b.source, "https://github.com/author/b.git")
  opts.dev.fallback = false
  H.raises(function()
    resolve({ { id = "b", source = "a/b", dev = true } }, opts)
  end, "development directory missing")
end)

H.finish()
