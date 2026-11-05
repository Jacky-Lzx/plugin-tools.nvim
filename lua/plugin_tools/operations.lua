local U = require("plugin_tools.util")
local uv = vim.uv
local M = {}

local function lock_data(manager)
  local data = U.read_json(manager.lockfile, { version = 1, plugins = {} })
  U.check(data.version == 1 and type(data.plugins) == "table", "unsupported lockfile " .. manager.lockfile)
  for id, entry in pairs(data.plugins) do
    U.check(
      type(id) == "string"
        and type(entry) == "table"
        and type(entry.source) == "string"
        and type(entry.commit) == "string"
        and entry.commit:match("^%x+$")
        and #entry.commit == 40,
      "invalid lockfile entry " .. tostring(id)
    )
  end
  return data
end

local function owned(package)
  local stat = uv.fs_lstat(package.dir)
  if not stat then
    return false
  end
  U.check(stat.type == "directory", "refusing non-directory package " .. package.dir)
  local git = uv.fs_lstat(package.dir .. "/.git")
  U.check(git and git.type == "directory", "refusing unmanaged checkout " .. package.dir)
  local marker = U.read_json(package.dir .. "/.git/plugin-tools-owner.json", {})
  U.check(marker.id == package.id and marker.source == package.source, "ownership/source mismatch for " .. package.dir)
  return true, marker
end

local function selected(manager, opts)
  local wanted = {}
  if opts.ids then
    U.check(type(opts.ids) == "table" and vim.islist(opts.ids), "ids must be a list")
    for _, id in ipairs(opts.ids) do
      local n = manager.graph.nodes[id]
      U.check(n, "unknown plugin " .. tostring(id))
      wanted[n.owner] = true
    end
  end
  local out = {}
  for _, id in ipairs(manager.graph.package_order) do
    local p = manager.graph.packages[id]
    if p.managed and (not opts.ids or wanted[id]) then
      out[#out + 1] = p
    end
  end
  return out
end

-- One coroutine per operation, with bounded asynchronous staging workers. All
-- filesystem publication happens on the main thread after every worker succeeds.
function M.run(manager, action, opts)
  U.check(not manager.operation, "an operation is already running on this manager")
  local task = { done = false, action = action }
  local root, staging, swaps, locked = manager.graph.root, {}, {}, false
  local lockdir = root .. "/.operation-lock"
  local timeout = opts.timeout or manager.options.git_timeout or 120000
  local concurrency = opts.concurrency or manager.options.concurrency or 4
  U.check(
    type(concurrency) == "number" and concurrency >= 1 and concurrency % 1 == 0,
    "concurrency must be a positive integer"
  )
  U.check(type(timeout) == "number" and timeout > 0, "timeout must be a positive number")
  manager.operation = task
  local co

  local function resume(thread, ...)
    local ok, err = coroutine.resume(thread, ...)
    if not ok then
      -- Expected errors are caught by the transaction's xpcall.
      task.done, task.error, manager.operation = true, tostring(err), nil
    end
  end

  local function process(argv, cwd)
    local thread = coroutine.running()
    U.check(thread, "internal process call outside operation")
    local ok, err = pcall(
      vim.system,
      argv,
      { cwd = cwd, text = true, timeout = timeout, env = { GIT_TERMINAL_PROMPT = "0" } },
      function(result)
        vim.schedule(function()
          resume(thread, result)
        end)
      end
    )
    U.check(ok, "cannot start " .. tostring(argv[1]) .. ": " .. tostring(err))
    local result = coroutine.yield()
    local output = result.stderr and result.stderr ~= "" and result.stderr or result.stdout or ""
    U.check(
      result.code == 0,
      table.concat(argv, " ") .. " failed: " .. output .. " (exit " .. tostring(result.code) .. ")"
    )
    return vim.trim(result.stdout or "")
  end

  local function git(dir, ...)
    local argv = { "git", "-c", "advice.detachedHead=false", "-C", dir }
    vim.list_extend(argv, { ... })
    return process(argv)
  end

  local function clean_staging()
    for _, path in ipairs(staging) do
      vim.fn.delete(path, "rf")
    end
  end

  local function stage(package, mode, lock)
    local exists, marker = owned(package)
    local previous_commit
    if exists then
      U.check(
        git(package.dir, "status", "--porcelain", "--untracked-files=normal") == "",
        "local modifications in " .. package.dir
      )
      previous_commit = git(package.dir, "rev-parse", "HEAD")
    end
    local entry = lock.plugins[package.id]
    if mode == "update" and exists then
      U.check(
        (not entry or entry.source == package.source) and (entry and entry.commit or marker.commit) == previous_commit,
        package.id .. ": checkout differs from lockfile; use freeze() or restore() first"
      )
    end
    if mode == "install" and exists then
      local commit = previous_commit
      U.check(
        not entry or (entry.source == package.source and entry.commit == commit),
        package.id .. ": installed version differs from lockfile; use restore() or freeze()"
      )
      return { package = package, commit = commit, unchanged = true }
    end
    if entry and mode ~= "update" then
      U.check(entry.source == package.source, package.id .. ": lockfile source differs from spec")
    end
    U.check(mode ~= "restore" or entry, package.id .. ": no locked revision to restore")
    local temporary, err = uv.fs_mkdtemp(root .. "/.stage-" .. package.id .. "-XXXXXX")
    U.check(temporary, "cannot stage " .. package.id .. ": " .. tostring(err))
    staging[#staging + 1] = temporary
    local checkout = temporary .. "/checkout"
    local clone = { "git", "clone", "--quiet", "--filter=blob:none", "--no-checkout" }
    if exists then
      vim.list_extend(clone, { "--reference-if-able", package.dir, "--dissociate" })
    end
    vim.list_extend(clone, { "--", package.source, checkout })
    process(clone)
    local ref = (mode ~= "update" and entry and entry.commit) or package.version or "HEAD"
    U.check(not ref:match("^-"), package.id .. ": version cannot begin with '-' ")
    -- Git clone stores remote branches under refs/remotes/origin; prefer an
    -- explicit branch/tag and only then accept a commit-ish.
    local revision
    if ref == "HEAD" or (#ref == 40 and ref:match("^%x+$")) or ref:match("^refs/") then
      revision = git(checkout, "rev-parse", "--verify", ref .. "^{commit}")
    else
      local refs =
        git(checkout, "for-each-ref", "--format=%(refname)", "refs/remotes/origin/" .. ref, "refs/tags/" .. ref)
      local branch = "refs/remotes/origin/" .. ref
      if vim.list_contains(vim.split(refs, "\n", { plain = true }), branch) then
        ref = branch
      end
      revision = git(checkout, "rev-parse", "--verify", ref .. "^{commit}")
    end
    git(checkout, "checkout", "--quiet", "--detach", revision)
    git(checkout, "submodule", "update", "--init", "--recursive")
    U.write_json(
      checkout .. "/.git/plugin-tools-owner.json",
      { id = package.id, source = package.source, commit = revision }
    )
    if package.build then
      if type(package.build) == "function" then
        package.build({ id = package.id, dir = checkout })
      else
        process(package.build, checkout)
      end
    end
    if U.directory(checkout .. "/doc") then
      vim.api.nvim_cmd({ cmd = "helptags", args = { checkout .. "/doc" } }, {})
      -- Generated help tags are manager-owned build artifacts.
      local exclude = assert(io.open(checkout .. "/.git/info/exclude", "a"))
      exclude:write("\n/doc/tags\n/doc/tags-*\n")
      exclude:close()
    end
    -- Build outputs must be ignored by the plugin itself; tracked modifications
    -- would otherwise make the next update fail or silently discard changes.
    U.check(
      git(checkout, "status", "--porcelain", "--untracked-files=normal") == "",
      package.id .. ": build left a dirty checkout; ignore generated outputs"
    )
    return {
      package = package,
      commit = revision,
      checkout = checkout,
      temporary = temporary,
      existed = exists,
      previous_commit = previous_commit,
    }
  end

  local function stage_all(packages, mode, lock)
    local parent, next_index, remaining, failed = coroutine.running(), 1, math.min(concurrency, #packages), nil
    if remaining == 0 then
      return {}
    end
    local results = {}
    for _ = 1, remaining do
      local worker = coroutine.create(function()
        while not failed and next_index <= #packages do
          local index = next_index
          next_index = index + 1
          local ok, result = xpcall(function()
            return stage(packages[index], mode, lock)
          end, debug.traceback)
          if not ok then
            failed = result
          else
            results[index] = result
          end
        end
        remaining = remaining - 1
        if remaining == 0 then
          vim.schedule(function()
            resume(parent)
          end)
        end
      end)
      resume(worker)
    end
    coroutine.yield()
    U.check(not failed, tostring(failed))
    return results
  end

  local function execute()
    U.check(
      not uv.fs_lstat(root) or uv.fs_lstat(root).type == "directory",
      "refusing symlink/non-directory root " .. root
    )
    U.mkdir(root)
    local acquired, err = uv.fs_mkdir(lockdir, 448)
    U.check(acquired, "operation lock unavailable at " .. lockdir .. ": " .. tostring(err))
    locked = true
    U.write_json(lockdir .. "/owner.json", { pid = uv.os_getpid(), action = action })
    local lock, packages = lock_data(manager), selected(manager, opts)
    if action == "clean" then
      U.check(not opts.ids, "clean operates on the complete graph; ids are not supported")
      local unused = {}
      local scan = uv.fs_scandir(root)
      while scan do
        local name, kind = uv.fs_scandir_next(scan)
        if not name then
          break
        end
        if kind == "directory" and not name:match("^%.") and not manager.graph.packages[name] then
          local dir = root .. "/" .. name
          local marker = U.read_json(dir .. "/.git/plugin-tools-owner.json", {})
          if marker.id == name and type(marker.source) == "string" then
            local p = { id = name, dir = dir, source = marker.source }
            owned(p)
            U.check(
              git(dir, "status", "--porcelain", "--untracked-files=normal") == "",
              "local modifications in " .. dir
            )
            local entry = lock.plugins[name]
            U.check(
              (not entry or entry.source == marker.source)
                and (entry and entry.commit or marker.commit) == git(dir, "rev-parse", "HEAD"),
              name .. ": checkout differs from recorded revision; preserve local commits before cleaning"
            )
            unused[#unused + 1] = p
          end
        end
      end
      table.sort(unused, function(a, b)
        return a.id < b.id
      end)
      if opts.dry_run == false then
        for _, p in ipairs(unused) do
          local temp = assert(uv.fs_mkdtemp(root .. "/.stage-clean-XXXXXX"))
          staging[#staging + 1] = temp
          local backup = temp .. "/previous"
          U.check(uv.fs_rename(p.dir, backup), "cannot remove " .. p.dir)
          swaps[#swaps + 1] = { dir = p.dir, backup = backup }
          lock.plugins[p.id] = nil
        end
        U.write_json(manager.lockfile, lock)
      end
      return {
        action = action,
        dry_run = opts.dry_run ~= false,
        packages = vim.tbl_map(function(p)
          return p.id
        end, unused),
      }
    end
    if action == "freeze" then
      for _, p in ipairs(packages) do
        U.check(owned(p), "missing checkout " .. p.dir)
        U.check(
          git(p.dir, "status", "--porcelain", "--untracked-files=normal") == "",
          "local modifications in " .. p.dir
        )
        lock.plugins[p.id] = { source = p.source, commit = git(p.dir, "rev-parse", "HEAD") }
      end
    else
      local results = stage_all(packages, action, lock)
      -- All builds succeeded. Publish complete directories, retaining backups
      -- until the lockfile's atomic replacement succeeds.
      for _, result in ipairs(results) do
        local p = result.package
        if not result.unchanged then
          local swap = { dir = p.dir }
          if result.existed then
            -- Recheck after asynchronous work before moving an existing tree.
            owned(p)
            U.check(
              git(p.dir, "status", "--porcelain", "--untracked-files=normal") == "",
              "local modifications in " .. p.dir
            )
            U.check(
              git(p.dir, "rev-parse", "HEAD") == result.previous_commit,
              p.id .. ": checkout changed during operation"
            )
            swap.backup = result.temporary .. "/previous"
            U.check(uv.fs_rename(p.dir, swap.backup), "cannot back up " .. p.dir)
          else
            U.check(not uv.fs_lstat(p.dir), "package directory appeared during operation: " .. p.dir)
          end
          swaps[#swaps + 1] = swap
          U.check(uv.fs_rename(result.checkout, p.dir), "cannot publish " .. p.dir)
          swap.published = true
        end
        lock.plugins[p.id] = { source = p.source, commit = result.commit }
      end
    end
    U.write_json(manager.lockfile, lock)
    return {
      action = action,
      packages = vim.tbl_map(function(p)
        return p.id
      end, packages),
      lockfile = manager.lockfile,
      restart_required = manager.started,
    }
  end

  co = coroutine.create(function()
    local ok, result = xpcall(execute, debug.traceback)
    if not ok then
      local rollback_errors = {}
      for i = #swaps, 1, -1 do
        local swap = swaps[i]
        if swap.published and uv.fs_lstat(swap.dir) then
          local removed = vim.fn.delete(swap.dir, "rf")
          if removed ~= 0 then
            rollback_errors[#rollback_errors + 1] = "cannot remove " .. swap.dir
          end
        end
        if swap.backup then
          local restored, err = uv.fs_rename(swap.backup, swap.dir)
          if not restored then
            rollback_errors[#rollback_errors + 1] = "backup retained at " .. swap.backup .. ": " .. tostring(err)
          end
        end
      end
      if #rollback_errors == 0 then
        clean_staging()
      else
        result = result .. "\nROLLBACK: " .. table.concat(rollback_errors, "; ")
      end
    else
      clean_staging()
    end
    if locked then
      vim.fn.delete(lockdir, "rf")
    end
    task.done, task.result, task.error, manager.operation = true, ok and result or nil, not ok and result or nil, nil
    if opts.on_complete then
      local callback_ok, callback_err = pcall(opts.on_complete, task.result, task.error)
      if not callback_ok then
        vim.notify(tostring(callback_err), vim.log.levels.ERROR)
      end
    end
  end)

  function task:wait(milliseconds)
    local finished = self.done or vim.wait(milliseconds or 300000, function()
      return self.done
    end, 10)
    if not finished then
      return nil, "operation still running (wait timed out)"
    end
    return self.result, self.error
  end
  vim.schedule(function()
    resume(co)
  end)
  return task
end

return M
