local H = dofile("tests/helpers.lua")
local U = require("plugin_tools.util")
local source = H.repo("manager-source")
local unsupported = H.git(source, "rev-parse", "HEAD")
-- A real standalone repository containing the working tree implementation.
for _, pattern in ipairs({ "lua/**/*.lua", "doc/*.txt", "bootstrap.lua", ".gitignore" }) do
  for _, file in ipairs(vim.fn.glob(pattern, false, true)) do
    H.write(source .. "/" .. file, table.concat(vim.fn.readfile(file), "\n"))
  end
end
H.write(source .. "/lua/plugin_tools/session_probe.lua", "return { version = 'old' }")
local initial = H.commit(source, "bootstrap implementation")
local dependency = H.repo("dependency")
H.write(dependency .. "/plugin/native.lua", "_G.bootstrap_native = (_G.bootstrap_native or 0) + 1")
H.commit(dependency, "native startup fixture")
local root, lockfile = H.root .. "/packages, 中文", H.root .. "/lock.json"
local target = root .. "/plugin-tools.nvim"
local original_lock = { version = 1, plugins = { ["plugin-tools.nvim"] = { source = source, commit = initial } } }
U.write_json(lockfile, original_lock)
-- Seed HEAD differs from the locked installation; the installed code must win.
H.write(source .. "/lua/plugin_tools/session_probe.lua", "return { version = 'seed' }")
local latest = H.commit(source, "new seed")

local readme = table.concat(vim.fn.readfile("README.md"), "\n")
local loader = assert(readme:match("```lua\n(.-)\n```"))
local function replace(text, before, after)
  local first, last = assert(text:find(before, 1, true))
  return text:sub(1, first - 1) .. after .. text:sub(last + 1)
end
loader = replace(loader, 'local root = vim.fn.stdpath("data") .. "/plugin-tools"', ("local root = %q"):format(root))
loader = replace(loader, "https://github.com/Jacky-Lzx/plugin-tools.nvim.git", source)
loader = replace(
  loader,
  "specs = {}",
  ("lockfile = %q, self = { source = %q }, specs = {{ id = 'dependency', source = %q }},"):format(
    lockfile,
    source,
    dependency
  )
)

local function run(body, extra_loader, expected_error, cached)
  local init = H.root .. "/init.lua"
  local probe = H.root .. "/result.json"
  vim.fn.delete(probe)
  H.write(
    init,
    ("local ok, err = pcall(function()\n%s\n%s\nend)\n"):format(extra_loader or loader, body or "")
      .. ("vim.fn.writefile({vim.json.encode({ok = ok, error = tostring(err), seed_exists = _G.bootstrap_seed and vim.uv.fs_stat(_G.bootstrap_seed) ~= nil})}, %q)\n"):format(
        probe
      )
      .. "if not ok then vim.cmd('cquit 1') end\n"
  )
  local result = vim
    .system({
      "nvim",
      "--headless",
      "--cmd",
      "lua vim.loader.enable(" .. tostring(cached ~= false) .. ")",
      "-u",
      init,
      "-i",
      "NONE",
      "+qa!",
    }, { text = true })
    :wait(30000)
  local report = U.read_json(probe, {})
  if expected_error then
    assert(result.code ~= 0 and report.error:find(expected_error, 1, true), vim.inspect({ result, report }))
    assert(report.seed_exists ~= true, "Failed bootstrap left its temporary seed")
  else
    assert(result.code == 0 and report.ok, vim.inspect({ result, report }))
  end
end

H.case("README init loader installs locked self and plugins, discards seed and uses native startup", function()
  run([[
    local U = require('plugin_tools.util')
    assert(manager.graph.packages['plugin-tools.nvim'].managed)
    assert(manager.graph.packages['plugin-tools.nvim'].version == nil)
    assert(require('plugin_tools.session_probe').version == 'old', 'Seed version leaked')
    assert(debug.getinfo(require('plugin_tools').setup, 'S').source == '@' .. path .. '/lua/plugin_tools/init.lua')
    assert(seed and not vim.uv.fs_stat(seed), 'Seed was not removed')
    for _, runtime in ipairs(U.runtime_paths()) do assert(runtime ~= seed, 'Seed runtime survived') end
    assert(manager.states['plugin-tools.nvim'].count == 1)
    assert(manager.options.self == nil)
    vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = function()
      if _G.bootstrap_native ~= 1 then vim.cmd('cquit 1') end
    end })
  ]])
  H.eq(H.git(target, "rev-parse", "HEAD"), initial)
  H.eq(U.read_json(lockfile).plugins["plugin-tools.nvim"].commit, initial)
  H.eq(U.read_json(target .. "/.git/plugin-tools-owner.json").source, source)
  assert(vim.uv.fs_stat(root .. "/dependency/.git"))
end)

H.case("warm bootstrap uses no Git or lockfile reads and preserves lazy modules", function()
  run(
    [[
    assert(seed == nil)
    assert(package.loaded['plugin_tools.operations'] == nil)
    assert(package.loaded['plugin_tools.session'] == nil)
    assert(package.loaded['plugin_tools.ui'] == nil)
  ]],
    [[
    vim.system = function() error('Unexpected startup subprocess') end
    local open = io.open
    io.open = function(path, ...) assert(not path:find('lock.json', 1, true), 'Unexpected lock read'); return open(path, ...) end
  ]] .. loader
  )
  H.eq(H.git(target, "rev-parse", "HEAD"), initial)
end)

H.case("warm bootstrap leaves newly declared packages for explicit installation", function()
  local later = replace(loader, "specs = {{", "strict = false, specs = {{ id = 'later', source = 'example/later' }, {")
  run(
    [[
    assert(manager.states.later.phase == 'missing')
    assert(not vim.uv.fs_stat(root .. '/later'))
  ]],
    "vim.system = function() error('Unexpected automatic installation') end\n" .. later
  )
end)

H.case("self plan and apply keep old lazy modules until a fresh startup", function()
  run(([[
    assert(package.loaded['plugin_tools.session_probe'] == nil)
    assert(package.loaded['plugin_tools.ui'] == nil)
    vim.cmd('PluginTools plan plugin-tools.nvim')
    assert(vim.wait(10000, function() return not manager.operation end))
    assert(manager.last_plan, 'Self update plan failed')
    vim.cmd('PluginTools apply')
    assert(vim.wait(10000, function() return not manager.operation end))
    assert(manager.last_operation.result and manager.last_operation.result.restart_required)
    assert(require('plugin_tools.session_probe').version == 'old', 'Mixed self update modules')
    assert(require('plugin_tools.util').read_json(%q).plugins['plugin-tools.nvim'].commit == %q)
    vim.cmd('PluginTools status')
    assert(vim.bo.filetype == 'plugin-tools')
  ]]):format(lockfile, latest))
  H.eq(H.git(target, "rev-parse", "HEAD"), latest)
  run("assert(require('plugin_tools.session_probe').version == 'seed')")
end)

H.case("self restore and dirty checkout protection use normal package operations", function()
  U.write_json(lockfile, original_lock)
  run([[
    local task = manager:restore({ ids = { 'plugin-tools.nvim' } })
    local report, err = task:wait(10000)
    assert(report and report.restart_required, err)
    assert(require('plugin_tools.session_probe').version == 'seed')
  ]])
  H.eq(H.git(target, "rev-parse", "HEAD"), initial)
  H.write(target .. "/user-edit", "preserve")
  run([[
    local report, err = manager:update({ ids = { 'plugin-tools.nvim' } }):wait(10000)
    assert(not report and err:find('local modifications', 1, true), tostring(err))
  ]])
  H.eq(vim.fn.readfile(target .. "/user-edit"), { "preserve" })
  vim.fn.delete(target .. "/user-edit")
end)

H.case("bootstrap copies options and rejects reserved or already loaded managers", function()
  run(
    ([[
    local opts = {
      root = %q, lockfile = %q, self = { source = %q },
      dev = { path = %q }, specs = {},
    }
    local before = vim.deepcopy(opts)
    local manager = dofile(%q).setup(opts)
    assert(vim.deep_equal(opts, before), 'Bootstrap mutated caller options')
    assert(manager.graph.packages['plugin-tools.nvim'].managed, 'Global dev override affected self')
  ]]):format(root, lockfile, source, H.root, target .. "/bootstrap.lua"),
    ""
  )
  run(
    ([[
    dofile(%q).setup({specs = {{id='parent', children={{id='plugin-tools.nvim'}}}}})
  ]]):format(target .. "/bootstrap.lua"),
    "",
    "reserves the id"
  )
  run(
    ([[
    vim.o.runtimepath = vim.fn.escape(%q, ',\\') .. ',' .. vim.o.runtimepath
    require('plugin_tools')
    dofile(%q).setup({})
  ]]):format(target, target .. "/bootstrap.lua"),
    "",
    "before loading plugin_tools"
  )
end)

H.case("failed first installation removes seed and leaves lock and existing packages intact", function()
  local failing_root = H.root .. "/failed-install"
  local checked = replace(loader, "seed = vim.fn.tempname()", "seed = vim.fn.tempname(); _G.bootstrap_seed = seed")
  local broken = replace(checked, root, failing_root)
  broken = replace(broken, dependency, H.root .. "/missing-source")
  local before = vim.fn.readfile(lockfile)
  run("", broken, "failed")
  H.eq(vim.uv.fs_stat(failing_root .. "/plugin-tools.nvim"), nil)
  H.eq(vim.fn.readfile(lockfile), before)
  H.eq(vim.fn.glob(failing_root .. "/.stage-*", false, true), {})
  H.eq(vim.uv.fs_stat(failing_root .. "/.operation-lock"), nil)
  local retry = replace(loader, root, failing_root)
  run("", retry)
  assert(vim.uv.fs_stat(failing_root .. "/plugin-tools.nvim/.git"))
  local clone_failure = replace(checked, root, H.root .. "/failed-clone")
  clone_failure = replace(clone_failure, source, H.root .. "/missing-seed-source")
  run("", clone_failure, "does not exist")
end)

H.case("existing manual checkouts are not adopted by bootstrap", function()
  local unowned_root = H.root .. "/unowned"
  vim.fn.mkdir(unowned_root, "p")
  H.git(unowned_root, "clone", "-q", "--", source, unowned_root .. "/plugin-tools.nvim")
  local unowned = replace(loader, root, unowned_root)
  unowned = replace(unowned, "id = 'dependency'", "id = 'dependency', enabled = false")
  run(
    [[
    local report, err = manager:update({ids={'plugin-tools.nvim'}}):wait(10000)
    assert(not report and err:find('ownership/source mismatch', 1, true), tostring(err))
    assert(not vim.uv.fs_lstat(path .. '/.git/plugin-tools-owner.json'))
  ]],
    unowned
  )
end)

H.case("bootstrap also installs and starts with the native Lua loader", function()
  local native = replace(loader, root, H.root .. "/native-loader")
  run("assert(require('plugin_tools.session_probe').version == 'old')", native, nil, false)
end)

H.case("locked revisions without a bootstrap entry fail with a specific diagnostic", function()
  local incompatible_lock = H.root .. "/incompatible-lock.json"
  U.write_json(incompatible_lock, {
    version = 1,
    plugins = { ["plugin-tools.nvim"] = { source = source, commit = unsupported } },
  })
  local incompatible = replace(loader, root, H.root .. "/incompatible")
  incompatible = replace(incompatible, lockfile, incompatible_lock)
  run("", incompatible, "installed revision lacks bootstrap.lua")
end)

H.finish()
