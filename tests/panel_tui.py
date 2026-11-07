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
    cancel_ready = root / "cancel-ready"
    quote = lambda value: json.dumps(str(value))
    init.write_text(f"""
vim.opt.rtp:prepend({quote(repo)})
local H = dofile({quote(repo / 'tests/helpers.lua')})
local source = H.repo('panel')
local original=vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(original,0,-1,false,{{'original unsaved text'}})
local m = require('plugin_tools').setup({{strict=false, root=H.root..'/packages', lockfile=H.root..'/lock.json', specs={{{{
 id='panel',source=source,build={{'sh','-c','sleep 0.2; printf PTY_BUILD'}}
}},{{id='optional-template', optional=true, origin='test.optional'}}}}}})
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
  _G.log_checked=true;press_stage('profile')
 elseif _G.log_checked and view.mode=='profile' and not _G.profile_checked then
  assert(m.timings.complete and m.timings.boundary=='VimEnter')
  assert(text:find('Startup stages',1,true))
  _G.profile_checked=true;press_stage('sort')
 elseif _G.profile_checked and view.sort=='name' and not _G.sort_checked then
  _G.sort_checked=true;press_stage('help')
 elseif _G.sort_checked and view.mode=='help' and not _G.help_checked then
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
 elseif _G.wide_checked and view.mode=='profile' and not _G.status_requested then
  _G.status_requested=true;press_stage('status')
 elseif _G.status_requested and view.mode=='status' and not _G.preview_requested then
  _G.preview_requested=true
  H.write(source..'/next','next');H.commit(source,'PTY update summary')
  press_stage('preview')
 elseif _G.preview_requested and m.last_operation.action=='plan' and m.last_operation.done and text:find('forward',1,true) and not _G.preview_checked then
  assert(text:find('PTY update summary',1,true),'commit summary missing')
  _G.preview_checked=true;press_stage('inactive')
 elseif _G.preview_checked and view.include_inactive and view.by_id['optional-template'] and not _G.cancel_started then
  _G.cancel_started=true
  m.graph.packages.panel.build={{'sh','-c','printf ready > "$1"; sleep 30','build',{quote(cancel_ready)}}}
  press_stage('update')
 elseif _G.cancel_started and vim.uv.fs_stat({quote(cancel_ready)}) and not _G.cancel_requested then
  _G.cancel_requested=true;press_stage('cancel')
 elseif _G.cancel_requested and m.last_operation.done and m.last_operation.cancelled and text:find('Operation cancelled',1,true) then
  assert(not m.operation and m.last_operation.report.status=='cancelled')
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
    actions = {"install": b" i", "details": b"\r", "log": b"l", "profile": b"P", "sort": b"t", "help": b"?",
               "narrow": None, "wide": None, "return": b"?", "status": b"P", "preview": b"p", "inactive": b"I", "update": b"u", "cancel": b"x", "close": b"q"}
    handled = set()
    output = bytearray()
    try:
        deadline = time.monotonic() + 20
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
        assert b"optional-template" in output and b"Operation cancelled" in output, output.decode(errors="replace")[-5000:]
        print("PASS panel PTY: select, progress, details, logs, startup profile, sort, help, SIGWINCH resize, update summaries, inactive declarations, cancellation, close and unsaved source")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
