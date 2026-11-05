local H = dofile("tests/helpers.lua")
local Tools = require("plugin_tools")
local U = require("plugin_tools.util")
local source = H.repo("planned")
local initial = H.git(source, "rev-parse", "HEAD")
local builds = 0
local manager = Tools.new({
  root = H.root .. "/packages",
  lockfile = H.root .. "/lock.json",
  specs = {
    {
      id = "planned",
      source = source,
      build = function()
        builds = builds + 1
      end,
      children = { { id = "planned.component" } },
    },
  },
})
H.wait(manager:install())
local lock_before = vim.fn.readfile(manager.lockfile)
H.write(source .. "/next", "next")
local target = H.commit(source, "target")
local report

H.case("previewing a new installation leaves its checkout and lockfile absent", function()
  local fresh = Tools.new({
    root = H.root .. "/fresh",
    lockfile = H.root .. "/fresh-lock.json",
    specs = { { id = "planned", source = source } },
  })
  local result = H.wait(fresh:plan())
  H.eq(result.details[1].before_commit, nil)
  H.eq(vim.uv.fs_stat(fresh.lockfile), nil)
  H.eq(vim.uv.fs_stat(fresh.graph.packages.planned.dir), nil)
end)

H.case("preview resolves versions and affected components without builds or publication", function()
  report = H.wait(manager:plan({ ids = { "planned.component" } }))
  H.eq(builds, 1)
  H.eq(report.details[1].before_commit, initial)
  H.eq(report.details[1].after_commit, target)
  H.eq(report.details[1].build, true)
  H.eq(report.details[1].components, { "planned", "planned.component" })
  H.eq(report.details[1].phase, "planned")
  H.eq(H.git(manager.graph.packages.planned.dir, "rev-parse", "HEAD"), initial)
  H.eq(vim.fn.readfile(manager.lockfile), lock_before)
  H.eq(vim.fn.glob(manager.graph.root .. "/.stage-*", false, true), {})
end)

H.case("applying a reviewed plan pins its original commits even if upstream moves", function()
  H.write(source .. "/later", "later")
  local later = H.commit(source, "later")
  -- Public report mutations cannot change the private reviewed selection/revisions.
  report.details[1].after_commit = later
  report.packages[1] = "unknown"
  H.wait(manager:update({ plan = report }))
  H.eq(H.git(manager.graph.packages.planned.dir, "rev-parse", "HEAD"), target)
  H.eq(U.read_json(manager.lockfile).plugins.planned.commit, target)
  H.eq(builds, 2)
  H.eq(manager.last_plan, nil)
end)

H.case("configuration or checkout changes invalidate the reviewed plan", function()
  local planned = H.wait(manager:plan())
  local original = manager.graph.packages.planned.build
  manager.graph.packages.planned.build = function() end
  H.wait(manager:update({ plan = planned }), "configuration changed since preview")
  manager.graph.packages.planned.build = original
  H.git(manager.graph.packages.planned.dir, "checkout", "-q", initial)
  H.wait(manager:update({ plan = planned }), "checkout changed since preview")
  H.raises(function()
    manager:update({ plan = {} })
  end, "latest successful preview")
  H.eq(manager.operation, nil)
end)
H.finish()
