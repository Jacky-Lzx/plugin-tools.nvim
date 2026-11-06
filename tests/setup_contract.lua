vim.opt.rtp:prepend(vim.fn.getcwd())
local plugin = require("plugin_tools")
local options = { specs = {} }
local caller = vim.deepcopy(options)
plugin.setup(options)
assert(vim.deep_equal(caller, options), "setup mutated caller configuration")
local commands = vim.api.nvim_get_commands({})
local handlers = vim.api.nvim_get_autocmds({})
assert(not pcall(plugin.setup, false), "setup(false) must reject an invalid configuration type")
assert(vim.deep_equal(commands, vim.api.nvim_get_commands({})), "Invalid setup replaced commands")
assert(vim.deep_equal(handlers, vim.api.nvim_get_autocmds({})), "Invalid setup replaced handlers")
assert(not pcall(plugin.setup, caller), "Singleton manager requires an explicit new() instance")
print("plugin-tools.nvim: setup input isolation, invalid configuration and registration lifetime passed")

local opts = { specs = {}, profile = false }
local manager = plugin.new(opts)
opts.profile = true
assert(manager.options.profile == false, "new retained caller options")
assert(not pcall(plugin.new, false))
manager:start()
manager:start()
assert(manager.started)
