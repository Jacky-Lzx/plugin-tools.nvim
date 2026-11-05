local M = {}

function M.run(manager, args)
  local action = args[1] or "status"
  if action == "status" or action == "log" then
    manager:open({ mode = action })
  elseif action == "explain" then
    assert(args[2], "usage: PluginTools explain {id}")
    manager:open({ id = args[2] })
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
    local task = manager[action](manager, {
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
    if package.loaded["plugin_tools.ui"] then
      require("plugin_tools.ui").track(manager, task)
    end
  end
end

function M.complete(manager, lead, line, cursor)
  local before = line:sub(1, cursor)
  local words = vim.split(before, "%s+", { trimempty = true })
  if before:match("%s$") then
    words[#words + 1] = ""
  end
  local choices
  if #words <= 2 then
    choices = { "status", "log", "explain", "install", "update", "restore", "freeze", "clean" }
  elseif words[2] == "clean" then
    choices = { "--apply" }
  elseif vim.list_contains({ "explain", "install", "update", "restore", "freeze" }, words[2]) then
    choices = manager.graph.order
  else
    choices = {}
  end
  return vim.tbl_filter(function(value)
    return vim.startswith(value, lead)
  end, choices)
end

return M
