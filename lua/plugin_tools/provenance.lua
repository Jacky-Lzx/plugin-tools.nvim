local M = {}

function M.label(declaration)
  return declaration.origin .. " (" .. declaration.position .. ")"
end

-- Record assignments, not option values. A replacement of an ancestor path
-- supersedes its descendants; maps recurse only when the merge itself does.
function M.options(history, base, extra, declaration, prefix)
  prefix = prefix or {}
  local keys = vim.tbl_keys(extra)
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, key in ipairs(keys) do
    local value = extra[key]
    local path = vim.list_extend(vim.list_slice(prefix), { key })
    if
      type(value) == "table"
      and next(value)
      and not vim.islist(value)
      and type(base[key]) == "table"
      and not vim.islist(base[key])
    then
      M.options(history, base[key], value, declaration, path)
    else
      history[#history + 1] = {
        path = path,
        operation = type(value) == "table" and not next(value) and "clear" or "replace",
        origin = declaration.origin,
        position = declaration.position,
        declaration = declaration.index,
      }
    end
  end
end

return M
