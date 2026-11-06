local M = {}

-- Build a display forest without changing initialization or package ownership.
-- Shared nodes appear once; parent cycles cannot recurse indefinitely.
function M.layout(items, filter, flat)
  local by_id, rank, included = {}, {}, {}
  for index, item in ipairs(items) do
    by_id[item.id], rank[item.id] = item, index
  end
  local function include(id)
    if included[id] or not by_id[id] then
      return
    end
    included[id] = true
    if not flat then
      for _, parent in ipairs(by_id[id].parents or {}) do
        include(parent)
      end
    end
  end
  for _, item in ipairs(items) do
    if (item.id .. " " .. item.dir):lower():find(filter:lower(), 1, true) then
      include(item.id)
    end
  end
  local chosen, children, roots, rows = {}, {}, {}, {}
  for _, item in ipairs(items) do
    if included[item.id] then
      local parents = vim.deepcopy(flat and {} or item.parents or {})
      table.sort(parents, function(a, b)
        return (rank[a] or math.huge) < (rank[b] or math.huge)
      end)
      for _, parent in ipairs(parents) do
        local ancestor = parent
        while ancestor and ancestor ~= item.id do
          ancestor = chosen[ancestor]
        end
        if included[parent] and ancestor ~= item.id then
          chosen[item.id] = parent
          break
        end
      end
      local parent = chosen[item.id]
      local siblings = parent and (children[parent] or {}) or roots
      if parent then
        children[parent] = siblings
      end
      siblings[#siblings + 1] = item
    end
  end
  local function append(item, branch, continuation)
    rows[#rows + 1] = { item = item, branch = branch }
    local descendants = children[item.id] or {}
    for index, child in ipairs(descendants) do
      local last = index == #descendants
      append(child, continuation .. (last and "└─ " or "├─ "), continuation .. (last and "   " or "│  "))
    end
  end
  for _, item in ipairs(roots) do
    append(item, "", "")
  end
  return rows
end

return M
