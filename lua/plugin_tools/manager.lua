local U = require("plugin_tools.util")
local Manager = {}
Manager.__index = Manager

function Manager.new(opts)
  U.check(vim.fn.has("nvim-0.11") == 1, "Neovim 0.11+ is required")
  opts = opts or {}
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
      return self:use(id)
    end,
    activate = function(id)
      U.check(n.dependencies[id] ~= nil, n.id .. ": undeclared dependency " .. id)
      return self:activate(id)
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
  local time = vim.uv.hrtime()
  local paths, afters, seen, missing, directories = {}, {}, {}, {}, {}
  for _, id in ipairs(self.graph.order) do
    local n = self.graph.nodes[id]
    if directories[n.dir] == nil then
      directories[n.dir] = U.directory(n.dir)
    end
    if directories[n.dir] then
      self.states[id].phase = "mounted"
      if not seen[n.dir] then
        seen[n.dir], paths[#paths + 1] = true, n.dir
        local after = n.dir .. "/after"
        if U.directory(after) then
          afters[#afters + 1] = after
        end
      end
    else
      self.states[id].phase = "missing"
      missing[#missing + 1] = id
    end
  end
  U.check(
    self.options.strict == false or #missing == 0,
    "missing plugin directories: " .. table.concat(missing, ", ") .. "; run install() before starting"
  )
  local runtime = U.runtime_paths()
  local managed_paths, managed = paths, seen
  for _, path in ipairs(afters) do
    managed[path] = true
  end
  paths, seen = {}, {}
  local inserted, inserted_afters = false, false
  local function append(path)
    if not seen[path] then
      seen[path], paths[#paths + 1] = true, path
    end
  end
  local function insert_managed()
    if not inserted then
      for _, path in ipairs(managed_paths) do
        append(path)
      end
      inserted = true
    end
  end
  local function insert_afters()
    if not inserted_afters then
      for i = #afters, 1, -1 do
        append(afters[i])
      end
      inserted_afters = true
    end
  end
  for _, path in ipairs(runtime) do
    local is_after = path:match("[/\\]after$") ~= nil
    if path == vim.env.VIMRUNTIME or is_after then
      insert_managed()
    end
    if is_after then
      insert_afters()
    end
    if not managed[path] then
      append(path)
    end
  end
  insert_managed()
  insert_afters()
  -- A single option assignment avoids rebuilding Neovim's runtime cache N times.
  U.set_runtime_paths(paths)
  self.started = true
  for _, id in ipairs(self.graph.activation_order) do
    if self.graph.nodes[id].start and self.states[id].phase ~= "missing" then
      local ok, err = pcall(self.activate, self, id)
      if not ok then
        self.start_error = err
        U.fail(err)
      end
    end
  end
  self.timings.start_ms = (vim.uv.hrtime() - time) / 1e6
  return self
end

function Manager:activate(id)
  U.check(self.started, "call start() before activation")
  local n, state = self.graph.nodes[id], self.states[id]
  U.check(n, "unknown plugin " .. tostring(id))
  if state.phase == "ready" then
    return self
  end
  U.check(state.phase ~= "missing", id .. ": plugin directory is missing")
  U.check(state.phase ~= "initializing", "activation cycle: " .. table.concat(self.stack, " -> ") .. " -> " .. id)
  U.check(state.phase ~= "failed", id .. ": previous initialization failed: " .. tostring(state.error))
  state.phase, self.stack[#self.stack + 1] = "initializing", id
  local time = self.options.profile and vim.uv.hrtime()
  local ok, err = xpcall(function()
    for _, before in ipairs(n.after) do
      self:activate(before)
    end
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
  if time then
    state.duration_ms = (vim.uv.hrtime() - time) / 1e6
  end
  state.phase, state.error = ok and "ready" or "failed", not ok and err or nil
  if not ok then
    U.fail(id .. ": initialization failed: " .. err)
  end
  state.count = state.count + 1
  return self
end

function Manager:use(id)
  self:activate(id)
  local n = self.graph.nodes[id]
  U.check(n.main, id .. ": use() requires a main module")
  return require(n.main)
end

function Manager:status()
  local out = {}
  for _, id in ipairs(self.graph.order) do
    local n = self.graph.nodes[id]
    out[#out + 1] =
      { id = id, package = n.owner, dir = n.dir, managed = n.package.managed, state = vim.deepcopy(self.states[id]) }
  end
  return out
end

function Manager:explain(id)
  local n = self.graph.nodes[id]
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
    opts = vim.deepcopy(n.opts),
    state = vim.deepcopy(self.states[id]),
  }
end

for _, operation in ipairs({ "install", "update", "restore", "freeze", "clean" }) do
  Manager[operation] = function(self, opts)
    return require("plugin_tools.operations").run(self, operation, opts or {})
  end
end

return Manager
