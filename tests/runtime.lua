local H = dofile("tests/helpers.lua")
local Tools = require("plugin_tools")
local original_rtp = vim.opt.runtimepath:get()

H.case("no processes, source scans, lockfile reads, or dependency setup on startup", function()
  H.write(
    H.root .. "/lua/cold_backend.lua",
    [[
_G.backend_required = (_G.backend_required or 0) + 1
return { setup = function(opts) _G.backend_opts = opts end, render = function() return 'rendered' end }
]]
  )
  local trigger
  local system, glob, readfile = vim.system, vim.fn.globpath, io.open
  vim.system = function()
    error("process spawned during startup")
  end
  vim.fn.globpath = function()
    error("plugin source scanned during startup")
  end
  io.open = function()
    error("file read during startup")
  end
  local manager = Tools.new({
    specs = {
      {
        id = "a",
        dir = H.root,
        dependencies = { "b", { id = "absent", optional = true } },
        config = function(ctx)
          H.eq(ctx.has("absent"), false)
          trigger = function()
            return ctx.use("b").render()
          end
        end,
      },
      { id = "b", dir = H.root, start = false, main = "cold_backend", opts = { answer = 42 } },
    },
  }):start()
  H.eq(package.loaded["plugin_tools.operations"], nil)
  H.eq(package.loaded.cold_backend, nil)
  H.eq(manager:explain("b").state.phase, "mounted")
  H.eq(manager:explain("b").referenced_by, { "a" })
  H.eq(trigger(), "rendered")
  H.eq(trigger(), "rendered")
  H.eq(_G.backend_required, 1)
  H.eq(_G.backend_opts, { answer = 42 })
  H.eq(manager:explain("b").state.count, 1)
  vim.system, vim.fn.globpath, io.open = system, glob, readfile
end)

H.case("runtimepath is assigned once and preserves commas and Unicode", function()
  local path = H.root .. "/a,b 中文"
  vim.fn.mkdir(path .. "/after", "p")
  local changes = 0
  local previous = vim.opt.runtimepath:get()
  local set = vim.api.nvim_set_option_value
  vim.api.nvim_set_option_value = function(name, value, opts)
    if name == "runtimepath" then
      changes = changes + 1
    end
    return set(name, value, opts)
  end
  local m = Tools.new({ specs = { { id = "a", dir = path, children = { { id = "child" } } } } }):start()
  m:start()
  H.eq(changes, 1)
  vim.api.nvim_set_option_value = set
  local paths = require("plugin_tools.util").runtime_paths()
  local positions = {}
  for i, p in ipairs(paths) do
    positions[p] = i
  end
  assert(positions[path] < positions[vim.env.VIMRUNTIME])
  assert(positions[path .. "/after"] > positions[vim.env.VIMRUNTIME])
  local count = 0
  for _, p in ipairs(paths) do
    if p == path then
      count = count + 1
    end
  end
  H.eq(count, 1)
  vim.opt.runtimepath = previous
end)

H.case("configuration modules and after directories retain override priority", function()
  local config, plugin = H.root .. "/config", H.root .. "/managed"
  H.write(config .. "/lua/priority_fixture.lua", "return 'user'")
  H.write(plugin .. "/lua/priority_fixture.lua", "return 'plugin'")
  vim.fn.mkdir(config .. "/after", "p")
  vim.fn.mkdir(plugin .. "/after", "p")
  local U = require("plugin_tools.util")
  local before = U.runtime_paths()
  local runtime = vim.deepcopy(before)
  table.insert(runtime, 1, config)
  runtime[#runtime + 1] = config .. "/after"
  U.set_runtime_paths(runtime)
  Tools.new({ specs = { { id = "managed", dir = plugin } } }):start()
  H.eq(require("priority_fixture"), "user")
  local positions = {}
  for i, p in ipairs(U.runtime_paths()) do
    positions[p] = i
  end
  assert(positions[plugin .. "/after"] < positions[config .. "/after"])
  U.set_runtime_paths(before)
end)

H.case("explicit prerequisites initialize before demand-loaded component", function()
  local events = {}
  local m = Tools.new({
    specs = {
      {
        id = "parent",
        dir = H.root,
        bootstrap = function()
          events[#events + 1] = "bootstrap"
        end,
        children = {
          {
            id = "first",
            config = function()
              events[#events + 1] = "first"
            end,
          },
          {
            id = "second",
            after = { "first" },
            config = function()
              events[#events + 1] = "second"
            end,
          },
        },
      },
    },
  }):start()
  H.eq(events, { "bootstrap" })
  m:activate("second")
  H.eq(events, { "bootstrap", "first", "second" })
end)

H.case("runtime cycles and failed initialization are recorded", function()
  local m = Tools.new({
    specs = {
      {
        id = "a",
        dir = H.root,
        start = false,
        dependencies = { "b" },
        config = function(ctx)
          ctx.activate("b")
        end,
      },
      {
        id = "b",
        dir = H.root,
        start = false,
        dependencies = { "a" },
        config = function(ctx)
          ctx.activate("a")
        end,
      },
    },
  }):start()
  H.raises(function()
    m:activate("a")
  end, "activation cycle: a -> b -> a")
  H.eq(m:explain("a").state.phase, "failed")
  H.raises(function()
    m:activate("a")
  end, "previous initialization failed")
end)

H.case("strict startup fails before mutating runtimepath; permissive mode reports missing", function()
  local before = vim.o.runtimepath
  H.raises(function()
    Tools.new({ specs = { { id = "missing", dir = H.root .. "/missing" } } }):start()
  end, "missing plugin directories")
  H.eq(vim.o.runtimepath, before)
  local m = Tools.new({ strict = false, specs = { { id = "missing", dir = H.root .. "/missing" } } }):start()
  H.eq(m:has("missing"), false)
  H.raises(function()
    m:activate("missing")
  end, "directory is missing")
end)

H.case("configuration and inspection return isolated option copies", function()
  local m = Tools.new({
    specs = {
      {
        id = "a",
        dir = H.root,
        opts = { value = 1 },
        config = function(ctx)
          ctx.opts.value = 2
        end,
      },
    },
  }):start()
  local info = m:explain("a")
  H.eq(info.opts.value, 1)
  info.opts.value = 3
  H.eq(m:explain("a").opts.value, 1)
end)

H.case("bootstrap failures are visible and startup is not silently retried", function()
  local m = Tools.new({
    specs = {
      {
        id = "broken",
        dir = H.root,
        bootstrap = function()
          error("bootstrap boom")
        end,
      },
    },
  })
  H.raises(function()
    m:start()
  end, "bootstrap boom")
  H.eq(m:explain("broken").state.phase, "failed")
  H.raises(function()
    m:start()
  end, "previous startup failed")
end)

vim.opt.runtimepath = original_rtp
H.finish()
