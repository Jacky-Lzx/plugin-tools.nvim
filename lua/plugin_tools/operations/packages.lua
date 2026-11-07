local U = require("plugin_tools.util")
local uv = vim.uv
local M = {}

function M.lock_data(manager)
  local data = U.read_json(manager.lockfile, { version = 1, plugins = {} })
  U.check(data.version == 1 and type(data.plugins) == "table", "unsupported lockfile " .. manager.lockfile)
  for id, entry in pairs(data.plugins) do
    U.check(
      type(id) == "string"
        and type(entry) == "table"
        and type(entry.source) == "string"
        and type(entry.commit) == "string"
        and entry.commit:match("^%x+$")
        and #entry.commit == 40,
      "invalid lockfile entry " .. tostring(id)
    )
  end
  return data
end

function M.owned(package)
  local stat = uv.fs_lstat(package.dir)
  if not stat then
    return false
  end
  U.check(stat.type == "directory", "refusing non-directory package " .. package.dir)
  local git = uv.fs_lstat(package.dir .. "/.git")
  U.check(git and git.type == "directory", "refusing unmanaged checkout " .. package.dir)
  local marker = U.read_json(package.dir .. "/.git/plugin-tools-owner.json", {})
  U.check(marker.id == package.id and marker.source == package.source, "ownership/source mismatch for " .. package.dir)
  return true, marker
end

function M.selected(manager, opts)
  local wanted = {}
  if opts.ids then
    U.check(type(opts.ids) == "table" and vim.islist(opts.ids), "ids must be a list")
    for _, id in ipairs(opts.ids) do
      local n = manager.graph.nodes[id]
      U.check(n, "unknown plugin " .. tostring(id))
      wanted[n.owner] = true
    end
  end
  local out = {}
  for _, id in ipairs(manager.graph.package_order) do
    local p = manager.graph.packages[id]
    if p.managed and (not opts.ids or wanted[id]) then
      out[#out + 1] = p
    end
  end
  return out
end

return M
