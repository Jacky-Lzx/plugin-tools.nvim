local U = require("plugin_tools.util")
local uv = vim.uv
local owned = require("plugin_tools.operations.packages").owned
local M = {}

-- Prepare complete checkouts; publication is the transaction's responsibility.
function M.new(context)
  local task, git, process = context.task, context.git, context.process
  local root, staging = context.root, context.staging
  local reviewed, rebuild = context.reviewed, context.rebuild
  return function(package, mode, lock)
    local transaction = context.transaction
    task:emit("checking", package.id)
    local exists, marker = owned(package)
    local previous_commit
    if exists then
      U.check(
        git(package.dir, "status", "--porcelain", "--untracked-files=normal") == "",
        "local modifications in " .. package.dir
      )
      previous_commit = git(package.dir, "rev-parse", "HEAD")
    end
    task:emit("checking", package.id, { before_commit = previous_commit })
    local preview = reviewed and reviewed.entries[package.id]
    if preview then
      U.check(
        preview.source == package.source
          and preview.version == package.version
          and vim.deep_equal(preview.build, package.build),
        package.id .. ": configuration changed since preview; create a new plan"
      )
      U.check(preview.before_commit == previous_commit, package.id .. ": checkout changed since preview")
    end
    local entry = lock.plugins[package.id]
    local updating = mode == "update" or mode == "plan"
    if updating and exists then
      U.check(
        (not entry or entry.source == package.source) and (entry and entry.commit or marker.commit) == previous_commit,
        package.id .. ": checkout differs from lockfile; use freeze() or restore() first"
      )
    end
    if mode == "install" and exists and not rebuild then
      local commit = previous_commit
      U.check(
        not entry or (entry.source == package.source and entry.commit == commit),
        package.id .. ": installed version differs from lockfile; use restore() or freeze()"
      )
      task:emit("staged", package.id, { after_commit = commit, unchanged = true })
      return { package = package, commit = commit, unchanged = true }
    end
    if entry and not updating then
      U.check(entry.source == package.source, package.id .. ": lockfile source differs from spec")
    end
    U.check(mode ~= "restore" or entry, package.id .. ": no locked revision to restore")
    local temporary, err = uv.fs_mkdtemp(root .. "/.stage-" .. package.id .. "-XXXXXX")
    U.check(temporary, "cannot stage " .. package.id .. ": " .. tostring(err))
    staging[#staging + 1] = temporary
    transaction:stage(temporary)
    local checkout = temporary .. "/checkout"
    local clone = { "git", "clone", "--quiet", "--filter=blob:none", "--no-checkout" }
    if exists then
      vim.list_extend(clone, { "--reference-if-able", package.dir, "--dissociate" })
    end
    vim.list_extend(clone, { "--", package.source, checkout })
    task:emit("cloning", package.id)
    process(clone)
    local ref = (preview and preview.after_commit)
      or (not updating and entry and entry.commit)
      or package.version
      or "HEAD"
    U.check(not ref:match("^-"), package.id .. ": version cannot begin with '-' ")
    -- Git clone stores remote branches under refs/remotes/origin; prefer an
    -- explicit branch/tag and only then accept a commit-ish.
    local revision
    if ref == "HEAD" or (#ref == 40 and ref:match("^%x+$")) or ref:match("^refs/") then
      revision = git(checkout, "rev-parse", "--verify", ref .. "^{commit}")
    else
      local refs =
        git(checkout, "for-each-ref", "--format=%(refname)", "refs/remotes/origin/" .. ref, "refs/tags/" .. ref)
      local branch = "refs/remotes/origin/" .. ref
      if vim.list_contains(vim.split(refs, "\n", { plain = true }), branch) then
        ref = branch
      end
      revision = git(checkout, "rev-parse", "--verify", ref .. "^{commit}")
    end
    local recipe
    if type(package.build) == "table" then
      recipe = package.build
    elseif package.build == nil then
      recipe = false
    end
    local unchanged = exists
      and revision == previous_commit
      and not rebuild
      and recipe ~= nil
      and vim.deep_equal(marker.build, recipe)
    task:emit(
      "resolved",
      package.id,
      { after_commit = revision, unchanged = unchanged, build = package.build ~= nil and not unchanged }
    )
    if mode == "plan" then
      task:emit(
        "resolved",
        package.id,
        { changes = require("plugin_tools.operations.plan").changes(git, checkout, package, previous_commit, revision) }
      )
      return { package = package, commit = revision, previous_commit = previous_commit }
    end
    if unchanged then
      task:emit("staged", package.id)
      return { package = package, commit = revision, unchanged = true }
    end
    task:emit("checkout", package.id)
    git(checkout, "checkout", "--quiet", "--detach", revision)
    task:emit("submodules", package.id)
    git(checkout, "submodule", "update", "--init", "--recursive")
    U.write_json(
      checkout .. "/.git/plugin-tools-owner.json",
      { id = package.id, source = package.source, commit = revision, transaction = transaction.data.id, build = recipe }
    )
    if package.build then
      task:emit("building", package.id)
      task:check_cancelled()
      if type(package.build) == "function" then
        package.build({
          id = package.id,
          dir = checkout,
          cancelled = function()
            return task.cancel_requested
          end,
        })
        task:check_cancelled()
      else
        process(package.build, checkout)
      end
    end
    if U.directory(checkout .. "/doc") then
      task:emit("helptags", package.id)
      vim.api.nvim_cmd({ cmd = "helptags", args = { checkout .. "/doc" } }, {})
      -- Generated help tags are manager-owned build artifacts.
      local exclude = assert(io.open(checkout .. "/.git/info/exclude", "a"))
      exclude:write("\n/doc/tags\n/doc/tags-*\n")
      exclude:close()
    end
    -- Build outputs must be ignored by the plugin itself; tracked modifications
    -- would otherwise make the next update fail or silently discard changes.
    U.check(
      git(checkout, "status", "--porcelain", "--untracked-files=normal") == "",
      package.id .. ": build left a dirty checkout; ignore generated outputs"
    )
    task:emit("staged", package.id)
    return {
      package = package,
      commit = revision,
      checkout = checkout,
      temporary = temporary,
      existed = exists,
      previous_commit = previous_commit,
    }
  end
end

return M
