# Screenshots

These images capture the current plugin in a live, embedded Neovim UI:

| Image | Demonstrated behavior |
| --- | --- |
| [overview.png](overview.png) | Package hierarchy, selection, local overrides and activation states. |
| [details.png](details.png) | On-demand activation chain, owning package, dependencies and declaration origin. |
| [profile.png](profile.png) | Startup stages, native script attribution and later activation timings. |
| [update-plan.png](update-plan.png) | A completed review of two updates, including exact revisions and change counts. |

The packages are small offline fixtures, not the plugins from a personal
configuration. Their Git installations, on-demand activation and update plans run
through the real manager. Timings are measured from those fixtures, not benchmark
results for third-party plugins. No manager states, UI layouts or timing values
are manufactured for the images.

## Update all images

Requires Python **3.9+**, Neovim **0.11+**, Git and `rsvg-convert` on PATH, on macOS
or Linux. No Python packages, desktop session, Nerd Font or network are needed.
The checked-in PNGs use Neovim 0.12.6, rsvg-convert 2.63.3 and Menlo on macOS.

From the repository root:

```sh
python3 doc/screenshots/capture.py
```

This replaces the four PNGs beside the script. To inspect a new capture before
replacing the documentation images, use a different output directory:

```sh
python3 doc/screenshots/capture.py --output /tmp/plugin-tools-screenshots
```

Use `--nvim /path/to/nvim` (or `NVIM_BIN`) to select Neovim. On systems without
Menlo, a monospace font such as DejaVu Sans Mono can be selected explicitly:

```sh
python3 doc/screenshots/capture.py --font "DejaVu Sans Mono, monospace"
```

## How capture works

1. Create temporary local Git sources, install them with the current checkout's
   package manager, and commit two source updates for the review scene.
2. Start an isolated Neovim process with its own data, configuration, cache and
   state directories. The fixtures load during normal startup so the profile
   includes real native sourcing through `VimEnter`.
3. Send actual panel key input for selection, details, profiling and update
   preview. Wait for the corresponding rendered states and operation completion.
4. Record Neovim's composed `ext_linegrid` cells and RGB highlight attributes,
   render them to SVG, and convert to **1440 × 960 PNGs** with `rsvg-convert`.

These are UI-grid captures, not desktop-window screenshots. The renderer preserves
the text, colors and positions produced by Neovim; it does not recreate panel
layouts. Fonts, measured timings and temporary path names can vary between runs.
Temporary repositories and processes are cleaned up, and personal Neovim and Git
configuration are not loaded or changed.

- `capture.py`: RPC/grid capture, PNG rendering and scripted panel interactions.
- `demo.lua`: fixture packages, package declarations and preparation.
- `theme.lua`: capture-session colors and cursor appearance, using native
  highlight groups. This does not change the plugin's defaults.

If panel keymaps or labels change, update the interaction and expected-text checks
near the end of `capture.py`. `COLS` and `ROWS` at the top control the captured
terminal size. After regenerating, inspect all four PNGs and run:

```sh
python3 tests/run.py unit --filter docs
python3 tests/run.py format
```
