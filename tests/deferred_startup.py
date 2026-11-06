"""Exercise demand mounting before native startup, on FileType, and after VimEnter."""
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

repo = Path(__file__).resolve().parents[1]
for case in ("early", "filetype", "late"):
    with tempfile.TemporaryDirectory(prefix="plugin-tools-demand-") as temporary:
        root = Path(temporary)
        package = root / "package, 中文"
        for directory in ("plugin", "after/plugin", "ftplugin"):
            (package / directory).mkdir(parents=True, exist_ok=True)
        (package / "plugin/entry.lua").write_text("vim.g.demand_native = (vim.g.demand_native or 0) + 1; vim.api.nvim_exec_autocmds('User', {pattern='DemandNative'})")
        (package / "after/plugin/entry.lua").write_text("vim.g.demand_after = (vim.g.demand_after or 0) + 1")
        (package / "ftplugin/demandft.lua").write_text("vim.b.demand_ftplugin = true")
        (root / "sample.demandft").write_text("first buffer")
        cold, warm = root / "cold.json", root / "warm.json"
        quote = lambda p: json.dumps(str(p), ensure_ascii=False)
        init = root / "init.lua"
        init.write_text(f"""
vim.opt.runtimepath:prepend({quote(repo)})
vim.filetype.add({{extension = {{demandft = 'demandft'}}}})
vim.cmd('filetype plugin on')
local events = 0
vim.api.nvim_create_autocmd('User', {{pattern='DemandNative', callback=function() events=events+1 end}})
local function snapshot(path, manager)
  vim.cmd.redraw()
  vim.fn.writefile({{vim.json.encode({{native=vim.g.demand_native or 0, after=vim.g.demand_after or 0,
    events=events, setup=vim.g.demand_setup or 0, attached=vim.b.demand_attached == true,
    profile=manager:profile(), errors=vim.v.errmsg}})}}, path)
end
local manager = require('plugin_tools').setup({{specs={{{{
  id='demand', dir={quote(package)}, mount='on-demand', ft={{{"'demandft'" if case == "filetype" else ""}}},
  config=function()
    assert(vim.g.demand_native == 1 and vim.g.demand_after == 1)
    vim.g.demand_setup = (vim.g.demand_setup or 0) + 1
    vim.b.demand_attached = true
  end,
}}}}}})
if {quote(case)} == 'early' then manager:activate('demand') end
vim.api.nvim_create_user_command('DemandUse', function()
  manager:activate('demand'); manager:activate('demand')
  snapshot({quote(warm)}, manager)
end, {{}})
vim.api.nvim_create_autocmd('VimEnter', {{once=true, callback=function()
  vim.schedule(function() snapshot({quote(cold)}, manager) end)
end}})
""")
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        env = dict(os.environ, TERM="xterm-256color", NVIM_LOG_FILE=str(root / "nvim.log"))
        for name in ("DATA", "STATE", "CACHE", "CONFIG"):
            env[f"XDG_{name}_HOME"] = str(root / name.lower())
        process = subprocess.Popen(["nvim", "-u", str(init), "-i", "NONE", str(root / "sample.demandft")],
                                   env=env, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        output = bytearray()
        def drain():
            if select.select([master], [], [], .03)[0]:
                try: output.extend(os.read(master, 65536))
                except OSError: pass
        def wait_file(path):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                drain()
                if path.exists(): return json.loads(path.read_text())
                if process.poll() is not None: break
            raise AssertionError(output.decode(errors="replace")[-4000:])
        try:
            before = wait_file(cold)
            assert before['errors'] == '', before
            assert before['native'] == (0 if case == 'late' else 1), before
            os.write(master, b':DemandUse\r')
            after = wait_file(warm)
            assert all(after[k] == 1 for k in ('native','after','events','setup')), after
            assert after['attached'] and after['errors'] == '', after
            assert after['profile']['timings'] == before['profile']['timings'], after
            state = after['profile']['plugins'][0]['state']
            assert state['count'] == 1 and state['mounted'], state
            if case == 'late': assert state['deferred_scripts_ms'] > 0, state
            os.write(master, b':qa!\r')
            deadline = time.monotonic()+5
            while process.poll() is None and time.monotonic()<deadline: drain()
            assert process.poll() == 0, output.decode(errors='replace')[-4000:]
            print('PASS demand PTY:', case, 'native scripts once, events, first buffer, frozen startup timings')
        finally:
            if process.poll() is None: process.kill()
            process.wait()
            os.close(master)
