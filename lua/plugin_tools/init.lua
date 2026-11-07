---@class plugin_tools.API
---@field start fun(): plugin_tools.Manager
---@field has fun(id: string): boolean
---@field mount fun(id: string, cause?: plugin_tools.Trigger): plugin_tools.Manager
---@field activate fun(id: string, cause?: plugin_tools.Trigger): plugin_tools.Manager
---@field use fun(id: string, cause?: plugin_tools.Trigger): any
---@field status fun(opts?: plugin_tools.StatusOptions): plugin_tools.Status[]
---@field profile fun(): plugin_tools.Profile
---@field diagnostics fun(): plugin_tools.Diagnostic[]
---@field open fun(opts?: plugin_tools.OpenOptions): table
---@field explain fun(id: string): plugin_tools.Explanation
---@field install fun(opts?: plugin_tools.OperationOptions): plugin_tools.Task Install absent managed packages at locked revisions.
---@field update fun(opts?: plugin_tools.OperationOptions): plugin_tools.Task Stage and publish source revisions, or apply a reviewed plan.
---@field restore fun(opts?: plugin_tools.OperationOptions): plugin_tools.Task Restore selected packages to locked revisions.
---@field freeze fun(opts?: plugin_tools.OperationOptions): plugin_tools.Task Record current clean checkout revisions in the lockfile.
---@field clean fun(opts?: plugin_tools.OperationOptions): plugin_tools.Task Preview unused managed packages; dry_run=false removes them.
---@field plan fun(opts?: plugin_tools.OperationOptions): plugin_tools.Task Preview exact update revisions, builds and Git changes.
---@field recover fun(opts?: plugin_tools.OperationOptions): plugin_tools.Task Preview an interrupted transaction; dry_run=false applies recovery.
local M = {}
local current

---Create an isolated manager; call :start() when packages should be mounted.
---@param opts? plugin_tools.Options
---@return plugin_tools.Manager
function M.new(opts)
  return require("plugin_tools.manager").new(opts)
end

---Configure the default manager once, register its command and start it.
---@param opts? plugin_tools.Options
---@return plugin_tools.Manager
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
  "diagnostics",
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
