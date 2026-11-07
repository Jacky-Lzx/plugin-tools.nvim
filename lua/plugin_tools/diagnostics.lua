local U = require("plugin_tools.util")
local M = {}

-- Explicit inspection only: never called by startup or status().
function M.collect(manager)
  local issues = {}
  local function issue(level, message, advice)
    issues[#issues + 1] = { level = level, message = message, advice = advice }
  end
  local function read(path, default)
    local ok, value = pcall(U.read_json, path, default)
    if not ok then
      issue("error", tostring(value), { "Inspect the file before running package operations" })
    end
    return ok and value or nil
  end
  local git_available = vim.fn.executable("git") == 1
  if not git_available then
    issue("warn", "Git is unavailable; package operations are disabled.", { "Install Git" })
  end
  for _, item in ipairs(manager:status()) do
    if item.state.phase == "missing" or item.state.phase == "failed" then
      issue(
        "error",
        item.id .. ": " .. item.state.phase .. "; " .. tostring(item.state.error or item.dir),
        { "Inspect :PluginTools and install missing packages or repair the reported configuration" }
      )
    end
  end
  local lockdir = manager.graph.root .. "/.operation-lock"
  local busy = manager.operation ~= nil
  if vim.uv.fs_lstat(lockdir) then
    local owner = read(lockdir .. "/owner.json", {})
    local pid = owner and owner.pid
    local valid = type(pid) == "number" and pid > 0 and pid % 1 == 0
    local alive, err
    if valid then
      alive, err = vim.uv.kill(pid, 0)
    end
    local exited = valid and not alive and tostring(err):find("ESRCH", 1, true)
    busy = busy or owner and owner.finished ~= true and valid and not exited
    if busy then
      issue("info", "Package operation lock is held by a running process.", { "Wait for the operation to finish" })
    else
      issue(
        "warn",
        "Interrupted or incomplete package operation at " .. lockdir,
        { "Preview :PluginTools recover; inspect the lock manually if no valid journal exists" }
      )
    end
    if vim.uv.fs_lstat(lockdir .. "/journal.json") then
      local journal = read(lockdir .. "/journal.json", {})
      if
        journal and (journal.version ~= 1 or journal.root ~= manager.graph.root or journal.lockfile ~= manager.lockfile)
      then
        issue(
          "error",
          "Recovery journal root, lockfile or version does not match this manager.",
          { "Inspect the recovery journal before attempting recovery" }
        )
      end
    elseif not busy then
      issue("warn", "Operation lock has no transaction journal.", { "Inspect its owner and staging paths manually" })
    end
  end
  local previous = manager.last_operation
  if previous and previous.done and previous.error then
    issue(
      "warn",
      "Last " .. previous.action .. " operation failed: " .. tostring(previous.error):match("[^\n]+"),
      { "Inspect :PluginTools log" }
    )
  end
  -- A transaction temporarily changes checkouts and its lockfile; avoid false
  -- drift reports while an owner is active or interrupted publication is pending.
  if not vim.uv.fs_lstat(lockdir) and not busy then
    local lock = read(manager.lockfile, { version = 1, plugins = {} })
    if lock and (lock.version ~= 1 or type(lock.plugins) ~= "table") then
      issue("error", "Unsupported lockfile " .. manager.lockfile, { "Inspect the lockfile schema" })
      lock = nil
    end
    local function git(dir, args)
      local argv = { "git", "--no-optional-locks", "-C", dir }
      vim.list_extend(argv, args)
      local ok, result = pcall(function()
        return vim.system(argv, { text = true, timeout = 3000, env = { GIT_TERMINAL_PROMPT = "0" } }):wait()
      end)
      if not ok or result.code ~= 0 then
        issue("warn", "Cannot inspect checkout " .. dir, { "Check Git metadata and filesystem access" })
        return nil
      end
      return vim.trim(result.stdout or "")
    end
    for _, id in ipairs(manager.graph.package_order) do
      local package = manager.graph.packages[id]
      if package.managed and U.directory(package.dir) then
        local entry = lock and lock.plugins[id]
        if lock and not entry then
          issue(
            "warn",
            id .. ": no locked revision",
            { "Run :PluginTools freeze " .. id .. " after checking the checkout" }
          )
        elseif entry then
          if
            type(entry) ~= "table"
            or type(entry.commit) ~= "string"
            or not entry.commit:match("^%x+$")
            or #entry.commit ~= 40
          then
            issue("error", id .. ": invalid locked revision", { "Inspect the lockfile entry" })
            entry = nil
          elseif entry.source ~= package.source then
            issue(
              "error",
              id .. ": lockfile source differs from manifest",
              { "Review the source change before restoring or updating" }
            )
          end
        end
        local marker = read(package.dir .. "/.git/plugin-tools-owner.json", {})
        if marker and (marker.id ~= id or marker.source ~= package.source) then
          issue(
            "error",
            id .. ": checkout ownership/source mismatch",
            { "Inspect the checkout; package operations will refuse it" }
          )
        end
        if git_available then
          local head = git(package.dir, { "rev-parse", "HEAD" })
          if entry and head and head ~= entry.commit then
            issue(
              "warn",
              id .. ": checkout differs from locked revision",
              { "Use freeze to keep it or restore to reproduce the lockfile" }
            )
          end
          local changes = git(package.dir, { "status", "--porcelain", "--untracked-files=normal" })
          if changes and changes ~= "" then
            issue(
              "warn",
              id .. ": local checkout modifications",
              { "Preserve local changes before package operations" }
            )
          end
        end
      end
    end
  end
  local rank = { error = 1, warn = 2, info = 3 }
  table.sort(issues, function(a, b)
    return a.level == b.level and a.message < b.message or rank[a.level] < rank[b.level]
  end)
  return issues
end

return M
