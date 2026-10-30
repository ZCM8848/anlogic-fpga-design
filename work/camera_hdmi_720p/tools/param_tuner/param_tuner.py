"""camera_hdmi_720p 串口热调参上位机。

协议：115200 8N1，ASCII 行，命令以 \n 结尾。
  GET / SET <name> <value> / APPLY / DEFAULT / RECAPTURE / VER
"""

import json
import queue
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

import serial
from serial.tools import list_ports


class Param:
    def __init__(self, name, label, lo, hi, group, note=""):
        self.name = name
        self.label = label
        self.lo = lo
        self.hi = hi
        self.group = group
        self.note = note


PARAMS = [
    Param("enable", "启用检测", 0, 1, "相机"),
    Param("exposure", "曝光（半行）", 2, 1991, "相机"),
    Param("gain", "增益", 16, 176, "相机"),

    Param("bg_thr", "背景阈值", 0, 255, "前端"),
    Param("min_run", "最短 run", 0, 32, "前端"),
    Param("bg_capture_delay", "上电采背景延时", 0, 60000, "前端", "仅启动阶段生效"),
    Param("bg_settle_frames", "采背景稳定帧数", 0, 60000, "前端", "仅启动阶段生效"),
    Param("bg_recalc_settle_frames", "重采稳定帧数", 0, 60000, "前端"),

    Param("min_area", "最小面积", 0, 32767, "筛选"),
    Param("max_area", "最大面积", 0, 32767, "筛选"),
    Param("min_w", "最小宽度", 0, 320, "筛选"),
    Param("max_w", "最大宽度", 0, 320, "筛选"),
    Param("min_h", "最小高度", 0, 180, "筛选"),
    Param("max_h", "最大高度", 0, 180, "筛选"),
    Param("min_fill", "最小填充率", 0, 100, "筛选"),
    Param("min_ratio", "最小长短比", 0, 100, "筛选"),
    Param("edge_margin", "贴边剔除", 0, 320, "筛选"),
    Param("merge_dist", "碎块合并距离", 0, 320, "筛选"),
    Param("max_run_len", "最大 run 长度", 0, 1023, "筛选"),

    Param("box_w_small", "绿框边长", 1, 320, "几何"),
    Param("gate_x", "门线 X", 0, 319, "几何"),
    Param("gate_y0", "门线 Y0", 0, 179, "几何"),
    Param("gate_y1", "门线 Y1", 0, 180, "几何"),
    Param("roi_y1", "ROI 底边", -1, 180, "几何"),

    Param("track_gate", "关联半径", 1, 181, "跟踪"),
    Param("max_miss", "最大丢失帧", 0, 255, "跟踪"),
    Param("min_hits", "确认命中数", 1, 255, "跟踪"),
    Param("min_move", "最小总位移", 0, 320, "跟踪"),
    Param("min_window", "5 帧位移门限", 0, 320, "跟踪"),
    Param("vx_max", "左向速度门限", -320, 0, "跟踪"),
    Param("static_max_age", "静态轨迹寿命", 0, 10000, "跟踪"),

    Param("debug", "调试输出", 0, 1, "调试"),
    Param("debug_div", "调试输出分频", 1, 60000, "调试"),
    Param("beep_ms", "短鸣时长 ms", 1, 10000, "调试"),
    Param("beep_freq_hz", "短鸣频率 Hz", 400, 5000, "调试"),
]

GROUPS = ["相机", "前端", "筛选", "几何", "跟踪", "调试"]


class SerialLink:
    def __init__(self, port):
        self.ser = serial.Serial(port, 115200, timeout=0.05, write_timeout=1.0)
        self.lines = queue.Queue()
        self.stop_flag = False
        self.thread = threading.Thread(target=self._reader, daemon=True)
        self.thread.start()

    def _reader(self):
        while not self.stop_flag:
            try:
                raw = self.ser.readline()
            except serial.SerialException as exc:
                self.lines.put("__ERROR__ " + str(exc))
                break
            if not raw:
                continue
            text = raw.decode("ascii", errors="replace").strip()
            if text:
                self.lines.put(text)

    def send(self, line):
        self.ser.write((line + "\n").encode("ascii"))
        self.ser.flush()

    def close(self):
        self.stop_flag = True
        try:
            self.ser.close()
        except serial.SerialException:
            pass


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("camera_hdmi_720p 参数调参")
        self.geometry("900x720")
        self.minsize(760, 560)

        self.link = None
        self.vars = {}
        self.device_values = {}
        self.expected = None
        self.expected_event = threading.Event()
        self.saw_error = False

        self.port_var = tk.StringVar()
        self.status_var = tk.StringVar(value="未连接")
        self.build_ui()
        self.refresh_ports()
        self.after(50, self.poll_lines)

    def build_ui(self):
        top = ttk.Frame(self, padding=8)
        top.pack(fill=tk.X)

        ttk.Label(top, text="串口").pack(side=tk.LEFT)
        self.port_box = ttk.Combobox(top, textvariable=self.port_var, width=10, state="readonly")
        self.port_box.pack(side=tk.LEFT, padx=(4, 4))
        ttk.Button(top, text="刷新", command=self.refresh_ports).pack(side=tk.LEFT)
        self.connect_btn = ttk.Button(top, text="连接", command=self.toggle_connect)
        self.connect_btn.pack(side=tk.LEFT, padx=(8, 4))
        ttk.Label(top, textvariable=self.status_var).pack(side=tk.LEFT, padx=8)

        body = ttk.Frame(self, padding=(8, 0, 8, 8))
        body.pack(fill=tk.BOTH, expand=True)

        self.nb = ttk.Notebook(body)
        self.nb.pack(fill=tk.BOTH, expand=True)

        for group in GROUPS:
            frame = ttk.Frame(self.nb, padding=10)
            self.nb.add(frame, text=group)
            row = 0
            for p in (x for x in PARAMS if x.group == group):
                ttk.Label(frame, text=p.label, width=16, anchor=tk.W).grid(
                    row=row, column=0, sticky=tk.W, pady=4)
                var = tk.StringVar()
                spin = ttk.Spinbox(frame, from_=p.lo, to=p.hi, textvariable=var,
                                   width=12, increment=1)
                spin.grid(row=row, column=1, sticky=tk.W, pady=4)
                ttk.Label(frame, text=f"{p.lo} .. {p.hi}", foreground="#666").grid(
                    row=row, column=2, sticky=tk.W, padx=(8, 0))
                if p.note:
                    ttk.Label(frame, text=p.note, foreground="#a06000").grid(
                        row=row, column=3, sticky=tk.W, padx=(12, 0))
                ttk.Label(frame, text=p.name, foreground="#888").grid(
                    row=row, column=4, sticky=tk.W, padx=(12, 0))
                self.vars[p.name] = (var, spin)
                row += 1

        buttons = ttk.Frame(body)
        buttons.pack(fill=tk.X, pady=(8, 4))
        ttk.Button(buttons, text="读取参数", command=self.do_get).pack(side=tk.LEFT, padx=(0, 6))
        ttk.Button(buttons, text="应用", command=self.do_apply).pack(side=tk.LEFT, padx=(0, 6))
        ttk.Button(buttons, text="恢复默认", command=self.do_default).pack(side=tk.LEFT, padx=(0, 6))
        ttk.Button(buttons, text="重新采样背景", command=self.do_recapture).pack(side=tk.LEFT, padx=(0, 6))
        ttk.Button(buttons, text="保存预设", command=self.save_preset).pack(side=tk.LEFT, padx=(0, 6))
        ttk.Button(buttons, text="加载预设", command=self.load_preset).pack(side=tk.LEFT)

        log_frame = ttk.LabelFrame(body, text="串口日志", padding=4)
        log_frame.pack(fill=tk.BOTH, expand=False)
        self.log = tk.Text(log_frame, height=10, wrap=tk.NONE, state=tk.DISABLED)
        self.log.pack(fill=tk.BOTH, expand=True)

    def refresh_ports(self):
        ports = [p.device for p in list_ports.comports()]
        self.port_box["values"] = ports
        if ports and not self.port_var.get():
            self.port_var.set(ports[0])

    def log_line(self, text):
        self.log.configure(state=tk.NORMAL)
        self.log.insert(tk.END, text + "\n")
        self.log.see(tk.END)
        self.log.configure(state=tk.DISABLED)

    def toggle_connect(self):
        if self.link:
            self.disconnect()
        else:
            self.connect()

    def connect(self):
        port = self.port_var.get()
        if not port:
            messagebox.showerror("错误", "没有可用串口")
            return
        try:
            self.link = SerialLink(port)
        except serial.SerialException as exc:
            self.link = None
            messagebox.showerror("连接失败", str(exc))
            return
        self.connect_btn.configure(text="断开")
        self.status_var.set(f"已连接 {port}")
        self.log_line(f"# connected {port}")
        self.send_and_wait(["VER", "GET"], "OK GET", timeout=2.0)

    def disconnect(self):
        if self.link:
            self.link.close()
            self.link = None
        self.connect_btn.configure(text="连接")
        self.status_var.set("未连接")
        self.log_line("# disconnected")

    def send_and_wait(self, lines, expect, timeout=3.0):
        if not self.link:
            messagebox.showerror("错误", "串口未连接")
            return False
        self.expected = expect
        self.expected_event.clear()
        self.saw_error = False
        for line in lines:
            self.link.send(line)
            time.sleep(0.008)
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.update()
            if self.expected_event.wait(0.01):
                break
        ok = self.expected_event.is_set()
        self.expected = None
        if not ok:
            self.log_line(f"# timeout waiting {expect}")
        return ok

    def poll_lines(self):
        if self.link:
            while True:
                try:
                    line = self.link.lines.get_nowait()
                except queue.Empty:
                    break
                if line.startswith("__ERROR__"):
                    self.log_line(line)
                    continue
                self.log_line(line)
                if line.startswith("PARAM "):
                    body = line[6:]
                    if "=" in body:
                        name, value = body.split("=", 1)
                        self.device_values[name] = value
                        if name in self.vars:
                            self.vars[name][0].set(value)
                if line.startswith("ERR"):
                    self.saw_error = True
                if self.expected and line.startswith(self.expected):
                    self.expected_event.set()
        self.after(50, self.poll_lines)

    def read_values(self):
        values = {}
        for p in PARAMS:
            text = self.vars[p.name][0].get().strip()
            try:
                val = int(text)
            except ValueError:
                raise ValueError(f"{p.name} 不是整数")
            if val < p.lo or val > p.hi:
                raise ValueError(f"{p.name} 超出范围 {p.lo}..{p.hi}")
            values[p.name] = val
        return values

    def do_get(self):
        self.send_and_wait(["GET"], "OK GET", timeout=2.0)

    def do_apply(self):
        try:
            values = self.read_values()
        except ValueError as exc:
            messagebox.showerror("参数错误", str(exc))
            return
        lines = []
        for p in PARAMS:
            val = values[p.name]
            if self.device_values.get(p.name) != str(val):
                lines.append(f"SET {p.name} {val}")
        if not lines:
            self.log_line("# 参数没有变化")
            return
        lines.append("APPLY")
        ok = self.send_and_wait(lines, "OK APPLY", timeout=5.0)
        if ok and not self.saw_error:
            for p in PARAMS:
                self.device_values[p.name] = str(values[p.name])
            self.status_var.set("参数已应用")
        elif self.saw_error:
            self.status_var.set("应用失败，查看日志")

    def do_default(self):
        if self.send_and_wait(["DEFAULT"], "OK DEFAULT", timeout=3.0):
            self.send_and_wait(["GET"], "OK GET", timeout=2.0)
            self.status_var.set("已恢复默认")

    def do_recapture(self):
        if self.send_and_wait(["RECAPTURE"], "OK RECAPTURE", timeout=10.0):
            self.status_var.set("背景已重采")

    def save_preset(self):
        try:
            values = self.read_values()
        except ValueError as exc:
            messagebox.showerror("参数错误", str(exc))
            return
        path = filedialog.asksaveasfilename(
            defaultextension=".json",
            filetypes=[("JSON", "*.json")],
            title="保存参数预设")
        if not path:
            return
        with open(path, "w", encoding="utf-8") as f:
            json.dump(values, f, ensure_ascii=False, indent=2)
        self.log_line(f"# saved {path}")

    def load_preset(self):
        path = filedialog.askopenfilename(
            filetypes=[("JSON", "*.json")],
            title="加载参数预设")
        if not path:
            return
        try:
            with open(path, "r", encoding="utf-8") as f:
                values = json.load(f)
        except (OSError, ValueError) as exc:
            messagebox.showerror("读取失败", str(exc))
            return
        for p in PARAMS:
            if p.name in values:
                self.vars[p.name][0].set(str(values[p.name]))
        self.log_line(f"# loaded {path}")

    def on_close(self):
        self.disconnect()
        self.destroy()


if __name__ == "__main__":
    app = App()
    app.protocol("WM_DELETE_WINDOW", app.on_close)
    app.mainloop()
