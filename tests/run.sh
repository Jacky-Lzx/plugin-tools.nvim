#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_home=$(mktemp -d)
trap 'rm -rf "$test_home"' EXIT HUP INT TERM
export XDG_DATA_HOME="$test_home/data"
export XDG_STATE_HOME="$test_home/state"
export XDG_CACHE_HOME="$test_home/cache"
export NVIM_LOG_FILE="$test_home/nvim.log"
for suite in graph runtime operations entrypoints setup_failures options; do
  nvim --headless -u NONE -i NONE --noplugin -l "tests/$suite.lua"
done
python3 tests/startup.py
stylua --check lua tests examples
