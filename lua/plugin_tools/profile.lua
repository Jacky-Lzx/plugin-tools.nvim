local Profile = {}
Profile.__index = Profile
local sequence = 0

local function refresh(manager)
  local ui = package.loaded["plugin_tools.ui"]
  if ui then
    ui.refresh(manager)
  end
end

function Profile:begin(kind, id, file)
  local frame = { kind = kind, id = id, file = file, at = vim.uv.hrtime(), children = 0 }
  self.stack[#self.stack + 1] = frame
  return frame
end

function Profile:leave(frame)
  local now = vim.uv.hrtime()
  -- An interrupted source may not emit SourcePost. Keep activation frames
  -- balanced, without presenting incomplete script samples as measurements.
  while self.stack[#self.stack] ~= frame do
    if #self.stack == 0 then
      return
    end
    local interrupted = table.remove(self.stack)
    local parent = self.stack[#self.stack]
    if parent then
      parent.children = parent.children + now - interrupted.at
    end
    self.manager.timings.incomplete_sources = (self.manager.timings.incomplete_sources or 0) + 1
  end
  table.remove(self.stack)
  local elapsed = now - frame.at
  local own = math.max(0, elapsed - frame.children) / 1e6
  local parent = self.stack[#self.stack]
  if parent then
    parent.children = parent.children + elapsed
  end
  local state = frame.id and self.manager.states[frame.id]
  if frame.kind == "config" then
    state.duration_ms, state.self_ms = elapsed / 1e6, own
    state.activation = self.recording and "startup" or "on demand"
    local field = self.recording and "startup_config_ms" or "deferred_ms"
    state[field] = (state[field] or 0) + own
    if self.recording then
      self.manager.timings.config_ms = self.manager.timings.config_ms + own
    end
  else
    self.manager.timings.native_ms = self.manager.timings.native_ms + own
    if state then
      state.scripts_ms = (state.scripts_ms or 0) + own
      state.scripts = state.scripts or {}
      state.scripts[#state.scripts + 1] = { file = frame.file, duration_ms = elapsed / 1e6, self_ms = own }
    end
  end
  if state and self.recording then
    state.startup_ms = (state.startup_ms or 0) + own
  end
  refresh(self.manager)
end

function Profile:finish(reason)
  if not self.recording then
    return
  end
  local t = self.manager.timings
  t.complete, t.boundary = true, reason
  t.total_ms = t.resolve_ms + (vim.uv.hrtime() - self.manager._start_at) / 1e6
  t.other_ms = math.max(0, t.total_ms - t.resolve_ms - (t.mount_ms or 0) - t.config_ms - t.native_ms)
  t.incomplete_sources = (t.incomplete_sources or 0) + #self.stack
  self.stack, self.recording = {}, false
  if self.group then
    vim.api.nvim_del_augroup_by_id(self.group)
    self.group = nil
  end
  refresh(self.manager)
end

function Profile:started(ok)
  self.manager.timings.manager_ms = self.manager.timings.resolve_ms + self.manager.timings.start_ms
  if not ok or not self.before_enter then
    self:finish(ok and "manager" or "failed")
  end
end

function Profile.new(manager)
  local self = setmetatable({ manager = manager, stack = {}, recording = true }, Profile)
  local t = manager.timings
  t.enabled, t.complete, t.config_ms, t.native_ms = true, false, 0, 0
  t.mount_ms, t.manager_ms, t.total_ms, t.other_ms, t.boundary = nil, nil, nil, nil, nil
  t.incomplete_sources = 0
  self.before_enter = vim.v.vim_did_enter == 0
  t.scope = self.before_enter and "startup" or "manager"
  if not self.before_enter then
    return self
  end
  -- Match the most specific declared runtime root; shared roots are charged
  -- once to their package. No directory scans or require() wrappers are needed.
  local roots = {}
  for _, id in ipairs(manager.graph.order) do
    local node = manager.graph.nodes[id]
    if not roots[node.dir] or node.id == node.owner then
      roots[node.dir] = id
    end
  end
  -- Source events may report a real path (e.g. /private/var on macOS)
  -- while runtimepath retains the symlink spelling. Accept both aliases.
  for _, dir in ipairs(vim.tbl_keys(roots)) do
    local real = vim.uv.fs_realpath(dir)
    if real and not roots[real] then
      roots[real] = roots[dir]
    end
  end
  local paths = vim.tbl_keys(roots)
  table.sort(paths, function(a, b)
    return #a > #b
  end)
  sequence = sequence + 1
  self.group = vim.api.nvim_create_augroup("PluginToolsStartupProfile" .. sequence, { clear = true })
  vim.api.nvim_create_autocmd("SourcePre", {
    group = self.group,
    callback = function(args)
      local file, owner = vim.fs.normalize(args.file)
      for _, dir in ipairs(paths) do
        if vim.startswith(file, dir .. "/") then
          owner = roots[dir]
          break
        end
      end
      self:begin("script", owner, file)
    end,
  })
  vim.api.nvim_create_autocmd("SourcePost", {
    group = self.group,
    callback = function(args)
      local file = vim.fs.normalize(args.file)
      for i = #self.stack, 1, -1 do
        local frame = self.stack[i]
        if frame.kind == "script" and frame.file == file then
          self:leave(frame)
          break
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimEnter", {
    group = self.group,
    once = true,
    callback = function()
      self:finish("VimEnter")
    end,
  })
  return self
end

return Profile
