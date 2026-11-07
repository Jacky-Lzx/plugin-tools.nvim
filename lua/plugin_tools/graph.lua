local U = require("plugin_tools.util")
local P = require("plugin_tools.provenance")
local M = {}
local fields = {
  id = true,
  origin = true,
  source = true,
  dir = true,
  dev = true,
  version = true,
  path = true,
  children = true,
  dependencies = true,
  after = true,
  enabled = true,
  optional = true,
  start = true,
  mount = true,
  ft = true,
  main = true,
  opts = true,
  config = true,
  build = true,
}
local scalars = { "source", "dir", "dev", "version", "path", "start", "mount", "main", "config", "build" }

local function valid_id(id)
  return type(id) == "string" and id:match("^[%w][%w_.-]*$") and id ~= "." and id ~= ".."
end

local function list(value, label)
  U.check(type(value) == "table" and vim.islist(value), label .. " must be a list")
  return value
end

function M.resolve(specs, opts)
  opts = opts or {}
  local nodes, order, disabled, declarations, unselected = {}, {}, {}, {}, {}
  local selected, waiting, pending, inputs = {}, {}, {}, {}
  local function enqueue(item)
    item.selected = true
    pending[#pending + 1] = item
  end
  local function prepare(spec)
    U.check(type(spec) == "table" and valid_id(spec.id), "each spec needs a safe, unique id")
    local id = spec.id
    U.check(spec.origin == nil or (type(spec.origin) == "string" and spec.origin ~= ""), id .. ": invalid origin")
    for key in pairs(spec) do
      U.check(fields[key], id .. ": unknown field " .. tostring(key))
    end
    U.check(spec.optional == nil or type(spec.optional) == "boolean", id .. ": optional must be boolean")
    local enabled = spec.enabled
    if type(enabled) == "function" then
      enabled = enabled()
    end
    U.check(enabled == nil or type(enabled) == "boolean", id .. ": enabled must be boolean or a predicate")
    local item = { spec = spec, enabled = enabled ~= false }
    if item.enabled then
      if spec.optional ~= true then
        if not selected[id] then
          selected[id] = true
          for _, candidate in ipairs(waiting[id] or {}) do
            enqueue(candidate)
          end
          waiting[id] = nil
        end
        enqueue(item)
      elseif selected[id] then
        enqueue(item)
      else
        waiting[id] = waiting[id] or {}
        waiting[id][#waiting[id] + 1] = item
      end
    end
    return item
  end
  for _, spec in ipairs(list(specs, "specs")) do
    inputs[#inputs + 1] = prepare(spec)
  end
  -- Expand only selected subtrees. Waiting declarations are released by an
  -- explicit non-optional declaration, never by dependency references.
  local cursor = 1
  while pending[cursor] do
    local item = pending[cursor]
    item.children = {}
    for _, child in ipairs(list(item.spec.children or {}, item.spec.id .. ".children")) do
      item.children[#item.children + 1] = prepare(child)
    end
    cursor = cursor + 1
  end
  local function add(item, parent, position, inherited_origin)
    local spec, enabled = item.spec, item.enabled
    local id = spec.id
    local contributions = declarations[id] or {}
    declarations[id] = contributions
    local declaration = {
      origin = spec.origin or inherited_origin or "manifest",
      position = position,
      index = #contributions + 1,
      parent = parent and parent.id,
      enabled = enabled,
      optional = spec.optional == true,
      selection = not enabled and "disabled" or item.selected and "selected" or "unselected",
      fields = {},
    }
    for key in pairs(spec) do
      if key ~= "id" and key ~= "origin" and key ~= "children" then
        declaration.fields[#declaration.fields + 1] = key
      end
    end
    table.sort(declaration.fields)
    contributions[#contributions + 1] = declaration
    if not enabled then
      disabled[id] = true
      return
    end
    if not item.selected then
      unselected[id] = true
      return
    end
    local n = nodes[id]
    if not n then
      n = {
        id = id,
        opts = {},
        dependencies = {},
        after = {},
        after_set = {},
        ft = {},
        ft_set = {},
        parents = {},
        roots = false,
        declarations = contributions,
        option_history = {},
        field_origins = {},
      }
      nodes[id], order[#order + 1] = n, id
    end
    if parent then
      n.parents[parent.id] = true
    else
      n.roots = true
    end
    local owner = (spec.source or spec.dir) and id or (parent and parent.owner or id)
    U.check(
      not n.owner or n.owner == owner,
      id
        .. ": conflicting package ownership between "
        .. (n.owner_origin or P.label(declaration))
        .. " and "
        .. P.label(declaration)
    )
    n.owner = owner
    n.owner_origin = n.owner_origin or P.label(declaration)
    for _, key in ipairs(scalars) do
      local value = spec[key]
      if value ~= nil then
        U.check(
          n[key] == nil or vim.deep_equal(n[key], value),
          id
            .. ": conflicting "
            .. key
            .. " between "
            .. (n.field_origins[key] or P.label(declaration))
            .. " and "
            .. P.label(declaration)
        )
        n[key] = value
        n.field_origins[key] = n.field_origins[key] or P.label(declaration)
      end
    end
    U.check(spec.opts == nil or type(spec.opts) == "table", id .. ": opts must be a table")
    if spec.opts then
      P.options(n.option_history, n.opts, spec.opts, declaration)
      U.merge_into(n.opts, spec.opts)
    end
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
    for _, ft in ipairs(list(spec.ft or {}, id .. ".ft")) do
      U.check(
        type(ft) == "string" and ft ~= "" and not ft:find("[*,%[%]{}?]"),
        id .. ": ft must contain literal filetypes"
      )
      if not n.ft_set[ft] then
        n.ft[#n.ft + 1], n.ft_set[ft] = ft, true
      end
    end
    for _, target in ipairs(list(spec.after or {}, id .. ".after")) do
      U.check(valid_id(target), id .. ": invalid after id")
      if not n.after_set[target] then
        n.after[#n.after + 1] = target
        n.after_set[target] = true
      end
    end
    for index, child in ipairs(item.children) do
      add(child, n, position .. ".children[" .. index .. "]", declaration.origin)
    end
  end
  for index, item in ipairs(inputs) do
    add(item, nil, "specs[" .. index .. "]")
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
    U.check(n.config == nil or n.config == false or type(n.config) == "function", id .. ": invalid config")
    U.check(
      n.build == nil
        or type(n.build) == "function"
        or (type(n.build) == "table" and vim.islist(n.build) and #n.build > 0),
      id .. ": build must be argv or a function"
    )
    U.check(
      n.mount == nil or n.mount == "startup" or n.mount == "on-demand",
      id .. ": mount must be 'startup' or 'on-demand'"
    )
    if n.start == nil then
      n.start = n.roots and n.mount ~= "on-demand" and #n.ft == 0
    end
    U.check(not n.start or #n.ft == 0, id .. ": ft requires start = false")
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
      U.check(not n.mount, id .. ": mount belongs on the package owner")
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
    n.mount = nodes[n.owner].mount or "startup"
    n.dir = package.dir .. (n.path and ("/" .. n.path) or "")
    for dep, optional in pairs(n.dependencies) do
      U.check(
        optional or nodes[dep],
        id
          .. ": required dependency "
          .. dep
          .. (
            disabled[dep] and " is disabled"
            or unselected[dep] and " is optional and not selected"
            or " is undeclared"
          )
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
  local inactive = {}
  for id, contributions in pairs(declarations) do
    if not nodes[id] then
      local phase = unselected[id] and "unselected" or "disabled"
      local parents, root = {}, false
      for _, declaration in ipairs(contributions) do
        if declaration.parent then
          parents[declaration.parent] = true
        else
          root = true
        end
      end
      inactive[id] = {
        id = id,
        package = id,
        dir = "",
        managed = false,
        selected = false,
        parents = vim.tbl_keys(parents),
        root = root,
        declarations = contributions,
        dependencies = {},
        after = {},
        ft = {},
        opts = {},
        option_history = {},
        referenced_by = {},
        mount = "none",
        start = false,
        state = {
          phase = phase,
          reason = phase == "disabled" and "all declarations disabled"
            or "optional declaration has no enabled selector",
        },
      }
      table.sort(inactive[id].parents)
    end
  end
  return {
    inactive = inactive,
    nodes = nodes,
    order = order,
    activation_order = sorted,
    packages = packages,
    package_order = package_order,
    root = root,
  }
end

return M
