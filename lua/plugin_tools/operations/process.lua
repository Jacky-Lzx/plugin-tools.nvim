local U = require("plugin_tools.util")
local uv = vim.uv
local M = {}

-- Drain every worker before the orchestrator may publish or roll back.
function M.new(task, timeout, concurrency, resume)
  local self = { worker_ids = {} }
  local processes = {}
  local grouped = vim.fn.has("win32") == 0
  local function terminate(handle)
    -- Dedicated Unix process groups include Git helpers and ordinary build
    -- children. Kill before rollback can remove their working directories.
    if grouped then
      uv.kill(-handle.pid, 9)
    else
      pcall(handle.kill, handle, 9)
    end
  end
  task._cancel = function()
    for handle in pairs(processes) do
      terminate(handle)
    end
  end

  local function process(argv, cwd)
    task:check_cancelled()
    local thread = coroutine.running()
    U.check(thread, "internal process call outside operation")
    local ok, err = pcall(
      vim.system,
      argv,
      { cwd = cwd, text = true, timeout = timeout, detach = grouped, env = { GIT_TERMINAL_PROMPT = "0" } },
      function(result)
        vim.schedule(function()
          resume(thread, result)
        end)
      end
    )
    U.check(ok, "cannot start " .. tostring(argv[1]) .. ": " .. tostring(err))
    local handle, process_key, journal_error = err
    processes[handle] = true
    if self.transaction then
      process_key = tostring(handle.pid)
      self.transaction.data.processes[process_key] =
        { pid = handle.pid, command = argv[1], pgid = grouped and handle.pid or nil }
      local saved, save_err = pcall(self.transaction.save, self.transaction)
      if not saved then
        journal_error = tostring(save_err)
        terminate(handle)
      end
    end
    local result = coroutine.yield()
    processes[handle] = nil
    if process_key then
      self.transaction.data.processes[process_key] = nil
      local saved, save_err = pcall(self.transaction.save, self.transaction)
      if not saved then
        journal_error = journal_error or tostring(save_err)
      end
    end
    task:log(self.worker_ids[thread], argv, result)
    U.check(not journal_error, "cannot journal process: " .. tostring(journal_error))
    task:check_cancelled()
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

  function self.map(packages, stage)
    local parent, next_index, remaining, failed = coroutine.running(), 1, math.min(concurrency, #packages), nil
    if remaining == 0 then
      return {}
    end
    local results = {}
    for _ = 1, remaining do
      local worker = coroutine.create(function()
        while not failed and not task.cancel_requested and next_index <= #packages do
          local index = next_index
          next_index = index + 1
          self.worker_ids[coroutine.running()] = packages[index].id
          local ok, result = xpcall(function()
            return stage(packages[index])
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
    task:check_cancelled()
    return results
  end

  self.process, self.git = process, git
  return self
end

return M
