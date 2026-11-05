-- Fresh-process worker. The fixture is prepared outside the measured interval.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local count = tonumber(vim.env.PLUGIN_TOOLS_BENCH_COUNT) or 100
local root = assert(vim.env.PLUGIN_TOOLS_BENCH_ROOT)
local specs = {}
for i = 1, count do
  specs[i] = { id = "p" .. i, dir = root .. "/p" .. i, start = false }
  if i > 1 then
    specs[i].dependencies = { "p" .. (i - 1) }
  end
end
local before_memory = collectgarbage("count")
local before = vim.uv.hrtime()
local tools = require("plugin_tools")
local manager = tools.new({ specs = specs, commands = false }):start()
local setup_ms = (vim.uv.hrtime() - before) / 1e6
local warm = vim.uv.hrtime()
for _ = 1, 10000 do
  manager:activate("p1")
end
local activate_ns = (vim.uv.hrtime() - warm) / 10000
print(vim.json.encode({
  setup_ms = setup_ms,
  memory_kib = collectgarbage("count") - before_memory,
  ready_call_ns = activate_ns,
  count = count,
}))
