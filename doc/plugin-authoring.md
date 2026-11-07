# Plugin authoring and manager integration

[README](../README.md) · [Manager reference](plugin-tools.txt) · [Integration guide](guide.md)

These guidelines cover reusable plugin implementation and integration with
plugin-tools.nvim. Individual plugins should document their own public contracts.

## Ownership

| Layer | Responsibility |
| --- | --- |
| Configuration | Personal mappings, feature selection, platform settings and integration policy. |
| Plugin | Reusable behavior, public APIs, feature activation, UI and resource lifetime. |
| Manager | Package installation and locking, runtime mounting, initialization and diagnostics. |

Keep reusable code independent of the manager and personal configuration modules.
Connect dependencies through public APIs or injected callbacks. External tool
installation is separate from plugin package management.

## Implementation rules

### Modules and configuration

- Keep public entry points small, implementation helpers private and mutable state
  local. Document the actual Lua module name, option types and return values.
- Validate options before changing live resources. Copy caller-owned tables and
  resolve each configuration from fresh defaults. Document partial updates separately.
- Define merge rules: dictionaries merge, sequences replace, and empty collections
  clear earlier values where supported. Test nested options and descriptor arrays.
- Register lightweight commands and events during setup; load expensive engines,
  indexes, views and processes on feature use. Keep pure metadata/capability APIs
  separate from engines.
- Read-only state queries must not initialize services. `package.loaded` observes
  loaded modules; `pcall(require, ...)` loads them.
- Native `plugin/` entry points should register once without resetting previously
  supplied options through an unconditional `setup({})`.

### Lifecycle and resources

For plugins supporting reconfiguration, repeated setup must not duplicate commands,
autocmds, mappings, timers or subscriptions. Validate a replacement before retiring
live resources and clean up a failed start.

If provided, `disable()` retains configuration; `dispose()` invalidates pending work
and releases owned resources, safely when cold or repeated. Document whether later
feature use initializes again. The manager itself accepts singleton setup once and
does not provide generic plugin unloading.

- Namespace commands, highlights, autocmd groups and events. Replace or remove a
  registration only while it still belongs to that owner; preserve later user changes.
- Invalidate async work before teardown. Recheck generation/request identity and
  relevant buffer, window, changed-tick or session context before applying results.
- Cancel owned requests, close timers and release watchers/subscriptions. Late
  callbacks must not recreate disposed UI.
- Own only feature-created resources. Preserve modified buffers, focus, cursor and
  editor mode; closing a view must not stop a shared backend or unrelated process.
- Bound result counts, retained logs, caches and rendering work. Prefer process argv
  and child-specific environments to shell interpolation and global PATH changes.
- Publish namespaced highlights, refresh private defaults and preserve explicit user
  overrides. Opening UI must not change the user's colorscheme.

## Manager integration

The examples use hypothetical local plugins. Replace the names, paths and options
with the plugin's documented API. Use `source = "owner/repository"` instead of `dir`
for a Git-managed package. See the [README](../README.md#installation) for the full
bootstrap and manager options.

### Setup and personal mappings

Put this declaration inside `specs`:

```lua
{
  id = "example.nvim",
  dir = vim.fn.expand("~/src/example.nvim"),
  main = "example",
  opts = { width = 40 },
  config = function(ctx)
    local plugin = require("example")
    plugin.setup(ctx.opts)
    vim.keymap.set("n", "<leader>e", plugin.open, { desc = "Open example" })
  end,
}
```

Without `config`, the manager calls `require(main).setup(opts)` automatically.
`config(ctx)` replaces that call; invoke setup yourself when needed. `config = false`
suppresses manager-driven setup. `ctx.opts` and automatic setup arguments are copies,
but public plugin APIs must also protect standalone callers' input.

Top-level options such as `root`, `auto_install` and `profile` configure the manager;
`specs[i].opts` configures a plugin. `origin` is an optional declaration label.

### Dependencies and activation

| Field or API | Meaning |
| --- | --- |
| `dependencies = { "id" }` | Require a declared enabled node; no setup order or implicit on-demand mounting. |
| `{ id = "id", optional = true }` in `dependencies` | Permit an absent reference; does not select an optional declaration. |
| `after = { "id" }` | Activate that node before this configuration; does not order runtimepath. |
| `start = false` | Skip startup configuration; startup-mounted runtime files remain available. |
| `mount = "on-demand"` | Defer package runtime visibility until mount, activation, use or a matching filetype. |
| `ft = { "markdown" }` | Initialize once on a matching existing or future buffer; incompatible with `start = true`. |
| `ctx.has("id")` | Inspect a declared dependency's availability without initialization. |
| `ctx.mount("id")` | Expose its runtime without running manager configuration. |
| `ctx.activate("id")` | Mount and initialize it once. |
| `ctx.use("id")` | Activate it and return its `main` module; requires `main`. |

Context methods use dot calls and only access declared dependencies. Manager methods
use colon calls. `require()` is not intercepted and does not trigger manager setup.
`mounted` means runtime visibility; `ready` means configuration completed. Neither
implies that every feature backend is running.

Keep first-use commands/events inside the plugin: the manager has no `event`, `cmd`
or `keys` loading proxy fields. Filetype setup must attach existing matching buffers
as well as future ones; the manager does not replay `FileType`. Late mounts source
`plugin/` and `after/plugin/`, but cannot replay all native detection/ftplugin phases.
Use startup mounting when those phases are required.

### Inject a deferred provider

As an alternative to the first spec, a plugin accepting a `render` callback can
activate its renderer only when that callback is used:

```lua
{
  id = "example.nvim",
  dir = vim.fn.expand("~/src/example.nvim"),
  main = "example",
  dependencies = { "renderer.nvim" },
  children = {
    {
      id = "renderer.nvim",
      dir = vim.fn.expand("~/src/renderer.nvim"),
      main = "renderer",
      mount = "on-demand",
      config = false,
    },
  },
  config = function(ctx)
    local opts = ctx.opts
    opts.render = function(value)
      return ctx.use("renderer.nvim").render(value)
    end
    require("example").setup(opts)
  end,
}
```

The renderer needs no setup here. The adapter owns activation policy; the feature
plugin only calls its supplied callback and has no manager dependency.

### Composition and selection

- A child with `source` or `dir` owns an independent package. Other children share
  the nearest package owner; `path` selects a component inside that checkout.
- Ordinary roots default to startup initialization; children, on-demand and filetype
  nodes default to deferred initialization. Nesting alone does not initialize children.
- Compatible repeated IDs merge options before setup. Dictionaries merge, sequences
  and empty tables replace, and conflicting scalar fields fail.
- `enabled = false` removes a contribution and subtree. An `optional = true`
  declaration is selected by another enabled, non-optional declaration of the same
  ID, never by a dependency reference alone.
- `dir` is external and never installed, updated or cleaned. `source` with `dev = true`
  prefers `dev.path/id`; `dev.fallback` controls managed fallback.
- Collect declarations in explicit order without starting features. Project-file
  discovery and trust belong to configuration, not the manager.

## Installation policy

`auto_install = true` installs missing managed packages at locked revisions before
configuration. Existing packages are not updated. Set it to `false` for explicit
installation; `strict = false` tolerates missing directories but does not suppress
automatic installation failures. With runtime directories present, the manager's
startup path runs no Git commands and reads no plugin lockfile.

Keep plugin revisions and external tool versions under their respective installers.
Feature setup should not silently download executables. Package installation builds
use the manager's `build` contract, with generated artifacts ignored and tracked
sources unchanged. Runtime compilation belongs to the feature API.

## Validation and documentation

Document the actual minimum Neovim version, defaults, public API, lifecycle and
external requirements. Keep full contracts in Vim help and examples in guides;
follow the [documentation style](documentation-style.md).

Verify input isolation, merge rules, invalid setup, repeated registration, disposal,
reinitialization, stale callbacks and preservation of later user replacements. UI
checks should exercise real input, focus/mode/cursor, resizing, cancellation and
modified-buffer preservation. Installation checks should cover locks, failures,
dirty checkouts and development overrides.

Use isolated offline fixtures, semantic completion conditions and retained failure
logs. Measure startup and first interaction separately before claiming a speedup.
Keep standalone tests separate from configuration-specific integrations. See the
[test workflow](../tests/README.md); for manager UI changes, regenerate the
[screenshots](screenshots/README.md).

The [manager reference](plugin-tools.txt) defines the complete declaration and
operation contracts.
