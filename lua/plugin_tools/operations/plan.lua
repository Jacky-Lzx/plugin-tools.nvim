local U = require("plugin_tools.util")
local M = {}

function M.changes(git, checkout, package, before, after)
  local out = {
    kind = not before and "install" or "unchanged",
    commits = {},
    files = {},
    ahead = 0,
    behind = 0,
    files_changed = 0,
    insertions = 0,
    deletions = 0,
    binary_files = 0,
  }
  if not before or before == after then
    return out
  end
  -- A force-pushed source may no longer contain the installed commit. Import
  -- that exact local object into staging without modifying the installed repo.
  git(checkout, "fetch", "--quiet", "--no-tags", "--", package.dir, before)
  local counts = git(checkout, "rev-list", "--left-right", "--count", before .. "..." .. after)
  local behind, ahead = counts:match("^(%d+)%s+(%d+)$")
  U.check(behind and ahead, "invalid Git history counts")
  out.behind, out.ahead = tonumber(behind), tonumber(ahead)
  out.kind = out.behind == 0 and "forward" or out.ahead == 0 and "rewind" or "diverged"
  local log = git(checkout, "log", "--format=%H%x09%s", "--max-count=20", before .. ".." .. after, "--")
  for line in log:gmatch("[^\n]+") do
    local commit, subject = line:match("^(%x+)%s(.*)$")
    if commit then
      out.commits[#out.commits + 1] = { commit = commit, subject = subject }
    end
  end
  out.commits_truncated = out.ahead > #out.commits
  local stats =
    git(checkout, "diff", "--numstat", "--no-ext-diff", "--no-textconv", "--no-renames", before, after, "--")
  for line in stats:gmatch("[^\n]+") do
    local added, removed, path = line:match("^([^\t]+)\t([^\t]+)\t(.*)$")
    if path then
      local binary = added == "-" or removed == "-"
      out.files_changed = out.files_changed + 1
      out.insertions = out.insertions + (tonumber(added) or 0)
      out.deletions = out.deletions + (tonumber(removed) or 0)
      out.binary_files = out.binary_files + (binary and 1 or 0)
      if #out.files < 50 then
        out.files[#out.files + 1] =
          { path = path, added = tonumber(added), removed = tonumber(removed), binary = binary }
      end
    end
  end
  out.files_truncated = out.files_changed > #out.files
  return out
end

return M
