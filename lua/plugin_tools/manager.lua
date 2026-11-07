local U = require("plugin_tools.util")
local Manager = {}
Manager.__index = Manager

function Manager.new(opts)
  U.check(vim.fn.has("nvim-0.11") == 1, "Neovim 0.11+ is required")
  assert(opts == nil or type(opts) == "table", "plugin-tools: new expects a table")
  opts = vim.deepcopy(opts or {})
  U.check(opts.auto_install == nil or type(opts.auto_install) == "boolean", "auto_install must be boolean")
  if opts.auto_install == nil then
    opts.auto_install = true
  end
  local started = vim.uv.hrtime()
  local self = setmetatable({ options = opts, states = {}, stack = {}, started = false }, Manager)
  self.graph = require("plugin_tools.graph").resolve(opts.specs or {}, opts)
  self.timings = { resolve_ms = (vim.uv.hrtime() - started) / 1e6 }
  self.lockfile = U.path(opts.lockfile or (vim.fn.stdpath("config") .. "/plugin-tools-lock.json"))
  for _, id in ipairs(self.graph.order) do
    self.states[id] = { phase = "registered", count = 0 }
  end
  return self
end

function Manager:has(id)
  local state = self.states[id]
  return state ~= nil and state.phase ~= "missing"
end

local context_options = setmetatable({}, { __mode = "k" })
local context_meta = {
  __index = function(ctx, key)
    if key == "opts" then
      local options = vim.deepcopy(context_options[ctx])
      context_options[ctx] = nil
      rawset(ctx, key, options)
      return options
    end
  end,
}

function Manager:_context(n)
  local ctx = {
    id = n.id,
    dir = n.dir,
    has = function(id)
      U.check(n.dependencies[id] ~= nil, n.id .. ": undeclared dependency " .. id)
      return self:has(id)
    end,
    use = function(id)
      U.check(n.dependencies[id] ~= nil, n.id .. ": undeclared dependency " .. id)
      return self:use(id, { kind = "dependency", parent = n.id, action = "use" })
    end,
    mount = function(id)
      U.check(n.dependencies[id] ~= nil, n.id .. ": undeclared dependency " .. id)
      return self:mount(id, { kind = "dependency", parent = n.id, action = "mount" })
    end,
    activate = function(id)
      U.check(n.dependencies[id] ~= nil, n.id .. ": undeclared dependency " .. id)
      return self:activate(id, { kind = "dependency", parent = n.id, action = "activate" })
    end,
  }
  if not next(n.opts) then
    ctx.opts = {}
    return ctx
  end
  context_options[ctx] = n.opts
  return setmetatable(ctx, context_meta)
end

function Manager:start()
  U.check(not self.start_error, "previous startup failed: " .. tostring(self.start_error))
  if self.started then
    return self
  end
  self._start_at = vim.uv.hrtime()
  self.timings.enabled = self.options.profile ~= false
  self._profile = nil
  if self.timings.enabled then
    self._profile = require("plugin_tools.profile").new(self)
  end
  local ok, err = pcall(function()
    require("plugin_tools.startup").run(self)
  end)
  self.timings.start_ms = (vim.uv.hrtime() - self._start_at) / 1e6
  if not ok and not self.started then
    self.timings.mount_ms = self.timings.start_ms
  end
  if self._profile then
    self._profile:started(ok)
  end
  if not ok then
    error(err, 0)
  end
  return self
end

local function trigger(manager, id, cause)
  cause = vim.deepcopy(cause or { kind = "explicit" })
  local parent = cause.parent and manager.states[cause.parent]
  local previous = parent and parent.trigger
  cause.chain = vim.deepcopy(previous and previous.chain or (cause.parent and { cause.parent } or {}))
  cause.chain[#cause.chain + 1] = id
  local reason = cause.kind == "dependency" and ("ctx." .. cause.action .. " from " .. cause.parent)
    or cause.kind == "after" and ("after prerequisite of " .. cause.parent)
    or cause.kind == "filetype" and ("FileType " .. cause.filetype)
    or cause.kind
  return cause, reason
end

function Manager:mount(id, cause)
  U.check(self.started, "call start() before mounting")
  local ok, err = pcall(self.runtime.mount, self.runtime, id)
  if not ok then
    local state = self.states[id]
    if state and state.phase ~= "missing" then
      state.phase, state.error = "failed", err
    end
    error(err, 0)
  end
  local state = self.states[id]
  if not state.mount_trigger then
    state.mount_trigger, state.mount_reason = trigger(self, id, cause or state.trigger)
    state.mount_reason = cause and state.mount_reason or state.reason or "explicit mount"
  end
  return self
end

function Manager:activate(id, cause)
  U.check(self.started, "call start() before activation")
  local n, state = self.graph.nodes[id], self.states[id]
  U.check(n, "unknown plugin " .. tostring(id))
  if state.phase == "ready" then
    return self
  end
  U.check(state.phase ~= "missing", id .. ": plugin directory is missing")
  U.check(state.phase ~= "initializing", "activation cycle: " .. table.concat(self.stack, " -> ") .. " -> " .. id)
  U.check(state.phase ~= "failed", id .. ": previous initialization failed: " .. tostring(state.error))
  state.trigger, state.reason = trigger(self, id, cause)
  state.phase, self.stack[#self.stack + 1] = "initializing", id
  local frame = self._profile and self._profile:begin("config", id)
  local ok, err = xpcall(function()
    for _, before in ipairs(n.after) do
      self:activate(before, { kind = "after", parent = id })
    end
    self:mount(id)
    if n.config then
      n.config(self:_context(n))
    elseif n.config ~= false and n.main then
      local module = require(n.main)
      U.check(
        type(module) == "table" and type(module.setup) == "function",
        id .. ": main has no setup(); supply config or config=false"
      )
      module.setup(vim.deepcopy(n.opts))
    end
  end, debug.traceback)
  self.stack[#self.stack] = nil
  if frame then
    self._profile:leave(frame)
  end
  state.phase, state.error = ok and "ready" or "failed", not ok and err or nil
  if not ok then
    U.fail(id .. ": initialization failed: " .. err)
  end
  state.count = state.count + 1
  return self
end

function Manager:use(id, cause)
  self:activate(id, cause)
  local n = self.graph.nodes[id]
  U.check(n.main, id .. ": use() requires a main module")
  return require(n.main)
end

function Manager:status(opts)
  local out = {}
  for _, id in ipairs(self.graph.order) do
    local n = self.graph.nodes[id]
    local parents = vim.tbl_keys(n.parents)
    table.sort(parents)
    out[#out + 1] = {
      id = id,
      package = n.owner,
      dir = n.dir,
      managed = n.package.managed,
      parents = parents,
      root = n.roots,
      state = vim.deepcopy(self.states[id]),
    }
  end
  if opts and opts.include_inactive then
    local ids = vim.tbl_keys(self.graph.inactive)
    table.sort(ids)
    for _, id in ipairs(ids) do
      out[#out + 1] = vim.deepcopy(self.graph.inactive[id])
    end
  end
  return out
end

function Manager:profile()
  local timings = vim.deepcopy(self.timings)
  if timings.enabled and not timings.complete and self._start_at then
    timings.total_ms = timings.resolve_ms + (vim.uv.hrtime() - self._start_at) / 1e6
    timings.other_ms = math.max(
      0,
      timings.total_ms - timings.resolve_ms - (timings.mount_ms or 0) - timings.config_ms - timings.native_ms
    )
  end
  return { timings = timings, plugins = self:status() }
end

function Manager:diagnostics()
  return require("plugin_tools.diagnostics").collect(self)
end

function Manager:open(opts)
  return require("plugin_tools.ui").open(self, opts)
end

function Manager:explain(id)
  local n = self.graph.nodes[id]
  if not n and self.graph.inactive[id] then
    return vim.deepcopy(self.graph.inactive[id])
  end
  U.check(n, "unknown plugin " .. tostring(id))
  local users = {}
  for _, other in ipairs(self.graph.order) do
    if self.graph.nodes[other].dependencies[id] ~= nil then
      users[#users + 1] = other
    end
  end
  local parents = vim.tbl_keys(n.parents)
  table.sort(parents)
  return {
    id = id,
    package = n.owner,
    dir = n.dir,
    source = n.package.source,
    managed = n.package.managed,
    root = n.roots,
    parents = parents,
    referenced_by = users,
    dependencies = vim.deepcopy(n.dependencies),
    after = vim.deepcopy(n.after),
    start = n.start,
    mount = n.mount,
    ft = vim.deepcopy(n.ft),
    opts = vim.deepcopy(n.opts),
    declarations = vim.deepcopy(n.declarations),
    option_history = vim.deepcopy(n.option_history),
    state = vim.deepcopy(self.states[id]),
  }
end

for _, operation in ipairs({ "install", "update", "restore", "freeze", "clean", "plan", "recover" }) do
  Manager[operation] = function(self, opts)
    return require("plugin_tools.operations").run(self, operation, opts or {})
  end
end

return Manager
