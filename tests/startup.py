"""Exercise native startup and first use in a real attached terminal."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time

REPO = Path(__file__).resolve().parents[1]
AUTO_INSTALL = "--auto-install" in sys.argv[1:]


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


with tempfile.TemporaryDirectory(prefix="plugin-tools-startup-") as temporary:
    root = Path(temporary)
    package = root / "package, 中文"
    cold, warm = root / "cold.json", root / "warm.json"
    write(package / "plugin" / "entry.lua", "_G.native_count = (_G.native_count or 0) + 1")
    write(package / "after" / "plugin" / "entry.lua", "_G.after_count = (_G.after_count or 0) + 1")
    write(package / "ftdetect" / "example.lua", "vim.filetype.add({ extension = { ptspec = 'ptspec' } })")
    write(package / "ftplugin" / "ptspec.lua", "vim.b.ptspec_loaded = true")
    write(package / "lua" / "terminal_backend.lua", """
return {
  setup = function(opts) _G.backend_setup = (_G.backend_setup or 0) + 1; _G.answer = opts.answer end,
  render = function() return require('terminal_heavy').render() end,
}
""")
    write(package / "lua" / "terminal_heavy.lua", "return { render = function() return 'rendered' end }")
    write(root / "sample.ptspec", "native filetype test")
    # JSON strings are valid Lua strings for these paths (no non-ASCII escapes).
    quote = lambda value: json.dumps(str(value), ensure_ascii=False)
    if AUTO_INSTALL:
        subprocess.run(["git", "init", "-q", "-b", "main", str(package)], check=True)
        subprocess.run(["git", "-C", str(package), "add", "."], check=True)
        subprocess.run([
            "git", "-C", str(package), "-c", "user.name=Plugin Tools Test",
            "-c", "user.email=plugin-tools@example.invalid", "-c", "commit.gpgsign=false",
            "commit", "-qm", "native startup fixture",
        ], check=True)
    location = f"source = {quote(package)}" if AUTO_INSTALL else f"dir = {quote(package)}"
    init = root / "init.lua"
    write(init, f"""
vim.opt.runtimepath:prepend({quote(REPO)})
local function snapshot(path)
  vim.fn.writefile({{vim.json.encode({{
    native = _G.native_count or 0, after = _G.after_count or 0,
    backend = package.loaded.terminal_backend ~= nil,
    heavy = package.loaded.terminal_heavy ~= nil,
    setup = _G.backend_setup or 0, answer = _G.answer or 0,
    ft = vim.bo.filetype, ftplugin = vim.b.ptspec_loaded == true,
    profile = require('plugin_tools').profile(),
    errors = vim.v.errmsg,
  }})}}, path)
end
local manager = require('plugin_tools').setup({{
root = {quote(root / 'managed, 中文')}, lockfile = {quote(root / 'lock.json')}, specs = {{{{
  id = 'front', {location}, dependencies = {{'backend'}},
  config = function(ctx)
    vim.api.nvim_create_user_command('PluginToolsTestUse', function()
      assert(ctx.use('backend').render() == 'rendered')
      snapshot({quote(warm)})
    end, {{}})
  end,
  children = {{{{ id = 'backend', main = 'terminal_backend', opts = {{answer = 42}} }}}},
}}}} }})
assert((manager.last_operation ~= nil) == {str(AUTO_INSTALL).lower()}, 'Unexpected startup installation state')
if manager.last_operation then
  assert(manager.last_operation.result and not manager.last_operation.result.restart_required)
  assert(manager.states.front.phase == 'ready')
end
vim.cmd('filetype plugin on')
vim.api.nvim_create_autocmd('VimEnter', {{once = true, callback = function()
  vim.schedule(function() snapshot({quote(cold)}) end)
end}})
""")
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
    env = dict(os.environ, TERM="xterm-256color", NVIM_LOG_FILE=str(root / "nvim.log"))
    for name in ("DATA", "STATE", "CACHE", "CONFIG"):
        env[f"XDG_{name}_HOME"] = str(root / name.lower())
    process = subprocess.Popen(
        ["nvim", "-u", str(init), "-i", "NONE", str(root / "sample.ptspec")],
        stdin=slave, stdout=slave, stderr=slave, env=env,
    )
    os.close(slave)
    transcript = bytearray()

    def wait_file(path):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if path.exists():
                return json.loads(path.read_text())
            if process.poll() is not None:
                break
            readable, _, _ = select.select([master], [], [], 0.05)
            if readable:
                transcript.extend(os.read(master, 65536))
        raise AssertionError(f"No snapshot at {path}: {transcript.decode(errors='replace')}")

    try:
        before = wait_file(cold)
        initial_profile = before.pop("profile")
        timing = initial_profile["timings"]
        assert timing["enabled"] and timing["complete"] and timing["boundary"] == "VimEnter", timing
        assert timing["total_ms"] >= timing["manager_ms"] > 0, timing
        states = {item["id"]: item["state"] for item in initial_profile["plugins"]}
        assert states["front"]["startup_config_ms"] > 0
        files = [item["file"] for item in states["front"].get("scripts", [])]
        assert files, initial_profile
        assert any("/plugin/entry.lua" in file and "/after/" not in file for file in files), files
        assert any("/after/plugin/entry.lua" in file for file in files), files
        assert any("/ftdetect/example.lua" in file for file in files), files
        assert "startup_ms" not in states["backend"], states["backend"]
        assert before == dict(native=1, after=1, backend=False, heavy=False, setup=0,
                              answer=0, ft="ptspec", ftplugin=True, errors=""), before
        os.write(master, b":PluginToolsTestUse\r")
        after = wait_file(warm)
        activated_profile = after.pop("profile")
        assert activated_profile["timings"] == timing, activated_profile
        backend = next(item["state"] for item in activated_profile["plugins"] if item["id"] == "backend")
        assert backend["activation"] == "on demand" and backend["deferred_ms"] > 0, backend
        assert "startup_ms" not in backend, backend
        assert after == dict(native=1, after=1, backend=True, heavy=True, setup=1,
                             answer=42, ft="ptspec", ftplugin=True, errors=""), after
        warm.unlink()
        os.write(master, b":PluginToolsTestUse\r")
        repeated = wait_file(warm)
        assert repeated["setup"] == 1
        repeated_backend = next(item["state"] for item in repeated["profile"]["plugins"] if item["id"] == "backend")
        assert repeated_backend == backend, repeated_backend
        os.write(master, b":qa!\r")
        deadline = time.monotonic() + 5
        while process.poll() is None and time.monotonic() < deadline:
            readable, _, _ = select.select([master], [], [], 0.05)
            if readable:
                try:
                    transcript.extend(os.read(master, 65536))
                except OSError:
                    break
        process.wait(timeout=5)
        assert process.returncode == 0
        mode = "automatic installation" if AUTO_INSTALL else "local checkout"
        print(f"PASS real PTY ({mode}): startup profile, native/after scripts, filetypes, frozen totals, cold dependency, first/repeated use")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
