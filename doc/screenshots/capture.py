"""Capture an actual embedded Neovim UI grid as PNG, without a desktop session.

Requires Python 3.9+, Neovim, Git and rsvg-convert. No Python packages, desktop
session, network or user configuration are needed. All panels and measurements
come from the current plugin code operating on local Git fixture packages.
"""
import argparse
import html
import json
import os
from pathlib import Path
import select
import shutil
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
COLS, ROWS = 120, 40
CELL_WIDTH, CELL_HEIGHT = 12, 24


def pack(value):
    if value is None:
        return b"\xc0"
    if isinstance(value, bool):
        return b"\xc3" if value else b"\xc2"
    if isinstance(value, int):
        return b"\xd3" + struct.pack(">q", value)
    if isinstance(value, str):
        data = value.encode()
        return b"\xdb" + struct.pack(">I", len(data)) + data
    if isinstance(value, (list, tuple)):
        return b"\xdd" + struct.pack(">I", len(value)) + b"".join(map(pack, value))
    if isinstance(value, dict):
        return b"\xdf" + struct.pack(">I", len(value)) + b"".join(pack(k) + pack(v) for k, v in value.items())
    raise TypeError(value)


def unpack(data, pos=0):
    def take(size):
        nonlocal pos
        end = pos + size
        if end > len(data):
            raise IndexError
        result = data[pos:end]
        pos = end
        return result

    tag = take(1)[0]
    if tag < 128:
        return tag, pos
    if tag >= 224:
        return tag - 256, pos
    if tag in (192, 194, 195):
        return {192: None, 194: False, 195: True}[tag], pos
    if tag in (202, 203):
        return struct.unpack(">f" if tag == 202 else ">d", take(4 if tag == 202 else 8))[0], pos
    if tag in (204, 205, 206, 207, 208, 209, 210, 211):
        fmt = {204: "B", 205: "H", 206: "I", 207: "Q", 208: "b", 209: "h", 210: "i", 211: "q"}[tag]
        return struct.unpack(">" + fmt, take(struct.calcsize(fmt)))[0], pos
    if 160 <= tag <= 191 or tag in (196, 197, 198, 217, 218, 219):
        size = tag - 160 if tag <= 191 else int.from_bytes(take({196: 1, 197: 2, 198: 4, 217: 1, 218: 2, 219: 4}[tag]), "big")
        raw = take(size)
        return (raw if tag in (196, 197, 198) else raw.decode()), pos
    if 144 <= tag <= 159 or tag in (220, 221):
        size = tag - 144 if tag <= 159 else int.from_bytes(take(2 if tag == 220 else 4), "big")
        result = []
        for _ in range(size):
            value, pos = unpack(data, pos)
            result.append(value)
        return result, pos
    if 128 <= tag <= 143 or tag in (222, 223):
        size = tag - 128 if tag <= 143 else int.from_bytes(take(2 if tag == 222 else 4), "big")
        result = {}
        for _ in range(size):
            key, pos = unpack(data, pos)
            value, pos = unpack(data, pos)
            result[key] = value
        return result, pos
    if tag in (199, 200, 201, 212, 213, 214, 215, 216):
        size = 2 ** (tag - 212) if tag >= 212 else int.from_bytes(take({199: 1, 200: 2, 201: 4}[tag]), "big")
        take(1)
        return take(size), pos
    raise ValueError(tag)


class UI:
    def __init__(self, temporary, nvim, env, init, output, font):
        self.output, self.font = output, font
        self.cache = Path(temporary) / "render-cache"
        self.stderr = open(Path(temporary) / "stderr.log", "w+b")
        self.child = subprocess.Popen([nvim, "--embed", "-u", str(init), "-i", "NONE", "-n"],
                                      cwd=temporary, env=env, stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=self.stderr)
        self.buffer = b""
        self.seq = 0
        self.grid = [[[" ", 0] for _ in range(COLS)] for _ in range(ROWS)]
        self.attrs = {0: {}}
        self.colors = [0xc0caf5, 0x161923, 0xc0caf5]
        self.cursor = (0, 0)

    def event(self, message):
        if message[:2] != [2, "redraw"]:
            return
        for event in message[2]:
            name = event[0]
            for args in event[1:]:
                if name == "default_colors_set":
                    self.colors = args[:3]
                elif name == "hl_attr_define":
                    self.attrs[args[0]] = args[1]
                elif name == "grid_resize":
                    assert args == [1, COLS, ROWS], args
                elif name == "grid_clear":
                    self.grid = [[[" ", 0] for _ in range(COLS)] for _ in range(ROWS)]
                elif name == "grid_line":
                    _, row, col, cells = args[:4]
                    attr = 0
                    for cell in cells:
                        if len(cell) > 1:
                            attr = cell[1]
                        for _ in range(cell[2] if len(cell) > 2 else 1):
                            self.grid[row][col] = [cell[0], attr]
                            col += 1
                elif name == "grid_scroll":
                    _, top, bottom, left, right, rows, cols = args
                    assert cols == 0
                    old = [[cell[:] for cell in row] for row in self.grid]
                    for row in range(top, bottom):
                        for col in range(left, right):
                            self.grid[row][col] = old[row + rows][col] if top <= row + rows < bottom else [" ", 0]
                elif name == "grid_cursor_goto":
                    self.cursor = tuple(args[1:])

    def message(self, deadline):
        while time.monotonic() < deadline:
            try:
                message, used = unpack(self.buffer)
                self.buffer = self.buffer[used:]
                return message
            except IndexError:
                if select.select([self.child.stdout], [], [], max(0, deadline - time.monotonic()))[0]:
                    chunk = os.read(self.child.stdout.fileno(), 1048576)
                    if not chunk:
                        self.stderr.seek(0)
                        raise RuntimeError("Neovim exited:\n" + self.stderr.read().decode(errors="replace"))
                    self.buffer += chunk
        raise TimeoutError("Neovim RPC timed out")

    def rpc(self, method, *args):
        self.seq += 1
        self.child.stdin.write(pack([0, self.seq, method, args]))
        self.child.stdin.flush()
        deadline = time.monotonic() + 20
        while True:
            message = self.message(deadline)
            if message[0] == 1 and message[1] == self.seq:
                if message[2]:
                    raise RuntimeError(message[2])
                return message[3]
            self.event(message)

    def lua(self, code):
        return self.rpc("nvim_exec_lua", code, [])

    def wait(self, code):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if self.lua(code):
                return
            time.sleep(0.05)
        raise TimeoutError(code + "\n" + self.text() + "\n" + str(self.lua("return vim.v.errmsg")))

    def text(self):
        return "\n".join("".join(cell[0] for cell in row) for row in self.grid)

    def capture(self, name, required):
        self.rpc("nvim_command", "redraw!")
        self.rpc("nvim_eval", "1")
        fg, bg, _ = self.colors
        color = lambda n: f"#{n:06x}"
        for text in required:
            assert text in self.text(), f"{name}: missing rendered text {text!r}\n{self.text()}"
        width, height = COLS * CELL_WIDTH, ROWS * CELL_HEIGHT
        svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
               f'<rect width="{width}" height="{height}" fill="{color(bg)}"/>',
               f'<g font-family="{html.escape(self.font, quote=True)}" font-size="20" xml:space="preserve">']
        backgrounds, glyphs = [], []
        for row, cells in enumerate(self.grid):
            for col, (text, attr) in enumerate(cells):
                a = self.attrs.get(attr, {})
                front, back = a.get("foreground", fg), a.get("background", bg)
                if a.get("reverse"):
                    front, back = back, front
                x, y = col * CELL_WIDTH, row * CELL_HEIGHT
                if back != bg:
                    backgrounds.append(f'<rect x="{x}" y="{y}" width="{CELL_WIDTH}" height="{CELL_HEIGHT}" fill="{color(back)}"/>')
                if text.strip():
                    style = (' font-weight="bold"' if a.get("bold") else '') + (' font-style="italic"' if a.get("italic") else '')
                    glyphs.append(f'<text x="{x}" y="{y + 19}" fill="{color(front)}"{style}>{html.escape(text)}</text>')
                if a.get("underline") or a.get("undercurl"):
                    glyphs.append(f'<path d="M{x} {y+21}h{CELL_WIDTH}" stroke="{color(a.get("special", front))}"/>')
        svg.extend(backgrounds)
        svg.extend(glyphs)
        row, col = self.cursor
        svg.append(f'<rect x="{col*CELL_WIDTH}" y="{row*CELL_HEIGHT}" width="2" height="{CELL_HEIGHT}" fill="{color(fg)}"/></g></svg>')
        path = self.output / (name + ".png")
        subprocess.run(["rsvg-convert", "-o", str(path)], input="".join(svg).encode(), check=True,
                       env=dict(os.environ, XDG_CACHE_HOME=str(self.cache)), timeout=20)
        assert path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"), "Invalid PNG"
        print(f"Captured {path}: {COLS}x{ROWS} Neovim UI cells")

    def close(self):
        try:
            if self.child.poll() is None:
                self.child.stdin.write(pack([2, "nvim_command", ["qa!"]]))
                self.child.stdin.flush()
                self.child.communicate(timeout=5)
        except (BrokenPipeError, subprocess.TimeoutExpired):
            pass
        finally:
            if self.child.poll() is None:
                self.child.kill()
                self.child.wait()
            self.child.stdin.close()
            self.child.stdout.close()
            self.stderr.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=OUT, help="PNG output directory")
    parser.add_argument("--font", default="Menlo, DejaVu Sans Mono, monospace", help="SVG font-family list")
    parser.add_argument("--nvim", default=os.environ.get("NVIM_BIN", "nvim"))
    args = parser.parse_args()
    for executable in (args.nvim, "git", "rsvg-convert"):
        if not shutil.which(executable):
            parser.error(f"Required executable not found: {executable}")
    nvim = str(Path(shutil.which(args.nvim)).resolve())
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="plugin-tools-demo-", dir="/tmp") as temporary:
        work = Path(temporary)
        env = dict(os.environ, PLUGIN_TOOLS_CAPTURE_ROOT=temporary, PLUGIN_TOOLS_CAPTURE_REPO=str(ROOT))
        for key in ("NVIM", "NVIM_LISTEN_ADDRESS", "NVIM_APPNAME", "VIMINIT", "EXINIT"):
            env.pop(key, None)
        for name in ("DATA", "CONFIG", "STATE", "CACHE"):
            env[f"XDG_{name}_HOME"] = str(work / name.lower())
        env["NVIM_LOG_FILE"] = str(work / "nvim.log")
        (work / "tmp").mkdir(mode=0o700)
        env.update(TMPDIR=str(work / "tmp"), GIT_CONFIG_GLOBAL=os.devnull,
                   GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0")
        result = subprocess.run([nvim, "--headless", "-u", "NONE", "-i", "NONE", "--noplugin",
                                 "-l", str(OUT / "demo.lua"), "prepare"], cwd=work, env=env,
                                capture_output=True, text=True, timeout=40)
        if result.returncode:
            raise RuntimeError("Fixture preparation failed:\n" + result.stdout + result.stderr)
        init = work / "init.lua"
        init.write_text(
            f'vim.o.runtimepath = vim.fn.escape({json.dumps(str(ROOT), ensure_ascii=False)}, ",\\\\") .. "," .. vim.o.runtimepath\n'
            f'dofile({json.dumps(str(OUT / "demo.lua"), ensure_ascii=False)}).start()\n'
        )
        ui = UI(temporary, nvim, env, init, output, args.font)
        try:
            ui.rpc("nvim_ui_attach", COLS, ROWS, {"rgb": True, "ext_linegrid": True})
            ui.wait("return capture_ready == true and capture_manager.timings.complete")
            assert ui.lua("return vim.v.errmsg") == ""

            def point(plugin):
                ui.lua(f"vim.api.nvim_win_set_cursor(capture_view.win, {{assert(capture_view.by_id[{json.dumps(plugin)}]), 0}})")

            def key(value, condition):
                ui.rpc("nvim_input", value)
                ui.wait("return " + condition)

            point("navigator.nvim")
            key(" ", "capture_view.selected['navigator.nvim'] == true")
            point("matcher.nvim")
            key(" ", "capture_view.selected['matcher.nvim'] == true")
            ui.capture("overview", ["navigator.outline", "matcher.nvim", "2 selected", "registered"])

            key("<CR>", "capture_view.expanded['matcher.nvim'] == true")
            ui.capture("details", ["Dependencies", "Referenced by", "Declared in"])
            key("<CR>", "capture_view.expanded['matcher.nvim'] == false")
            key("P", "capture_view.mode == 'profile'")
            ui.capture("profile", ["Startup stages", "Plugin timings", "LATER"])

            key("P", "capture_view.mode == 'status'")
            point("navigator.nvim")
            key(" ", "capture_view.selected['navigator.nvim'] == nil")
            point("syntax.nvim")
            key(" ", "capture_view.selected['syntax.nvim'] == true")
            key("p", "capture_manager.last_plan ~= nil and capture_manager.operation == nil")
            ui.capture("update-plan", ["Reviewed plan available", "forward", "ahead", "2/2 packages"])
            assert ui.lua("return vim.v.errmsg") == ""
        finally:
            ui.close()


if __name__ == "__main__":
    main()
