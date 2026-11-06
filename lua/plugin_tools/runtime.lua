local U = require("plugin_tools.util")
local Runtime = {}
Runtime.__index = Runtime
local sequence = 0

function Runtime.new(manager)
  local self = setmetatable({ manager = manager, roots = {}, order = {} }, Runtime)
  for _, id in ipairs(manager.graph.order) do
    local node = manager.graph.nodes[id]
    local root = self.roots[node.dir]
    if not root then
      root = { dir = node.dir, ids = {}, deferred = true }
      self.roots[node.dir], self.order[#self.order + 1] = root, root
    end
    root.ids[#root.ids + 1] = id
    root.deferred = root.deferred and node.mount == "on-demand"
  end
  return self
end

function Runtime:_paths()
  local paths, afters, managed, seen = {}, {}, {}, {}
  for _, root in ipairs(self.order) do
    if root.mounted then
      paths[#paths + 1], managed[root.dir] = root.dir, true
      if root.after then
        afters[#afters + 1], managed[root.after] = root.after, true
      end
    end
  end
  local runtime, result = U.runtime_paths(), {}
  local inserted, inserted_afters = false, false
  local function append(path)
    if not seen[path] then
      seen[path], result[#result + 1] = true, path
    end
  end
  local function insert_roots()
    if not inserted then
      for _, path in ipairs(paths) do
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
    local after = path:match("[/\\]after$") ~= nil
    if path == vim.env.VIMRUNTIME or after then
      insert_roots()
    end
    if after then
      insert_afters()
    end
    if not managed[path] then
      append(path)
    end
  end
  insert_roots()
  insert_afters()
  U.set_runtime_paths(result)
end

function Runtime:_mark(root)
  root.mounted = true
  root.after = U.directory(root.dir .. "/after") and root.dir .. "/after" or nil
  for _, id in ipairs(root.ids) do
    local state = self.manager.states[id]
    if state.phase == "registered" then
      state.phase = "mounted"
    end
    state.mounted = true
  end
end

function Runtime:start()
  local missing, existing = {}, {}
  for _, path in ipairs(U.runtime_paths()) do
    existing[path] = true
  end
  -- Check every selected directory before changing runtimepath, including cold packages.
  for _, root in ipairs(self.order) do
    root.available = U.directory(root.dir)
    if not root.available then
      for _, id in ipairs(root.ids) do
        self.manager.states[id].phase = "missing"
        missing[#missing + 1] = id
      end
    end
  end
  U.check(
    self.manager.options.strict == false or #missing == 0,
    "missing plugin directories: " .. table.concat(missing, ", ") .. "; run install() before starting"
  )
  for _, root in ipairs(self.order) do
    if root.available and (not root.deferred or existing[root.dir]) then
      self:_mark(root)
      -- Existing roots retain their host's native lifecycle.
      root.native = true
    end
  end
  self:_paths()
end

function Runtime:_guard(file)
  if vim.v.vim_did_enter == 1 then
    return
  end
  -- Native startup may still scan this newly mounted root. Intercept only exact
  -- files already sourced by us, and remove the guards at VimEnter.
  if not self.guard_group then
    sequence = sequence + 1
    self.guard_group = vim.api.nvim_create_augroup("PluginToolsNativeOnce" .. sequence, { clear = true })
    vim.api.nvim_create_autocmd("VimEnter", {
      group = self.guard_group,
      once = true,
      callback = function()
        vim.api.nvim_del_augroup_by_id(self.guard_group)
        self.guard_group = nil
      end,
    })
  end
  local aliases = { file }
  local real = vim.uv.fs_realpath(file)
  if real and real ~= file then
    aliases[#aliases + 1] = real
  end
  for _, alias in ipairs(aliases) do
    vim.api.nvim_create_autocmd("SourceCmd", {
      group = self.guard_group,
      pattern = vim.fn.escape(alias, "\\,*?[]{}"),
      callback = function() end,
    })
  end
end

function Runtime:_source(root)
  U.check(not root.error, "previous runtime loading failed: " .. tostring(root.error))
  if root.native then
    return
  end
  U.check(not root.loading, "runtime loading cycle: " .. root.dir)
  root.loading = true
  local node = self.manager.graph.nodes[root.ids[1]]
  local owner = node.dir == self.manager.graph.nodes[node.owner].dir and node.owner or node.id
  local ok, err = xpcall(function()
    if not vim.o.loadplugins then
      return
    end
    for _, directory in ipairs({ root.dir, root.after or false }) do
      if directory then
        for _, extension in ipairs({ "vim", "lua" }) do
          local pattern = vim.fn.escape(directory, "\\*?[]{}") .. "/plugin/**/*." .. extension
          local files = vim.fn.glob(pattern, false, true)
          table.sort(files)
          for _, file in ipairs(files) do
            local profile = self.manager._profile
            if profile then
              profile.manual_sources = profile.manual_sources or {}
              profile.manual_sources[vim.fs.normalize(file)] = true
            end
            local frame = profile and profile:begin("script", owner, file)
            local sourced, failure = pcall(vim.api.nvim_cmd, {
              cmd = "source",
              args = { file },
            }, {})
            if frame then
              profile:leave(frame)
              profile.manual_sources[vim.fs.normalize(file)] = nil
            end
            U.check(sourced, "cannot source " .. file .. ": " .. tostring(failure))
            self:_guard(file)
          end
        end
      end
    end
  end, debug.traceback)
  root.loading, root.native, root.error = false, ok, not ok and err or nil
  U.check(ok, "runtime loading failed: " .. tostring(err))
end

function Runtime:mount(id)
  local node, state = self.manager.graph.nodes[id], self.manager.states[id]
  U.check(node, "unknown plugin " .. tostring(id))
  U.check(state.phase ~= "missing", id .. ": plugin directory is missing")
  local owner = self.manager.graph.nodes[node.owner]
  local roots, changed = {}, false
  for _, dir in ipairs(owner.dir == node.dir and { node.dir } or { owner.dir, node.dir }) do
    local root = self.roots[dir]
    U.check(root.available, id .. ": plugin directory is missing")
    roots[#roots + 1] = root
    if not root.mounted then
      self:_mark(root)
      changed = true
    end
  end
  if changed then
    local started = vim.uv.hrtime()
    self:_paths()
    state.mount_ms = (vim.uv.hrtime() - started) / 1e6
  end
  for _, root in ipairs(roots) do
    self:_source(root)
  end
end

return Runtime
