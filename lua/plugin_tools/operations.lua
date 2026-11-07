local U = require("plugin_tools.util")
local uv = vim.uv
local M = {}

local Packages = require("plugin_tools.operations.packages")
local owned, selected, lock_data = Packages.owned, Packages.selected, Packages.lock_data

-- One coroutine per operation, with bounded asynchronous staging workers. All
-- filesystem publication happens on the main thread after every worker succeeds.
function M.run(manager, action, opts)
  U.check(not manager.operation, "an operation is already running on this manager")
  local reviewed = opts.plan and manager.reviewed_plan
  if opts.plan then
    U.check(action == "update" and not opts.ids, "apply a plan with update({plan=report}) and no ids")
    U.check(reviewed and reviewed.report == opts.plan, "plan must be the latest successful preview from this manager")
  end
  U.check(opts.rebuild == nil or type(opts.rebuild) == "boolean", "rebuild must be boolean")
  U.check(not opts.plan or opts.rebuild == nil, "rebuild policy is fixed by the reviewed plan")
  local rebuild = reviewed and reviewed.rebuild or not reviewed and opts.rebuild == true
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

  local runner = require("plugin_tools.operations.process").new(task, timeout, concurrency, resume)
  worker_ids = runner.worker_ids
  local git = runner.git
  runner.task, runner.root, runner.staging = task, root, staging
  runner.reviewed, runner.rebuild = reviewed, rebuild
  local stage = require("plugin_tools.operations.checkout").new(runner)

  local function clean_staging()
    if transaction then
      return transaction:cleanup()
    end
    return {}
  end

  local function execute()
    task:check_cancelled()
    task:emit("locking")
    task:check_cancelled()
    U.check(
      not uv.fs_lstat(root) or uv.fs_lstat(root).type == "directory",
      "refusing symlink/non-directory root " .. root
    )
    U.mkdir(root)
    if action == "recover" then
      U.check(not opts.ids, "recover does not accept ids")
      if opts.dry_run == false then
        for _, package in pairs(manager.graph.packages) do
          require("plugin_tools.session").preserve(package)
        end
      end
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
    runner.transaction = transaction
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
      task:seal()
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
      local results = runner.map(packages, function(package)
        return stage(package, action, lock)
      end)
      task:seal()
      if action == "plan" then
        review = { ids = {}, entries = {}, rebuild = rebuild }
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
        if not result.unchanged then
          require("plugin_tools.session").preserve(result.package)
        end
      end
      for _, result in ipairs(results) do
        local p = result.package
        worker_ids[coroutine.running()] = p.id
        transaction:publish(result, git, task)
        lock.plugins[p.id] = { source = p.source, commit = result.commit }
      end
    end
    task:seal()
    transaction:target(lock)
    if not transaction.data.before_exists or not vim.deep_equal(lock, transaction.data.before_lock) then
      U.write_json(manager.lockfile, lock)
    end
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
      restart_required = manager.started and #swaps > 0,
    }
  end

  co = coroutine.create(function()
    local ok, result = xpcall(execute, debug.traceback)
    if not ok then
      if not task.failure then
        task:fail(worker_ids[coroutine.running()], result)
      end
      local rollback_errors = {}
      task.cancellable = false
      task:emit("rolling_back")
      if transaction then
        rollback_errors = transaction:rollback()
      end
      if #rollback_errors > 0 then
        keep_lock = true
        task.recovery_required = true
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
        task.recovery_required = true
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
