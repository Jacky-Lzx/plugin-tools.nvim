-- Real offline fixture packages. Never replace manager state or measured times.
local M = {}
local root = assert(vim.env.PLUGIN_TOOLS_CAPTURE_ROOT, "missing screenshot workspace")

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), path)
end

local function git(dir, ...)
  local command = { "git", "-C", dir }
  vim.list_extend(command, { ... })
  local result = vim
    .system(command, {
      text = true,
      env = {
        GIT_AUTHOR_DATE = "2026-01-01T12:00:00+0000",
        GIT_COMMITTER_DATE = "2026-01-01T12:00:00+0000",
      },
    })
    :wait(20000)
  assert(result.code == 0, result.stderr)
end

local function commit(dir, message)
  git(dir, "add", ".")
  git(dir, "commit", "-qm", message)
end

local function source(name)
  return root .. "/sources/" .. name .. ".nvim"
end

local function options()
  return {
    root = root .. "/plugins",
    lockfile = root .. "/plugin-tools-lock.json",
    specs = {
      {
        id = "navigator.nvim",
        source = source("navigator"),
        origin = "demo/navigation.lua",
        dependencies = { "matcher.nvim" },
        config = function(ctx)
          require("demo_navigator").setup()
          vim.api.nvim_create_user_command("DemoFind", function()
            assert(ctx.use("matcher.nvim").find("plugin") == "plugin-tools.nvim")
          end, {})
        end,
        children = {
          { id = "navigator.outline", path = "extras/outline", main = "demo_outline" },
          {
            id = "matcher.nvim",
            source = source("matcher"),
            main = "demo_matcher",
            dependencies = { "icons.nvim" },
            opts = { layout = "compact", max_results = 100 },
            config = function(ctx)
              ctx.use("icons.nvim")
              require("demo_matcher").setup(ctx.opts)
            end,
          },
        },
      },
      { id = "icons.nvim", source = source("icons"), main = "demo_icons", start = false },
      { id = "theme.nvim", source = source("theme"), main = "demo_theme", origin = "demo/appearance.lua" },
      { id = "syntax.nvim", source = source("syntax"), main = "demo_syntax", origin = "demo/editing.lua" },
      {
        id = "debugger.nvim",
        source = source("debugger"),
        main = "demo_debugger",
        mount = "on-demand",
        origin = "demo/debugging.lua",
      },
      { id = "local-dev.nvim", dir = root .. "/local-dev", config = false, origin = "demo/local.lua" },
    },
  }
end

function M.prepare()
  for index, name in ipairs({ "navigator", "matcher", "icons", "theme", "syntax", "debugger" }) do
    local dir = source(name)
    vim.fn.mkdir(dir, "p")
    git(dir, "init", "-q", "-b", "main")
    git(dir, "config", "user.name", "Plugin Tools Demo")
    git(dir, "config", "user.email", "demo@example.invalid")
    git(dir, "config", "commit.gpgsign", "false")
    -- Bounded real work makes actual profiling columns readable. These are
    -- illustrative fixture measurements, not performance claims about plugins.
    write(
      dir .. "/lua/demo_" .. name .. ".lua",
      ("local M = {}\nfunction M.setup(opts)\n  local sum = 0\n  for i = 1, %d do sum = sum + math.sqrt(i) end\n  M.checksum, M.options = sum, opts\nend\nfunction M.find() return 'plugin-tools.nvim' end\nreturn M"):format(
        index * 16000
      )
    )
    write(dir .. "/plugin/entry.lua", ("vim.g.demo_%s_loaded = true"):format(name))
    write(dir .. "/README.md", "# " .. name .. ".nvim\n\nOffline screenshot fixture.")
    if name == "navigator" then
      write(dir .. "/extras/outline/lua/demo_outline.lua", "return { setup = function() end }")
    end
    commit(dir, "Initial " .. name .. " package")
  end
  vim.fn.mkdir(root .. "/local-dev", "p")
  local manager = require("plugin_tools").new(options())
  local task = manager:install()
  local report, err = task:wait(30000)
  assert(report and task.done, err)
  for _, change in ipairs({
    { "matcher", "Cache repeated fuzzy matches" },
    { "syntax", "Add filetype-aware highlighting" },
  }) do
    local dir = source(change[1])
    write(dir .. "/CHANGELOG.md", "# Changes\n\n- " .. change[2] .. ".")
    commit(dir, change[2])
  end
end

function M.start()
  local repo = assert(vim.env.PLUGIN_TOOLS_CAPTURE_REPO)
  dofile(repo .. "/doc/screenshots/theme.lua")
  _G.capture_manager = require("plugin_tools").setup(options())
  vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = function()
      vim.schedule(function()
        vim.cmd("DemoFind")
        _G.capture_view = capture_manager:open()
        _G.capture_ready = true
      end)
    end,
  })
end

if arg and arg[1] == "prepare" then
  local repo = assert(vim.env.PLUGIN_TOOLS_CAPTURE_REPO)
  vim.o.runtimepath = vim.fn.escape(repo, ",\\") .. "," .. vim.o.runtimepath
  M.prepare()
end

return M
