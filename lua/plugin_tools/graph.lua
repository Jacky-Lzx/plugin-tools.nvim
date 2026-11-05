local U = require("plugin_tools.util")
local M = {}
local fields = {
  id = true,
  source = true,
  dir = true,
  dev = true,
  version = true,
  path = true,
  children = true,
  dependencies = true,
  after = true,
  enabled = true,
  start = true,
  main = true,
  opts = true,
  bootstrap = true,
  config = true,
  build = true,
}
local scalars = { "source", "dir", "dev", "version", "path", "start", "main", "bootstrap", "config", "build" }

local function valid_id(id)
  return type(id) == "string" and id:match("^[%w][%w_.-]*$") and id ~= "." and id ~= ".."
end

local function list(value, label)
  U.check(type(value) == "table" and vim.islist(value), label .. " must be a list")
  return value
end

function M.resolve(specs, opts)
  opts = opts or {}
  local nodes, order, disabled = {}, {}, {}
  local function add(spec, parent)
    U.check(type(spec) == "table" and valid_id(spec.id), "each spec needs a safe, unique id")
    local id = spec.id
    for key in pairs(spec) do
      U.check(fields[key], id .. ": unknown field " .. tostring(key))
    end
    local enabled = spec.enabled
    if type(enabled) == "function" then
      enabled = enabled()
    end
    U.check(enabled == nil or type(enabled) == "boolean", id .. ": enabled must be boolean or a predicate")
    if enabled == false then
      disabled[id] = true
      return
    end
    local n = nodes[id]
    if not n then
      n = { id = id, opts = {}, dependencies = {}, after = {}, after_set = {}, parents = {}, roots = false }
      nodes[id], order[#order + 1] = n, id
    end
    if parent then
      n.parents[parent.id] = true
    else
      n.roots = true
    end
    local owner = (spec.source or spec.dir) and id or (parent and parent.owner or id)
    U.check(not n.owner or n.owner == owner, id .. ": conflicting package ownership")
    n.owner = owner
    for _, key in ipairs(scalars) do
      local value = spec[key]
      if value ~= nil then
        U.check(n[key] == nil or vim.deep_equal(n[key], value), id .. ": conflicting " .. key)
        n[key] = value
      end
    end
    U.check(spec.opts == nil or type(spec.opts) == "table", id .. ": opts must be a table")
    n.opts = U.merge(n.opts, spec.opts)
    for _, dep in ipairs(list(spec.dependencies or {}, id .. ".dependencies")) do
      local target, optional
      if type(dep) == "string" then
        target, optional = dep, false
      else
        U.check(type(dep) == "table", id .. ": invalid dependency")
        for key in pairs(dep) do
          U.check(key == "id" or key == "optional", id .. ": invalid dependency field " .. tostring(key))
        end
        U.check(dep.optional == nil or type(dep.optional) == "boolean", id .. ": optional must be boolean")
        target, optional = dep.id, dep.optional == true
      end
      U.check(valid_id(target), id .. ": invalid dependency id")
      local previous = n.dependencies[target]
      n.dependencies[target] = (previous == nil and optional) or (previous == true and optional) or false
    end
    for _, target in ipairs(list(spec.after or {}, id .. ".after")) do
      U.check(valid_id(target), id .. ": invalid after id")
      if not n.after_set[target] then
        n.after[#n.after + 1] = target
        n.after_set[target] = true
      end
    end
    for _, child in ipairs(list(spec.children or {}, id .. ".children")) do
      add(child, n)
    end
  end
  for _, spec in ipairs(list(specs, "specs")) do
    add(spec)
  end

  local packages, package_order = {}, {}
  local root = U.path(opts.root or (vim.fn.stdpath("data") .. "/plugin-tools"))
  for _, id in ipairs(order) do
    local n = nodes[id]
    U.check(not (n.source and n.dir), id .. ": source and dir are mutually exclusive")
    for _, key in ipairs({ "source", "dir", "version", "main", "path" }) do
      U.check(n[key] == nil or (type(n[key]) == "string" and n[key] ~= ""), id .. ": invalid " .. key)
    end
    for _, key in ipairs({ "dev", "start" }) do
      U.check(n[key] == nil or type(n[key]) == "boolean", id .. ": " .. key .. " must be boolean")
    end
    U.check(n.bootstrap == nil or type(n.bootstrap) == "function", id .. ": bootstrap must be a function")
    U.check(n.config == nil or n.config == false or type(n.config) == "function", id .. ": invalid config")
    U.check(
      n.build == nil
        or type(n.build) == "function"
        or (type(n.build) == "table" and vim.islist(n.build) and #n.build > 0),
      id .. ": build must be argv or a function"
    )
    if n.start == nil then
      n.start = n.roots
    end
    if n.owner == id then
      U.check(n.source or n.dir, id .. ": a top-level package needs source or dir")
      U.check(not n.path, id .. ": path belongs on same-package children")
      local dir, managed = n.dir and U.path(n.dir) or (root .. "/" .. id), n.dir == nil
      if n.dev then
        U.check(type(opts.dev) == "table" and type(opts.dev.path) == "string", id .. ": dev.path is required")
        local candidate = U.path(opts.dev.path) .. "/" .. id
        if U.directory(candidate) then
          dir, managed = candidate, false
        else
          U.check(opts.dev.fallback ~= false, id .. ": development directory missing: " .. candidate)
        end
      end
      local source = n.source
      if source and source:match("^[%w_.-]+/[%w_.-]+$") then
        source = (opts.url_format or "https://github.com/%s.git"):format(source)
      elseif source and (source:match("^[./~$]") or source:match("^%a:[/\\]")) then
        source = U.path(source)
      end
      n.package = { id = id, dir = dir, source = source, managed = managed, version = n.version, build = n.build }
      packages[id], package_order[#package_order + 1] = n.package, id
    end
  end
  for _, id in ipairs(order) do
    local n = nodes[id]
    local package = packages[n.owner]
    U.check(package, id .. ": missing package owner " .. n.owner)
    n.package = package
    if n.owner ~= id then
      U.check(not n.version and not n.dev and not n.build, id .. ": version/dev/build belong on the package owner")
    end
    if n.path then
      local normalized = vim.fs.normalize(n.path)
      U.check(
        not normalized:match("^/")
          and not normalized:match("^%.%.$")
          and not normalized:match("^%.%./")
          and not normalized:match("^%a:"),
        id .. ": path must stay inside its package"
      )
      n.path = normalized
    end
    n.dir = package.dir .. (n.path and ("/" .. n.path) or "")
    for dep, optional in pairs(n.dependencies) do
      U.check(
        optional or nodes[dep],
        id .. ": required dependency " .. dep .. (disabled[dep] and " is disabled" or " is undeclared")
      )
    end
  end

  -- Only explicit initialization constraints are edges in this graph.
  local sorted, visiting, visited, stack = {}, {}, {}, {}
  local function visit(id)
    U.check(nodes[id], "after references undeclared or disabled plugin " .. id)
    U.check(not visiting[id], "initialization cycle: " .. table.concat(stack, " -> ") .. " -> " .. id)
    if visited[id] then
      return
    end
    visiting[id], stack[#stack + 1] = true, id
    for _, before in ipairs(nodes[id].after) do
      visit(before)
    end
    stack[#stack], visiting[id], visited[id] = nil, nil, true
    sorted[#sorted + 1] = id
  end
  for _, id in ipairs(order) do
    visit(id)
  end
  return {
    nodes = nodes,
    order = order,
    activation_order = sorted,
    packages = packages,
    package_order = package_order,
    root = root,
  }
end

return M
