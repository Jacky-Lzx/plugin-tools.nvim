#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_home=$(mktemp -d)
trap 'rm -rf "$test_home"' EXIT HUP INT TERM
export XDG_DATA_HOME="$test_home/data"
export XDG_STATE_HOME="$test_home/state"
export XDG_CACHE_HOME="$test_home/cache"
export NVIM_LOG_FILE="$test_home/nvim.log"
for suite in json graph optional provenance runtime deferred operations progress plan recovery panel entrypoints setup_failures options; do
  nvim --headless -u NONE -i NONE --noplugin -l "tests/$suite.lua"
done
# Run before VimEnter so the startup collector observes the real lifecycle.
nvim --headless -u NONE -i NONE --noplugin \
  --cmd 'lua local ok, err = pcall(dofile, "tests/profile.lua"); if not ok then print(err); vim.cmd("cquit 1") end' +qa!
python3 tests/startup.py
python3 tests/optional_startup.py
python3 tests/deferred_startup.py
python3 tests/panel_tui.py
stylua --check lua tests examples
