local H = dofile("tests/helpers.lua")
local U = require("plugin_tools.util")
local path = H.root .. "/nested/data.json"

H.case("JSON uses two-space indentation, sorted keys and a final newline", function()
  U.write_json(path, { version = 1, plugins = { zeta = { source = "z", commit = "b" }, alpha = {} } })
  H.eq(vim.fn.readfile(path, "b"), {
    "{",
    '  "plugins": {',
    '    "alpha": [],',
    '    "zeta": {',
    '      "commit": "b",',
    '      "source": "z"',
    "    }",
    "  },",
    '  "version": 1',
    "}",
    "",
  })
end)

H.case("JSON preserves native escaping, arrays, empty objects and nulls", function()
  local value = {
    ['quotes"\\\n'] = '目录/"quoted"\\path\n\t',
    booleans = { true, false },
    empty_object = vim.empty_dict(),
    empty_list = {},
    null = vim.NIL,
    sparse = { [3] = "third" },
    numeric_keys = { [2] = "two", named = "value" },
  }
  U.write_json(path, value)
  H.eq(U.read_json(path), vim.json.decode(vim.json.encode(value)))
  local before = vim.fn.readfile(path, "b")
  U.write_json(path, U.read_json(path))
  H.eq(vim.fn.readfile(path, "b"), before)
end)

H.case("insertion order is stable and a revision change affects one line", function()
  local first = { zeta = { source = "z", commit = "old" }, alpha = { commit = "a", source = "a" } }
  U.write_json(path, { version = 1, plugins = first })
  local before = vim.fn.readfile(path, "b")
  local second = {}
  second.alpha = { source = "a", commit = "a" }
  second.zeta = { commit = "old", source = "z" }
  U.write_json(path, { plugins = second, version = 1 })
  H.eq(vim.fn.readfile(path, "b"), before)
  second.zeta.commit = "new"
  U.write_json(path, { plugins = second, version = 1 })
  local after, changed = vim.fn.readfile(path, "b"), 0
  H.eq(#after, #before)
  for i, line in ipairs(before) do
    if line ~= after[i] then
      changed = changed + 1
      H.eq(line, '      "commit": "old",')
      H.eq(after[i], '      "commit": "new",')
    end
  end
  H.eq(changed, 1)
end)

H.case("invalid JSON values preserve the destination without temporary files", function()
  local before = vim.fn.readfile(path, "b")
  local cycle = {}
  cycle.self = cycle
  assert(not pcall(U.write_json, path, cycle))
  H.eq(vim.fn.readfile(path, "b"), before)
  H.eq(vim.fn.glob(path .. ".*", false, true), {})
end)

H.finish()
