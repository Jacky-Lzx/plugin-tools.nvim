local H = dofile("tests/helpers.lua")
local Tools = require("plugin_tools")
local source = H.repo("progress")
local initial = H.git(source, "rev-parse", "HEAD")
local manager = Tools.new({
  root = H.root .. "/packages",
  lockfile = H.root .. "/lock.json",
  specs = { { id = "progress", source = source, build = { "sh", "-c", "printf build-output" } } },
})

H.case("progress exposes phases, versions and isolated observers before completion", function()
  local phases, running, detached = {}, false, 0
  local task = manager:install({
    on_progress = function(event)
      phases[event.phase] = true
      running = running or not manager.last_operation.done
      event.phase = "mutated"
    end,
  })
  local unsubscribe = task:subscribe(function()
    detached = detached + 1
  end)
  unsubscribe()
  task:subscribe(function()
    error("observer failure")
  end)
  local result = H.wait(task)
  assert(running and phases.cloning and phases.building and phases.publishing and phases.done)
  H.eq(detached, 0)
  H.eq(#task.observer_errors, 1)
  H.eq(result.status, "success")
  H.eq(result.completed, 1)
  H.eq(result.total, 1)
  H.eq(result.phase, "done")
  H.eq(result.details[1].phase, "installed")
  H.eq(result.details[1].after_commit, initial)
  H.eq(manager.last_operation, task)
  assert(vim.iter(task.events):any(function(event)
    return event.stdout == "build-output"
  end))
  local snapshot = task:snapshot()
  snapshot.details[1].id = "changed"
  H.eq(task.items.progress.id, "progress")
end)

H.case("updates report previous and target commits", function()
  H.write(source .. "/next", "next")
  local next_commit = H.commit(source, "next")
  local result = H.wait(manager:update())
  H.eq(result.details[1].before_commit, initial)
  H.eq(result.details[1].after_commit, next_commit)
  H.eq(result.details[1].phase, "updated")
end)

H.case("failed builds retain structured failure and transaction logs", function()
  manager.graph.packages.progress.build = function()
    error("build probe")
  end
  local task = manager:update()
  H.wait(task, "build probe")
  H.eq(task.report.status, "failed")
  H.eq(task.report.error.id, "progress")
  H.eq(task.report.error.phase, "building")
  H.eq(task.report.completed, 0)
  assert(task.report.error.message:find("build probe", 1, true))
  H.eq(manager.operation, nil)
end)

H.finish()
