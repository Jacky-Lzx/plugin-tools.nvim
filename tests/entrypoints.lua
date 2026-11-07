local H = dofile("tests/helpers.lua")
local Tools = require("plugin_tools")
local manager = Tools.setup({
  root = H.root .. "/packages",
  lockfile = H.root .. "/lock.json",
  specs = { { id = "local", dir = H.root } },
})
local notices = {}
vim.notify = function(message)
  notices[#notices + 1] = message
end

H.case("default manager commands inspect and finish asynchronous operations", function()
  H.eq(Tools.has("local"), true)
  vim.cmd("PluginTools status")
  assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("local", 1, true))
  vim.cmd("PluginTools profile")
  assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("Startup stages", 1, true))
  assert(Tools.profile().timings.enabled)
  H.eq(require("plugin_tools.command").complete(manager, "prof", "PluginTools prof", 16), { "profile" })
  vim.cmd("PluginTools explain local")
  assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("Referenced by", 1, true))
  vim.cmd.close()
  vim.cmd("PluginTools install")
  assert(vim.wait(10000, function()
    return not manager.operation
  end))
  assert(notices[#notices]:find("install", 1, true))
  vim.cmd("PluginTools clean")
  assert(vim.wait(10000, function()
    return not manager.operation
  end))
  assert(notices[#notices]:find("dry_run = true", 1, true))
  H.raises(function()
    vim.cmd("PluginTools unknown")
  end, "unknown action")
  H.raises(function()
    Tools.setup({})
  end, "only be called once")
end)

H.case("health reads state and help tags resolve", function()
  local health = vim.health
  local captured = {}
  vim.health = {}
  for _, name in ipairs({ "start", "ok", "warn", "error", "info" }) do
    vim.health[name] = function(message)
      captured[#captured + 1] = message
    end
  end
  require("plugin_tools.health").check()
  vim.health = health
  assert(#captured == 3 and captured[3] == "Details: :PluginTools", "Health stays compact")
  H.write(H.root .. "/doc/plugin-tools.txt", table.concat(vim.fn.readfile("doc/plugin-tools.txt"), "\n"))
  vim.api.nvim_cmd({ cmd = "helptags", args = { H.root .. "/doc" } }, {})
  vim.cmd("help plugin-tools-api")
  H.eq(vim.bo.filetype, "help")
end)

H.case("commands preview, apply and recover with explicit argument validation", function()
  vim.cmd("PluginTools plan")
  assert(vim.wait(10000, function()
    return not manager.operation
  end))
  assert(manager.last_plan and manager.last_plan.action == "plan")
  H.eq(vim.bo.filetype, "plugin-tools")
  vim.cmd("PluginTools apply")
  assert(vim.wait(10000, function()
    return not manager.operation
  end))
  H.eq(manager.last_plan, nil)
  H.raises(function()
    vim.cmd("PluginTools apply")
  end, "run PluginTools plan first")
  vim.cmd("PluginTools recover")
  assert(vim.wait(10000, function()
    return not manager.operation
  end))
  H.eq(manager.last_operation.result.dry_run, true)
  H.raises(function()
    vim.cmd("PluginTools recover --unexpected")
  end, "usage: PluginTools recover")
  vim.cmd.close()
end)

H.case("standalone administration example runs without mounting plugins", function()
  local repo = H.repo("example")
  local manifest = H.root .. "/manifest.lua"
  H.write(
    manifest,
    ("return {root=%q, lockfile=%q, specs={{id='example', source=%q}}}"):format(
      H.root .. "/example-packages",
      H.root .. "/example-lock.json",
      repo
    )
  )
  local result = vim
    .system({
      "nvim",
      "--headless",
      "-u",
      "NONE",
      "-i",
      "NONE",
      "--noplugin",
      "-l",
      "examples/manage.lua",
      manifest,
      "install",
    }, { text = true })
    :wait(30000)
  assert(result.code == 0, result.stderr)
  assert(vim.uv.fs_stat(H.root .. "/example-packages/example/.git"))
end)

H.finish()
