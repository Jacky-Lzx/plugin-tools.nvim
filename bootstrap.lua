-- Standalone entry point: usable from a temporary clone before any module loads.
local M = {}
local id = "plugin-tools.nvim"
local checkout = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))

local function prepend(path)
  vim.o.runtimepath = vim.fn.escape(path, ",\\") .. "," .. vim.o.runtimepath
end

function M.setup(options)
  assert(vim.fn.has("nvim-0.11") == 1, "plugin-tools: Neovim 0.11+ is required")
  assert(options == nil or type(options) == "table", "plugin-tools: bootstrap expects a table")
  for name in pairs(package.loaded) do
    assert(
      name ~= "plugin_tools" and not name:match("^plugin_tools%."),
      "plugin-tools: bootstrap must run before loading plugin_tools"
    )
  end
  local opts = vim.deepcopy(options or {})
  local self_spec = opts.self == nil and {} or opts.self
  assert(type(self_spec) == "table", "plugin-tools: self expects a table")
  for key in pairs(self_spec) do
    assert(key == "source" or key == "version", "plugin-tools: unknown self option " .. tostring(key))
  end
  opts.self = nil
  opts.root = vim.fs.normalize(opts.root or (vim.fn.stdpath("data") .. "/plugin-tools"))
  if not opts.root:match("^/") and not opts.root:match("^%a:/") then
    opts.root = vim.fs.normalize(vim.uv.cwd() .. "/" .. opts.root)
  end
  local target = opts.root .. "/" .. id
  local function reserved(specs)
    for _, spec in ipairs(specs) do
      assert(spec.id ~= id, "plugin-tools: bootstrap reserves the id " .. id)
      reserved(spec.children or {})
    end
  end
  opts.specs = opts.specs or {}
  reserved(opts.specs)
  table.insert(opts.specs, 1, {
    id = id,
    source = self_spec.source == nil and "Jacky-Lzx/plugin-tools.nvim" or self_spec.source,
    version = self_spec.version,
    dev = false,
    config = false,
  })

  local runtimepath = vim.o.runtimepath
  local installing = not vim.uv.fs_lstat(target)
  -- Use the seed only to install; no seed module or runtime path survives setup.
  if installing then
    prepend(checkout)
    local ok, err = pcall(function()
      local manager = require("plugin_tools").new(opts)
      local task = manager:install()
      local result, failure
      repeat
        result, failure = task:wait()
      until task.done
      assert(result, failure)
    end)
    vim.o.runtimepath = runtimepath
    for name in pairs(package.loaded) do
      if name == "plugin_tools" or name:match("^plugin_tools%.") then
        package.loaded[name] = nil
      end
    end
    if vim.loader then
      vim.loader.reset(checkout)
    end
    if not ok then
      error(err, 0)
    end
    assert(
      vim.uv.fs_stat(target .. "/bootstrap.lua"),
      "plugin-tools: installed revision lacks bootstrap.lua; select a bootstrap-compatible revision"
    )
  end
  local stat = vim.uv.fs_lstat(target)
  assert(stat and stat.type == "directory", "plugin-tools: refusing non-directory self package " .. target)
  -- The managed checkout supplies every module used by the running manager.
  prepend(target)
  if installing and vim.loader and vim.loader.enabled then
    -- The seed still exists until the init.lua loader removes it. Refresh the
    -- cached runtime paths even if the old path still resolves this module.
    vim.loader.find("plugin_tools", { all = true })
  end
  return require("plugin_tools").setup(opts)
end

return M
