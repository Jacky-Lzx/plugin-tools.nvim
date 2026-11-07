# plugin-tools.nvim

Explicit plugin composition, package installation and runtime mounting.

## Features

- Inspect plugin ownership, activation reasons and timings.
- Install exact locked revisions and review updates before applying them.
- Keep package management separate from feature initialization.
- Bootstrap from init.lua and manage plugin-tools.nvim's own locked revision.

![Plugin hierarchy, selection and activation states in the Plugin Tools panel](doc/screenshots/overview.png)

## Requirements

Neovim **0.11+**. Git is required for installation and updates. Startup installs
missing managed plugins by default; set `auto_install = false` to disable this.

## Installation

For automatic first installation, put this in `init.lua`, before loading plugins:

```lua
local root = vim.fn.stdpath("data") .. "/plugin-tools"
local path, seed = root .. "/plugin-tools.nvim", nil
local ok, manager = pcall(function()
  if not vim.uv.fs_lstat(path) then
    seed = vim.fn.tempname()
    local result = vim.system({
      "git", "clone", "--filter=blob:none", "--",
      "https://github.com/Jacky-Lzx/plugin-tools.nvim.git", seed,
    }, { text = true }):wait(120000)
    assert(result.code == 0, result.stderr)
  end
  return dofile((seed or path) .. "/bootstrap.lua").setup({ root = root, specs = {} })
end)
if seed then vim.fn.delete(seed, "rf") end
if not ok then error(manager, 0) end
```

The temporary clone installs the managed copy and declared packages through the
normal transaction and lockfile workflow, then is removed. Subsequent startups
automatically install newly declared or deleted managed packages before loading
your plugin configuration. Existing plugins are not updated. When packages are
present, startup runs no Git commands and does not read the lockfile. Keep
`plugin-tools-lock.json` with your configuration to reproduce revisions.

`auto_install` defaults to `true` for both bootstrap and ordinary `setup()`.
Set it to `false` in the setup options to install packages explicitly with
`:PluginTools install`; use `strict = false` to enter Neovim with missing plugins.

Update plugin-tools.nvim itself with `:PluginTools update plugin-tools.nvim`, or
include it in `:PluginTools plan` followed by `:PluginTools apply`. Restart after
updating. See the [bootstrap guide](doc/guide.md#bootstrap-and-self-updates) for
options, failure recovery and migration.

For manual installation, clone into Neovim's native package directory:

```sh
git clone https://github.com/Jacky-Lzx/plugin-tools.nvim.git \
  "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/pack/tools/start/plugin-tools.nvim"
```

With manual installation, call this from `init.lua`, before native plugin loading:

```lua
require("plugin_tools").setup({ specs = {} })
```

## Usage

```vim
:PluginTools
:PluginTools profile
:PluginTools explain {id}
```

<details>
<summary>Startup profiling, dependency details and update previews</summary>

**See where startup time goes.**

![Startup stages and per-plugin initialization, script and on-demand timings](doc/screenshots/profile.png)

**Understand why a plugin is active and where it was declared.**

![Plugin details showing activation causes, package ownership and declared dependencies](doc/screenshots/details.png)

**Review exact commits and change counts before applying an update.**

![An update plan with locked and proposed revisions and Git history summaries](doc/screenshots/update-plan.png)

</details>

Captured from an isolated offline demo. [Recreate the screenshots](doc/screenshots/README.md).

## Documentation

- [Complete reference](doc/plugin-tools.txt) — `:help plugin-tools`.
- [Workflow and integration guide](doc/guide.md).
- Diagnose availability with `:checkhealth plugin_tools`.

## Development

Run from the repository root:

```sh
python3 tests/run.py unit --filter docs
python3 tests/run.py default
```

Refresh the screenshots after UI changes (requires `rsvg-convert`):

```sh
python3 doc/screenshots/capture.py
```

See [the test workflow](tests/README.md) for dependencies, optional suites and
retained failure evidence. Local development overrides belong in your package
manager configuration; public installation uses the repository above.

[License](LICENSE).
