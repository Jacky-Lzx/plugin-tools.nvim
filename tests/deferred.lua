local H = dofile("tests/helpers.lua")
local Tools = require("plugin_tools")
local U = require("plugin_tools.util")
local original = U.runtime_paths()
local loadplugins = vim.o.loadplugins
vim.o.loadplugins = true
local function reset()
  U.set_runtime_paths(original)
end

H.case("cold roots stay invisible until explicit use, with native scripts before setup", function()
  local dir = H.root .. "/cold, 中文"
  H.write(dir .. "/plugin/first.vim", "let g:demand_vim = get(g:, 'demand_vim', 0) + 1")
  H.write(dir .. "/plugin/second.lua", "assert(vim.g.demand_vim == 1); vim.g.demand_lua = 1")
  H.write(dir .. "/after/plugin/last.lua", "assert(vim.g.demand_lua == 1); vim.g.demand_after = 1")
  H.write(
    dir .. "/lua/demand_backend.lua",
    [[return {
    setup = function(opts) assert(vim.g.demand_after == 1); _G.demand_options = opts end,
    run = function() return 'ok' end,
  }]]
  )
  local m = Tools.new({
    specs = { { id = "cold", dir = dir, mount = "on-demand", main = "demand_backend", opts = { answer = 42 } } },
  }):start()
  H.eq(m.states.cold.phase, "registered")
  H.eq(vim.g.demand_vim, nil)
  H.eq(pcall(require, "demand_backend"), false)
  H.eq(m:use("cold").run(), "ok")
  H.eq(_G.demand_options, { answer = 42 })
  m:use("cold")
  H.eq(vim.g.demand_vim, 1)
  H.eq(m.states.cold.count, 1)
  assert(m.states.cold.mount_ms >= 0)
  reset()
end)

H.case("mounting a dependency exposes it without initialization; children share visibility", function()
  local backend, front = H.root .. "/backend", H.root .. "/front"
  H.write(backend .. "/lua/demand_provider.lua", "return { answer = 42 }")
  vim.fn.mkdir(front, "p")
  local m = Tools.new({
    specs = {
      {
        id = "front",
        dir = front,
        dependencies = { "backend" },
        config = function(ctx)
          ctx.mount("backend")
          H.eq(require("demand_provider").answer, 42)
        end,
      },
      {
        id = "backend",
        dir = backend,
        mount = "on-demand",
        config = function()
          error("must not initialize")
        end,
        children = {
          {
            id = "backend.child",
            config = function()
              _G.child_ready = true
            end,
          },
        },
      },
    },
  }):start()
  H.eq(m.states.backend.phase, "mounted")
  H.eq(m.states["backend.child"].phase, "mounted")
  H.eq(m.states.backend.count, 0)
  m:activate("backend.child")
  H.eq(_G.child_ready, true)
  H.eq(m.states.backend.count, 0)
  reset()
end)

H.case("filetype initialization covers first and later buffers without replaying FileType", function()
  local dir = H.root .. "/filetype"
  vim.fn.mkdir(dir, "p")
  local configs, attaches, external = 0, 0, 0
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "demandft",
    callback = function()
      external = external + 1
    end,
  })
  local m = Tools.new({
    specs = {
      {
        id = "ft",
        dir = dir,
        mount = "on-demand",
        ft = { "demandft" },
        config = function()
          configs = configs + 1
          vim.api.nvim_create_autocmd("FileType", {
            pattern = "demandft",
            callback = function()
              attaches = attaches + 1
            end,
          })
          for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.bo[buf].filetype == "demandft" then
              attaches = attaches + 1
            end
          end
        end,
      },
    },
  }):start()
  vim.bo.filetype = "otherft"
  H.eq(configs, 0)
  vim.bo.filetype = "demandft"
  H.eq(configs, 1)
  H.eq(attaches, 1)
  vim.cmd.enew()
  vim.bo.filetype = "demandft"
  H.eq(configs, 1)
  H.eq(attaches, 2)
  H.eq(external, 2)
  H.eq(m.states.ft.reason, "FileType demandft")
  reset()
end)

H.case("existing buffers and explicit after prerequisites initialize correctly", function()
  local dir = H.root .. "/existing"
  vim.fn.mkdir(dir, "p")
  vim.bo.filetype = "alreadyft"
  local order = {}
  local m = Tools.new({
    specs = {
      {
        id = "first",
        dir = dir,
        mount = "on-demand",
        config = function()
          order[#order + 1] = "first"
        end,
      },
      {
        id = "second",
        dir = dir,
        mount = "on-demand",
        ft = { "alreadyft" },
        after = { "first" },
        config = function()
          order[#order + 1] = "second"
        end,
      },
    },
  }):start()
  H.eq(order, { "first", "second" })
  H.eq(m.states.second.count, 1)
  reset()
end)

H.case("invalid declarations and late script errors remain explicit", function()
  H.raises(function()
    Tools.new({ specs = { { id = "bad", dir = H.root, mount = "later" } } })
  end, "mount must be")
  H.raises(function()
    Tools.new({ specs = { { id = "bad", dir = H.root, ft = { "*" } } } })
  end, "literal filetypes")
  H.raises(function()
    Tools.new({ specs = { { id = "bad", dir = H.root, ft = { "lua" }, start = true } } })
  end, "ft requires")
  H.raises(function()
    Tools.new({ specs = { { id = "parent", dir = H.root, children = { { id = "child", mount = "on-demand" } } } } })
  end, "mount belongs")
  local dir = H.root .. "/broken"
  H.write(dir .. "/plugin/broken.lua", "error('native failure')")
  local m = Tools.new({ specs = { { id = "broken", dir = dir, mount = "on-demand" } } }):start()
  H.raises(function()
    m:activate("broken")
  end, "native failure")
  H.eq(m.states.broken.phase, "failed")
  H.raises(function()
    m:activate("broken")
  end, "previous initialization failed")
  reset()
end)

H.case("explicit mount failures are inspectable without calling setup", function()
  local dir = H.root .. "/mount-failure"
  H.write(dir .. "/plugin/broken.lua", "error('mount source failure')")
  local m = Tools.new({ specs = { { id = "broken", dir = dir, mount = "on-demand" } } }):start()
  H.raises(function()
    m:mount("broken")
  end, "mount source failure")
  H.eq(m.states.broken.phase, "failed")
  assert(m:explain("broken").state.error:find("mount source failure", 1, true))
  H.raises(function()
    m:mount("broken")
  end, "previous runtime loading failed")
  H.eq(m.states.broken.count, 0)
  reset()
end)

vim.o.loadplugins = loadplugins
H.finish()
