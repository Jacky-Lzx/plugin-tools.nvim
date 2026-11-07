local H = dofile("tests/helpers.lua")
local Tools = require("plugin_tools")
local U = require("plugin_tools.util")
local original_rtp = vim.o.runtimepath

H.case("ready default startup does not load operations, run Git or read locks", function()
  local root = H.root .. "/ready"
  vim.fn.mkdir(root .. "/present", "p")
  local system, open = vim.system, io.open
  vim.system = function()
    error("unexpected startup process")
  end
  io.open = function()
    error("unexpected startup file read")
  end
  local manager = Tools.new({ root = root, specs = { { id = "present", source = "example/present" } } }):start()
  H.eq(manager.options.auto_install, true)
  H.eq(manager.last_operation, nil)
  H.eq(package.loaded["plugin_tools.operations"], nil)
  H.eq(package.loaded["plugin_tools.task"], nil)
  vim.system, io.open = system, open
  vim.o.runtimepath = original_rtp
end)

H.case("startup installs only absent enabled owners at locked revisions before any configuration", function()
  local existing, backend, extra = H.repo("existing"), H.repo("auto_backend"), H.repo("extra")
  H.write(
    backend .. "/lua/auto_backend.lua",
    "return {setup=function() _G.auto_configured = (_G.auto_configured or 0)+1 end}"
  )
  local locked = H.commit(backend, "locked backend")
  local root, lockfile = H.root .. "/packages, 中文", H.root .. "/lock.json"
  local existing_spec = { id = "existing", source = existing }
  H.wait(Tools.new({ root = root, lockfile = lockfile, specs = { existing_spec } }):install())
  local existing_head = H.git(root .. "/existing", "rev-parse", "HEAD")
  H.write(root .. "/existing/local-edit", "preserve")
  H.write(existing .. "/next", "upstream moved")
  H.commit(existing, "new existing revision")
  H.write(backend .. "/lua/auto_backend.lua", "error('unlocked backend loaded')")
  H.commit(backend, "unlocked backend")
  local lock = U.read_json(lockfile)
  lock.plugins.backend = { source = backend, commit = locked }
  U.write_json(lockfile, lock)
  local callbacks = 0
  existing_spec.config = function()
    callbacks = callbacks + 1
    assert(vim.uv.fs_stat(root .. "/backend/.git"), "configuration ran before backend installation")
    assert(vim.uv.fs_stat(root .. "/extra/.git"), "configuration ran before all installations")
  end
  existing_spec.children = {
    { id = "existing.component", config = false },
    { id = "backend", source = backend, main = "auto_backend", start = true },
  }
  local manager = Tools.new({
    root = root,
    lockfile = lockfile,
    specs = {
      existing_spec,
      { id = "extra", source = extra },
      { id = "disabled", source = "example/disabled", enabled = false },
      { id = "dormant", source = "example/dormant", optional = true },
      { id = "local", dir = H.root },
    },
  }):start()
  H.eq(manager.last_operation.order, { "backend", "extra" })
  H.eq(manager.last_operation.result.restart_required, false)
  H.eq(manager.states.backend.phase, "ready")
  H.eq(manager.states.backend.count, 1)
  H.eq(_G.auto_configured, 1)
  H.eq(callbacks, 1)
  H.eq(H.git(root .. "/backend", "rev-parse", "HEAD"), locked)
  H.eq(H.git(root .. "/existing", "rev-parse", "HEAD"), existing_head)
  H.eq(vim.fn.readfile(root .. "/existing/local-edit"), { "preserve" })
  H.eq(U.read_json(lockfile).plugins.existing, lock.plugins.existing)
  manager:start()
  H.eq(callbacks, 1)
  vim.o.runtimepath = original_rtp
end)

H.case("auto_install=false preserves strict and permissive startup without any process", function()
  local opts = {
    auto_install = false,
    root = H.root .. "/manual",
    lockfile = H.root .. "/manual-lock.json",
    specs = { { id = "manual", source = H.repo("manual") } },
  }
  local system = vim.system
  vim.system = function()
    error("disabled automatic installation spawned a process")
  end
  local strict = Tools.new(opts)
  H.raises(function()
    strict:start()
  end, "missing plugin directories")
  H.eq(vim.o.runtimepath, original_rtp)
  H.eq(strict.last_operation, nil)
  local permissive = Tools.new(vim.tbl_extend("force", opts, { strict = false })):start()
  H.eq(permissive.states.manual.phase, "missing")
  H.eq(permissive.last_operation, nil)
  vim.system = system
  H.wait(strict:install())
  strict:start()
  H.eq(strict.states.manual.phase, "ready")
  vim.o.runtimepath = original_rtp
end)

H.case("missing external directories and package components are never cloned", function()
  local root = H.root .. "/components"
  vim.fn.mkdir(root .. "/owner", "p")
  local system = vim.system
  vim.system = function()
    error("attempted to clone an external directory or existing package")
  end
  local manager = Tools.new({
    root = root,
    strict = false,
    specs = {
      { id = "external", dir = H.root .. "/missing-external" },
      { id = "owner", source = "example/owner", children = { { id = "component", path = "missing" } } },
    },
  }):start()
  H.eq(manager.states.external.phase, "missing")
  H.eq(manager.states.component.phase, "missing")
  H.eq(manager.last_operation, nil)
  vim.system = system
  vim.o.runtimepath = original_rtp
end)

H.case("existing files and dangling symlinks are preserved without automatic replacement", function()
  local root = H.root .. "/protected"
  H.write(root .. "/file", "preserve")
  assert(vim.uv.fs_symlink(root .. "/absent", root .. "/link"))
  local system = vim.system
  vim.system = function()
    error("attempted to replace an existing path")
  end
  local manager = Tools.new({
    root = root,
    specs = { { id = "file", source = "example/file" }, { id = "link", source = "example/link" } },
  })
  H.raises(function()
    manager:start()
  end, "missing plugin directories")
  H.eq(vim.o.runtimepath, original_rtp)
  H.eq(manager.last_operation, nil)
  H.eq(vim.fn.readfile(root .. "/file"), { "preserve" })
  H.eq(vim.uv.fs_lstat(root .. "/link").type, "link")
  vim.system = system
end)

H.case("automatic installation failure leaves configuration cold and can be retried explicitly", function()
  local root, source = H.root .. "/failure", H.root .. "/not-yet-a-repo"
  local callbacks = 0
  local manager = Tools.new({
    root = root,
    lockfile = H.root .. "/failure-lock.json",
    strict = false,
    specs = {
      {
        id = "local",
        dir = H.root,
        config = function()
          callbacks = callbacks + 1
        end,
      },
      { id = "retry", source = source },
    },
  })
  H.raises(function()
    manager:start()
  end, "automatic installation failed")
  H.eq(callbacks, 0)
  H.eq(vim.o.runtimepath, original_rtp)
  H.eq(manager.started, false)
  H.eq(manager.states.retry.phase, "missing")
  assert(manager.last_operation.done and manager.last_operation.error)
  H.eq(vim.uv.fs_lstat(root .. "/.operation-lock"), nil)
  H.repo("not-yet-a-repo")
  manager:start()
  H.eq(callbacks, 1)
  H.eq(manager.states.retry.phase, "ready")
  vim.o.runtimepath = original_rtp
end)

H.case("setup defaults to automatic installation and rejects nonboolean configuration", function()
  for _, value in ipairs({ 0, "false", {} }) do
    H.raises(function()
      Tools.new({ auto_install = value })
    end, "auto_install must be boolean")
  end
  local options = {
    root = H.root .. "/setup",
    lockfile = H.root .. "/setup-lock.json",
    specs = { { id = "setup", source = H.repo("setup") } },
  }
  local before = vim.deepcopy(options)
  local manager = Tools.setup(options)
  H.eq(options, before)
  H.eq(manager.states.setup.phase, "ready")
  H.eq(manager.options.auto_install, true)
  H.eq(vim.fn.exists(":PluginTools"), 2)
end)

H.finish()
