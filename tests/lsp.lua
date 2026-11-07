-- Optional integration suite: requires lua-language-server on PATH.
local repo = vim.uv.cwd()
assert(vim.fn.executable("lua-language-server") == 1, "install lua-language-server before running the lsp suite")
local workspace = assert(vim.uv.fs_mkdtemp((vim.env.TMPDIR or "/tmp") .. "/plugin-tools-lsp-XXXXXX"))
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_name(buf, workspace .. "/plugins.lua")
vim.bo[buf].filetype = "lua"
local diagnostics = {}
local id = assert(vim.lsp.start({
  name = "plugin_tools_types",
  cmd = {
    "lua-language-server",
    "--logpath=" .. workspace .. "/logs",
    "--metapath=" .. workspace .. "/meta",
  },
  root_dir = workspace,
  settings = {
    Lua = {
      runtime = { version = "LuaJIT" },
      workspace = { library = { repo .. "/lua", vim.env.VIMRUNTIME .. "/lua" }, checkThirdParty = false },
      diagnostics = { globals = { "vim" } },
      telemetry = { enable = false },
    },
  },
  handlers = {
    ["textDocument/publishDiagnostics"] = function(_, result)
      if result.uri == vim.uri_from_bufnr(buf) then
        diagnostics = result.diagnostics
      end
    end,
  },
}, { bufnr = buf }))
local client = assert(vim.lsp.get_client_by_id(id))

local function check_completion(source, expected)
  local text, marker = source:gsub("|", "")
  assert(marker == 1, "one cursor marker required")
  local cursor = assert(source:find("|", 1, true))
  local prefix = source:sub(1, cursor - 1)
  local _, line = prefix:gsub("\n", "")
  local character = #(prefix:match("[^\n]*$") or "")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  local labels = {}
  local ok = vim.wait(30000, function()
    if not client.initialized then
      return false
    end
    local responses = vim.lsp.buf_request_sync(buf, "textDocument/completion", {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
      position = { line = line, character = character },
      context = { triggerKind = 1 },
    }, 5000)
    local response = responses and responses[id]
    if response and response.err then
      error(vim.inspect(response.err))
    end
    local result = response and response.result
    for _, item in ipairs(result and (result.items or result) or {}) do
      labels[item.label:match("^[%w_]+") or item.label] = true
    end
    for _, label in ipairs(expected) do
      if not labels[label] then
        return false
      end
    end
    return true
  end, 100)
  assert(ok, "missing completions " .. vim.inspect(expected) .. "; received " .. vim.inspect(labels))
  print("PASS LuaLS completion: " .. table.concat(expected, ", "))
end

local ok, err = xpcall(function()
  check_completion('require("plugin_tools").setup({ | })', { "auto_install", "specs", "git_timeout", "dev" })
  check_completion(
    'require("plugin_tools").new({ specs = {{ id = "demo", | }} })',
    { "mount", "children", "dependencies" }
  )
  check_completion(
    'require("plugin_tools").setup({ specs = {{ id = "demo", children = {{ | }} }} })',
    { "id", "opts", "config" }
  )
  check_completion(
    'require("plugin_tools").setup({ specs = {{ id = "demo", config = function(ctx) ctx.| end }} })',
    { "opts", "dir", "has", "use", "mount" }
  )
  check_completion(
    'require("plugin_tools").setup({ specs = {{ id = "demo", build = function(ctx) ctx.| end }} })',
    { "id", "dir", "cancelled" }
  )
  check_completion('local m = require("plugin_tools").new()\nm:|', { "install", "update", "start", "status" })
  check_completion(
    'local m = require("plugin_tools").new()\nm:update({ | })',
    { "plan", "ids", "rebuild", "on_progress" }
  )
  check_completion(
    'require("plugin_tools").install({ on_progress = function(event) event.| end })',
    { "phase", "elapsed_ms", "completed" }
  )
  check_completion(
    'local task = require("plugin_tools").install()\ntask:|',
    { "wait", "cancel", "subscribe", "snapshot" }
  )
  check_completion(
    '---@module "plugin_tools"\n---@type plugin_tools.BootstrapOptions\nlocal opts = { | }\nreturn opts',
    { "self", "auto_install", "specs" }
  )
  check_completion(
    "---@type plugin_tools.BootstrapOptions\nlocal opts = { self = { | } }\nreturn opts",
    { "source", "version" }
  )
  check_completion("---@type plugin_tools.Spec[]\nlocal specs = {{ | }}\nreturn specs", { "config", "ft", "mount" })
  check_completion('require("plugin_tools").|', { "install", "profile", "setup", "new" })
  check_completion(
    'local result = require("plugin_tools").install():wait()\nif result then result.| end',
    { "status", "restart_required", "details" }
  )

  diagnostics = {}
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    'require("plugin_tools").setup({ auto_install = "yes", specs = {{ id = "demo", mount = "later" }} })',
  })
  -- Flush pending didChange before waiting for server diagnostics.
  vim.lsp.buf_request_sync(buf, "textDocument/hover", {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = 0, character = 35 },
  }, 5000)
  assert(
    vim.wait(30000, function()
      local found = 0
      for _, diagnostic in ipairs(diagnostics) do
        if diagnostic.code == "assign-type-mismatch" then
          found = found + 1
        end
      end
      return found >= 2
    end, 100),
    "LuaLS should reject invalid boolean and mount policy: " .. vim.inspect(diagnostics)
  )
  -- LuaLS may omit an initial empty report. Verify the transition from the
  -- invalid fixture above to this valid annotated configuration instead.
  diagnostics = nil
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '---@module "plugin_tools"',
    "---@type plugin_tools.BootstrapOptions",
    "local opts = {",
    "  auto_install = true, self = { version = 'main' },",
    "  specs = {{ id = 'demo', dir = '/tmp/demo', mount = 'on-demand',",
    "    config = function(ctx) print(ctx.id, ctx.opts) end,",
    "  }},",
    "}",
    "return opts",
  })
  vim.lsp.buf_request_sync(buf, "textDocument/hover", {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = 2, character = 8 },
  }, 5000)
  assert(
    vim.wait(30000, function()
      return diagnostics ~= nil and #diagnostics == 0
    end, 100),
    "unexpected diagnostics for valid annotated configuration: " .. vim.inspect(diagnostics)
  )
  print("PASS LuaLS diagnostics: annotated bootstrap configuration is valid")
  assert(not package.loaded.plugin_tools, "editor type discovery must not load the manager")
  print("PASS LuaLS diagnostics: invalid manager option and mount policy")
end, debug.traceback)
client:stop(true)
vim.wait(5000, function()
  return client:is_stopped()
end, 20)
if not ok then
  error(err .. "\nLuaLS artifacts: " .. workspace, 0)
end
vim.fn.delete(workspace, "rf")
