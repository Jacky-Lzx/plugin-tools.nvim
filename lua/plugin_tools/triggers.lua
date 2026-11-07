local M = {}
local sequence = 0

function M.watch(manager)
  local waiting, count = {}, 0
  for _, id in ipairs(manager.graph.activation_order) do
    local n, state = manager.graph.nodes[id], manager.states[id]
    if #n.ft > 0 and state.phase ~= "ready" and state.phase ~= "missing" then
      waiting[id], count = true, count + 1
    end
  end
  if count == 0 then
    return
  end
  sequence = sequence + 1
  local group = vim.api.nvim_create_augroup("PluginToolsFiletypes" .. sequence, { clear = true })
  local function activate(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local ft = vim.bo[buf].filetype
    if ft == "" then
      return
    end
    for _, id in ipairs(manager.graph.activation_order) do
      local state = manager.states[id]
      if waiting[id] and state.phase ~= "initializing" then
        if state.phase == "ready" or state.phase == "failed" then
          waiting[id], count = nil, count - 1
        elseif manager.graph.nodes[id].ft_set[ft] then
          waiting[id], count = nil, count - 1
          state.reason = "FileType " .. ft
          manager:activate(id, { kind = "filetype", filetype = ft })
        end
      end
    end
    if count == 0 and group then
      vim.api.nvim_del_augroup_by_id(group)
      group = nil
    end
  end
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    callback = function(ev)
      activate(ev.buf)
    end,
  })
  -- setup() can also run after the first FileType, or on an existing session.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      activate(buf)
    end
  end
end

return M
