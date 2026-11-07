local H = dofile("tests/helpers.lua")
local Tools = require("plugin_tools")
local U = require("plugin_tools.util")
local source = H.repo("source")
local initial = H.git(source, "rev-parse", "HEAD")
local root, lockfile = H.root .. "/packages", H.root .. "/lock.json"
local function manager(extra)
  local opts = { root = root, lockfile = lockfile, specs = { { id = "source", source = source } } }
  return Tools.new(vim.tbl_extend("force", opts, extra or {}))
end
local m = manager()
local second

H.case("asynchronous install publishes checkout and precise lockfile", function()
  local task = m:install()
  H.eq(task.done, false)
  H.raises(function()
    m:install()
  end, "already running")
  H.wait(task)
  H.eq(H.git(root .. "/source", "rev-parse", "HEAD"), initial)
  H.eq(U.read_json(lockfile).plugins.source.commit, initial)
  H.eq(vim.fn.readfile(lockfile), {
    "{",
    '  "plugins": {',
    '    "source": {',
    '      "commit": "' .. initial .. '",',
    '      "source": ' .. vim.json.encode(source),
    "    }",
    "  },",
    '  "version": 1',
    "}",
  })
  local formatted = vim.fn.readfile(lockfile, "b")
  H.wait(m:freeze())
  H.eq(vim.fn.readfile(lockfile, "b"), formatted)
  H.eq(U.read_json(root .. "/source/.git/plugin-tools-owner.json").id, "source")
  H.eq(vim.uv.fs_stat(root .. "/.operation-lock"), nil)
end)

H.case("install respects lock; update moves branch; restore reproduces old revision", function()
  local old_lock = vim.fn.readfile(lockfile)
  H.write(source .. "/next", "new")
  second = H.commit(source, "second")
  H.wait(m:install())
  H.eq(H.git(root .. "/source", "rev-parse", "HEAD"), initial)
  H.wait(m:update())
  H.eq(H.git(root .. "/source", "rev-parse", "HEAD"), second)
  vim.fn.writefile(old_lock, lockfile)
  H.wait(m:restore())
  H.eq(H.git(root .. "/source", "rev-parse", "HEAD"), initial)
  H.git(root .. "/source", "checkout", "-q", second)
  H.wait(m:freeze())
  H.eq(U.read_json(lockfile).plugins.source.commit, second)
end)

H.case("local changes are preserved and reject update", function()
  H.write(root .. "/source/untracked", "keep me")
  H.wait(m:update(), "local modifications")
  H.eq(vim.fn.readfile(root .. "/source/untracked"), { "keep me" })
  vim.fn.delete(root .. "/source/untracked")
end)

H.case("failed build leaves every checkout and lock untouched", function()
  local before = vim.fn.readfile(lockfile)
  H.write(source .. "/third", "third")
  H.commit(source, "third")
  local broken = manager({
    specs = {
      {
        id = "source",
        source = source,
        build = function()
          error("broken build")
        end,
      },
    },
  })
  H.wait(broken:update(), "broken build")
  H.eq(H.git(root .. "/source", "rev-parse", "HEAD"), second)
  H.eq(vim.fn.readfile(lockfile), before)
  local scan = vim.fn.glob(root .. "/.stage-*", false, true)
  H.eq(scan, {})
end)

H.case("parallel staging waits for all workers before rollback", function()
  local broken = manager({
    concurrency = 2,
    specs = {
      { id = "source", source = source },
      { id = "bad", source = H.root .. "/not-a-repository" },
    },
  })
  H.wait(broken:update(), "failed")
  H.eq(H.git(root .. "/source", "rev-parse", "HEAD"), second)
  H.eq(vim.uv.fs_stat(root .. "/bad"), nil)
  H.eq(vim.fn.glob(root .. "/.stage-*", false, true), {})
end)

H.case("lockfile write failure rolls back published checkouts", function()
  local invalid = H.root .. "/directory-instead-of-file"
  vim.fn.mkdir(invalid, "p")
  -- Fail publication only after reading a valid lockfile.
  local write = U.write_json
  U.write_json = function(path, value)
    if path == lockfile then
      error("simulated lock write failure")
    end
    return write(path, value)
  end
  H.wait(m:update(), "simulated lock write failure")
  U.write_json = write
  H.eq(H.git(root .. "/source", "rev-parse", "HEAD"), second)
end)

H.case("operations exclude other managers and release lock after failure", function()
  vim.fn.mkdir(root .. "/.operation-lock", "p")
  H.wait(m:update(), "operation lock unavailable")
  assert(vim.uv.fs_stat(root .. "/.operation-lock"))
  vim.fn.delete(root .. "/.operation-lock", "rf")
  H.wait(m:freeze())
end)

H.case("invalid options leave the manager usable", function()
  H.raises(function()
    m:update({ concurrency = 0 })
  end, "positive integer")
  H.eq(m.operation, nil)
  H.wait(m:freeze())
end)

H.case("unrecorded local commits are preserved", function()
  H.git(root .. "/source", "checkout", "-q", initial)
  H.wait(m:update(), "checkout differs from lockfile")
  H.eq(H.git(root .. "/source", "rev-parse", "HEAD"), initial)
  H.git(root .. "/source", "checkout", "-q", second)
end)

H.case("an unrelated directory created during staging survives", function()
  local intruder = manager({
    specs = {
      {
        id = "intruder",
        source = source,
        build = function()
          H.write(root .. "/intruder/preserve", "created during staging")
        end,
      },
    },
  })
  H.wait(intruder:install(), "appeared during operation")
  H.eq(vim.fn.readfile(root .. "/intruder/preserve"), { "created during staging" })
end)

H.case("slow build processes leave the event loop responsive", function()
  local ticked = false
  local slow = manager({
    root = H.root .. "/slow-packages",
    lockfile = H.root .. "/slow-lock.json",
    specs = { { id = "slow", source = source, build = { "sh", "-c", "sleep 0.1" } } },
  })
  vim.defer_fn(function()
    ticked = true
  end, 30)
  H.wait(slow:install())
  H.eq(ticked, true)
end)

H.case("help tags, build argv, version branches and shared package selection", function()
  local branch = H.repo("branch")
  H.git(branch, "checkout", "-qb", "feature")
  H.write(branch .. "/doc/test.txt", "*plugin-tools-test* help\n")
  H.write(branch .. "/.gitignore", "generated\n")
  local revision = H.commit(branch, "feature")
  local shared = manager({
    specs = {
      {
        id = "branch",
        source = branch,
        version = "feature",
        build = { "sh", "-c", "printf built > generated" },
        children = { { id = "branch.child" } },
      },
    },
  })
  H.wait(shared:install({ ids = { "branch.child" } }))
  H.eq(H.git(root .. "/branch", "rev-parse", "HEAD"), revision)
  assert(vim.uv.fs_stat(root .. "/branch/doc/tags"))
  H.eq(vim.fn.readfile(root .. "/branch/generated"), { "built" })
end)

H.case("clean protects checkouts moved away from the recorded commit", function()
  local dir = root .. "/branch"
  local current = H.git(dir, "rev-parse", "HEAD")
  H.git(
    dir,
    "-c",
    "user.name=Plugin Tools Test",
    "-c",
    "user.email=plugin-tools@example.invalid",
    "-c",
    "commit.gpgsign=false",
    "commit",
    "--allow-empty",
    "-qm",
    "local-only commit"
  )
  H.wait(m:clean({ dry_run = false }), "checkout differs from recorded revision")
  assert(vim.uv.fs_stat(dir))
  H.git(dir, "checkout", "-q", current)
end)

H.case("clean previews then removes only unreferenced owned checkouts", function()
  H.write(root .. "/unowned/preserve", "keep")
  local result = H.wait(m:clean())
  H.eq(result.packages, { "branch" })
  assert(vim.uv.fs_stat(root .. "/branch"))
  H.wait(m:clean({ dry_run = false }))
  H.eq(vim.uv.fs_stat(root .. "/branch"), nil)
  assert(vim.uv.fs_stat(root .. "/source"))
  assert(vim.uv.fs_stat(root .. "/unowned/preserve"))
end)

H.case("external directories and development checkouts are never installed or cleaned", function()
  local external = H.root .. "/external"
  vim.fn.mkdir(external, "p")
  local local_only = manager({ specs = { { id = "external", dir = external } } })
  H.eq(H.wait(local_only:install()).packages, {})
  H.wait(local_only:clean())
  assert(vim.uv.fs_stat(external))
end)

H.case("source mismatch and malformed lockfile are explicit failures", function()
  local data = U.read_json(lockfile)
  data.plugins.source.source = "other"
  U.write_json(lockfile, data)
  H.wait(m:restore(), "lockfile source differs")
  H.write(lockfile, "{not json}")
  H.wait(m:install(), "invalid JSON")
end)

H.case("unchanged updates skip builds and publication while rebuild and recipe changes are explicit", function()
  local counter = H.root .. "/build-count"
  local args = { "sh", "-c", 'printf built >> "$1"', "build", counter }
  local same = manager({
    root = H.root .. "/same",
    lockfile = H.root .. "/same-lock.json",
    specs = { { id = "source", source = source, build = args } },
  })
  H.wait(same:install())
  same:start()
  local dir = same.graph.packages.source.dir
  local ino = vim.uv.fs_stat(dir).ino
  local lock_stat = vim.uv.fs_stat(same.lockfile)
  local report = H.wait(same:plan())
  H.eq(report.details[1].build, false)
  local applied = H.wait(same:update({ plan = report }))
  H.eq(applied.details[1].phase, "unchanged")
  H.eq(applied.restart_required, false)
  H.eq(vim.uv.fs_stat(dir).ino, ino)
  H.eq(vim.uv.fs_stat(same.lockfile).mtime, lock_stat.mtime)
  H.eq(vim.fn.readfile(counter), { "built" })
  H.wait(same:update({ rebuild = true }))
  H.eq(vim.fn.readfile(counter), { "builtbuilt" })
  same.graph.packages.source.build = vim.list_extend(vim.deepcopy(args), { "changed-recipe" })
  H.wait(same:update())
  H.eq(vim.fn.readfile(counter), { "builtbuiltbuilt" })
  local marker = U.read_json(dir .. "/.git/plugin-tools-owner.json")
  marker.build = nil
  U.write_json(dir .. "/.git/plugin-tools-owner.json", marker)
  H.wait(same:update())
  H.eq(vim.fn.readfile(counter), { "builtbuiltbuiltbuilt" })
  local calls = 0
  same.graph.packages.source.build = function()
    calls = calls + 1
  end
  H.wait(same:update())
  H.wait(same:update())
  H.eq(calls, 2)
  same.graph.packages.source.build = nil
  H.wait(same:update())
  H.eq(U.read_json(dir .. "/.git/plugin-tools-owner.json").build, false)
  H.eq(H.wait(same:update()).details[1].phase, "unchanged")
  local rebuild_plan = H.wait(same:plan({ rebuild = true }))
  H.raises(function()
    same:update({ plan = rebuild_plan, rebuild = false })
  end, "fixed by the reviewed plan")
  H.eq(H.wait(same:update({ plan = rebuild_plan })).details[1].phase, "updated")
end)
H.finish()
