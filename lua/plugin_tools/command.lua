local M = {}

function M.run(manager, args)
  local action = args[1] or "status"
  if action == "status" then
    local lines = {}
    for _, item in ipairs(manager:status()) do
      lines[#lines + 1] = ("%-28s %-12s %s"):format(item.id, item.state.phase, item.dir)
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "PluginTools" })
  elseif action == "explain" then
    vim.notify(vim.inspect(manager:explain(args[2])), vim.log.levels.INFO, { title = "PluginTools" })
  else
    assert(
      vim.list_contains({ "install", "update", "restore", "freeze", "clean" }, action),
      "plugin-tools: unknown action " .. action
    )
    local ids = #args > 1 and vim.list_slice(args, 2) or nil
    local dry_run
    if action == "clean" then
      assert(not args[2] or (#args == 2 and args[2] == "--apply"), "usage: PluginTools clean [--apply]")
      dry_run, ids = args[2] ~= "--apply", nil
    end
    manager[action](manager, {
      ids = ids,
      dry_run = dry_run,
      on_complete = function(result, err)
        vim.notify(
          err or vim.inspect(result),
          err and vim.log.levels.ERROR or vim.log.levels.INFO,
          { title = "PluginTools " .. action }
        )
      end,
    })
  end
end

return M
