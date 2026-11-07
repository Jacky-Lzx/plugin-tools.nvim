local Task = {}
Task.__index = Task

function Task.new(action, opts)
  local self = setmetatable({
    action = action,
    done = false,
    phase = "queued",
    cancellable = true,
    cancel_requested = false,
    total = 0,
    completed = 0,
    items = {},
    order = {},
    events = {},
    observers = {},
    observer_errors = {},
    started_at = vim.uv.hrtime(),
  }, Task)
  if opts.on_progress then
    self:subscribe(opts.on_progress)
  end
  return self
end

function Task:cancel()
  if self.done or not self.cancellable or self.cancel_requested then
    return false
  end
  self.cancel_requested = true
  self:emit("cancelling")
  if self._cancel then
    self._cancel()
  end
  return true
end

function Task:check_cancelled()
  if self.cancel_requested then
    error("plugin-tools: operation cancelled", 0)
  end
end

-- Publication/recovery and rollback must finish without interruption.
function Task:seal()
  self:check_cancelled()
  self.cancellable = false
end

function Task:subscribe(callback)
  assert(type(callback) == "function", "plugin-tools: progress listener must be a function")
  self.observers[callback] = true
  return function()
    self.observers[callback] = nil
  end
end

function Task:select(packages)
  self.total = #packages
  for _, p in ipairs(packages) do
    if not self.items[p.id] then
      self.order[#self.order + 1] = p.id
      self.items[p.id] = {
        id = p.id,
        dir = p.dir,
        source = p.source,
        phase = "queued",
        build = p.build ~= nil,
        build_command = type(p.build) == "table" and vim.deepcopy(p.build) or nil,
      }
    end
  end
end

function Task:emit(phase, id, fields)
  fields = fields or {}
  self.phase = phase
  local item = id and self.items[id]
  if item then
    item.phase = phase
    for key, value in pairs(fields) do
      item[key] = vim.deepcopy(value)
    end
  end
  local event = vim.tbl_extend("force", {
    action = self.action,
    phase = phase,
    id = id,
    elapsed_ms = ((self.finished_at or vim.uv.hrtime()) - self.started_at) / 1e6,
    total = self.total,
    completed = self.completed,
  }, vim.deepcopy(fields))
  self.events[#self.events + 1] = event
  if #self.events > 500 then
    table.remove(self.events, 1)
  end
  for callback in pairs(self.observers) do
    local ok, err = pcall(callback, vim.deepcopy(event))
    if not ok then
      self.observer_errors[#self.observer_errors + 1] = tostring(err)
      self.observers[callback] = nil
    end
  end
end

function Task:log(id, argv, result)
  local function bounded(value)
    value = value or ""
    return #value > 16384 and (value:sub(1, 16384) .. "\n[output truncated]") or value
  end
  self:emit(self.items[id] and self.items[id].phase or self.phase, id, {
    command = argv,
    exit_code = result.code,
    stdout = bounded(result.stdout),
    stderr = bounded(result.stderr),
  })
end

function Task:fail(id, message)
  local failure = { id = id, phase = id and self.items[id] and self.items[id].phase or self.phase, message = message }
  self.failure = self.failure or failure
  self:emit("failed", id, { error = failure })
end

function Task:complete(id, phase)
  self.completed = self.completed + 1
  self:emit(phase, id)
end

function Task:snapshot()
  local details = {}
  for _, id in ipairs(self.order) do
    details[#details + 1] = vim.deepcopy(self.items[id])
  end
  return {
    action = self.action,
    phase = self.phase,
    done = self.done,
    cancellable = self.cancellable,
    cancel_requested = self.cancel_requested,
    cancelled = self.cancelled or false,
    recovery_required = self.recovery_required or false,
    total = self.total,
    completed = self.completed,
    details = details,
    failure = vim.deepcopy(self.failure),
    elapsed_ms = ((self.finished_at or vim.uv.hrtime()) - self.started_at) / 1e6,
  }
end

function Task:finish(result, err)
  if err and not self.failure then
    self:fail(nil, err)
  end
  self.done, self.error, self.finished_at = true, err, vim.uv.hrtime()
  self.cancellable, self._cancel = false, nil
  self.recovery_required = self.recovery_required or result and result.recovery_required or false
  self.cancelled = err ~= nil
      and self.cancel_requested
      and not self.recovery_required
      and self.failure
      and tostring(self.failure.message):find("operation cancelled", 1, true) ~= nil
    or false
  self.phase = self.cancelled and "cancelled" or err and "failed" or "done"
  if self.cancelled then
    for _, item in pairs(self.items) do
      if
        item.phase == "failed"
        and item.error
        and tostring(item.error.message):find("operation cancelled", 1, true)
      then
        item.phase = "cancelled"
      end
    end
  end
  self.report = vim.tbl_extend("force", result or { action = self.action }, self:snapshot(), {
    status = self.cancelled and "cancelled" or err and "failed" or "success",
    error = self.failure,
  })
  self.result = not err and self.report or nil
  self:emit(self.phase, nil)
  self.observers = {}
end

function Task:wait(milliseconds)
  local finished = self.done or vim.wait(milliseconds or 300000, function()
    return self.done
  end, 10)
  if not finished then
    return nil, "operation still running (wait timed out)"
  end
  return self.result, self.error
end

return Task
