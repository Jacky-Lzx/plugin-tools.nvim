# plugin-tools.nvim

Explicit plugin composition, package installation and runtime mounting.

## Features

- Inspect plugin ownership, activation reasons and timings.
- Install exact locked revisions and review updates before applying them.
- Keep package management separate from feature initialization.

## Requirements

Neovim **0.11+**. Git is required for package operations. Startup does not download packages.

## Installation

Clone the public repository into Neovim's native package directory:

```sh
git clone https://github.com/Jacky-Lzx/plugin-tools.nvim.git \
  "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/pack/tools/start/plugin-tools.nvim"
```

Call this from `init.lua`, before native plugin loading:

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
