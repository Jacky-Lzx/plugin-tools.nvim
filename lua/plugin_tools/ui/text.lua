local M = {}
local width = vim.fn.strdisplaywidth

local function clean(value)
  return tostring(value):gsub("[%c]", " ")
end

local function error_text(value)
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" and type(value.message) == "string" then
    return value.message
  end
  return vim.inspect(value)
end

function M.fit(value, limit, suffix)
  value, limit = clean(value), math.max(0, limit)
  if width(value) <= limit then
    return value
  end
  suffix = suffix == nil and "…" or suffix
  if width(suffix) > limit then
    return ""
  end
  local low, high = 0, vim.fn.strchars(value)
  while low < high do
    local middle = math.ceil((low + high) / 2)
    if width(vim.fn.strcharpart(value, 0, middle)) + width(suffix) <= limit then
      low = middle
    else
      high = middle - 1
    end
  end
  return vim.fn.strcharpart(value, 0, low) .. suffix
end

local function pad(value, limit)
  value = M.fit(value, limit)
  return value .. string.rep(" ", math.max(0, limit - width(value)))
end

local function piece(value, available)
  local part = M.fit(value, available, "")
  if part == "" and value ~= "" then
    part = vim.fn.strcharpart(value, 0, 1)
  elseif #part < #value then
    local space = part:match("^.*()%s")
    if space and width(part:sub(1, space - 1)) >= available / 2 then
      return part:sub(1, space - 1), value:sub(space + 1)
    end
  end
  return part, value:sub(#part + 1)
end

local function home(path)
  if not path or path == "" then
    return "Not selected"
  end
  local directory = vim.uv.os_homedir()
  return directory
      and (path == directory or vim.startswith(path, directory .. "/"))
      and ("~" .. path:sub(#directory + 1))
    or path
end

local function path_label(path, limit)
  path = home(path)
  if width(path) <= limit then
    return path
  end
  local tail = vim.fs.basename(path)
  if width(tail) + 3 < limit then
    return M.fit(path:sub(1, #path - #tail), limit - width(tail) - 1) .. "/" .. tail
  end
  return M.fit(path, limit)
end

local Builder = {}
Builder.__index = Builder

function Builder:line(parts)
  parts = type(parts) == "string" and { { parts } } or parts or {}
  local text, marks = "  ", {}
  for _, part in ipairs(parts) do
    local value = clean(part[1])
    if part[2] then
      marks[#marks + 1] = { start = #text, finish = #text + #value, group = part[2] }
    end
    text = text .. value
  end
  text = M.fit(text, math.max(1, self.window_width - 2), "")
  local row = #self.lines + 1
  self.lines[row] = text
  for _, mark in ipairs(marks) do
    if mark.start < #text then
      mark.row, mark.finish = row - 1, math.min(mark.finish, #text)
      self.marks[#self.marks + 1] = mark
    end
  end
  return row
end

function Builder:wrap(value, indent, group)
  value, indent = clean(value), indent or ""
  local available = math.max(1, self.inner - width(indent))
  repeat
    local part, rest = piece(value, available)
    self:line({ { indent .. part, group } })
    value = rest
  until value == ""
end

function Builder:detail(label, value, group)
  local size = self.inner < 50 and 10 or 15
  local prefix = "    " .. pad(label, size)
  local available = math.max(1, self.inner - width(prefix))
  value = clean(value)
  repeat
    local part, rest = piece(value, available)
    self:line({ { prefix, "PluginToolsMuted" }, { part, group or "PluginToolsName" } })
    value, prefix = rest, string.rep(" ", width(prefix))
  until value == ""
end

function M.new(window_width)
  return setmetatable({
    window_width = window_width,
    inner = math.max(1, window_width - 4),
    lines = {},
    marks = {},
    rows = {},
    owners = {},
    by_id = {},
    selected = {},
  }, Builder)
end

function M.milliseconds(value)
  return value and ("%.3f ms"):format(value) or "—"
end

M.pad, M.home, M.path_label, M.error_text = pad, home, path_label, error_text
return M
