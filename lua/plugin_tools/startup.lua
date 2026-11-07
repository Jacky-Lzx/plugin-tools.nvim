local U = require("plugin_tools.util")
local M = {}

-- Coordinate readiness, mount, activation and filetype triggers in that order.
function M.run(manager)
  local runtime = require("plugin_tools.runtime").new(manager)
  manager.runtime = runtime
  -- Check every selected directory before installation or runtimepath changes,
  -- including cold packages. Ready startup never loads package operations.
  local missing = runtime:check()
  if #missing > 0 and manager.options.auto_install then
    local ids = {}
    for _, id in ipairs(manager.graph.package_order) do
      local package = manager.graph.packages[id]
      -- Component paths and external checkouts cannot be repaired by cloning.
      -- Existing files and dangling symlinks must not be replaced automatically.
      if package.managed and not vim.uv.fs_lstat(package.dir) then
        ids[#ids + 1] = id
      end
    end
    if #ids > 0 then
      local task = manager:install({ ids = ids })
      local result, err
      repeat
        result, err = task:wait()
      until task.done
      U.check(result, "automatic installation failed: " .. tostring(err))
      missing = runtime:check()
      if manager._profile and manager._profile.before_enter then
        -- Newly created directories can now resolve through filesystem aliases.
        manager._profile:refresh_roots()
      end
    end
  end
  U.check(
    manager.options.strict == false or #missing == 0,
    "missing plugin directories: " .. table.concat(missing, ", ") .. "; run install() before starting"
  )
  runtime:mount_startup()
  manager.timings.mount_ms = (vim.uv.hrtime() - manager._start_at) / 1e6
  manager.started = true
  for _, id in ipairs(manager.graph.activation_order) do
    if manager.graph.nodes[id].start and manager.states[id].phase ~= "missing" then
      local ok, err = pcall(manager.activate, manager, id, { kind = "startup" })
      if not ok then
        manager.start_error = err
        U.fail(err)
      end
    end
  end
  local ok, err = pcall(function()
    for _, id in ipairs(manager.graph.order) do
      if #manager.graph.nodes[id].ft > 0 then
        require("plugin_tools.triggers").watch(manager)
        return
      end
    end
  end)
  if not ok then
    manager.start_error = err
    U.fail(err)
  end
end

return M
