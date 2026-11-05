local H = dofile("tests/helpers.lua")
local Tools = require("plugin_tools")
local U = require("plugin_tools.util")
local source = H.repo("recoverable")
local initial = H.git(source, "rev-parse", "HEAD")
local root, lockfile = H.root .. "/packages", H.root .. "/lock.json"
local manager = Tools.new({ root = root, lockfile = lockfile, specs = { { id = "recoverable", source = source } } })
H.wait(manager:install())
H.write(source .. "/next", "next")
local target = H.commit(source, "target")
local function crash(checkpoint, action)
  local script = H.root .. "/crash.lua"
  H.write(
    script,
    ([[
vim.opt.rtp:prepend(%q)
local tools=require('plugin_tools')
local U=require('plugin_tools.util')
local m=tools.new({root=%q,lockfile=%q,specs={{id='recoverable',source=%q}}})
if %q=='clean' then m.graph.packages={};m.graph.nodes={};m.graph.order={};m.graph.package_order={} end
local rename=vim.uv.fs_rename
vim.uv.fs_rename=function(from,to)
 local ok,err=rename(from,to)
 if ok and ((%q=='backup' and from==%q..'/recoverable') or
            (%q=='publish' and to==%q..'/recoverable')) then os.exit(91) end
 return ok,err
end
local write=U.write_json
U.write_json=function(path,value)
 write(path,value)
 if %q=='lock' and path==%q then os.exit(91) end
end
local delete=vim.fn.delete
vim.fn.delete=function(path,flags)
 if %q=='cleanup' and path:find(%q..'/.stage-',1,true)==1 then
  delete(path..'/plugin-tools-stage.json')
  delete(path..'/previous/.git','rf')
  os.exit(91)
 end
 return delete(path,flags)
end
local result,err=m[%q](m,{dry_run=false}):wait(10000)
error(err or 'did not reach crash checkpoint')
]]):format(
      vim.fn.getcwd(),
      root,
      lockfile,
      source,
      action or "update",
      checkpoint,
      root,
      checkpoint,
      root,
      checkpoint,
      lockfile,
      checkpoint,
      root,
      action or "update"
    )
  )
  local result = vim
    .system({ "nvim", "--headless", "-u", "NONE", "-i", "NONE", "--noplugin", "-l", script }, { text = true })
    :wait(15000)
  H.eq(result.code, 91)
  assert(vim.uv.fs_stat(root .. "/.operation-lock/journal.json"))
end
local function reset()
  local lock = U.read_json(lockfile)
  lock.plugins.recoverable.commit = initial
  U.write_json(lockfile, lock)
  H.wait(manager:restore())
end

H.case("a crash between backup rename and journal acknowledgement rolls back", function()
  crash("backup")
  H.eq(vim.uv.fs_stat(root .. "/recoverable"), nil)
  local plan = H.wait(manager:recover())
  H.eq(plan.mode, "rollback")
  H.eq(plan.steps[1].action, "restore")
  assert(vim.uv.fs_stat(root .. "/.operation-lock"))
  H.wait(manager:recover({ dry_run = false }))
  H.eq(H.git(root .. "/recoverable", "rev-parse", "HEAD"), initial)
  H.eq(U.read_json(lockfile).plugins.recoverable.commit, initial)
  H.eq(vim.uv.fs_stat(root .. "/.operation-lock"), nil)
end)

H.case("published dirty files block recovery and preserve backups", function()
  crash("publish")
  H.write(root .. "/recoverable/preserve", "user edit after crash")
  H.wait(manager:recover({ dry_run = false }), "local modifications during recovery")
  H.eq(vim.fn.readfile(root .. "/recoverable/preserve"), { "user edit after crash" })
  assert(#vim.fn.glob(root .. "/.stage-*/previous", false, true) == 1)
  vim.fn.delete(root .. "/recoverable/preserve")
  H.wait(manager:recover({ dry_run = false }))
  H.eq(H.git(root .. "/recoverable", "rev-parse", "HEAD"), initial)
end)

H.case("a committed lockfile survives a crash before the journal commit marker", function()
  crash("lock")
  local plan = H.wait(manager:recover())
  H.eq(plan.mode, "complete")
  H.wait(manager:recover({ dry_run = false }))
  H.eq(H.git(root .. "/recoverable", "rev-parse", "HEAD"), target)
  H.eq(U.read_json(lockfile).plugins.recoverable.commit, target)
  H.eq(vim.fn.glob(root .. "/.stage-*", false, true), {})
end)

H.case("partially deleted committed backups can finish cleanup after a crash", function()
  reset()
  crash("cleanup")
  local plan = H.wait(manager:recover())
  H.eq(plan.mode, "complete")
  H.wait(manager:recover({ dry_run = false }))
  H.eq(H.git(root .. "/recoverable", "rev-parse", "HEAD"), target)
  H.eq(vim.fn.glob(root .. "/.stage-*", false, true), {})
end)

H.case("live owners and mismatched journal paths are refused", function()
  reset()
  crash("backup")
  local path = root .. "/.operation-lock/owner.json"
  local owner = U.read_json(path)
  U.write_json(path, { pid = vim.uv.os_getpid(), action = "update" })
  H.wait(manager:recover({ dry_run = false }), "owning process is still running")
  U.write_json(path, owner)
  local journal_path = root .. "/.operation-lock/journal.json"
  local journal = U.read_json(journal_path)
  journal.processes.probe = { pid = vim.uv.os_getpid(), command = "build" }
  U.write_json(journal_path, journal)
  H.wait(manager:recover({ dry_run = false }), "recorded Git/build process is still running")
  journal.processes.probe = nil
  local old = journal.lockfile
  journal.lockfile = H.root .. "/unrelated"
  U.write_json(journal_path, journal)
  H.wait(manager:recover({ dry_run = false }), "journal root/lockfile mismatch")
  journal.lockfile = old
  U.write_json(journal_path, journal)
  H.wait(manager:recover({ dry_run = false }))
end)

H.case("interrupted cleanup restores the removed checkout and its lock entry", function()
  crash("backup", "clean")
  H.eq(vim.uv.fs_stat(root .. "/recoverable"), nil)
  H.wait(manager:recover({ dry_run = false }))
  H.eq(H.git(root .. "/recoverable", "rev-parse", "HEAD"), initial)
  H.eq(U.read_json(lockfile).plugins.recoverable.commit, initial)
end)

H.case("an unrelated directory appearing after a crash is preserved", function()
  crash("backup")
  H.write(root .. "/recoverable/preserve", "unowned")
  H.wait(manager:recover({ dry_run = false }), "missing Git metadata")
  H.eq(vim.fn.readfile(root .. "/recoverable/preserve"), { "unowned" })
  vim.fn.delete(root .. "/recoverable", "rf")
  H.wait(manager:recover({ dry_run = false }))
end)

H.case("journal commit failures restore both checkouts and the previous lockfile", function()
  local write = U.write_json
  local failed = false
  U.write_json = function(path, value)
    if path:match("/journal.json$") and value.phase == "committed" and not failed then
      failed = true
      error("journal commit probe")
    end
    return write(path, value)
  end
  H.wait(manager:update(), "journal commit probe")
  U.write_json = write
  H.eq(H.git(root .. "/recoverable", "rev-parse", "HEAD"), initial)
  H.eq(U.read_json(lockfile).plugins.recoverable.commit, initial)
  H.eq(vim.uv.fs_stat(root .. "/.operation-lock"), nil)
end)

H.case("a first-install publication is removed when no prior checkout existed", function()
  local empty = Tools.new({ root = root, lockfile = lockfile })
  H.wait(empty:clean({ dry_run = false }))
  crash("publish", "install")
  H.wait(manager:recover({ dry_run = false }))
  H.eq(vim.uv.fs_stat(root .. "/recoverable"), nil)
  H.eq(U.read_json(lockfile).plugins.recoverable, nil)
end)
H.finish()
