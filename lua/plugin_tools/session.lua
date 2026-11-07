local M = {}
local source = debug.getinfo(1, "S").source:sub(2)
local module_dir = vim.fs.dirname(source)
while
  module_dir
  and not (vim.fs.basename(module_dir) == "plugin_tools" and vim.fs.basename(vim.fs.dirname(module_dir)) == "lua")
do
  local parent = vim.fs.dirname(module_dir)
  module_dir = parent ~= module_dir and parent or nil
end
local running_dir = module_dir and vim.uv.fs_realpath(vim.fs.dirname(vim.fs.dirname(module_dir)))
local preserved = false

-- Before replacing our own checkout, load its remaining modules from the old
-- tree. Lazy requires in this session must not mix old and newly installed code.
function M.preserve(package)
  if preserved or not running_dir or vim.uv.fs_realpath(package.dir) ~= running_dir then
    return
  end
  local files = {}
  for name, kind in vim.fs.dir(running_dir .. "/lua/plugin_tools", { depth = math.huge }) do
    if (kind == "file" or kind == "link") and name:match("%.lua$") then
      files[#files + 1] = name
    end
  end
  table.sort(files)
  for _, file in ipairs(files) do
    local name = ("plugin_tools/" .. file:sub(1, -5)):gsub("/init$", ""):gsub("/", ".")
    require(name)
  end
  preserved = true
end

return M
