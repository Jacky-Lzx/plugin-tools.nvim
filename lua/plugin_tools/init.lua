local M = {}
local current

function M.new(opts)
  return require("plugin_tools.manager").new(opts)
end

function M.setup(opts)
  assert(opts == nil or type(opts) == "table", "plugin-tools.nvim: setup expects a table")
  opts = vim.deepcopy(opts or {})
  assert(not current, "plugin-tools: setup() may only be called once; use new() for isolated instances")
  local manager = M.new(opts)
  current = manager
  if not opts or opts.commands ~= false then
    require("plugin_tools.user_command").create("PluginTools", function(args)
      require("plugin_tools.command").run(current, args.fargs)
    end, {
      nargs = "*",
      complete = function(lead, line, cursor)
        return require("plugin_tools.command").complete(current, lead, line, cursor)
      end,
      desc = "Manage plugin-tools packages",
    })
  end
  manager:start()
  return manager
end

for _, method in ipairs({
  "start",
  "has",
  "activate",
  "mount",
  "use",
  "status",
  "profile",
  "open",
  "explain",
  "install",
  "update",
  "restore",
  "freeze",
  "clean",
  "plan",
  "recover",
}) do
  M[method] = function(...)
    assert(current, "plugin-tools: call setup() first, or use new()")
    return current[method](current, ...)
  end
end

return M
