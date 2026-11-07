local H = dofile("tests/helpers.lua")
H.root = assert(vim.uv.fs_realpath(H.root))
local Tools = require("plugin_tools")
local Help = require("plugin_tools.help")
local U = require("plugin_tools.util")
local original = U.runtime_paths()

local function manager(directory, opts)
  U.set_runtime_paths(original)
  local spec = vim.tbl_extend("force", { id = "help-fixture", dir = directory, start = false }, opts or {})
  return Tools.new({ specs = { spec } }):start()
end

local function jump(tag, file)
  vim.cmd.help(tag)
  H.eq(vim.bo.buftype, "help")
  H.eq(vim.api.nvim_buf_get_name(0), file)
  vim.cmd.helpclose()
end

H.case("missing local tags are cached and help jumps into the original read-only checkout", function()
  local dir = H.root .. "/read-only, 中文 space"
  local file = dir .. "/doc/local-help.txt"
  H.write(file, "*local-help.txt*\tFixture\n\n*local-help-root*\n")
  assert(vim.uv.fs_chmod(file, 292)) -- 0444
  assert(vim.uv.fs_chmod(dir .. "/doc", 365)) -- 0555
  local m = manager(dir, { children = { { id = "same-root" } } })
  H.eq(m.states["help-fixture"].phase, "mounted")
  jump("local-help-root", file)
  jump("local-help.txt", file)
  assert(not vim.uv.fs_stat(dir .. "/doc/tags"))
  H.eq(vim.fn.readdir(dir .. "/doc"), { "local-help.txt" })
  H.eq(vim.uv.fs_stat(file).mode % 512, 292)
  local cache = assert(m.runtime.roots[dir].help)
  local count = 0
  for _, path in ipairs(U.runtime_paths()) do
    count = count + (path == cache and 1 or 0)
  end
  H.eq(count, 1)
  assert(vim.uv.fs_chmod(dir .. "/doc", 493)) -- 0755
end)

H.case("stale checkout tags do not hide new tags and cache reuse avoids regeneration", function()
  local dir = H.root .. "/stale"
  local file = dir .. "/doc/stale.txt"
  local stale = "old-help\tstale.txt\t/*old-help*"
  H.write(file, "*new-help*\n")
  H.write(dir .. "/doc/tags", stale)
  local m = manager(dir)
  jump("new-help", file)
  H.eq(vim.fn.readfile(dir .. "/doc/tags"), { stale })
  local cmd = vim.api.nvim_cmd
  local calls = 0
  vim.api.nvim_cmd = function(command, options)
    if command.cmd == "helptags" then
      calls = calls + 1
    end
    return cmd(command, options)
  end
  local cache = Help.prepare(dir)
  H.eq(cache, m.runtime.roots[dir].help)
  H.eq(calls, 0)
  vim.api.nvim_cmd = cmd
  assert(vim.uv.fs_unlink(cache .. "/doc/tags"))
  Help.prepare(dir)
  jump("new-help", file)
end)

H.case("changed, added and removed documentation refreshes cached indexes", function()
  local dir = H.root .. "/refresh"
  local file = dir .. "/doc/refresh.txt"
  H.write(file, "*before-refresh*\n")
  local m = manager(dir)
  local cache = assert(m.runtime.roots[dir].help)
  local before = vim.uv.fs_stat(file)
  H.write(file, "*after-refresh-longer*\n")
  assert(vim.uv.fs_utime(file, before.atime.sec, before.mtime.sec))
  H.write(dir .. "/doc/extra.txt", "*added-help*\n")
  Help.prepare(dir)
  jump("after-refresh-longer", file)
  jump("added-help", dir .. "/doc/extra.txt")
  local tags = table.concat(vim.fn.readfile(cache .. "/doc/tags"), "\n")
  assert(not tags:find("before-refresh", 1, true))
  assert(vim.uv.fs_unlink(dir .. "/doc/extra.txt"))
  Help.prepare(dir)
  tags = table.concat(vim.fn.readfile(cache .. "/doc/tags"), "\n")
  assert(not tags:find("added-help", 1, true))
end)

H.case("translated help gets native language indexes and removed translations disappear", function()
  local dir = H.root .. "/translated"
  H.write(dir .. "/doc/translated.txt", "*translated-help*\n")
  H.write(dir .. "/doc/translated.frx", "*translated-help*\n")
  local m = manager(dir)
  local cache = assert(m.runtime.roots[dir].help)
  jump("translated-help@fr", dir .. "/doc/translated.frx")
  assert(vim.uv.fs_unlink(dir .. "/doc/translated.frx"))
  Help.prepare(dir)
  assert(not vim.uv.fs_stat(cache .. "/doc/tags-fr"))
end)

H.case("nested documentation follows native helptags discovery", function()
  local dir = H.root .. "/nested"
  local file = dir .. "/doc/reference/nested.txt"
  H.write(file, "*nested-help*\n")
  manager(dir)
  jump("nested-help", file)
end)

H.case("on-demand documentation is indexed on mount without initializing the plugin", function()
  local dir = H.root .. "/on-demand"
  H.write(dir .. "/doc/cold.txt", "*cold-help*\n")
  local m = manager(dir, {
    mount = "on-demand",
    config = function()
      error("help indexing initialized the plugin")
    end,
  })
  H.eq(m.runtime.roots[dir].help, nil)
  m:mount("help-fixture")
  jump("cold-help", dir .. "/doc/cold.txt")
  H.eq(m.states["help-fixture"].phase, "mounted")
end)

H.case("the manager's own help is indexed even when it is not a declared package", function()
  manager(H.root .. "/on-demand")
  jump("plugin-tools-api", vim.fn.getcwd() .. "/doc/plugin-tools.txt")
end)

H.case("malformed documentation warns without preventing runtime startup", function()
  local dir = H.root .. "/bad-help"
  H.write(dir .. "/doc/bad.txt", "*duplicate-help*\n*duplicate-help*\n")
  local notify = vim.notify
  local warnings = {}
  vim.notify = function(message)
    warnings[#warnings + 1] = message
  end
  local m = manager(dir)
  H.eq(m.states["help-fixture"].phase, "mounted")
  assert(vim.wait(1000, function()
    return #warnings > 0
  end))
  assert(warnings[1]:find("cannot index help", 1, true))
  vim.notify = notify
end)

U.set_runtime_paths(original)
H.finish()
