"""Exercise the actual status panel with terminal input and an asynchronous build."""
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
with tempfile.TemporaryDirectory(prefix="plugin-tools-panel-") as directory:
    root = Path(directory)
    stage = root / "stage"
    init = root / "init.lua"
    quote = lambda value: json.dumps(str(value))
    init.write_text(f"""
vim.opt.rtp:prepend({quote(repo)})
local H = dofile({quote(repo / 'tests/helpers.lua')})
local source = H.repo('panel')
local m = require('plugin_tools').setup({{strict=false, root=H.root..'/packages', lockfile=H.root..'/lock.json', specs={{{{
 id='panel',source=source,build={{'sh','-c','sleep 0.2; printf PTY_BUILD'}}
}}}}}})
local view
local function press_stage(name) vim.fn.writefile({{name}}, {quote(stage)}) end
vim.api.nvim_create_autocmd('VimEnter', {{once=true,callback=function()
 vim.schedule(function()
  vim.cmd('PluginTools')
  view = m:open()
  for row,id in pairs(view.rows) do if id=='panel' then vim.api.nvim_win_set_cursor(0,{{row,0}}) end end
  press_stage('install')
 end)
end}})
local timer=vim.uv.new_timer()
timer:start(20,20,vim.schedule_wrap(function()
 if not view then return end
 local text=table.concat(vim.api.nvim_buf_get_lines(view.buf,0,-1,false),'\\n')
 if m.last_operation and m.last_operation.done and not _G.ready then
  assert(not m.last_operation.error,m.last_operation.error)
  _G.ready=true
  press_stage('details')
 elseif _G.ready and text:find('referenced_by',1,true) and not _G.details then
  _G.details=true
  press_stage('log')
 elseif _G.details and text:find('Operation log',1,true) and text:find('PTY_BUILD',1,true) then
  timer:stop();timer:close()
  press_stage('close')
  vim.defer_fn(function()
   assert(not vim.api.nvim_buf_is_valid(view.buf),'panel did not close')
   H.finish();vim.cmd('qa!')
  end,150)
 end
end))
""")
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 35, 120, 0, 0))
    env = dict(os.environ, TERM="xterm-256color", NVIM_LOG_FILE=str(root / "nvim.log"))
    for name in ("DATA", "STATE", "CACHE", "CONFIG"):
        env[f"XDG_{name}_HOME"] = str(root / name.lower())
    process = subprocess.Popen(["nvim", "-u", str(init), "-i", "NONE"], cwd=repo,
                               env=env, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    actions = {"install": b" i", "details": b"\r", "log": b"l", "close": b"q"}
    handled = set()
    output = bytearray()
    try:
        deadline = time.monotonic() + 15
        while process.poll() is None and time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.03)
            if ready:
                try:
                    output.extend(os.read(master, 65536))
                except OSError:
                    break
            name = stage.read_text().strip() if stage.exists() else ""
            if name in actions and name not in handled:
                handled.add(name)
                os.write(master, actions[name])
        process.wait(timeout=2)
        assert process.returncode == 0 and handled == set(actions), output.decode(errors="replace")[-5000:]
        print("PASS panel PTY: select, install, live progress, expand, logs and close")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
