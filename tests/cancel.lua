local H = dofile("tests/helpers.lua")
local Tools = require("plugin_tools")
local source = H.repo("cancel")
local function manager(name, specs)
  return Tools.new({ root = H.root .. "/" .. name, lockfile = H.root .. "/" .. name .. "-lock.json", specs = specs })
end
local function clean(m)
  H.eq(m.operation, nil)
  H.eq(vim.uv.fs_stat(m.graph.root .. "/.operation-lock"), nil)
  H.eq(vim.fn.glob(m.graph.root .. "/.stage-*", false, true), {})
end
H.case("queued cancellation finishes without creating roots or starting commands", function()
  local m = manager("queued", { { id = "cancel", source = source } })
  local task = m:install()
  H.eq(task:cancel(), true)
  H.eq(task:cancel(), false)
  H.wait(task, "operation cancelled")
  H.eq(task.report.status, "cancelled")
  H.eq(task.report.cancelled, true)
  H.eq(vim.uv.fs_stat(m.graph.root), nil)
  H.eq(task:cancel(), false)
  clean(m)
end)
H.case("active cancellation stops child processes and queued packages before cleanup", function()
  if vim.fn.has("win32") == 1 then
    return
  end
  local ready = H.root .. "/build-ready"
  local child = H.root .. "/child-ready"
  local code = [=[import pathlib, subprocess, sys, time
subprocess.Popen([sys.executable, "-c", "import pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text('ready'); time.sleep(30)", sys.argv[2]])
pathlib.Path(sys.argv[1]).write_text('ready')
time.sleep(30)
]=]
  local m = manager("active", {
    { id = "first", source = source, build = { vim.fn.exepath("python3"), "-c", code, ready, child } },
    { id = "later", source = source },
  })
  local task = m:install({ concurrency = 1 })
  assert(vim.wait(10000, function()
    return vim.uv.fs_stat(ready) and vim.uv.fs_stat(child)
  end))
  local result, err = task:wait(1)
  H.eq(result, nil)
  assert(err:find("still running", 1, true) and not task.cancel_requested)
  require("plugin_tools.command").run(m, { "cancel" })
  H.wait(task, "operation cancelled")
  H.eq(task.report.status, "cancelled")
  H.eq(task.items.later.phase, "rolled_back")
  H.eq(vim.uv.fs_stat(m.graph.root .. "/first"), nil)
  H.eq(vim.uv.fs_stat(m.lockfile), nil)
  assert(not vim.iter(task.events):any(function(event)
    return event.id == "later" and event.phase == "cloning"
  end))
  clean(m)
  -- The completion callback waits for inherited output pipes to close, so a
  -- surviving child would hold the operation open until the test times out.
end)
H.case("parallel cancellation drains every active worker before releasing the operation lock", function()
  local first, second = H.root .. "/first-ready", H.root .. "/second-ready"
  local function build(path)
    return { "sh", "-c", 'printf ready > "$1"; sleep 30', "build", path }
  end
  local m = manager("parallel", {
    { id = "first", source = source, build = build(first) },
    { id = "second", source = source, build = build(second) },
    { id = "queued", source = source },
  })
  local task = m:install({ concurrency = 2 })
  assert(vim.wait(10000, function()
    return vim.uv.fs_stat(first) and vim.uv.fs_stat(second)
  end))
  assert(task:cancel())
  H.wait(task, "operation cancelled")
  H.eq(task.report.status, "cancelled")
  H.eq(task.items.queued.phase, "rolled_back")
  H.eq(vim.uv.fs_stat(m.graph.root .. "/first"), nil)
  H.eq(vim.uv.fs_stat(m.graph.root .. "/second"), nil)
  clean(m)
end)
H.case("cooperative build cancellation preserves existing checkout and lock", function()
  local m = manager("cooperative", { { id = "cancel", source = source } })
  H.wait(m:install())
  local before = vim.fn.readfile(m.lockfile)
  local ino = vim.uv.fs_stat(m.graph.packages.cancel.dir).ino
  m.graph.packages.cancel.build = function(ctx)
    assert(not ctx.cancelled())
    H.eq(m.operation:cancel(), true)
    assert(ctx.cancelled())
  end
  local task = m:update()
  H.wait(task, "operation cancelled")
  H.eq(task.report.status, "cancelled")
  H.eq(vim.fn.readfile(m.lockfile), before)
  H.eq(vim.uv.fs_stat(m.graph.packages.cancel.dir).ino, ino)
  clean(m)
end)
H.case("publication and rollback reject cancellation and finish consistently", function()
  local m = manager("sealed", { { id = "cancel", source = source } })
  local attempted = false
  local task = m:install({
    on_progress = function(event)
      if event.phase == "publishing" then
        attempted = true
        H.eq(m.operation:cancel(), false)
      end
    end,
  })
  H.wait(task)
  assert(attempted and not task.cancel_requested)
  H.eq(#task.observer_errors, 0)
  m.graph.packages.cancel.build = function()
    error("build failure")
  end
  local rolled = false
  local failed = m:update({
    on_progress = function(event)
      if event.phase == "rolling_back" then
        rolled = true
        H.eq(m.operation:cancel(), false)
      end
    end,
  })
  H.wait(failed, "build failure")
  assert(rolled and failed.report.status == "failed")
  H.eq(#failed.observer_errors, 0)
  clean(m)
end)
H.case("cancellation cleanup failures retain recovery state and can be recovered", function()
  local m = manager("cleanup", { { id = "cancel", source = source, build = function() end } })
  local remove = vim.fn.delete
  vim.fn.delete = function(path, flags)
    if path:find(m.graph.root .. "/.stage-", 1, true) == 1 then
      return -1
    end
    return remove(path, flags)
  end
  local task = m:install({
    on_progress = function(event)
      if event.phase == "building" then
        m.operation:cancel()
      end
    end,
  })
  local ok, err = pcall(H.wait, task, "operation cancelled")
  vim.fn.delete = remove
  assert(ok, err)
  H.eq(task.report.status, "failed")
  H.eq(task.report.recovery_required, true)
  assert(vim.uv.fs_stat(m.graph.root .. "/.operation-lock"))
  H.wait(m:recover({ dry_run = false }))
  clean(m)
end)
H.case("recovery refuses cancellation after its validation boundary", function()
  local m = manager("recovery", {})
  H.wait(m:recover())
  H.eq(m.last_operation:cancel(), false)
  H.raises(function()
    require("plugin_tools.command").run(m, { "cancel", "extra" })
  end, "usage: PluginTools cancel")
end)
H.finish()
