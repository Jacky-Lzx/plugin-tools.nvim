local M = {}
local current

function M.new(opts)
  return require("plugin_tools.manager").new(opts)
end

function M.setup(opts)
  assert(not current, "plugin-tools: setup() may only be called once; use new() for isolated instances")
  local manager = M.new(opts)
  manager:start()
  current = manager
  if not opts or opts.commands ~= false then
    vim.api.nvim_create_user_command("PluginTools", function(args)
      require("plugin_tools.command").run(current, args.fargs)
    end, {
      nargs = "*",
      complete = function()
        return { "status", "explain", "install", "update", "restore", "freeze", "clean" }
      end,
      desc = "Manage plugin-tools packages",
    })
  end
  return manager
end

for _, method in ipairs({
  "start",
  "has",
  "activate",
  "use",
  "status",
  "explain",
  "install",
  "update",
  "restore",
  "freeze",
  "clean",
}) do
  M[method] = function(...)
    assert(current, "plugin-tools: call setup() first, or use new()")
    return current[method](current, ...)
  end
end

return M
