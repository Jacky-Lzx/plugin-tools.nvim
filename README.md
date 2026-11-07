# plugin-tools.nvim

Explicit plugin composition, package installation and runtime mounting.

## Features

- Inspect plugin ownership, activation reasons and timings.
- Install exact locked revisions and review updates before applying them.
- Keep package management separate from feature initialization.
- Bootstrap from init.lua and manage plugin-tools.nvim's own locked revision.

## Requirements

Neovim **0.11+**. Git is required for installation and updates. Normal startup
does not download packages; the opt-in bootstrap installs on its first run.

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
load the managed copy directly without Git or lockfile reads. Keep
`plugin-tools-lock.json` with your configuration to reproduce revisions.

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

See [the test workflow](tests/README.md) for dependencies, optional suites and
retained failure evidence. Local development overrides belong in your package
manager configuration; public installation uses the repository above.

[License](LICENSE).
