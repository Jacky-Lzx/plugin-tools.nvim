---@meta

---@alias plugin_tools.Action 'install'|'update'|'restore'|'freeze'|'clean'|'plan'|'recover'
---@alias plugin_tools.Mount 'startup'|'on-demand'
---@alias plugin_tools.Phase 'registered'|'missing'|'mounted'|'initializing'|'ready'|'failed'|'disabled'|'unselected'

---@class plugin_tools.DevOptions
---@field path string Parent directory containing local checkouts named by plugin id.
---@field fallback? boolean Use the managed source when a dev checkout is absent (default true).

---@class plugin_tools.SelfOptions
---@field source? string Manager repository; defaults to Jacky-Lzx/plugin-tools.nvim.
---@field version? string Branch, tag or commit for unlocked installation and updates.

---@class plugin_tools.Options
---@field specs? plugin_tools.Spec[] Plugin declarations (default {}).
---@field root? string Managed checkout directory (default stdpath('data') .. '/plugin-tools').
---@field lockfile? string Lockfile path (default stdpath('config') .. '/plugin-tools-lock.json').
---@field auto_install? boolean Install absent managed packages before startup activation (default true).
---@field strict? boolean Fail startup on remaining missing directories (default true).
---@field commands? boolean Register :PluginTools when using setup() (default true).
---@field profile? boolean Collect startup and activation timings (default true).
---@field concurrency? integer Maximum simultaneous staging workers (default 4).
---@field git_timeout? number Timeout per Git/build process in milliseconds (default 120000).
---@field url_format? string Format for owner/repo sources (default https://github.com/%s.git).
---@field dev? plugin_tools.DevOptions Local checkout policy for specs with dev = true.

---Options accepted by the standalone bootstrap.lua; self is consumed before setup().
---@class plugin_tools.BootstrapOptions: plugin_tools.Options
---@field self? plugin_tools.SelfOptions Managed source and revision of plugin-tools.nvim itself.

---@class plugin_tools.Dependency
---@field id string Declared plugin id; dependencies never create declarations or impose setup order.
---@field optional? boolean Allow the target to be absent (default false).

---Functions in this context use dot calls, e.g. ctx.use('renderer').
---@class plugin_tools.Context
---@field id string Current plugin id.
---@field dir string Resolved runtime directory of this plugin/component.
---@field opts table Merged options, copied lazily once for this activation.
---@field has fun(id: string): boolean Inspect a declared dependency without activating it.
---@field mount fun(id: string): plugin_tools.Manager Mount a declared dependency without configuring it.
---@field activate fun(id: string): plugin_tools.Manager Configure a declared dependency once.
---@field use fun(id: string): any Activate a declared dependency and return its main module.

---@class plugin_tools.BuildContext
---@field id string Package id.
---@field dir string Staged checkout; builds must use this directory, not the installed tree.
---@field cancelled fun(): boolean Whether cooperative cancellation was requested.

---@class plugin_tools.Spec
---@field id string Stable plugin/component id; also names managed package directories.
---@field origin? string Declaration label shown in diagnostics and merge history.
---@field source? string owner/repo, repository URL or local Git source; mutually exclusive with dir.
---@field dir? string External checkout; never installed, updated or removed by the manager.
---@field dev? boolean Prefer dev.path/id for this package (default false).
---@field version? string Package branch, tag or commit; install/restore honor locked revisions.
---@field path? string Relative runtime directory for a component within its parent's checkout.
---@field enabled? boolean|fun(): boolean Disable this declaration and its subtree when false.
---@field optional? boolean Contribute only when a non-optional declaration selects this id.
---@field start? boolean Configure at startup (default true for roots without ft or on-demand mount).
---@field mount? plugin_tools.Mount Runtime mounting policy (default 'startup').
---@field main? string Lua module; its setup(opts) is called unless config overrides it.
---@field opts? table Plugin-specific options; dictionaries merge, lists and empty tables replace.
---@field config? false|fun(ctx: plugin_tools.Context) Custom initialization, or false to suppress setup.
---@field build? string[]|fun(ctx: plugin_tools.BuildContext) Staged build argv or Lua callback.
---@field children? plugin_tools.Spec[] Nested components or independent packages declaring source/dir.
---@field dependencies? (string|plugin_tools.Dependency)[] Availability references, without setup ordering.
---@field after? string[] Explicit initialization prerequisites.
---@field ft? string[] Literal filetypes that trigger activation; requires start = false.

---@class plugin_tools.OperationOptions
---@field ids? string[] Restrict managed owners via plugin/component ids; unsupported for clean/recover.
---@field concurrency? integer Override staging concurrency for this operation.
---@field timeout? number Override per-process timeout in milliseconds.
---@field rebuild? boolean Rebuild even at an unchanged revision; fixed when applying a plan.
---@field plan? plugin_tools.OperationReport Latest successful plan from this manager; update only, without ids/rebuild.
---@field dry_run? boolean clean/recover preview by default; false applies changes.
---@field on_progress? fun(event: plugin_tools.ProgressEvent) Receives isolated progress events.
---@field on_complete? fun(result: plugin_tools.OperationReport?, err: string?) Called once on completion.

---@class plugin_tools.Failure
---@field id? string
---@field phase string
---@field message string

---@class plugin_tools.Changes
---@field kind 'install'|'unchanged'|'forward'|'rewind'|'diverged'
---@field ahead integer
---@field behind integer
---@field files_changed integer
---@field insertions integer
---@field deletions integer
---@field binary_files integer
---@field commits {commit: string, subject: string}[] At most 20 entries.
---@field commits_truncated? boolean
---@field files {path: string, added?: integer, removed?: integer, binary: boolean}[] At most 50 entries.
---@field files_truncated? boolean

---@class plugin_tools.PackageProgress
---@field id string
---@field dir string
---@field source? string
---@field phase string
---@field components? string[]
---@field before_commit? string
---@field after_commit? string
---@field unchanged? boolean
---@field build boolean
---@field build_command? string[]
---@field changes? plugin_tools.Changes
---@field error? plugin_tools.Failure

---@class plugin_tools.ProgressEvent
---@field action plugin_tools.Action
---@field phase string
---@field id? string
---@field elapsed_ms number
---@field total integer
---@field completed integer
---@field before_commit? string
---@field after_commit? string
---@field unchanged? boolean
---@field build? boolean
---@field changes? plugin_tools.Changes
---@field command? string[]
---@field exit_code? integer
---@field stdout? string
---@field stderr? string
---@field error? plugin_tools.Failure

---@class plugin_tools.OperationSnapshot
---@field action plugin_tools.Action
---@field phase string
---@field done boolean
---@field cancellable boolean
---@field cancel_requested boolean
---@field cancelled boolean
---@field recovery_required boolean
---@field total integer
---@field completed integer
---@field details plugin_tools.PackageProgress[]
---@field failure? plugin_tools.Failure
---@field elapsed_ms number

---@class plugin_tools.OperationReport: plugin_tools.OperationSnapshot
---@field status 'success'|'failed'|'cancelled'
---@field error? plugin_tools.Failure
---@field packages? string[]
---@field lockfile? string
---@field dry_run? boolean
---@field restart_required? boolean
---@field cleanup_errors? string[]
---@field steps? {action: string, dir: string}[] Recovery steps.

---@class plugin_tools.Trigger
---@field kind string
---@field parent? string
---@field action? string
---@field filetype? string
---@field chain? string[]

---@class plugin_tools.State
---@field phase plugin_tools.Phase
---@field count? integer Successful initialization count; absent for inactive declarations.
---@field mounted? boolean
---@field error? string
---@field reason? string
---@field mount_reason? string
---@field trigger? plugin_tools.Trigger
---@field duration_ms? number Inclusive initialization time.
---@field self_ms? number Exclusive initialization time.
---@field startup_ms? number Startup initialization and native scripts, excluding nested managed calls.
---@field startup_config_ms? number
---@field scripts_ms? number
---@field deferred_ms? number
---@field mount_ms? number
---@field activation? string
---@field scripts? {file: string, self_ms: number}[]

---@class plugin_tools.StatusOptions
---@field include_inactive? boolean Include disabled and unselected declarations (default false).

---@class plugin_tools.Status
---@field id string
---@field package? string
---@field dir? string
---@field managed? boolean
---@field parents? string[]
---@field root? boolean
---@field state plugin_tools.State
---@field selected? boolean False for inactive declarations.
---@field declarations? table[]

---@class plugin_tools.Explanation: plugin_tools.Status
---@field source? string
---@field referenced_by? string[]
---@field dependencies? table<string, boolean> True means optional.
---@field after? string[]
---@field start? boolean
---@field mount? plugin_tools.Mount|'none'
---@field ft? string[]
---@field opts? table
---@field option_history? table[]

---@class plugin_tools.Timings
---@field enabled? boolean
---@field complete? boolean
---@field scope? 'startup'|'manager'
---@field boundary? string
---@field resolve_ms number
---@field start_ms? number
---@field mount_ms? number
---@field config_ms? number
---@field native_ms? number
---@field other_ms? number
---@field total_ms? number
---@field incomplete_sources? integer

---@class plugin_tools.Profile
---@field timings plugin_tools.Timings
---@field plugins plugin_tools.Status[]

---@class plugin_tools.OpenOptions
---@field mode? 'status'|'profile'|'log'|'help' Initial panel view (default 'status').
---@field id? string Expand and filter to this plugin.

---@class plugin_tools.Diagnostic
---@field level 'error'|'warn'|'info'
---@field message string
---@field advice string[]
