"""Exercise the actual status panel with terminal input and an asynchronous build."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
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
local original=vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(original,0,-1,false,{{'original unsaved text'}})
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
 elseif _G.ready and text:find('Referenced by',1,true) and not _G.details then
  _G.details=true
  press_stage('log')
 elseif _G.details and text:find('Operation log',1,true) and text:find('PTY_BUILD',1,true) and not _G.log_checked then
  _G.log_checked=true;press_stage('help')
 elseif _G.log_checked and view.mode=='help' and not _G.help_checked then
  _G.help_checked=true;press_stage('narrow')
 elseif _G.help_checked and vim.o.columns==62 and not _G.narrow_checked then
  assert(vim.api.nvim_win_get_width(view.win)<=58)
  assert(view.selected.panel,'selection was lost during resize')
  for _,line in ipairs(vim.api.nvim_buf_get_lines(view.buf,0,-1,false)) do
   assert(vim.fn.strdisplaywidth(line)<=vim.api.nvim_win_get_width(view.win)-2,'narrow panel overflow')
  end
  _G.narrow_checked=true;press_stage('wide')
 elseif _G.narrow_checked and vim.o.columns==120 and not _G.wide_checked then
  _G.wide_checked=true;press_stage('return')
 elseif _G.wide_checked and view.mode=='log' then
  timer:stop();timer:close()
  press_stage('close')
  vim.defer_fn(function()
   assert(not vim.api.nvim_buf_is_valid(view.buf),'panel did not close')
   assert(vim.api.nvim_get_current_buf()==original and vim.bo.modified,'source buffer changed')
   assert(vim.api.nvim_buf_get_lines(original,0,1,false)[1]=='original unsaved text')
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
    actions = {"install": b" i", "details": b"\r", "log": b"l", "help": b"?",
               "narrow": None, "wide": None, "return": b"?", "close": b"q"}
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
                if name in ("narrow", "wide"):
                    rows, columns = (24, 62) if name == "narrow" else (35, 120)
                    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
                    os.kill(process.pid, signal.SIGWINCH)
                else:
                    os.write(master, actions[name])
        process.wait(timeout=2)
        assert process.returncode == 0 and handled == set(actions), output.decode(errors="replace")[-5000:]
        print("PASS panel PTY: select, progress, details, logs, help, SIGWINCH resize, close and unsaved source")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
