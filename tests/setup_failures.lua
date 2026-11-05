local H = dofile("tests/helpers.lua")
local original_rtp = vim.o.runtimepath
local notify = vim.notify
local notices = {}
vim.notify = function(message)
  notices[#notices + 1] = message
end

local function fresh()
  package.loaded.plugin_tools = nil
  return require("plugin_tools")
end

local function health_messages()
  local original, messages = vim.health, {}
  vim.health = {}
  for _, level in ipairs({ "start", "ok", "warn", "error", "info" }) do
    vim.health[level] = function(message)
      messages[#messages + 1] = level .. ": " .. message
    end
  end
  local ok, err = pcall(require("plugin_tools.health").check)
  vim.health = original
  assert(ok, err)
  return table.concat(messages, "\n")
end

H.case("strict missing-package startup keeps diagnostics and installation available", function()
  local source = H.repo("source")
  local tools = fresh()
  H.raises(function()
    tools.setup({
      root = H.root .. "/packages",
      lockfile = H.root .. "/lock.json",
      specs = { { id = "source", source = source } },
    })
  end, "missing plugin directories")
  H.eq(vim.o.runtimepath, original_rtp)
  H.eq(tools.status()[1].state.phase, "missing")
  vim.cmd("PluginTools status")
  assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("missing", 1, true))
  vim.cmd.close()
  assert(health_messages():find("error: source: missing", 1, true))
  vim.cmd("PluginTools install")
  assert(vim.wait(10000, function()
    return vim.uv.fs_stat(H.root .. "/lock.json") ~= nil
  end))
  assert(vim.uv.fs_stat(H.root .. "/packages/source/.git"))
end)

H.case("configuration failures retain their traceback without retrying callbacks", function()
  local tools, attempts = fresh(), 0
  H.raises(function()
    tools.setup({
      specs = {
        {
          id = "broken",
          dir = H.root,
          config = function()
            attempts = attempts + 1
            error("configuration probe")
          end,
        },
      },
    })
  end, "configuration probe")
  H.eq(tools.status()[1].state.phase, "failed")
  assert(tools.explain("broken").state.error:find("configuration probe", 1, true))
  vim.cmd("PluginTools explain broken")
  assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("configuration probe", 1, true))
  vim.cmd.close()
  assert(health_messages():find("error: broken: failed", 1, true))
  H.raises(function()
    tools.start()
  end, "previous startup failed")
  H.raises(function()
    tools.activate("broken")
  end, "previous initialization failed")
  H.raises(function()
    tools.setup({})
  end, "only be called once")
  H.eq(attempts, 1)
end)

vim.notify = notify
vim.o.runtimepath = original_rtp
H.finish()
