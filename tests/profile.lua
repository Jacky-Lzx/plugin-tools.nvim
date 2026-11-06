local H = dofile("tests/helpers.lua")
local Tools = require("plugin_tools")
local clock, now = vim.uv.hrtime, 0
vim.uv.hrtime = function()
  return now
end
local function advance(ms)
  now = now + ms * 1e6
end
local function enter()
  vim.api.nvim_exec_autocmds("VimEnter", { modeline = false })
end
local function source(event, file)
  vim.api.nvim_exec_autocmds(event, { pattern = file, modeline = false })
end

H.case("nested initialization has exclusive and inclusive timings without double counting", function()
  local manager = Tools.new({
    specs = {
      {
        id = "outer",
        dir = H.root,
        dependencies = { "inner" },
        config = function(ctx)
          advance(2)
          ctx.activate("inner")
          advance(5)
        end,
      },
      {
        id = "inner",
        dir = H.root,
        start = false,
        config = function()
          advance(3)
        end,
      },
      {
        id = "later",
        dir = H.root,
        start = false,
        config = function()
          advance(11)
        end,
      },
    },
  }):start()
  H.eq(manager.states.outer.duration_ms, 10)
  H.eq(manager.states.outer.self_ms, 7)
  H.eq(manager.states.inner.startup_ms, 3)
  H.eq(manager.states.outer.startup_ms, 7)
  H.eq(manager.timings.config_ms, 10)
  advance(4)
  enter()
  H.eq(manager.timings.total_ms, 14)
  H.eq(manager.timings.other_ms, 4)
  H.eq(manager.timings.boundary, "VimEnter")
  local frozen = vim.deepcopy(manager.timings)
  advance(1000)
  manager:activate("later")
  H.eq(manager.states.later.startup_ms, nil)
  H.eq(manager.states.later.deferred_ms, 11)
  H.eq(manager.states.later.activation, "on demand")
  manager:activate("later")
  H.eq(manager.states.later.deferred_ms, 11)
  H.eq(manager.timings, frozen)
  local report = manager:profile()
  report.timings.total_ms, report.plugins[1].state.startup_ms = 0, 0
  H.eq(manager.timings.total_ms, 14)
  H.eq(manager.states.outer.startup_ms, 7)
end)

H.case("source ownership uses the most specific root and shared roots are counted once", function()
  local path = H.root .. "/package 中文"
  vim.fn.mkdir(path .. "/component", "p")
  local m = Tools.new({
    specs = {
      {
        id = "package",
        dir = path,
        start = false,
        children = {
          { id = "shared", start = false },
          { id = "component", path = "component", start = false },
        },
      },
      { id = "triggered", dir = H.root .. "/other", start = false },
    },
    strict = false,
  }):start()
  local parent, child, foreign =
    path .. "/plugin/entry.lua", path .. "/component/plugin/entry.vim", H.root .. "/builtin.vim"
  source("SourcePre", parent)
  advance(2)
  source("SourcePre", child)
  advance(3)
  source("SourcePost", child)
  source("SourcePre", foreign)
  advance(7)
  source("SourcePost", foreign)
  advance(5)
  source("SourcePost", parent)
  H.eq(m.states.package.scripts_ms, 7)
  H.eq(m.states.package.scripts[1].duration_ms, 17)
  H.eq(m.states.component.scripts_ms, 3)
  H.eq(m.states.shared.scripts_ms, nil)
  H.eq(m.timings.native_ms, 17)
  local group = m._profile.group
  enter()
  H.eq(pcall(vim.api.nvim_get_autocmds, { group = group }), false)
  H.eq(m._profile.group, nil)
  source("SourcePre", parent)
  advance(100)
  source("SourcePost", parent)
  H.eq(m.states.package.scripts_ms, 7)
end)

H.case("initialization inside a native script is separate from that script's own time", function()
  local m = Tools.new({
    specs = {
      { id = "native", dir = H.root, start = false },
      {
        id = "backend",
        dir = H.root .. "/backend",
        start = false,
        config = function()
          advance(6)
        end,
      },
    },
    strict = false,
  })
  vim.fn.mkdir(H.root .. "/backend", "p")
  m:start()
  local file = H.root .. "/plugin/native.lua"
  source("SourcePre", file)
  advance(2)
  m:activate("backend")
  advance(3)
  source("SourcePost", file)
  enter()
  H.eq(m.states.native.startup_ms, 5)
  H.eq(m.states.backend.startup_ms, 6)
  H.eq(m.timings.native_ms, 5)
  H.eq(m.timings.config_ms, 6)
  H.eq(m.timings.total_ms, 11)
end)

H.case("failed startup records partial work and removes source observers", function()
  local m = Tools.new({
    specs = {
      {
        id = "broken",
        dir = H.root,
        config = function()
          advance(9)
          error("profiled failure")
        end,
      },
    },
  })
  H.raises(function()
    m:start()
  end, "profiled failure")
  H.eq(m.states.broken.self_ms, 9)
  H.eq(m.states.broken.phase, "failed")
  H.eq(m.timings.boundary, "failed")
  H.eq(m._profile.group, nil)
  H.eq(m.timings.total_ms, 9)
  local strict = Tools.new({ specs = { { id = "missing", dir = H.root .. "/missing" } } })
  H.raises(function()
    strict:start()
  end, "missing plugin directories")
  H.eq(strict.timings.boundary, "failed")
  H.eq(strict._profile.group, nil)
end)

H.case("incomplete native sources are omitted and explicitly reported", function()
  local m = Tools.new({ specs = { { id = "source", dir = H.root, start = false } } }):start()
  source("SourcePre", H.root .. "/interrupted.vim")
  advance(4)
  enter()
  H.eq(m.timings.incomplete_sources, 1)
  H.eq(m.states.source.scripts_ms, nil)
  H.eq(m.timings.other_ms, 4)
end)

H.case("interrupted sources inside failed activation do not contaminate its self time", function()
  local m = Tools.new({
    specs = {
      {
        id = "interrupted",
        dir = H.root,
        config = function()
          advance(2)
          source("SourcePre", H.root .. "/unfinished.lua")
          advance(4)
          error("interrupted source")
        end,
      },
    },
  })
  H.raises(function()
    m:start()
  end, "interrupted source")
  H.eq(m.states.interrupted.self_ms, 2)
  H.eq(m.states.interrupted.duration_ms, 6)
  H.eq(m.timings.incomplete_sources, 1)
  H.eq(m.timings.other_ms, 4)
end)

H.case("profiling can be disabled without installing observers or per-plugin timers", function()
  local m = Tools.new({
    profile = false,
    specs = { {
      id = "plain",
      dir = H.root,
      config = function()
        advance(2)
      end,
    } },
  }):start()
  H.eq(m._profile, nil)
  H.eq(m.timings.enabled, false)
  H.eq(m.states.plain.duration_ms, nil)
  H.eq(m.timings.start_ms, 2)
  H.eq(m:profile().timings.enabled, false)
end)

vim.uv.hrtime = clock
H.finish()
