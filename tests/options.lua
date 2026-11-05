local H = dofile("tests/helpers.lua")
local Tools = require("plugin_tools")
local resolve = require("plugin_tools.graph").resolve

H.case("private graph merges preserve declaration and node isolation", function()
  local shared = { nested = { original = true, list = { 1, 2 } }, clear = { old = true } }
  local specs = {
    { id = "a", dir = H.root, opts = shared },
    { id = "b", dir = H.root, opts = shared },
    { id = "a", opts = { nested = { added = true, list = { 3 } }, clear = {} } },
  }
  local first = resolve(specs)
  H.eq(first.nodes.a.opts, { nested = { original = true, added = true, list = { 3 } }, clear = {} })
  H.eq(first.nodes.b.opts, shared)
  first.nodes.a.opts.nested.original = false
  assert(shared.nested.original and first.nodes.b.opts.nested.original)
  shared.nested.list[1] = 99
  H.eq(first.nodes.b.opts.nested.list, { 1, 2 })
  H.eq(resolve(specs).nodes.b.opts.nested.list, { 99, 2 })
end)

H.case("contexts copy opts once on demand and remain isolated", function()
  local unused, used
  local source = { nested = { value = 1 } }
  local m = Tools.new({
    specs = {
      {
        id = "unused",
        dir = H.root,
        opts = source,
        config = function(ctx)
          unused = ctx
          H.eq(ctx.id, "unused")
        end,
      },
      {
        id = "used",
        dir = H.root,
        opts = source,
        config = function(ctx)
          used = ctx
          local options = ctx.opts
          assert(ctx.opts == options)
          options.nested.value = 2
        end,
      },
    },
  })
  local copy, counts = vim.deepcopy, { unused = 0, used = 0 }
  vim.deepcopy = function(value, ...)
    for id in pairs(counts) do
      if value == m.graph.nodes[id].opts then
        counts[id] = counts[id] + 1
      end
    end
    return copy(value, ...)
  end
  local ok, err = pcall(function()
    m:start()
    H.eq(counts, { unused = 0, used = 1 })
    H.eq(unused.opts.nested.value, 1)
    H.eq(counts, { unused = 1, used = 1 })
    unused.opts.nested.value = 3
    H.eq(used.opts.nested.value, 2)
    H.eq(source.nested.value, 1)
    H.eq(m.graph.nodes.unused.opts.nested.value, 1)
    H.eq(m.graph.nodes.used.opts.nested.value, 1)
  end)
  vim.deepcopy = copy
  assert(ok, err)
end)

print(H.count .. " option isolation cases passed")
