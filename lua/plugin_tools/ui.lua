local M = {}
local views = setmetatable({}, { __mode = "k" })
local View = {}
View.__index = View

function View:valid()
  return vim.api.nvim_buf_is_valid(self.buf)
end

function View:render()
  if not self:valid() then
    return
  end
  local win = vim.fn.bufwinid(self.buf)
  local current = win ~= -1 and self.rows and self.rows[vim.api.nvim_win_get_cursor(win)[1]]
  local lines = {
    "PluginTools",
    " / filter  <Space> select  <CR> details  u update  i install  s restore  f freeze",
    " r refresh  l log/status  c clean preview  C clean apply  q close",
    "Filter: " .. self.filter .. " | Selected: " .. vim.tbl_count(self.selected),
  }
  local task = self.manager.last_operation
  if task then
    lines[#lines + 1] = ("Operation: %s | %s | %d/%d"):format(task.action, task.phase, task.completed, task.total)
    if task.error then
      lines[#lines + 1] = "Error: " .. (task.failure and task.failure.message or task.error):match("[^\n]+")
    elseif task.result and task.result.restart_required then
      lines[#lines + 1] = "Restart Neovim to use changed plugin files."
    end
    if task.action == "clean" and task.result then
      lines[#lines + 1] = "Cleanup "
        .. (task.result.dry_run and "preview: " or "removed: ")
        .. table.concat(task.result.packages, ", ")
    end
  end
  lines[#lines + 1] = ""
  self.rows = {}
  if self.mode == "log" then
    lines[#lines + 1] = "Operation log"
    for _, event in ipairs(task and task.events or {}) do
      lines[#lines + 1] = ("%8.1f ms  %-14s %s"):format(event.elapsed_ms, event.phase, event.id or "")
      if event.command then
        lines[#lines + 1] = "  " .. table.concat(event.command, " ")
      end
      for _, field in ipairs({ "stdout", "stderr" }) do
        for _, line in ipairs(vim.split(event[field] or "", "\n", { plain = true, trimempty = true })) do
          lines[#lines + 1] = "  " .. line
        end
      end
      if event.error then
        for _, line in ipairs(vim.split(event.error.message, "\n", { plain = true })) do
          lines[#lines + 1] = "  " .. line
        end
      end
    end
  else
    lines[#lines + 1] = "  Plugin                        Runtime      Location  Operation"
    for _, item in ipairs(self.manager:status()) do
      if (item.id .. " " .. item.dir):lower():find(self.filter:lower(), 1, true) then
        local progress = task and task.items[item.package]
        lines[#lines + 1] = ("%s %-29s %-12s %-9s %s"):format(
          self.selected[item.id] and "*" or " ",
          item.id,
          item.state.phase,
          item.managed and "managed" or "local",
          (progress and progress.phase or "") .. "  " .. item.dir
        )
        self.rows[#lines] = item.id
        if self.expanded[item.id] then
          for _, line in ipairs(vim.split(vim.inspect(self.manager:explain(item.id)), "\n", { plain = true })) do
            lines[#lines + 1] = "    " .. line
          end
        end
      end
    end
  end
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
  if current and win ~= -1 then
    for row, id in pairs(self.rows) do
      if id == current then
        vim.api.nvim_win_set_cursor(win, { row, 0 })
        break
      end
    end
  end
end

function View:refresh()
  if self.scheduled then
    return
  end
  self.scheduled = true
  vim.schedule(function()
    self.scheduled = false
    self:render()
  end)
end

function View:attach(task)
  if self.unsubscribe then
    self.unsubscribe()
  end
  self.task = task
  self.unsubscribe = task and task:subscribe(function()
    self:refresh()
  end) or nil
  self:render()
end

function View:current()
  return self.rows[vim.api.nvim_win_get_cursor(0)[1]]
end

function View:operate(action, opts)
  opts = opts or {}
  if action ~= "clean" then
    local ids = vim.tbl_keys(self.selected)
    if #ids == 0 and self:current() then
      ids = { self:current() }
    end
    if #ids == 0 then
      vim.notify("PluginTools: select a plugin first", vim.log.levels.WARN)
      return
    end
    table.sort(ids)
    opts.ids = ids
  end
  local ok, task = pcall(self.manager[action], self.manager, opts)
  if not ok then
    vim.notify(tostring(task), vim.log.levels.ERROR)
    return
  end
  self:attach(task)
end

function M.track(manager, task)
  local view = views[manager]
  if view and view:valid() then
    view:attach(task)
  end
end

function M.open(manager, opts)
  opts = opts or {}
  local view = views[manager]
  if not view or not view:valid() then
    view = setmetatable(
      { manager = manager, buf = vim.api.nvim_create_buf(false, true), filter = "", selected = {}, expanded = {} },
      View
    )
    views[manager] = view
    vim.bo[view.buf].bufhidden = "wipe"
    vim.bo[view.buf].filetype = "plugin-tools"
    vim.api.nvim_buf_set_name(view.buf, "plugin-tools://" .. view.buf)
    local function map(key, callback, desc)
      vim.keymap.set(
        "n",
        key,
        callback,
        { buffer = view.buf, silent = true, nowait = true, desc = "PluginTools: " .. desc }
      )
    end
    map("q", function()
      vim.cmd.close()
    end, "Close")
    map("r", function()
      view:attach(manager.last_operation)
    end, "Refresh")
    map("/", function()
      vim.ui.input({ prompt = "Plugin filter: ", default = view.filter }, function(value)
        if value and view:valid() then
          view.filter = value
          view:render()
        end
      end)
    end, "Filter")
    map("<Space>", function()
      local id = view:current()
      if id then
        view.selected[id] = not view.selected[id] or nil
        view:render()
      end
    end, "Select")
    map("<CR>", function()
      local id = view:current()
      if id then
        view.expanded[id] = not view.expanded[id]
        view:render()
      end
    end, "Details")
    map("l", function()
      view.mode = view.mode == "log" and "status" or "log"
      view:render()
    end, "Toggle operation log")
    for key, action in pairs({ u = "update", i = "install", s = "restore", f = "freeze" }) do
      map(key, function()
        view:operate(action)
      end, action)
    end
    map("c", function()
      view:operate("clean")
    end, "Preview cleanup")
    map("C", function()
      view:operate("clean", { dry_run = false })
    end, "Apply cleanup")
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = view.buf,
      once = true,
      callback = function()
        if view.unsubscribe then
          view.unsubscribe()
        end
        views[manager] = nil
      end,
    })
    vim.api.nvim_create_autocmd("BufEnter", {
      buffer = view.buf,
      callback = function()
        view:attach(manager.last_operation)
      end,
    })
  end
  view.mode = opts.mode or "status"
  if opts.id then
    manager:explain(opts.id)
    view.expanded[opts.id], view.filter = true, opts.id
  end
  local win = vim.fn.bufwinid(view.buf)
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd("botright 16split")
    vim.api.nvim_win_set_buf(0, view.buf)
  end
  vim.wo.wrap, vim.wo.number, vim.wo.relativenumber = false, false, false
  vim.wo.signcolumn = "no"
  view:attach(manager.last_operation)
  return view
end

return M
