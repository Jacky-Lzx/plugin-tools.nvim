# Workflow and integration guide

[Quick start](../README.md) · [Complete reference](plugin-tools.txt)

Configuration defaults and API contracts are maintained in the help reference.
The examples here illustrate particular workflows.
For reusable plugin implementation and lifecycle rules, see the
[plugin authoring standard](plugin-authoring.md).

## Installation details

The [README bootstrap example](../README.md#installation) provides automatic
first installation and self updates. For an existing local checkout or manual
installation, use the explicit setup below.

Add this checkout to `runtimepath` in `init.lua`, before native plugin loading:

```lua
vim.opt.runtimepath:prepend(vim.fn.expand("~/src/neovim-plugins/plugin-tools.nvim"))
require("plugin_tools").setup(require("my_plugin_specs"))
```

`my_plugin_specs.lua` returns the options table. A small real-package example:

```lua
return {
  root = vim.fn.stdpath("data") .. "/plugin-tools",
  lockfile = vim.fn.stdpath("config") .. "/plugin-tools-lock.json",
  dev = { path = "~/src/neovim-plugins", fallback = true },
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

By default, setup installs missing managed packages before mounting runtimes or
running plugin configuration. Installation honors the lockfile and leaves
existing checkouts unchanged. The packages are available in the same startup,
including native plugin scripts and filetype detection when setup runs in
`init.lua`. Local `dir` overrides and missing component subdirectories are not
cloned. Package operations are loaded only when a managed package is absent.

For an explicit installation workflow, set `auto_install = false` and run the
administration script:

```sh
nvim --headless -u NONE -i NONE --noplugin \
  -l /path/to/plugin-tools.nvim/examples/manage.lua /path/to/my_plugin_specs.lua install
```

Then start Neovim normally. Alternatively, also set `strict = false`, run
`:PluginTools install`, wait for completion, and restart. Missing plugins are
reported as `missing`, and skipped in permissive mode. Strict startup is the
default and checks every directory before changing `runtimepath`.

An automatic installation failure stops startup before mounting or configuration,
even with `strict = false`. The transaction rolls back caught failures; the
default manager's status, logs and commands remain available for diagnosis.
Repair the cause and retry startup. Interrupted operations require the normal
explicit recovery workflow. Automatic installation never updates existing
packages or recovers interrupted transactions on its own.

## Bootstrap and self updates

The standalone `bootstrap.lua` entry point runs before any `plugin_tools` module
is loaded. Its `setup(options)` returns the configured manager and adds a managed
`plugin-tools.nvim` package to your declarations. It does not call setup on itself.
Use this entry point on every startup; do not also call `plugin_tools.setup()`.

On the first run, the README loader clones a disposable seed. Bootstrap uses that
seed's package operations to install the official checkout and, by default, all
selected packages, honoring an existing lockfile. With `auto_install = false`,
the seed installs only plugin-tools.nvim itself; other packages use explicit
installation. Seed modules are unloaded before setup loads the installed version.
Git clone or installation failures stop startup;
the seed is removed by the loader, and the normal transaction protects packages
and lock revisions. A failed first installation can be retried. An interrupted
transaction can require explicit recovery as described below; bootstrap never
deletes operation locks to retry automatically.

If an interrupted first install prevents normal startup, clone a separate
recovery checkout and use its `examples/manage.lua` with `recover`, then
`recover --apply`. The manifest only needs the same `root` and `lockfile` and
`specs = {}`; recovery validates the recorded transaction independently of the
current declarations. Retry the normal bootstrap after recovery completes.

After installation, startup loads `root/plugin-tools.nvim/bootstrap.lua` directly.
Missing managed packages are automatically installed unless `auto_install` is
false. With all packages present, startup does not run Git or read the lockfile.
For manual additions, set `auto_install = false` and `strict = false`, run
`:PluginTools install`, then restart. Use `:PluginTools plan plugin-tools.nvim`
and `:PluginTools apply` to review and apply a self update; the ordinary update,
restore and freeze commands also support this package. The running session
retains the previous Lua modules
until restart, including modules that had not been loaded before the update.

To use a mirror, change the seed clone URL in the README loader and pass the
matching `self.source`. `self.version` selects the managed branch/tag for updates
and unlocked installs:

```lua
return dofile(path .. "/bootstrap.lua").setup({
  self = { source = "https://example.org/plugin-tools.nvim.git", version = "main" },
  specs = {},
})
```

The seed must contain this bootstrap entry point, even when the lockfile pins a
different revision for installation. Installed revisions must also support this
entry point for subsequent startup. For a private mirror, configure normal Git
authentication before installation.

When migrating a manual installation, remove its old runtimepath/package loading
entry and use the README loader. Bootstrap installs a separate owned copy under
`root`; it does not adopt or delete the manual checkout. Remove an old native
`pack/*/start/` copy from package discovery to keep one runtime owner. Local
development through ordinary `setup()` with `dir` remains available and is
excluded from remote updates.

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

`mount = "on-demand"` keeps a package off runtimepath until `mount(id)`,
`activate(id)`, `use(id)` or a declared `ft` matches. It defaults to not starting;
`start = true` explicitly overrides that default. Same-checkout children share the
package policy and runtime directory, but retain independent initialization.
Children with `path` mount their component plus the package root when activated.
Existing declarations default to `mount = "startup"`.

```lua
{ id = "tex-tools.nvim", source = "Jacky-Lzx/tex-tools.nvim", main = "tex-tools",
  mount = "on-demand", ft = { "tex", "plaintex" }, opts = {} }
```

`ft` contains literal filetypes and initializes once, including buffers that exist
before manager setup. Repeated declarations combine filetypes in declaration order.
It defaults `start` to false and rejects an explicit `start = true`. The plugin's
setup must attach existing matching buffers as well as future buffers; the manager
does not replay FileType or ftplugin scripts. Keep filetype detection rules and
settings required by native ftplugins in the host's early configuration.

Late mounting sources only that runtime root's `plugin/**/*.vim`, then Lua files,
then `after/plugin/` Vim and Lua files, before configuration. It honors
`loadplugins` and uses temporary exact-file SourceCmd guards before VimEnter to
prevent duplicate native startup sourcing. Source events retain their normal
behavior; explicit script timings are measured by the manager, including when
source events are suppressed inside a non-nested FileType callback.
Runtime source errors are retained and are not silently retried. A mount exposes
runtime files and runs native plugin scripts, but does not call setup. It does not
source ftdetect/ftplugin files or replay past events. Plugins depending on those
startup phases should retain startup mounting until explicitly adapted.

With startup mounting, `start = false` controls **manager configuration only**.
It does not prevent native
`plugin/`, `ftdetect/`, `ftplugin/`, or other runtime scripts from executing. A
backend with expensive native startup scripts must first move that work into its
own API. This manager does not rewrite third-party plugin lifecycles.

Call `setup()` during `init.lua`. Native Neovim loads `plugin/` and `after/plugin/`
scripts for startup-mounted roots in its usual phases. The manager sources native
plugin scripts only for on-demand roots, as described above.
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
backups retained until the lockfile is atomically replaced. JSON is written with
two-space indentation, sorted object keys, and a final newline for stable Git
diffs. Caught failures roll back published checkouts. Help tags are generated when
a `doc/` directory exists. Other build outputs must be gitignored; a dirty build
is rejected.

Tracked/untracked changes block replacement and cleanup. A checkout moved away
from its locked commit blocks update; explicitly freeze or restore it first.
Cleanup also rejects a checkout that differs from its recorded commit, preserving
local commits when a plugin is removed from the manifest.
Existing paths need matching manager ownership metadata under `.git/` before
replacement. New paths are checked again before publication. Clean ignores
unknown directories and never follows a package-directory symlink. Shared
packages remain selected while any enabled declaration still owns them.

An exclusive `root/.operation-lock` prevents concurrent operations on the same
root, including across processes. Its atomically replaced `journal.json` records
staging ownership, active child PIDs, publication intents before renames, backups,
and the old/target lockfile. A process crash leaves those records for explicit
recovery. `:PluginTools recover` previews actions; `--apply` rolls back unfinished
publication or keeps an already committed version and removes backups. A target
lockfile proves commit completion even if termination preceded the final journal
marker. Caught rollback/cleanup failures retain their journal and backups.

Recovery checks all paths and checkout states before changing any package. It
refuses unfinished live owners, recorded live Git/build processes, dirty or moved
checkouts, changed lockfiles, mismatched ownership, symlinks and unsafe journal
paths. Unknown directories are preserved. Resolve the reported condition and
preview again. Legacy locks without a journal require manual inspection.
Recovery takes a separate claim under the operation lock. If recovery itself is
killed, inspect `recovery/owner.json`; after confirming that process has stopped,
remove only the stale `recovery/` claim and preview again. Do not delete the
transaction journal or backups. Recovery handles process termination; storage
failure or power loss can still require manual inspection. Use one root/lockfile
pair per configuration and do not externally edit checkouts during an operation.

## Performance and verification

The entry module is small. Git and JSON lockfile handling load for package
operations, including automatic installation when a managed package is absent.
Command rendering loads only when requested. Startup with all packages present
resolves declarations, checks directories, then assigns `runtimepath` once.
It does not inspect Git status, read the lockfile, index Lua modules, check
updates, or create timers. Module availability uses
Neovim's native runtime lookup. Ready activation is a constant-time state check.
Lightweight profiling is enabled by default (`profile = false` disables it).
Open `:PluginTools profile`, or press `P` in the panel. `t` switches between
slowest startup first and alphabetical order; filtering, selection, details and
package actions work in both plugin views. Wide status panels also show STARTUP.

The plugin list shows `children` as a tree, including independently installed
child packages. Filtering keeps matching nodes and their ancestors visible.
Shared children appear once; details list every declared parent. The profile
stays flat for time/name sorting and annotates children with `↳ parent` rows.
Ordinary dependencies do not create tree nesting. Enter still toggles details.

The profile separates declaration resolution, runtimepath mounting, plugin
initialization, native sourced scripts, and other startup work. Its total adds
resolution time to the interval from `start()` through the beginning of
`VimEnter`; it excludes earlier configuration/spec construction and any idle gap
between `new()` and `start()`. It is not whole-process Neovim startup time.
When startup installs missing packages, mounting and manager elapsed timings
include the installation wait.
Setup after `VimEnter` measures only the manager's own startup, explicitly labeled.

Plugin STARTUP includes exclusive initialization and attributed source time.
INIT excludes nested managed activations and timed source calls; details retain
the inclusive activation duration. SCRIPTS records emitted `SourcePre`/`SourcePost`
pairs, matching the most specific declared runtime root (including symlink
aliases); shared roots are attributed once to their package. This includes native
`plugin/` and `after/plugin/` scripts without replaying them. Script lists appear
in plugin details. Source events suppressed by non-nested autocommands (including
some filetype scripts) and work outside these spans fall under Other startup
work. Profiling itself contributes to measured wall time. There are no `require()` or autocommand wrappers.

Source observers remove themselves at `VimEnter` or startup failure. Startup
measurements then remain frozen; later managed activation appears under LATER.
Unmanaged plugin-internal first-use work is not automatically measured. Failed
initialization retains its elapsed time; interrupted source samples are omitted
and reported. `manager:profile()` returns copied `{timings, plugins}` data;
`manager.timings.resolve_ms` and `start_ms` retain their existing meanings.

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
