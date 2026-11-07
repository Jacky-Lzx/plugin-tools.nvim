local M = {}
local source = debug.getinfo(1, "S").source:sub(2)
local running_dir = vim.uv.fs_realpath(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source))))
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
