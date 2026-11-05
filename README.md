# plugin-tools.nvim

A small Neovim plugin manager for explicit plugin composition and plugin-owned
on-demand initialization. Requires Neovim 0.11+ and Git for package operations.

The manager installs packages, mounts runtime directories, applies configuration,
and explains relationships. Plugins decide when their features do work. There are
no event/key/command/filetype loading specifications, `require()` hooks, module
scans, polling timers, automatic downloads, or update checks during startup.

## Use the local checkout

Add this checkout to `runtimepath` in `init.lua`, before native plugin loading:

```lua
vim.opt.runtimepath:prepend(vim.fn.expand("~/Documents/Github/nvim_plugins/plugin-tools.nvim"))
require("plugin_tools").setup(require("my_plugin_specs"))
```

`my_plugin_specs.lua` returns the options table. A small real-package example:

```lua
return {
  root = vim.fn.stdpath("data") .. "/plugin-tools",
  lockfile = vim.fn.stdpath("config") .. "/plugin-tools-lock.json",
  dev = { path = "~/Documents/Github/nvim_plugins", fallback = true },
  specs = {
    {
      id = "file-tools.nvim",
      source = "Jacky-Lzx/file-tools.nvim",
      dev = true,
      main = "file_tools",
      opts = { tree = { width = 40 } },
    },
  },
}
```

Keep an existing configuration unchanged while developing this manifest. A
plugin's integration with your other plugins belongs in your configuration or
that plugin; this manager does not supply those integrations.

For the first installation, explicitly run the administration script:

```sh
nvim --headless -u NONE -i NONE --noplugin \
  -l /path/to/plugin-tools.nvim/examples/manage.lua /path/to/my_plugin_specs.lua install
```

Then start Neovim normally. Alternatively, temporarily set `strict = false`, run
`:PluginTools install`, wait for completion, and restart. Missing plugins are
reported as `missing`, and skipped in permissive mode. Strict startup is the
default and checks every directory before changing `runtimepath`.

## Composition and activation

The following illustrative manifest shows both forms of nesting:

```lua
local manager = require("plugin_tools").setup({
  specs = {
    {
      id = "frontend",
      dir = "~/plugins/frontend",
      dependencies = { "renderer", { id = "icons", optional = true } },
      config = function(ctx)
        -- This callback only registers an entry point.
        vim.api.nvim_create_user_command("MyPreview", function()
          ctx.use("renderer").render()
        end, {})
      end,
      children = {
        -- A module within the same checkout; no extra clone or version.
        { id = "frontend.outline", main = "frontend.outline" },
        -- A separate runtime root inside the same checkout.
        { id = "frontend.syntax", path = "components/syntax" },
        -- An independent package organized under this frontend.
        {
          id = "renderer",
          dir = "~/plugins/renderer",
          main = "renderer",
          opts = { border = "rounded" },
        },
      },
    },
  },
})
```

Before `:MyPreview`, `renderer` is available on `runtimepath` but its main module
and configuration have not been loaded by this manager. On first use,
`ctx.use("renderer")` initializes it once and returns `require("renderer")`.
Subsequent calls reuse its initialized state and Lua's module cache.

For plugins that should work without depending on this manager, inject a provider
function from `config(ctx)` into the frontend's setup options. The plugin calls
that provider only when needed. Or give the backend a lightweight setup and let
its public API lazily initialize expensive internals itself.

`start = false` controls **manager configuration only**. It does not prevent native
`plugin/`, `ftdetect/`, `ftplugin/`, or other runtime scripts from executing. A
backend with expensive native startup scripts must first move that work into its
own API. This manager does not rewrite third-party plugin lifecycles.

Call `setup()` during `init.lua`. Native Neovim loads `plugin/` and `after/plugin/`
scripts in its usual startup phases; the manager neither sources nor replays
them. Mounting after startup does not replay missed events or native scripts.
Managed roots are inserted before the built-in runtime, preserving preceding
configuration directories. Managed `after/` directories precede existing
configuration `after/` directories so user overrides still apply last.

## Entry-point ownership

Plugins own their commands, public APIs, and feature-specific events. Keep their
`setup()` lightweight: save options and register native entry points, then load
heavy implementations when those entry points run. Personal keymaps and
cross-plugin adapters belong in the configuration's `config(ctx)` callback.
The manager has one configuration phase and no separate `bootstrap` hook.

For example, a plugin's lightweight setup may register `:MyPreview`; your config
calls setup and maps `<leader>p` to that command. The command callback loads the
renderer itself. Neither the plugin nor the keymap needs to know the manager.

## Specification

Every node has a required explicit `id` containing letters, digits, `_`, `-`, or
`.` and beginning with a letter or digit. Unknown fields are rejected.

| Field | Meaning |
| --- | --- |
| `source` | Git URL, local Git repository path, or `owner/repository` shorthand |
| `dir` | External checkout, never installed, updated, frozen, or deleted |
| `dev` | Prefer `dev.path/id`; fall back to `source` unless `dev.fallback = false` |
| `version` | Branch, tag, commit, or explicit Git ref; no semver solver |
| `children` | Nested node declarations |
| `path` | Component runtime directory relative to its package owner, not immediate parent |
| `dependencies` | IDs, or `{ id = "...", optional = true }` references |
| `after` | IDs that must initialize before this node; activates them when necessary |
| `enabled` | Boolean or zero-argument predicate; false omits this contribution and its subtree |
| `start` | Initialize during startup; defaults true for roots, false for children |
| `main` | Module passed to `require()` on activation; default activation calls its `setup(opts)` |
| `opts` | Configuration table, copied before passing to plugin code |
| `config` | `function(ctx)` replacing default setup, or false to skip automatic setup |
| `build` | Package-owner-only argv list, or `function({ id, dir })`; runs in staging |

A declaration containing `source` or `dir` owns its package. Other children share
their nearest package owner's checkout, version, and build. Their `path`, when
present, must be a relative path inside that checkout. Components may have their
own `main`, configuration, and explicit activation.

IDs are global. Repeated declarations of an ID share one node and package.
Scalar fields must agree. Options merge in declaration order: maps merge
recursively; lists replace; an empty table clears that key. Dependencies combine,
with required references taking precedence over optional references. Children do
not inherit the parent's arbitrary options. A disabled declaration does not veto
another enabled declaration of the same shared plugin.

All enabled declarations participate in installation. Dependencies are validated
references, not a discovery or version resolution system. Required references
must be declared and enabled; optional references may be absent. An optional
reference alone does not create or install a package.

Dependencies impose no setup order and never activate their targets. Only
`after` adds initialization constraints. Dependency cycles are allowed;
initialization cycles and recursive activation report the cycle path.

`ctx` contains `id`, `dir`, a private `opts` copy, and `has(id)`, `activate(id)`,
and `use(id)` closures. Those closures accept only dependencies declared by that
node. `has()` inspects availability without loading modules. A context uses dot
calls (`ctx.use(id)`), while manager instances use colon calls (`manager:use(id)`).
Nonempty `opts` are copied and cached on first access; a callback that only
registers entry points does not copy the options tree. Contexts receive independent
copies. Graph option merges mutate only manager-owned tables, copying incoming
values once; caller
specifications and other nodes remain isolated.

## Lua API and commands

`require("plugin_tools").setup(options)` creates, starts, and returns the default
manager. The manager and commands remain available for status, health checks,
and package operations if startup configuration fails. Failed initialization is
not retried automatically. Call setup once. Top-level methods forward to that manager. `new(options)`
creates an independent instance without mounting or initializing anything;
call `manager:start()` when ready. Start is idempotent.

Synchronous inspection/runtime methods:

```lua
manager:has(id)       -- Declared and not known missing; no require(), Git, or source scan
manager:activate(id)  -- Configure once; explicit after prerequisites are activated first
manager:use(id)       -- Activate and return require(main); main is required
manager:status()      -- Copies of registered/mounted/ready/missing/failed states
manager:explain(id)   -- Package, source, parents, users, dependencies, configuration, state
```

A failed configuration is retained as `failed` and is not automatically retried;
restart after fixing it. `after` requires a present node even if the caller is not
started automatically. `strict = false` tolerates missing directories, but an
explicit activation of a missing plugin still fails.

Async package methods return a task with `done`, `result`, `error`, and
`task:wait(timeout_ms)`. `wait()` pumps the event loop; a wait timeout does not
cancel or unlock the ongoing operation. Inspect the task or wait again.

| Method / command | Behavior |
| --- | --- |
| `install()` / `:PluginTools install [ids...]` | Install missing packages at locked revision, or declared version; verify existing versions against the lock |
| `update()` / `:PluginTools update [ids...]` | Update selected packages and lock revisions |
| `restore()` / `:PluginTools restore [ids...]` | Restore selected packages to exact locked revisions |
| `freeze()` / `:PluginTools freeze [ids...]` | Record selected existing checkout revisions |
| `clean()` / `:PluginTools clean` | Preview unreferenced owned packages |
| `clean({dry_run=false})` / `:PluginTools clean --apply` | Remove those packages and their lock entries |
| `:PluginTools status` / `:PluginTools explain id` | Inspect state and inclusion reasons |

Operations accept `{ ids = {...}, concurrency = 4, timeout = 120000,
on_complete = function(result, err) ... end }`. IDs select package owners, so
selecting a component selects its shared checkout. Clean uses the whole graph and
does not accept IDs. Manager options `concurrency` and `git_timeout` supply the
defaults. `timeout` bounds each process. `commands = false` omits `:PluginTools`.

Package operations never execute plugin configuration. After installing or
updating, restart Neovim to use new runtime files and configuration; already
required modules are not unloaded. Commands report completion asynchronously.

## Update and cleanup guarantees

Packages live under `root/id`. Local development directories are used directly,
and excluded from remote operations. Lockfile entries for temporarily local
development overrides are preserved. Shorthand URLs default to
`https://github.com/%s.git`; override `url_format` when needed.

Install/update/restore use a bounded worker pool (default four). Each package is
cloned and built in a private staging directory. Updates reuse existing Git
objects with `--reference-if-able --dissociate`; partial clone filters reduce
unneeded blob transfers when supported by the server. Submodules are initialized.
Build argv runs without an implicit shell. A Lua build function runs on Neovim's
main thread; use argv for expensive work.

Only after every package succeeds are complete directories published, with
backups retained until the lockfile is atomically replaced. Caught failures roll
back published checkouts. Help tags are generated when a `doc/` directory exists.
Other build outputs must be gitignored; a dirty build is rejected.

Tracked/untracked changes block replacement and cleanup. A checkout moved away
from its locked commit blocks update; explicitly freeze or restore it first.
Cleanup also rejects a checkout that differs from its recorded commit, preserving
local commits when a plugin is removed from the manifest.
Existing paths need matching manager ownership metadata under `.git/` before
replacement. New paths are checked again before publication. Clean ignores
unknown directories and never follows a package-directory symlink. Shared
packages remain selected while any enabled declaration still owns them.

An exclusive `root/.operation-lock` prevents concurrent operations on the same
root, including across processes. A process crash can leave that lock and staging
backups behind. Inspect the recorded PID, stop the owning process, and recover
needed backups before removing a stale lock. Transactions recover caught errors,
not abrupt termination or power loss. Use one root/lockfile pair per configuration
and do not externally edit checkouts during an operation.

## Performance and verification

The entry module is small. Git, JSON lockfile handling, and command rendering load
only when requested. Startup resolves declarations, checks directories, then
assigns `runtimepath` once. It does not inspect Git status, read the lockfile,
index Lua modules, check updates, or create timers. Module availability uses
Neovim's native runtime lookup. Ready activation is a constant-time state check.
`profile = true` records individual activation times; default timing records only
resolution and total start duration in `manager.timings`.

```sh
sh tests/run.sh
python3 tests/benchmark.py
```

The suite covers graph validation, shared components, first-use dependencies,
runtime paths with commas/Unicode, native startup in a real PTY, asynchronous Git
installation, lock restoration, dirty-checkout protection, transaction rollback,
safe cleanup, and event-loop responsiveness. Tests isolate data/cache/state and
use temporary local repositories; no network or configuration migration is needed.

The benchmark writes `benchmark-results.json`: 15 fresh Neovim processes per
10/100/500-plugin manifest after one warm-up, with median/p95 manager setup,
Lua allocation delta, and repeated ready-activation cost. Package directories are
prepared before timing. It includes the first `require("plugin_tools")`, graph
resolution, and mounting; plugin business initialization is excluded. OS caches
are warm, and Lua allocation delta is not process RSS or a leak measurement.

License: MIT.
