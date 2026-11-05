local U = require("plugin_tools.util")
local uv = vim.uv
local T = {}
T.__index = T

function T.begin(manager, action, lock, stages, swaps)
  local self = setmetatable({ path = manager.graph.root .. "/.operation-lock/journal.json", manager = manager }, T)
  self.data = {
    version = 1,
    id = tostring(uv.os_getpid()) .. "-" .. string.format("%.0f", uv.hrtime()),
    pid = uv.os_getpid(),
    action = action,
    root = manager.graph.root,
    lockfile = manager.lockfile,
    phase = "staging",
    before_exists = uv.fs_lstat(manager.lockfile) ~= nil,
    before_lock = vim.deepcopy(lock),
    staging = stages,
    staging_identity = {},
    swaps = swaps,
    processes = {},
  }
  self:save()
  return self
end

function T:save()
  U.write_json(self.path, self.data)
end

function T:stage(path)
  local stat = assert(uv.fs_lstat(path))
  self.data.staging_identity[path] = { dev = stat.dev, ino = stat.ino }
  U.write_json(path .. "/plugin-tools-stage.json", { transaction = self.data.id })
  self:save()
end

function T:cleanup_start()
  self.data.cleanup_started = true
  self:save()
end

function T:target(lock)
  self.data.target_lock = vim.deepcopy(lock)
  self:save()
end

function T:phase(phase)
  self.data.phase = phase
  self:save()
end

local function same_lock(data, value)
  return value ~= nil and vim.deep_equal(data, value)
end

function T:restore_lock()
  local data = self.data
  local exists = uv.fs_lstat(data.lockfile) ~= nil
  local current = U.read_json(data.lockfile, nil)
  if exists == data.before_exists and (not exists or same_lock(current, data.before_lock)) then
    return
  end
  U.check(not exists or same_lock(current, data.target_lock), "lockfile changed outside interrupted transaction")
  if data.before_exists then
    U.write_json(data.lockfile, data.before_lock)
  elseif exists then
    U.check(uv.fs_unlink(data.lockfile), "cannot restore absent lockfile")
  end
end

function T:finished()
  U.write_json(vim.fs.dirname(self.path) .. "/owner.json", {
    pid = uv.os_getpid(),
    action = self.data.action,
    finished = true,
    id = self.data.id,
  })
end

local function alive(pid)
  U.check(type(pid) == "number" and pid > 0 and pid % 1 == 0, "invalid transaction owner PID")
  local ok, err = uv.kill(pid, 0)
  -- Permission errors are not evidence that the owner has exited.
  return ok ~= nil or not tostring(err):find("ESRCH", 1, true)
end

local function directory(path)
  local stat = uv.fs_lstat(path)
  U.check(not stat or stat.type == "directory", "refusing symlink/non-directory recovery path " .. path)
  return stat ~= nil
end

local function validate(data, manager)
  U.check(type(data) == "table" and data.version == 1 and type(data.id) == "string", "invalid transaction journal")
  U.check(data.root == manager.graph.root and data.lockfile == manager.lockfile, "journal root/lockfile mismatch")
  U.check(type(data.before_exists) == "boolean" and type(data.before_lock) == "table", "invalid prior lockfile record")
  U.check(type(data.staging) == "table" and vim.islist(data.staging), "invalid staging journal")
  U.check(type(data.staging_identity) == "table", "invalid staging identity journal")
  U.check(type(data.swaps) == "table" and vim.islist(data.swaps), "invalid publication journal")
  local stages = {}
  for _, path in ipairs(data.staging) do
    U.check(
      type(path) == "string" and vim.fs.dirname(path) == data.root and vim.fs.basename(path):match("^%.stage%-"),
      "unsafe staging path in journal"
    )
    if directory(path) then
      local stat, identity = uv.fs_lstat(path), data.staging_identity[path]
      U.check(
        identity and identity.dev == stat.dev and identity.ino == stat.ino,
        "staging directory was replaced: " .. path
      )
      local marker = U.read_json(path .. "/plugin-tools-stage.json", {})
      U.check(
        marker.transaction == data.id or (not next(marker) and data.cleanup_started == true),
        "staging ownership mismatch: " .. path
      )
    end
    stages[path] = true
  end
  local seen = {}
  for _, swap in ipairs(data.swaps) do
    U.check(
      type(swap.id) == "string" and swap.id:match("^[%w][%w_.-]*$") and not seen[swap.id],
      "invalid journal package"
    )
    seen[swap.id] = true
    U.check(swap.dir == data.root .. "/" .. swap.id and type(swap.source) == "string", "unsafe package path in journal")
    if swap.backup then
      U.check(
        stages[vim.fs.dirname(swap.backup)] and vim.fs.basename(swap.backup) == "previous",
        "unsafe backup path in journal"
      )
    end
  end
end

local function inspect(path, swap, commit, git, transaction)
  if not directory(path) then
    return false
  end
  U.check(directory(path .. "/.git"), "missing Git metadata in recovery path " .. path)
  local marker = U.read_json(path .. "/.git/plugin-tools-owner.json", {})
  U.check(marker.id == swap.id and marker.source == swap.source, "ownership mismatch during recovery: " .. path)
  U.check(not transaction or marker.transaction == transaction, "unrecognized published checkout: " .. path)
  U.check(git(path, "rev-parse", "HEAD") == commit, "checkout revision changed during recovery: " .. path)
  U.check(
    git(path, "status", "--porcelain", "--untracked-files=normal") == "",
    "local modifications during recovery: " .. path
  )
  return true, marker
end

function T.recover(manager, opts, git, task)
  local lockdir = manager.graph.root .. "/.operation-lock"
  if not directory(lockdir) then
    return { action = "recover", packages = {}, dry_run = opts.dry_run ~= false, steps = {} }
  end
  local claim = lockdir .. "/recovery"
  U.check(not uv.fs_lstat(claim), "recovery claim already exists; inspect its owner before removing a stale claim")
  local owner = U.read_json(lockdir .. "/owner.json", {})
  U.check(owner.finished == true or not alive(owner.pid), "owning process is still running; recovery refused")
  local data = U.read_json(lockdir .. "/journal.json", nil)
  U.check(data, "no transaction journal; inspect this legacy/incomplete lock manually")
  validate(data, manager)
  U.check(data.pid == owner.pid, "journal owner mismatch")
  U.check(type(data.processes) == "table", "invalid process journal")
  for _, process in pairs(data.processes) do
    U.check(not alive(process.pid), "a recorded Git/build process is still running; wait or stop it before recovery")
  end
  local self = setmetatable({ data = data, path = lockdir .. "/journal.json", manager = manager }, T)
  task:select(data.swaps)
  local acquired = false
  local ok, result = xpcall(function()
    if opts.dry_run == false then
      U.check(uv.fs_mkdir(claim, 448), "another recovery is already running")
      acquired = true
      U.write_json(claim .. "/owner.json", { pid = uv.os_getpid() })
    end
    local current_lock = U.read_json(data.lockfile, nil)
    U.check(
      (not current_lock and not data.before_exists)
        or same_lock(current_lock, data.before_lock)
        or same_lock(current_lock, data.target_lock),
      "lockfile changed outside interrupted transaction"
    )
    local complete = data.phase == "committed"
      or (
        data.phase ~= "rolling_back"
        and data.phase ~= "rolled_back"
        and data.phase ~= "rollback_failed"
        and data.target_lock
        and same_lock(current_lock, data.target_lock)
      )
    local steps, packages = {}, {}
    -- Validate every checkout before changing any path.
    for _, swap in ipairs(data.swaps) do
      task:emit("checking", swap.id)
      packages[#packages + 1] = swap.id
      local backup = swap.backup
        and (
          complete and data.cleanup_started and directory(swap.backup)
          or inspect(swap.backup, swap, swap.before_commit, git)
        )
      local current, kind = directory(swap.dir), nil
      if current then
        local marker = U.read_json(swap.dir .. "/.git/plugin-tools-owner.json", {})
        if marker.transaction == data.id then
          inspect(swap.dir, swap, swap.after_commit, git, data.id)
          kind = "new"
        else
          U.check(swap.before_commit, "unrecognized package appeared during recovery: " .. swap.dir)
          inspect(swap.dir, swap, swap.before_commit, git)
          kind = "old"
        end
      end
      if complete then
        U.check(
          swap.clean and not current or not swap.clean and kind == "new",
          "committed checkout missing or changed: " .. swap.dir
        )
        steps[#steps + 1] = { id = swap.id, action = "keep", dir = swap.dir }
      else
        U.check(not (backup and kind == "old"), "both original and backup exist; inspect manually: " .. swap.id)
        U.check(not swap.before_commit or backup or kind == "old", "missing recovery backup for " .. swap.id)
        steps[#steps + 1] = {
          id = swap.id,
          action = backup and "restore" or kind == "new" and "remove" or "keep",
          dir = swap.dir,
          backup = backup and swap.backup or nil,
          remove = kind == "new",
        }
      end
    end
    if opts.dry_run == false then
      if not complete then
        self:phase("rolling_back")
        for i = #steps, 1, -1 do
          local step = steps[i]
          task:emit("restoring", step.id)
          if step.remove then
            U.check(vim.fn.delete(step.dir, "rf") == 0, "cannot remove interrupted publication " .. step.dir)
          end
          if step.backup then
            U.check(uv.fs_rename(step.backup, step.dir), "cannot restore " .. step.dir)
          end
        end
        self:restore_lock()
        self:phase("rolled_back")
      else
        self:phase("committed")
      end
      self:cleanup_start()
      for _, path in ipairs(data.staging) do
        U.check(not uv.fs_lstat(path) or vim.fn.delete(path, "rf") == 0, "cannot clean recovery staging " .. path)
      end
      U.check(vim.fn.delete(lockdir, "rf") == 0, "cannot release recovered operation lock")
      acquired = false
    end
    for _, step in ipairs(steps) do
      task:complete(step.id, opts.dry_run ~= false and "previewed" or complete and "kept" or "recovered")
    end
    return {
      action = "recover",
      dry_run = opts.dry_run ~= false,
      mode = complete and "complete" or "rollback",
      packages = packages,
      steps = steps,
      restart_required = opts.dry_run == false and #steps > 0,
    }
  end, debug.traceback)
  if acquired then
    vim.fn.delete(claim, "rf")
  end
  U.check(ok, tostring(result))
  return result
end

return T
