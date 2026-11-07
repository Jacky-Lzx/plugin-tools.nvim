local M = {}
local uv = vim.uv

local function stamp(stat)
  return { stat.size, stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec }
end

local function documents(directory)
  local files = {}
  local seen = {}
  local function scan(relative)
    local path = directory .. (relative == "" and "" or "/" .. relative)
    local real = uv.fs_realpath(path)
    if not real or seen[real] then
      return
    end
    seen[real] = true
    local entries = assert(uv.fs_scandir(path))
    while true do
      local name = uv.fs_scandir_next(entries)
      if not name then
        break
      end
      local file = relative == "" and name or relative .. "/" .. name
      local stat = uv.fs_stat(directory .. "/" .. file)
      if stat and stat.type == "directory" then
        scan(file)
      elseif stat and stat.type == "file" and (name:match("%.txt$") or name:match("%.[a-z][a-z]x$")) then
        files[#files + 1] = { name = file, stamp = stamp(stat) }
      end
    end
  end
  scan("")
  table.sort(files, function(a, b)
    return a.name < b.name
  end)
  return files
end

local function prepare(root)
  local source = root .. "/doc"
  if not uv.fs_stat(source) then
    return
  end
  local files = documents(source)
  if #files == 0 then
    return
  end
  local parent = vim.fn.stdpath("cache") .. "/plugin-tools/help"
  local cache = parent .. "/" .. vim.fn.sha256(root)
  local signature = vim.json.encode(files)
  local metadata = cache .. "/index.json"
  local ok, saved = pcall(vim.fn.readfile, metadata)
  if ok then
    local decoded, index = pcall(vim.json.decode, table.concat(saved, "\n"))
    if decoded and type(index) == "table" and index.signature == signature and type(index.tags) == "table" then
      local complete = true
      for _, name in ipairs(index.tags) do
        complete = complete and uv.fs_stat(cache .. "/doc/" .. name) ~= nil
      end
      if complete then
        return cache
      end
    end
  end

  vim.fn.mkdir(parent, "p")
  local stage = assert(uv.fs_mkdtemp(parent .. "/.build-XXXXXX"))
  local built, failure = xpcall(function()
    vim.fn.mkdir(stage .. "/doc", "p")
    for _, file in ipairs(files) do
      vim.fn.mkdir(vim.fs.dirname(stage .. "/doc/" .. file.name), "p")
      assert(uv.fs_copyfile(source .. "/" .. file.name, stage .. "/doc/" .. file.name))
    end
    vim.api.nvim_cmd({ cmd = "helptags", args = { stage .. "/doc" } }, {})
    local tags = {}
    for name, kind in vim.fs.dir(stage .. "/doc") do
      if kind == "file" and (name == "tags" or name:match("^tags%-[a-z][a-z]$")) then
        local lines = vim.fn.readfile(stage .. "/doc/" .. name)
        for i, line in ipairs(lines) do
          if not line:match("^!_TAG_") then
            -- Help tag files support absolute filenames. Keep jumps in the
            -- original checkout, without copying docs onto runtimepath.
            lines[i] = line:gsub("^(.-\t)([^\t]+)(\t)", function(tag, file, separator)
              return tag .. source .. "/" .. file .. separator
            end, 1)
          end
        end
        vim.fn.writefile(lines, stage .. "/doc/" .. name)
        tags[#tags + 1] = name
      end
    end
    table.sort(tags)
    vim.fn.mkdir(cache .. "/doc", "p")
    for _, name in ipairs(tags) do
      assert(uv.fs_rename(stage .. "/doc/" .. name, cache .. "/doc/" .. name))
    end
    -- Remove indexes for translations that no longer exist.
    for name in vim.fs.dir(cache .. "/doc") do
      if (name == "tags" or name:match("^tags%-[a-z][a-z]$")) and not vim.list_contains(tags, name) then
        assert(uv.fs_unlink(cache .. "/doc/" .. name))
      end
    end
    vim.fn.writefile({ vim.json.encode({ signature = signature, tags = tags }) }, stage .. "/index.json")
    assert(uv.fs_rename(stage .. "/index.json", metadata))
  end, debug.traceback)
  vim.fn.delete(stage, "rf")
  assert(built, failure)
  return cache
end

-- No source-tree writes, Git, subprocesses, or plugin activation. A bad help
-- file must not prevent the plugin's runtime from mounting.
function M.prepare(root)
  local ok, cache = pcall(prepare, root)
  if not ok then
    vim.schedule(function()
      vim.notify("plugin-tools: cannot index help for " .. root .. ": " .. tostring(cache), vim.log.levels.WARN)
    end)
    return
  end
  return cache
end

return M
