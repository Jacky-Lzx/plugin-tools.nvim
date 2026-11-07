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
  local reviewed = opts.plan and manager.reviewed_plan
  if opts.plan then
    U.check(action == "update" and not opts.ids, "apply a plan with update({plan=report}) and no ids")
    U.check(reviewed and reviewed.report == opts.plan, "plan must be the latest successful preview from this manager")
  end
  local root, staging, swaps, locked = manager.graph.root, {}, {}, false
  local lockdir = root .. "/.operation-lock"
  local timeout = opts.timeout or manager.options.git_timeout or 120000
  local concurrency = opts.concurrency or manager.options.concurrency or 4
  U.check(
    type(concurrency) == "number" and concurrency >= 1 and concurrency % 1 == 0,
    "concurrency must be a positive integer"
  )
  U.check(type(timeout) == "number" and timeout > 0, "timeout must be a positive number")
  local task = require("plugin_tools.task").new(action, opts)
  manager.last_operation = task
  manager.operation = task
  local co
  local worker_ids = {}
  local transaction, keep_lock, review

  local function resume(thread, ...)
    local ok, err = coroutine.resume(thread, ...)
    if not ok then
      -- Expected errors are caught by the transaction's xpcall.
      task:finish(nil, tostring(err))
      manager.operation = nil
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
    local handle, process_key, journal_error = err
    if transaction then
      process_key = tostring(handle.pid)
      transaction.data.processes[process_key] = { pid = handle.pid, command = argv[1] }
      local saved, save_err = pcall(transaction.save, transaction)
      if not saved then
        journal_error = tostring(save_err)
        handle:kill(15)
      end
    end
    local result = coroutine.yield()
    if process_key then
      transaction.data.processes[process_key] = nil
      local saved, save_err = pcall(transaction.save, transaction)
      if not saved then
        journal_error = journal_error or tostring(save_err)
      end
    end
    task:log(worker_ids[thread], argv, result)
    U.check(not journal_error, "cannot journal process: " .. tostring(journal_error))
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
    local errors = {}
    if transaction then
      local saved, err = pcall(transaction.cleanup_start, transaction)
      if not saved then
        return { tostring(err) }
      end
    end
    for _, path in ipairs(staging) do
      if uv.fs_lstat(path) and vim.fn.delete(path, "rf") ~= 0 then
        errors[#errors + 1] = "cannot clean " .. path
      end
    end
    return errors
  end

  local function changes(checkout, package, before, after)
    local out = {
      kind = not before and "install" or "unchanged",
      commits = {},
      files = {},
      ahead = 0,
      behind = 0,
      files_changed = 0,
      insertions = 0,
      deletions = 0,
      binary_files = 0,
    }
    if not before or before == after then
      return out
    end
    -- A force-pushed source may no longer contain the installed commit. Import
    -- that exact local object into staging without modifying the installed repo.
    git(checkout, "fetch", "--quiet", "--no-tags", "--", package.dir, before)
    local counts = git(checkout, "rev-list", "--left-right", "--count", before .. "..." .. after)
    local behind, ahead = counts:match("^(%d+)%s+(%d+)$")
    U.check(behind and ahead, "invalid Git history counts")
    out.behind, out.ahead = tonumber(behind), tonumber(ahead)
    out.kind = out.behind == 0 and "forward" or out.ahead == 0 and "rewind" or "diverged"
    local log = git(checkout, "log", "--format=%H%x09%s", "--max-count=20", before .. ".." .. after, "--")
    for line in log:gmatch("[^\n]+") do
      local commit, subject = line:match("^(%x+)%s(.*)$")
      if commit then
        out.commits[#out.commits + 1] = { commit = commit, subject = subject }
      end
    end
    out.commits_truncated = out.ahead > #out.commits
    local stats =
      git(checkout, "diff", "--numstat", "--no-ext-diff", "--no-textconv", "--no-renames", before, after, "--")
    for line in stats:gmatch("[^\n]+") do
      local added, removed, path = line:match("^([^\t]+)\t([^\t]+)\t(.*)$")
      if path then
        local binary = added == "-" or removed == "-"
        out.files_changed = out.files_changed + 1
        out.insertions = out.insertions + (tonumber(added) or 0)
        out.deletions = out.deletions + (tonumber(removed) or 0)
        out.binary_files = out.binary_files + (binary and 1 or 0)
        if #out.files < 50 then
          out.files[#out.files + 1] =
            { path = path, added = tonumber(added), removed = tonumber(removed), binary = binary }
        end
      end
    end
    out.files_truncated = out.files_changed > #out.files
    return out
  end

  local function stage(package, mode, lock)
    task:emit("checking", package.id)
    local exists, marker = owned(package)
    local previous_commit
    if exists then
      U.check(
        git(package.dir, "status", "--porcelain", "--untracked-files=normal") == "",
        "local modifications in " .. package.dir
      )
      previous_commit = git(package.dir, "rev-parse", "HEAD")
    end
    task:emit("checking", package.id, { before_commit = previous_commit })
    local preview = reviewed and reviewed.entries[package.id]
    if preview then
      U.check(
        preview.source == package.source
          and preview.version == package.version
          and vim.deep_equal(preview.build, package.build),
        package.id .. ": configuration changed since preview; create a new plan"
      )
      U.check(preview.before_commit == previous_commit, package.id .. ": checkout changed since preview")
    end
    local entry = lock.plugins[package.id]
    local updating = mode == "update" or mode == "plan"
    if updating and exists then
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
      task:emit("staged", package.id, { after_commit = commit, unchanged = true })
      return { package = package, commit = commit, unchanged = true }
    end
    if entry and not updating then
      U.check(entry.source == package.source, package.id .. ": lockfile source differs from spec")
    end
    U.check(mode ~= "restore" or entry, package.id .. ": no locked revision to restore")
    local temporary, err = uv.fs_mkdtemp(root .. "/.stage-" .. package.id .. "-XXXXXX")
    U.check(temporary, "cannot stage " .. package.id .. ": " .. tostring(err))
    staging[#staging + 1] = temporary
    transaction:stage(temporary)
    local checkout = temporary .. "/checkout"
    local clone = { "git", "clone", "--quiet", "--filter=blob:none", "--no-checkout" }
    if exists then
      vim.list_extend(clone, { "--reference-if-able", package.dir, "--dissociate" })
    end
    vim.list_extend(clone, { "--", package.source, checkout })
    task:emit("cloning", package.id)
    process(clone)
    local ref = (preview and preview.after_commit)
      or (not updating and entry and entry.commit)
      or package.version
      or "HEAD"
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
    task:emit(mode == "plan" and "resolved" or "checkout", package.id, { after_commit = revision })
    if mode == "plan" then
      task:emit("resolved", package.id, { changes = changes(checkout, package, previous_commit, revision) })
      return { package = package, commit = revision, previous_commit = previous_commit }
    end
    git(checkout, "checkout", "--quiet", "--detach", revision)
    task:emit("submodules", package.id)
    git(checkout, "submodule", "update", "--init", "--recursive")
    U.write_json(
      checkout .. "/.git/plugin-tools-owner.json",
      { id = package.id, source = package.source, commit = revision, transaction = transaction.data.id }
    )
    if package.build then
      task:emit("building", package.id)
      if type(package.build) == "function" then
        package.build({ id = package.id, dir = checkout })
      else
        process(package.build, checkout)
      end
    end
    if U.directory(checkout .. "/doc") then
      task:emit("helptags", package.id)
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
    task:emit("staged", package.id)
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
          worker_ids[coroutine.running()] = packages[index].id
          local ok, result = xpcall(function()
            return stage(packages[index], mode, lock)
          end, debug.traceback)
          if not ok then
            task:fail(packages[index].id, result)
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
    task:emit("locking")
    U.check(
      not uv.fs_lstat(root) or uv.fs_lstat(root).type == "directory",
      "refusing symlink/non-directory root " .. root
    )
    U.mkdir(root)
    if action == "recover" then
      U.check(not opts.ids, "recover does not accept ids")
      return require("plugin_tools.transaction").recover(manager, opts, git, task)
    end
    local acquired, err = uv.fs_mkdir(lockdir, 448)
    U.check(acquired, "operation lock unavailable at " .. lockdir .. ": " .. tostring(err))
    locked = true
    U.write_json(lockdir .. "/owner.json", { pid = uv.os_getpid(), action = action })
    local lock, packages = lock_data(manager), selected(manager, opts)
    if reviewed then
      packages = selected(manager, { ids = reviewed.ids })
    end
    transaction = require("plugin_tools.transaction").begin(manager, action, lock, staging, swaps)
    task:select(action == "clean" and {} or packages)
    for _, p in ipairs(packages) do
      local components = {}
      for _, id in ipairs(manager.graph.order) do
        if manager.graph.nodes[id].owner == p.id then
          components[#components + 1] = id
        end
      end
      if task.items[p.id] then
        task.items[p.id].components = components
      end
    end
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
      task:select(unused)
      if opts.dry_run == false then
        for _, p in ipairs(unused) do
          worker_ids[coroutine.running()] = p.id
          task:emit("removing", p.id)
          local temp = assert(uv.fs_mkdtemp(root .. "/.stage-clean-XXXXXX"))
          staging[#staging + 1] = temp
          transaction:stage(temp)
          local backup = temp .. "/previous"
          swaps[#swaps + 1] = {
            id = p.id,
            source = p.source,
            dir = p.dir,
            backup = backup,
            before_commit = git(p.dir, "rev-parse", "HEAD"),
            clean = true,
          }
          transaction:phase("publishing")
          U.check(uv.fs_rename(p.dir, backup), "cannot remove " .. p.dir)
          lock.plugins[p.id] = nil
        end
        transaction:target(lock)
        U.write_json(manager.lockfile, lock)
      end
      transaction:phase("committed")
      for _, p in ipairs(unused) do
        task:complete(p.id, opts.dry_run == false and "removed" or "previewed")
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
        worker_ids[coroutine.running()] = p.id
        task:emit("checking", p.id, { before_commit = lock.plugins[p.id] and lock.plugins[p.id].commit })
        U.check(owned(p), "missing checkout " .. p.dir)
        U.check(
          git(p.dir, "status", "--porcelain", "--untracked-files=normal") == "",
          "local modifications in " .. p.dir
        )
        lock.plugins[p.id] = { source = p.source, commit = git(p.dir, "rev-parse", "HEAD") }
        task:emit("staged", p.id, { after_commit = lock.plugins[p.id].commit })
      end
    else
      local results = stage_all(packages, action, lock)
      if action == "plan" then
        review = { ids = {}, entries = {} }
        for _, result in ipairs(results) do
          local p = result.package
          review.ids[#review.ids + 1] = p.id
          review.entries[p.id] = {
            source = p.source,
            version = p.version,
            build = type(p.build) == "table" and vim.deepcopy(p.build) or p.build,
            before_commit = result.previous_commit,
            after_commit = result.commit,
          }
          task:complete(p.id, "planned")
        end
        transaction:phase("committed")
        return { action = "plan", packages = vim.list_slice(review.ids), dry_run = true, restart_required = false }
      end
      -- All builds succeeded. Publish complete directories, retaining backups
      -- until the lockfile's atomic replacement succeeds.
      for _, result in ipairs(results) do
        local p = result.package
        worker_ids[coroutine.running()] = p.id
        if not result.unchanged then
          task:emit("publishing", p.id)
          local swap = {
            id = p.id,
            source = p.source,
            dir = p.dir,
            before_commit = result.previous_commit,
            after_commit = result.commit,
          }
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
            swaps[#swaps + 1] = swap
            transaction:phase("publishing")
            U.check(uv.fs_rename(p.dir, swap.backup), "cannot back up " .. p.dir)
          else
            U.check(not uv.fs_lstat(p.dir), "package directory appeared during operation: " .. p.dir)
            swaps[#swaps + 1] = swap
            transaction:phase("publishing")
          end
          U.check(uv.fs_rename(result.checkout, p.dir), "cannot publish " .. p.dir)
          swap.published = true
          transaction:save()
        end
        lock.plugins[p.id] = { source = p.source, commit = result.commit }
      end
    end
    transaction:target(lock)
    U.write_json(manager.lockfile, lock)
    transaction:phase("committed")
    for _, p in ipairs(packages) do
      local item = task.items[p.id]
      local phases = { install = "installed", update = "updated", restore = "restored", freeze = "frozen" }
      task:complete(p.id, item.unchanged and "unchanged" or phases[action])
    end
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
      if not task.failure then
        task:fail(worker_ids[coroutine.running()], result)
      end
      local rollback_errors = {}
      task:emit("rolling_back")
      if transaction then
        local saved, err = pcall(transaction.phase, transaction, "rolling_back")
        if not saved then
          rollback_errors[#rollback_errors + 1] = tostring(err)
        end
      end
      for i = #swaps, 1, -1 do
        local swap = swaps[i]
        if swap.published and uv.fs_lstat(swap.dir) then
          local removed = vim.fn.delete(swap.dir, "rf")
          if removed ~= 0 then
            rollback_errors[#rollback_errors + 1] = "cannot remove " .. swap.dir
          end
        end
        if swap.backup and uv.fs_lstat(swap.backup) then
          local restored, err = uv.fs_rename(swap.backup, swap.dir)
          if not restored then
            rollback_errors[#rollback_errors + 1] = "backup retained at " .. swap.backup .. ": " .. tostring(err)
          end
        end
      end
      if transaction then
        local restored, err = pcall(transaction.restore_lock, transaction)
        if not restored then
          rollback_errors[#rollback_errors + 1] = tostring(err)
        end
      end
      if #rollback_errors == 0 then
        if transaction then
          local saved, err = pcall(transaction.phase, transaction, "rolled_back")
          if not saved then
            rollback_errors[#rollback_errors + 1] = tostring(err)
          end
        end
        if #rollback_errors == 0 then
          rollback_errors = clean_staging()
        end
      end
      if #rollback_errors > 0 then
        keep_lock = true
        if transaction then
          pcall(transaction.phase, transaction, "rollback_failed")
        end
        if transaction then
          pcall(transaction.finished, transaction)
        end
        result = result .. "\nROLLBACK: " .. table.concat(rollback_errors, "; ")
      end
      for _, id in ipairs(task.order) do
        local item = task.items[id]
        if item.phase ~= "failed" then
          task:emit(#rollback_errors > 0 and "recovery_required" or "rolled_back", id)
        end
      end
    else
      local errors = clean_staging()
      if #errors > 0 then
        keep_lock = true
        result.recovery_required = true
        result.cleanup_errors = errors
        if transaction then
          pcall(transaction.finished, transaction)
        end
      end
    end
    if locked and not keep_lock then
      if vim.fn.delete(lockdir, "rf") ~= 0 then
        if ok then
          result.recovery_required = true
        end
        if transaction then
          pcall(transaction.finished, transaction)
        end
      end
    end
    task:finish(ok and result or nil, not ok and result or nil)
    if ok and review then
      review.report = task.result
      manager.reviewed_plan, manager.last_plan = review, task.result
    elseif ok and action == "update" then
      manager.reviewed_plan, manager.last_plan = nil, nil
    end
    manager.operation = nil
    if opts.on_complete then
      local callback_ok, callback_err = pcall(opts.on_complete, task.result, task.error)
      if not callback_ok then
        vim.notify(tostring(callback_err), vim.log.levels.ERROR)
      end
    end
  end)

  vim.schedule(function()
    resume(co)
  end)
  return task
end

return M
