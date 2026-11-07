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

function T:cleanup()
  local saved, err = pcall(self.cleanup_start, self)
  if not saved then
    return { tostring(err) }
  end
  local errors = {}
  for _, path in ipairs(self.data.staging) do
    if uv.fs_lstat(path) and vim.fn.delete(path, "rf") ~= 0 then
      errors[#errors + 1] = "cannot clean " .. path
    end
  end
  return errors
end

function T:publish(result, git, task)
  local owned = require("plugin_tools.operations.packages").owned
  local p = result.package
  if result.unchanged then
    owned(p)
    U.check(git(p.dir, "status", "--porcelain", "--untracked-files=normal") == "", "local modifications in " .. p.dir)
    U.check(git(p.dir, "rev-parse", "HEAD") == result.commit, p.id .. ": checkout changed during operation")
  end
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
      U.check(git(p.dir, "status", "--porcelain", "--untracked-files=normal") == "", "local modifications in " .. p.dir)
      U.check(git(p.dir, "rev-parse", "HEAD") == result.previous_commit, p.id .. ": checkout changed during operation")
      swap.backup = result.temporary .. "/previous"
      self.data.swaps[#self.data.swaps + 1] = swap
      self:phase("publishing")
      U.check(uv.fs_rename(p.dir, swap.backup), "cannot back up " .. p.dir)
    else
      U.check(not uv.fs_lstat(p.dir), "package directory appeared during operation: " .. p.dir)
      self.data.swaps[#self.data.swaps + 1] = swap
      self:phase("publishing")
    end
    U.check(uv.fs_rename(result.checkout, p.dir), "cannot publish " .. p.dir)
    swap.published = true
    self:save()
  end
end

-- A failed journal write must not prevent attempts to restore every checkout.
function T:rollback()
  local errors = {}
  local function attempt(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
      errors[#errors + 1] = tostring(err)
    end
  end
  attempt(self.phase, self, "rolling_back")
  for i = #self.data.swaps, 1, -1 do
    local swap = self.data.swaps[i]
    if swap.published and uv.fs_lstat(swap.dir) and vim.fn.delete(swap.dir, "rf") ~= 0 then
      errors[#errors + 1] = "cannot remove " .. swap.dir
    end
    if swap.backup and uv.fs_lstat(swap.backup) then
      local restored, err = uv.fs_rename(swap.backup, swap.dir)
      if not restored then
        errors[#errors + 1] = "backup retained at " .. swap.backup .. ": " .. tostring(err)
      end
    end
  end
  attempt(self.restore_lock, self)
  if #errors == 0 then
    attempt(self.phase, self, "rolled_back")
    if #errors == 0 then
      errors = self:cleanup()
    end
  end
  return errors
end

function T.recover(manager, opts, git, task)
  return require("plugin_tools.operations.recovery").run(manager, opts, git, task)
end

return T
