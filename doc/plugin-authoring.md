# Plugin design, implementation and integration

[README](../README.md) · [Manager reference](plugin-tools.txt) · [Integration guide](guide.md)

This guide distills the current `config.nvim` configuration and the self-developed
plugin collection into an authoring standard. It covers both implementing a
reusable plugin and composing it with plugin-tools.nvim. The source examples are
listed in [Implementation references](#implementation-references).

The rules below are the target for new or changed code, not a claim that every
existing plugin has an identical API. A plugin's help documents its actual public
contract. In particular, feature reconfiguration and disposal differ from the
manager's session-wide, single-setup lifecycle.

- [Ownership](#1-assign-ownership-before-implementing-a-feature)
- [Packages and public APIs](#2-keep-packages-modules-and-public-apis-explicit)
- [Configuration and lifecycle](#3-specify-configuration-and-lifecycle-contracts)
- [Resource, async and UI ownership](#4-make-resource-ownership-survive-replacement-and-disposal)
- [Manager integration examples](#5-integrate-with-plugin-toolsnvim)
- [Installation policy and external tools](#6-separate-package-policy-from-external-tool-installation)
- [Validation and documentation](#7-validation-and-documentation-are-part-of-the-contract)

## 1. Assign ownership before implementing a feature

| Owner | Responsibility | Examples from this collection |
| --- | --- | --- |
| Configuration | Personal keys, feature selection, platform preferences, language declarations and project policy. | `core/`, `features/`, `languages/` and plugin specs in config.nvim. |
| Integration adapter | Connect public plugin APIs and translate personal policy into their options. | Completion source policy, image/TeX dispatch, toolchain requirements. |
| Feature plugin | Reusable behavior, commands, feature UI, events and resource lifetime. | File operations, picker presentation, completion, DAP panel, TeX builds. |
| plugin-tools.nvim | Resolve declarations, install/lock packages, mount runtimes, configure nodes and explain activation. | `specs`, `dependencies`, `after`, `mount`, `ft`, package operations. |
| External backend | Its own protocol or processing implementation. | Native LSP clients, nvim-dap sessions, image converters. |
| toolchain-tools.nvim | Resolve, install, activate and lock external tools and parser bundles. | Language servers, debug adapters, parsers and queries. |

Put reusable behavior in the owning plugin instead of accumulating it in the
configuration. Keep personal defaults and cross-plugin decisions in configuration
or adapters. Feature modules must work without requiring `plugin_tools`,
`config.plugins`, `config.context` or another personal configuration module.

For example, tex-tools owns formula selection and compilation; image-tools owns
media conversion and display. Completion owns its documentation window and
borrows image-tools' embedded rendering API for media previews. DAP tools owns
its panel and configuration interface while nvim-dap owns protocol sessions.

## 2. Keep packages, modules and public APIs explicit

A useful starting structure for a new plugin is:

```text
notes-tools.nvim/
  lua/notes_tools/init.lua       Public API and feature lifecycle
  lua/notes_tools/config.lua     Defaults, copying, merging and validation
  lua/notes_tools/commands.lua   Lightweight command registration
  lua/notes_tools/runtime.lua    Owned handlers, requests and resources
  lua/notes_tools/health.lua     Availability and configuration diagnostics
  plugin/notes-tools.lua         Optional native command/event entry point
  doc/notes-tools.txt            Complete public reference
  tests/                        Offline API/lifecycle and relevant UI checks
```

This is an illustrative layout, not a required internal class hierarchy. Split
large features into modules when they have distinct responsibilities or lifetimes.
Keep a public facade small enough that consumers do not import private UI state.
Follow the common `local M = {}` / `return M` module pattern: keep implementation
helpers and mutable state local, and export deliberate `M.method` entry points.
Annotate public option/context tables and callback results where their shape is
not obvious. For resource-heavy modules, state their purpose and lifetime owner
near the implementation rather than relying on the configuration to explain it.

Use a distinctive namespace for Lua modules, commands, highlights, autocmd groups
and `User` events. Document the actual main module: repository names are not Lua
module names. Existing examples include `file-tools.nvim` → `file_tools`,
`dap-tools.nvim` → `dap_tools`, and `tex-tools.nvim` → `tex-tools`. Preserve
documented names rather than renaming existing APIs to fit a new convention.

Expose operations such as `open()`, `close()`, `toggle()` and `get_state()` where
they have a clear meaning. Document argument ownership, return values, whether
they initialize services, and whether they can fail or return cancellation handles.
Prefer supported public operations and snapshots to cross-plugin access to
internal buffers, tables or module-local flags.

## 3. Specify configuration and lifecycle contracts

### Configuration input

- Validate the argument type before treating a missing argument as `{}`.
- Copy caller-owned options; do not retain writable aliases into their tables.
- Resolve a new feature configuration from fresh defaults on each `setup()`.
  Use a separate, explicitly documented operation for partial updates.
- Define merging precisely: dictionaries merge, sequences replace, and an empty
  table must be able to clear an earlier collection where that API promises it.
  Test arrays of descriptors and nested options rather than relying on accidental
  generic merge behavior.
- Validate the candidate before changing commands, handlers, options or a live
  instance. Invalid reconfiguration should leave the valid instance usable.
- Describe allowed values and defaults in the plugin's help. Reject invalid
  values with a message identifying the plugin and option.

The manager merges all declarations before activation. `ctx.opts` is a private
copy for that callback, and automatic `main.setup(opts)` also receives a copy.
This does not replace copying at a plugin's public API: standalone callers need
the same guarantees.

### Feature lifetime

For plugins that support reconfiguration, repeating setup must not accumulate
commands, mappings, autocmds, timers, client listeners or subscriptions. Construct
and validate a candidate before retiring the previous instance; unwind a failed
start so partially created resources cannot keep running.

| Operation | Contract to define |
| --- | --- |
| `setup(opts)` | Start from defaults, validate, and establish the selected feature configuration. |
| `disable()` / `enable()` | If provided, suspend/resume behavior while retaining the selected configuration. |
| `dispose()` | If provided, invalidate pending work and release owned runtime resources; safe when cold or repeated. |
| `status()` / `get_state()` | Return a read-only snapshot without opening UI or starting a backend. |
| Explicit feature use after disposal | Either initialize again through a documented path or report that setup is required. |

Do not invent these methods for every plugin solely for uniform naming. Document
real resource boundaries. plugin-tools accepts singleton `setup()` only once and
does not unload native scripts generically. Toolchain refuses reconfiguration or
disposal during active installation/lock operations, and disposal does not remove
installed assets. A feature must not stop a native LSP client, DAP session or
external build merely because it owns one view onto that resource.

### Lightweight entry points and cold state

Configuration collection should return declarations and options, not start
features. `setup()` should register the smallest useful command/event/API surface;
load expensive engines, indexes, views and processes when the feature is used.
If a feature needs an early watcher, keep that watcher in the plugin and guard
its first-use activation there.

Current examples are `completion_tools.bootstrap` for first input,
`image_tools.bootstrap` for preview candidates, file-tools' API delegating tree
creation to `file_tools.tree`, and `dap_tools.backend()` mounting/loading DAP only
on demand. These plugin-owned bootstraps are separate from the manager's
standalone [self-installation bootstrap](guide.md#bootstrap-and-self-updates).

Keep pure capability/metadata APIs separate from engines. Importing
`completion_tools.capabilities` can negotiate server capabilities without
loading completion UI. A read-only state query should preserve an unknown/cold
state rather than initialize a provider just to answer it. `package.loaded` can
observe an already loaded module; `pcall(require, ...)` actually loads it and is
appropriate only when activation is intended.

An optional `plugin/` entry point should register lightweight commands or watchers
with a native source guard. It must not unconditionally call `setup({})` after
the manager has already supplied user options. Registration must remain safe
when both explicit setup and native sourcing reach it.

## 4. Make resource ownership survive replacement and disposal

### Commands, mappings and global adapters

Personal global bindings belong to configuration. Feature-local buffer/window
bindings belong to the feature and should have a documented scope. In config.nvim,
`config.bindings.set(owner, entries)` installs ordinary mappings and tracks their
ownership; it is not a manager loading proxy and is not an API a reusable plugin
should import. Standalone examples can use `vim.keymap.set()` directly.

Command registration should detect unrelated name conflicts. Replace or delete a
registration only while it still matches the one installed by that owner. A
returned cleanup handle must not delete a later replacement. Apply the same rule
to mappings, global callbacks and integrations such as `vim.ui.select`.

Use namespaced autocmd groups and retain cleanup/subscription handles. Never clear
another feature's handlers as part of setup or disposal. The collection's
`user_command.lua` helpers and selection-tools' guarded restoration of
`vim.ui.select` demonstrate these rules; they do not require a shared helper plugin.

### Async work

Each asynchronous operation needs an authority token: an instance/generation,
request context, session/frame or other identity appropriate to the feature.
Before applying a result, recheck that identity and every resource it will touch.
Buffer identity alone is insufficient if the document changed or the cursor
request is obsolete.

- Invalidate pending authority before closing views or removing handlers.
- Stop/close owned timers, cancel owned requests, release watchers and unsubscribe
  listeners. Late callbacks must not resurrect disposed UI.
- Preserve buffer, window and changed-tick context where results depend on them.
  Check window validity and that it still displays the intended buffer.
- Keep display bounds, result counts, retained logs and caches finite.
- Prefer `vim.system()` argv and a per-child environment; do not concatenate
  arbitrary paths into shell commands or mutate global PATH for one job.
- Define completion, error, timeout and cancellation behavior. Report failures
  through the plugin's public diagnostics, not swallowed `pcall()` results.

DAP variables are guarded by session, frame and epoch. Completion/path previews
check request validity before updating a borrowed documentation window. Image
runtime disposal marks the instance disposed before removing resources. Adapt
those patterns to the actual owner instead of copying one universal token shape.

### UI and themes

Own only feature-created windows, buffers, namespaces and terminal resources.
Preserve the user's modified source buffer, focus, cursor and editor mode. A
refused cleanup is preferable to force-deleting an unrelated modified buffer.
Release embedded renderers when their borrowed window stops displaying the
expected content; let the rendering owner clean up terminal graphics.

Publish namespaced highlight groups. Refresh private defaults on `ColorScheme`
or a public palette subscription, while preserving explicit user/theme overrides
of public groups. File-tools' private default groups and `theme_tools.on_change()`
subscription are a concrete example. Opening a feature must not select another
colorscheme or initialize an unrelated theme manager.

## 5. Integrate with plugin-tools.nvim

Use the [README configuration example](../README.md#installation) for the complete
`init.lua` bootstrap and manager option table. Feature plugins do not need a
plugin-tools adapter module.

### Ordinary plugin with setup

Each entry below is a spec inside the manager's `specs` list:

```lua
{
  id = "file-tools.nvim",
  source = "Jacky-Lzx/file-tools.nvim",
  main = "file_tools",
  origin = "plugins.navigation.files",
  opts = { tree = { width = 40, follow = true } },
}
```

The manager calls `require("file_tools").setup(opts)` on activation. `origin` is
an explanation label, not an import instruction. Top-level manager options such
as `auto_install`, `profile` and `root` do not belong in this plugin's `opts`.

### Custom configuration and personal mappings

```lua
{
  id = "file-tools.nvim",
  source = "Jacky-Lzx/file-tools.nvim",
  main = "file_tools",
  opts = { tree = { width = 40 } },
  config = function(ctx)
    require("file_tools").setup(ctx.opts)
    vim.keymap.set("n", "<leader>e", "<cmd>FileTools toggle<cr>", {
      desc = "[Files] Toggle tree",
    })
  end,
}
```

`config(ctx)` **replaces** automatic `main.setup(opts)`. Call the plugin's setup
there if it needs one. Use `config = false` for a package that should expose
runtime files without manager-driven setup. A configured child without its own
source/dir can also use `config = false`.

### Availability, initialization and runtime visibility

| Declaration/API | Exact meaning |
| --- | --- |
| `dependencies = { "id" }` | The referenced enabled node must be declared. It does not impose setup order or mount an on-demand dependency. |
| `dependencies = { { id = "id", optional = true } }` | That reference may be absent; it does not select an optional declaration. |
| `after = { "id" }` | Activate the referenced node before this node's configuration. It is an initialization constraint, not a runtimepath ordering mechanism. |
| `start = false` | Skip startup configuration. With startup mounting, modules and native plugin scripts can still be available. |
| `mount = "on-demand"` | Keep the package runtime cold until explicit mounting/activation/use or a matching `ft`. Set this on the package owner. |
| `ctx.has("id")` | Inspect a declared dependency's availability without initializing it. |
| `ctx.mount("id")` | Expose the declared dependency's runtime without running its manager configuration. |
| `ctx.activate("id")` | Mount and initialize the declared dependency once. |
| `ctx.use("id")` | Activate it and return its `main` module; the dependency must define `main`. |

Context methods use dot calls and are restricted to declared dependencies.
The equivalent manager methods use colon calls. `require()` is not intercepted:
importing a mounted module does not run the corresponding manager config.
`mounted` means its runtime is exposed; `ready` means its config completed. Neither
state says that every feature-specific engine, view or server has started.

For example, config.nvim injects backend mounting into DAP tools through its
public callback option:

```lua
{
  id = "dap-tools.nvim",
  source = "Jacky-Lzx/dap-tools.nvim",
  main = "dap_tools",
  dependencies = { "nvim-dap" },
  children = {
    {
      id = "nvim-dap",
      source = "mfussenegger/nvim-dap",
      mount = "on-demand",
      start = false,
    },
  },
  opts = { ui = { auto_open = true } },
  config = function(ctx)
    local opts = ctx.opts
    opts.backend_loader = function()
      ctx.mount("nvim-dap")
    end
    require("dap_tools").setup(opts)
  end,
}
```

DAP tools decides when it needs a backend. The adapter supplies mounting policy;
the reusable plugin does not import the manager. Other owners can inject a plain
backend loader or place nvim-dap on runtimepath directly.

### Filetype activation

```lua
{
  id = "tex-tools.nvim",
  source = "Jacky-Lzx/tex-tools.nvim",
  main = "tex-tools",
  mount = "on-demand",
  ft = { "tex", "plaintex", "bib", "bst" },
  opts = { mappings = false },
}
```

This is a minimal filetype example; integrations such as formula media rendering
add their own dependency declarations and options. `ft` accepts literal filetypes
and cannot be combined with `start = true`. Matching existing and future buffers
can trigger the node's single initialization. Plugin setup must attach existing
matching buffers as well as register future hooks; the manager does not replay
`FileType` for a newly installed handler.

Late mounting sources `plugin/` and `after/plugin/` scripts, but cannot recreate
all earlier native detection/ftplugin phases. Keep startup mounting when those
native phases are required. The manager supplies no `event`, `cmd` or `keys`
loading proxy fields; put those entry points in the plugin. This does not prevent
ordinary personal keymaps in `config(ctx)`.

### Composition, selection and development paths

The collector in config.nvim uses explicit ordered module lists, annotates
`origin`, merges language contributions, then adds trusted project declarations.
That collector is configuration code, not a plugin-tools built-in. A simple
standalone configuration can use:

```lua
local specs = {}
for _, module in ipairs({ "plugins.navigation", "plugins.coding" }) do
  vim.list_extend(specs, require(module))
end
return { specs = specs }
```

Those modules should return spec lists without binding keys or starting plugins.
Only a configuration that implements project discovery/trust should load project
Lua; plugin-tools does not discover or execute `.nvim-plugins.lua` automatically.

- A child declaring `source` or `dir` owns an independent package. A child without
  either shares the nearest package owner. `path` selects a component runtime
  root inside that owner's checkout, not another install directory.
- Ordinary roots default to startup initialization; children, on-demand and
  filetype nodes default to deferred initialization. Be explicit when overriding
  these defaults. Visual tree nesting alone does not initialize child features.
- Repeated compatible IDs compose options before setup. Dictionaries merge,
  sequences/empty tables replace, and conflicting scalar fields fail. Declare
  exactly one configuration strategy for an ID rather than competing callbacks.
- `enabled = false` removes that contribution and subtree. `optional = true`
  keeps a declaration dormant until another enabled, non-optional declaration
  selects the same ID. A dependency reference alone cannot select it.
- `dir` is an external checkout and is never installed, updated or cleaned.
  `source` plus `dev = true` uses `dev.path/id` when present; `dev.fallback`
  controls fallback to the managed source. Keep developer paths in configuration,
  not inside the reusable plugin.

## 6. Separate package policy from external tool installation

`auto_install = true` is the current manager default: missing managed packages
are installed at locked revisions before configuration. Existing packages are
not updated, and external tools, debug adapters and parsers are not installed by
that operation. Server startup remains feature-owned and can follow plugin
configuration. When runtime directories are already present, the manager's
startup path does not run Git or read the plugin lockfile.

For a prepared/offline startup policy, explicitly set `auto_install = false` and
install separately. Omitting the option inherits the manager's current default;
an older configuration's installation instructions do not override that default.
`strict = false` permits remaining missing directories but does not hide an
automatic installation failure. Self registration through the standalone
bootstrap is separate from the ordinary plugin `specs` list.

Keep plugin revisions in `plugin-tools-lock.json` and tool versions in the
toolchain owner's lockfile. Resolve executables through a documented provider or
option, prefer existing system/Nix tools when configured, and install missing
tools through an explicit toolchain operation. Normal feature setup should not
silently download tools. For plugin installation builds, use the package `build`
contract, keep generated artifacts ignored, and avoid modifying tracked sources.
Runtime work such as compiling a TeX formula belongs to its feature API and is
separate from downloading a compiler or installing a plugin package.

## 7. Validation and documentation are part of the contract

Use [the test workflow](../tests/README.md) and the common
[documentation style](documentation-style.md). Keep README concise, put the
complete option/API contract in Vim help, and put implementation/integration
guides in `doc/`. State the plugin's actual minimum Neovim version: config.nvim
currently requires 0.12, while this manager requires 0.11; the configuration's
minimum is not automatically a requirement of every reusable plugin.

Validate the contracts that can break callers:

- Require/setup cold state, input copying, fresh defaults, list replacement,
  invalid setup preserving a valid instance, and repeated registration.
- Disposal when cold/repeated, explicit reinitialization, stale async callbacks,
  and preservation of later user/other-owner command, mapping and UI replacements.
- Installation and build failure boundaries, lockfile restoration, dirty checkout
  protection and external development overrides where the plugin owns installation.
- Actual UI input, focus, cursor/mode, resize, first and repeated use, cancellation,
  modified-buffer preservation and intermediate frames where they matter.

Offline defaults should never fetch fixtures implicitly. Register cases in
`tests/cases.json`, isolate state and processes, wait for semantic completion
rather than fixed sleeps, and retain failure logs. Keep cross-plugin, personal
keymap and selected-workflow checks in configuration integration tests; they do
not replace standalone plugin tests.

Measure startup and first interaction separately before claiming a speedup.
Moving a `require()` into another callback is a loading change until representative
fresh-process/real-PTY evidence establishes its effect. A ready manager state is
not evidence of a cold or fast feature backend.

For changes to this manager's UI, update the [reproducible screenshots](screenshots/README.md).
Distinguish local tests, a local commit, installation into a running configuration,
publication and hosted CI. A screenshot demo or headless test cannot stand in for
the other states.

## Implementation references

Inspected clean working checkouts on 2026-11-07. Paths below are relative to each
named repository, so the guide does not depend on a personal filesystem layout.
These are implementation examples; use the current help for the API of a version
you actually install.

| Repository / revision | Representative paths and observed responsibility |
| --- | --- |
| config.nvim · `e9152b0` | `lua/config/{init,specs,plugins,bindings}.lua`; `lua/integrations/`; `lua/plugins/debugging/dap-tools.lua`; `lua/languages/latex/plugins.lua`. Explicit composition, owned personal mappings and provider adapters. |
| file-tools.nvim · `35f96d7` | `lua/file_tools/{init,commands,user_command,theme}.lua`; `plugin/file-tools.lua`; `tests/setup_contract.lua`. Facade, deferred tree, command ownership and private theme defaults. |
| completion-tools.nvim · `b9ad9be` | `lua/completion_tools/{bootstrap,capabilities,init,path_preview}.lua`. Plugin-owned first input, pure capabilities, request/disposal guards and borrowed media rendering. |
| dap-tools.nvim · `59102bc` | `lua/dap_tools/{init,ui}.lua`. Injected backend loading and session/frame/epoch guarded panel requests. |
| image-tools.nvim · `e4ecff9` | `lua/image_tools/{init,bootstrap,runtime}.lua`. Candidate validation, lazy runtime and owned display cleanup. |
| selection-tools.nvim · `8a08e74` | `lua/selection_tools/init.lua`. Copied options, explicit sequence replacement and ownership-aware `vim.ui.select` restoration. |
| theme-tools.nvim · `f05be1e` | `lua/theme_tools/{init,palette}.lua`. Public palette snapshots and subscriptions. |
| toolchain-tools.nvim · `3b0a384` | `lua/toolchain/init.lua`. Explicit installations, lazy queue creation and protected active operations. |

The manager-specific contracts are implemented in [graph resolution](../lua/plugin_tools/graph.lua),
[activation/context handling](../lua/plugin_tools/manager.lua),
[runtime mounting](../lua/plugin_tools/runtime.lua) and
[filetype triggers](../lua/plugin_tools/triggers.lua). The
[manager reference](plugin-tools.txt) is authoritative for their complete fields
and failure behavior.
