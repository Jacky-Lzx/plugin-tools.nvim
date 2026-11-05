local Render = require("plugin_tools.ui.render")
local Style = require("plugin_tools.ui.style")
local namespace = vim.api.nvim_create_namespace("plugin-tools-panel")
local M = {}
local views = setmetatable({}, { __mode = "k" })
local View = {}
View.__index = View

local function geometry()
  local available_width = math.max(1, vim.o.columns - 4)
  local available_height = math.max(1, vim.o.lines - vim.o.cmdheight - 4)
  local width = math.min(132, available_width, math.max(36, math.floor(vim.o.columns * 0.88)))
  local height = math.min(40, available_height, math.max(10, math.floor(available_height * 0.84)))
  return {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    title = " " .. Render.fit("Plugin Tools", math.max(1, width - 2)) .. " ",
    title_pos = "left",
    footer = " " .. Render.fit("q Close   l Log   r Refresh   ? Help", math.max(1, width - 2)) .. " ",
    footer_pos = "right",
  }
end

function View:valid()
  return vim.api.nvim_buf_is_valid(self.buf)
end

function View:window()
  local win = self.win
  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == self.buf then
    return win
  end
  win = vim.fn.bufwinid(self.buf)
  return win ~= -1 and win or nil
end

function View:render()
  if not self:valid() then
    return
  end
  local win = self:window()
  local cursor = win and vim.api.nvim_win_get_cursor(win)
  local viewport = win and vim.api.nvim_win_call(win, vim.fn.winsaveview)
  local current = cursor and self.owners and self.owners[cursor[1]]
  local offset = current and self.by_id and (cursor[1] - self.by_id[current]) or 0
  self.positions = self.positions or {}
  if self.rendered_mode and cursor then
    self.positions[self.rendered_mode] = { id = current, offset = offset, row = cursor[1], topline = viewport.topline }
  end
  local anchor = self.positions[self.mode]
  local panel = Render.render(self, win and vim.api.nvim_win_get_width(win) or vim.o.columns)
  self.rows, self.owners, self.by_id = panel.rows, panel.owners, panel.by_id
  self.content_start = panel.content_start
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, panel.lines)
  vim.bo[self.buf].modifiable, vim.bo[self.buf].modified = false, false
  vim.api.nvim_buf_clear_namespace(self.buf, namespace, 0, -1)
  for _, row in ipairs(panel.selected) do
    vim.api.nvim_buf_set_extmark(
      self.buf,
      namespace,
      row,
      0,
      { line_hl_group = "PluginToolsSelectedLine", priority = 50 }
    )
  end
  for _, mark in ipairs(panel.marks) do
    vim.api.nvim_buf_set_extmark(self.buf, namespace, mark.row, mark.start, {
      end_col = mark.finish,
      hl_group = mark.group,
      priority = 100,
    })
  end
  if win then
    current, offset = anchor and anchor.id, anchor and anchor.offset or 0
    local target = current and panel.by_id[current]
    if target then
      if panel.owners[target + offset] == current then
        target = target + offset
      end
    elseif self.mode == "status" then
      for row in pairs(panel.rows) do
        target = math.min(target or row, row)
      end
    end
    if not target then
      target = math.min(#panel.lines, math.max(panel.content_start, anchor and anchor.row or 1))
    end
    local top = anchor and anchor.topline or 1
    if top > 1 then
      top = math.max(1, top + target - anchor.row)
    end
    local first
    for row in pairs(panel.rows) do
      first = math.min(first or row, row)
    end
    if target == first then
      top = 1
    end
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ lnum = target, col = 0, topline = top, leftcol = 0 })
    end)
  end
  self.rendered_mode = self.mode
end

function View:move(direction)
  if self.mode ~= "status" then
    vim.cmd.normal({ args = { direction > 0 and "j" or "k" }, bang = true })
    return
  end
  local current, target = vim.api.nvim_win_get_cursor(0)[1]
  for row in pairs(self.rows) do
    if direction > 0 and row > current then
      target = math.min(target or row, row)
    elseif direction < 0 and row < current then
      target = math.max(target or row, row)
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
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
  return self.owners[vim.api.nvim_win_get_cursor(0)[1]]
end

function View:operate(action, opts)
  opts = opts or {}
  if action ~= "clean" and action ~= "recover" and not opts.plan then
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
  Style.setup()
  local view = views[manager]
  if not view or not view:valid() then
    view = setmetatable({
      manager = manager,
      buf = vim.api.nvim_create_buf(false, true),
      filter = "",
      selected = {},
      expanded = {},
      full = {},
    }, View)
    views[manager] = view
    view.group = vim.api.nvim_create_augroup("PluginToolsPanel" .. view.buf, { clear = true })
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
    local function close()
      local win = view:window()
      if win then
        vim.api.nvim_win_close(win, true)
      end
    end
    map("q", close, "Close")
    map("<Esc>", close, "Close")
    map("j", function()
      view:move(1)
    end, "Next plugin")
    map("k", function()
      view:move(-1)
    end, "Previous plugin")
    map("?", function()
      if view.mode == "help" then
        view.mode = view.return_mode or "status"
      else
        view.return_mode, view.mode = view.mode, "help"
      end
      view:render()
    end, "Help")
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
    map("o", function()
      local id = view:current()
      if id then
        view.expanded[id], view.full[id] = true, not view.full[id]
        view:render()
      end
    end, "Full configuration")
    map("l", function()
      view.mode = view.mode == "log" and "status" or "log"
      view:render()
    end, "Toggle operation log")
    for key, action in pairs({ u = "update", i = "install", s = "restore", f = "freeze", p = "plan" }) do
      map(key, function()
        view:operate(action)
      end, action)
    end
    map("c", function()
      view:operate("clean")
    end, "Preview cleanup")
    map("a", function()
      if not manager.last_plan then
        vim.notify("PluginTools: create a plan with p first", vim.log.levels.WARN)
        return
      end
      view:operate("update", { plan = manager.last_plan })
    end, "Apply reviewed plan")
    map("R", function()
      view:operate("recover")
    end, "Preview crash recovery")
    map("C", function()
      view:operate("clean", { dry_run = false })
    end, "Apply cleanup")
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = view.group,
      buffer = view.buf,
      once = true,
      callback = function()
        if view.unsubscribe then
          view.unsubscribe()
        end
        views[manager] = nil
        pcall(vim.api.nvim_del_augroup_by_id, view.group)
      end,
    })
    vim.api.nvim_create_autocmd("BufEnter", {
      group = view.group,
      buffer = view.buf,
      callback = function()
        view:attach(manager.last_operation)
      end,
    })
    vim.api.nvim_create_autocmd("WinResized", {
      group = view.group,
      callback = function()
        view:refresh()
      end,
    })
    vim.api.nvim_create_autocmd("VimResized", {
      group = view.group,
      callback = function()
        local win = view:window()
        if win then
          if vim.api.nvim_win_get_config(win).relative ~= "" then
            vim.api.nvim_win_set_config(win, geometry())
          end
          view:refresh()
        end
      end,
    })
  end
  view.mode = opts.mode or "status"
  if opts.id then
    manager:explain(opts.id)
    view.expanded[opts.id], view.filter = true, opts.id
  end
  local win = view:window()
  if win then
    vim.api.nvim_set_current_win(win)
  else
    win = vim.api.nvim_open_win(view.buf, true, geometry())
  end
  view.win = win
  vim.wo.wrap, vim.wo.number, vim.wo.relativenumber = false, false, false
  vim.wo.signcolumn = "no"
  vim.wo.cursorline = true
  vim.wo.cursorlineopt = "line"
  vim.wo.foldcolumn, vim.wo.colorcolumn, vim.wo.winbar, vim.wo.statuscolumn = "0", "", "", ""
  vim.wo.spell, vim.wo.list = false, false
  vim.wo.scrolloff, vim.wo.sidescrolloff = 0, 0
  vim.wo.winhighlight =
    "Normal:PluginToolsNormal,FloatBorder:PluginToolsBorder,FloatTitle:PluginToolsTitle,FloatFooter:PluginToolsMuted,CursorLine:PluginToolsCursorLine"
  view:attach(manager.last_operation)
  return view
end

return M
