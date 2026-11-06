"""Verify optional project selection before native runtime loading in real PTYs."""
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time

REPO = Path(__file__).resolve().parents[1]


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


with tempfile.TemporaryDirectory(prefix="plugin-tools-optional-") as temporary:
    root = Path(temporary)
    package = root / "optional, 中文"
    write(package / "plugin" / "optional.lua", "_G.optional_native = true")
    write(package / "after" / "plugin" / "optional.lua", "_G.optional_after = true")
    write(package / "ftdetect" / "optional.lua", """
_G.optional_detect = true
vim.filetype.add({extension = {ptoptional = 'ptoptional'}})
""")
    write(package / "ftplugin" / "ptoptional.lua", "vim.b.optional_ftplugin = true")
    write(package / "lua" / "optional_backend.lua", """
return {setup = function(opts) _G.optional_answer = opts.answer end}
""")
    write(root / "sample.ptoptional", "project selection")
    quote = lambda value: json.dumps(str(value), ensure_ascii=False)
    for enabled in (False, True):
        result = root / f"result-{enabled}.json"
        project = root / ".nvim-plugins.lua"
        write(project, "return {{id='notes', opts={answer=42}}}" if enabled else "return {}")
        init = root / "init.lua"
        write(init, f"""
vim.opt.runtimepath:prepend({quote(REPO)})
local specs = {{{{
  id = 'notes', dir = {quote(package)}, optional = true,
  main = 'optional_backend', opts = {{answer=1}},
}}}}
vim.list_extend(specs, dofile({quote(project)}))
local manager = require('plugin_tools').setup({{specs=specs}})
vim.cmd('filetype plugin on')
vim.api.nvim_create_autocmd('VimEnter', {{once=true, callback=function()
  vim.schedule(function()
    vim.fn.writefile({{vim.json.encode({{
      selected = manager:has('notes'),
      mounted = vim.list_contains(require('plugin_tools.util').runtime_paths(), {quote(package)}),
      native = _G.optional_native == true, after = _G.optional_after == true,
      detect = _G.optional_detect == true, ftplugin = vim.b.optional_ftplugin == true,
      module = package.loaded.optional_backend ~= nil,
      answer = _G.optional_answer or 0, ft = vim.bo.filetype, errors = vim.v.errmsg,
    }})}}, {quote(result)})
    vim.cmd('qa!')
  end)
end}})
""")
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        env = dict(os.environ, TERM="xterm-256color", NVIM_LOG_FILE=str(root / "nvim.log"))
        for name in ("DATA", "STATE", "CACHE", "CONFIG"):
            env[f"XDG_{name}_HOME"] = str(root / name.lower())
        process = subprocess.Popen(
            ["nvim", "-n", "-i", "NONE", "-u", str(init), str(root / "sample.ptoptional")],
            stdin=slave, stdout=slave, stderr=slave, env=env,
        )
        os.close(slave)
        output = bytearray()
        try:
            deadline = time.monotonic() + 12
            while process.poll() is None and time.monotonic() < deadline:
                if select.select([master], [], [], 0.05)[0]:
                    try:
                        output.extend(os.read(master, 65536))
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                        break
            process.wait(timeout=3)
            assert process.returncode == 0 and result.exists(), output.decode(errors="replace")[-3000:]
            actual = json.loads(result.read_text())
            expected = dict(selected=enabled, mounted=enabled, native=enabled, after=enabled,
                            detect=enabled, ftplugin=enabled, module=enabled,
                            answer=42 if enabled else 0, ft="ptoptional" if enabled else "", errors="")
            assert actual == expected, (actual, expected)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
    print("PASS real PTY: optional projects control runtime, native/after scripts, filetypes, modules and merged setup")
