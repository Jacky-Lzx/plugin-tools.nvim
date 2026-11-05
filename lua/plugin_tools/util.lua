local M = {}
local uv = vim.uv

function M.fail(message)
  error("plugin-tools: " .. message, 0)
end

function M.check(ok, message)
  if not ok then
    M.fail(message)
  end
  return ok
end

function M.path(path)
  M.check(type(path) == "string" and path ~= "", "expected a nonempty path")
  local normalized = vim.fs.normalize(path)
  if not normalized:match("^/") and not normalized:match("^%a:/") then
    normalized = vim.fs.normalize(uv.cwd() .. "/" .. normalized)
  end
  return normalized
end

function M.exists(path)
  return uv.fs_stat(path) ~= nil
end

function M.directory(path)
  local stat = uv.fs_stat(path)
  return stat and stat.type == "directory" or false
end

-- vim.opt.runtimepath:get() splits escaped commas as well. Parse the raw
-- option so plugin directories may contain commas without losing entries.
function M.runtime_paths()
  local paths, chars, raw, i = {}, {}, vim.o.runtimepath, 1
  while i <= #raw do
    local char = raw:sub(i, i)
    if char == "\\" and i < #raw then
      i = i + 1
      chars[#chars + 1] = raw:sub(i, i)
    elseif char == "," then
      paths[#paths + 1], chars = table.concat(chars), {}
    else
      chars[#chars + 1] = char
    end
    i = i + 1
  end
  paths[#paths + 1] = table.concat(chars)
  return paths
end

function M.set_runtime_paths(paths)
  local encoded = {}
  for i, path in ipairs(paths) do
    encoded[i] = vim.fn.escape(path, ",\\")
  end
  vim.api.nvim_set_option_value("runtimepath", table.concat(encoded, ","), {})
end

function M.mkdir(path)
  vim.fn.mkdir(path, "p")
  M.check(M.directory(path), "cannot create directory " .. path)
end

function M.read_json(path, default)
  local file = io.open(path, "rb")
  if not file then
    M.check(not uv.fs_lstat(path), "cannot read " .. path)
    return default
  end
  local data = file:read("*a")
  file:close()
  local ok, value = pcall(vim.json.decode, data)
  M.check(ok and type(value) == "table", "invalid JSON in " .. path)
  return value
end

function M.write_json(path, value)
  M.mkdir(vim.fs.dirname(path))
  local temporary, err = uv.fs_mkstemp(path .. ".XXXXXX")
  M.check(temporary, "cannot create temporary file: " .. tostring(err))
  -- fs_mkstemp returns a descriptor followed by its path.
  local fd, name = temporary, err
  local data = vim.json.encode(value) .. "\n"
  local count, write_err = uv.fs_write(fd, data, 0)
  local synced, sync_err = uv.fs_fsync(fd)
  uv.fs_close(fd)
  if count ~= #data or not synced then
    uv.fs_unlink(name)
    M.fail("cannot write " .. path .. ": " .. tostring(write_err or sync_err))
  end
  local ok, rename_err = uv.fs_rename(name, path)
  if not ok then
    uv.fs_unlink(name)
    M.fail("cannot replace " .. path .. ": " .. tostring(rename_err))
  end
end

-- The graph owns base exclusively. Copy incoming values once; maps merge in
-- place while lists and explicit empty tables replace the previous key.
function M.merge_into(base, extra)
  for key, value in pairs(extra) do
    if type(value) == "table" and next(value) and not vim.islist(value) and type(base[key]) == "table" then
      M.merge_into(base[key], value)
    else
      base[key] = vim.deepcopy(value)
    end
  end
end

return M
