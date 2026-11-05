-- Usage: nvim --headless -u NONE -i NONE --noplugin -l examples/manage.lua manifest.lua install
local script = debug.getinfo(1, "S").source:sub(2)
vim.opt.runtimepath:prepend(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(script, ":p"))))
local manifest = assert(arg[1], "expected a manifest Lua file")
local action = arg[2] or "install"
assert(vim.list_contains({ "install", "update", "restore", "freeze", "clean" }, action), "unknown package operation")
local manager = require("plugin_tools").new(dofile(manifest))
local result, err = manager[action](manager):wait()
assert(result, err)
print(vim.inspect(result))
