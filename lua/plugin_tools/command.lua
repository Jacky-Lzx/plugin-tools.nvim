local M = {}

function M.run(manager, args)
  local action = args[1] or "status"
  if action == "status" or action == "log" or action == "profile" then
    manager:open({ mode = action })
  elseif action == "explain" then
    assert(args[2], "usage: PluginTools explain {id}")
    manager:open({ id = args[2] })
  else
    local plan, rebuild
    if action == "rebuild" then
      action, rebuild = "restore", true
    end
    if action == "apply" then
      assert(#args == 1 and manager.last_plan, "run PluginTools plan first; apply takes no arguments")
      action, plan = "update", manager.last_plan
    end
    assert(
      vim.list_contains({ "install", "update", "restore", "freeze", "clean", "plan", "recover" }, action),
      "plugin-tools: unknown action " .. action
    )
    local ids = #args > 1 and vim.list_slice(args, 2) or nil
    local dry_run
    if action == "clean" or action == "recover" then
      assert(not args[2] or (#args == 2 and args[2] == "--apply"), "usage: PluginTools " .. action .. " [--apply]")
      dry_run, ids = args[2] ~= "--apply", nil
    end
    local task = manager[action](manager, {
      ids = ids,
      dry_run = dry_run,
      plan = plan,
      rebuild = rebuild,
      on_complete = function(result, err)
        if not err and (action == "plan" or action == "recover") then
          manager:open()
          return
        end
        vim.notify(
          err or vim.inspect(result),
          err and vim.log.levels.ERROR or vim.log.levels.INFO,
          { title = "PluginTools " .. action, filetype = err and "text" or "lua" }
        )
      end,
    })
    if action == "plan" or action == "recover" then
      manager:open()
    elseif package.loaded["plugin_tools.ui"] then
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
    choices = {
      "status",
      "log",
      "profile",
      "explain",
      "install",
      "update",
      "restore",
      "rebuild",
      "freeze",
      "clean",
      "plan",
      "apply",
      "recover",
    }
  elseif words[2] == "clean" or words[2] == "recover" then
    choices = { "--apply" }
  elseif vim.list_contains({ "explain", "install", "update", "restore", "rebuild", "freeze", "plan" }, words[2]) then
    choices = vim.list_slice(manager.graph.order)
    if words[2] == "explain" then
      vim.list_extend(choices, vim.tbl_keys(manager.graph.inactive))
      table.sort(choices)
    end
  else
    choices = {}
  end
  return vim.tbl_filter(function(value)
    return vim.startswith(value, lead)
  end, choices)
end

return M
