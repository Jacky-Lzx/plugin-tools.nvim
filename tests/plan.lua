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
H.case("plans explain forward, rewound and diverged history with file and commit summaries", function()
  local history = H.repo("history")
  local original = H.git(history, "rev-parse", "HEAD")
  local m = Tools.new({
    root = H.root .. "/history-packages",
    lockfile = H.root .. "/history-lock.json",
    specs = { { id = "history", source = history } },
  })
  H.wait(m:install())
  H.write(history .. "/feature", "one\ntwo")
  H.commit(history, "add feature")
  local forward = H.wait(m:plan())
  local change = forward.details[1].changes
  H.eq(change.kind, "forward")
  H.eq({ change.ahead, change.behind, change.files_changed, change.insertions }, { 1, 0, 1, 2 })
  H.eq(change.commits[1].subject, "add feature")
  H.eq(change.files[1].path, "feature")
  local view = m:open({ id = "history" })
  local text = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")
  assert(text:find("add feature", 1, true) and text:find("1 ahead / 0 behind", 1, true))
  vim.api.nvim_win_close(view.win, true)
  H.wait(m:update({ plan = forward }))
  H.git(history, "reset", "--hard", original)
  local rewind = H.wait(m:plan()).details[1].changes
  H.eq(rewind.kind, "rewind")
  H.eq({ rewind.ahead, rewind.behind, rewind.deletions }, { 0, 1, 2 })
  H.write(history .. "/alternative", "alternative")
  H.commit(history, "alternate history")
  local divergent = H.wait(m:plan()).details[1].changes
  H.eq(divergent.kind, "diverged")
  H.eq({ divergent.ahead, divergent.behind, divergent.files_changed }, { 1, 1, 2 })
  H.eq(H.git(m.graph.packages.history.dir, "rev-parse", "HEAD"), forward.details[1].after_commit)
end)
H.finish()
