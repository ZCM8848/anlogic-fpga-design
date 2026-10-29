#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""console_server.py — camera_eth_720p 上位机 Web 控制台（后端）

功能：
  - /stream.mjpg        实时预览（UDP 4660 → cam_proc → JPEG）
  - /api/status         设备状态（串口 N/T/C/S/V、实时帧号/亮度、录制状态、任务）
  - /api/record/start   调 dumpcap 录制到 captures/<name>/raw.pcapng
  - /api/record/stop    停止录制
  - /api/session/render 对某个 session 跑处理流水线（meta / png / mp4）
  - /api/sessions       会话列表
  - /api/open           在资源管理器打开会话目录
  - /api/log?since=N    增量日志

设计原则：
  - 只用标准库 + numpy/opencv/pyserial（不引入 Flask/FastAPI）
  - 预览线程、串口线程、录制进程、处理任务彼此独立
  - 任何一步失败都只写日志，不拖垮服务

单独运行：
    python console_server.py --iface "\\Device\\NPF_{...}" --com COM4
（一般用 console.py 启动，它会自动开浏览器）
"""
import argparse
import json
import os
import queue
import re
import signal
import socket
import subprocess
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

import numpy as np
import cv2

# Windows 控制台默认 GBK，日志里的 ▶/·/✓ 会直接抛 UnicodeEncodeError 把线程弄死
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

from cam_proc import (W, H, PKT_BYTES, PKT_TOTAL, META_IDX, parse_meta,
                      awb_gains, awb_gains_from_meta, apply_awb,
                      column_profile, column_correction, to_bgr, denoise,
                      unpack_raw10)

HERE = os.path.dirname(os.path.abspath(__file__))
WEB = os.path.join(HERE, "webui")
CAPTURES = os.path.abspath(os.path.join(HERE, "..", "captures"))
DUMPCAP = r"D:\Program Files\Wireshark\dumpcap.exe"
CONFIG = os.path.join(HERE, "console.json")

STATE_LOCK = threading.Lock()
LOG_LOCK = threading.Lock()
LOG = deque(maxlen=4000)
LOG_TOTAL = 0
AUTO_PROCESS = {"on": True,
                "opts": {"meta": True, "png": True, "mp4": True, "raw": False}}
AWB_MODE = {"mode": "auto"}      # auto = 逐帧灰世界 / lock = 冻结当前增益 / off = 不校正


def log(msg):
    global LOG_TOTAL
    line = f"{time.strftime('%H:%M:%S')}  {msg}"
    with LOG_LOCK:
        LOG.append(line)
        LOG_TOTAL += 1
    try:
        print(line, flush=True)
    except Exception:
        try:
            print(line.encode("ascii", "replace").decode("ascii"), flush=True)
        except Exception:
            pass


def logs_since(since):
    """since 是绝对行号；返回 (新行, 当前总行号)"""
    with LOG_LOCK:
        total = LOG_TOTAL
        first = total - len(LOG)
        start = max(0, since - first)
        return list(LOG)[start:], total


# ======================================================================
# 配置
# ======================================================================
def load_config():
    cfg = {"iface": "", "com": "COM4", "port": 8770, "udp": 4660,
           "capture_dir": CAPTURES}
    if os.path.exists(CONFIG):
        try:
            with open(CONFIG, encoding="utf-8") as f:
                cfg.update(json.load(f))
        except Exception:
            pass
    return cfg


def save_config(cfg):
    try:
        with open(CONFIG, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
    except Exception:
        pass


def detect_iface():
    """优先按 PC 的 192.168.1.100 找到对应网卡，回退到 dumpcap -D 描述匹配"""
    # 1) 通过 IP 反查网卡 GUID（最可靠）
    try:
        ps = ("$i = (Get-NetIPAddress -AddressFamily IPv4 -IPAddress 192.168.1.100).InterfaceIndex; "
              "(Get-NetAdapter -InterfaceIndex $i).InterfaceGuid")
        out = subprocess.run(["powershell", "-NoProfile", "-Command", ps],
                             capture_output=True, timeout=15)
        guid = out.stdout.decode("ascii", errors="ignore").strip()
        if guid.startswith("{") and guid.endswith("}"):
            dev = "\\Device\\NPF_" + guid
            log(f"[iface] 按 192.168.1.100 选中: {dev}")
            return dev
    except Exception as e:
        log(f"[iface] IP 反查失败: {e}")

    # 2) 回退：dumpcap -D，多编码尝试
    try:
        out = subprocess.run([DUMPCAP, "-D"], capture_output=True, timeout=10)
    except Exception as e:
        log(f"[iface] dumpcap -D 失败: {e}")
        return ""
    for enc in ("mbcs", "utf-8", "gbk"):
        try:
            txt = out.stdout.decode(enc, errors="replace")
        except Exception:
            continue
        cands = []
        for line in txt.splitlines():
            m = re.match(r"\s*\d+\.\s+(\S+)\s*(.*)", line)
            if m:
                cands.append((m.group(1), m.group(2)))
        for dev, desc in cands:
            if "以太网" in desc:
                log(f"[iface] 按描述选中: {desc.strip()}  {dev}")
                return dev
        for dev, desc in cands:
            if "ethernet" in desc.lower():
                log(f"[iface] 按描述选中: {desc.strip()}  {dev}")
                return dev
    return ""


# ======================================================================
# 实时预览（UDP → 图像）
# ======================================================================
class Preview(threading.Thread):
    def __init__(self, port):
        super().__init__(daemon=True)
        self.port = port
        self.latest = None          # JPEG bytes
        self.lock = threading.Lock()
        self.fps = 0.0
        self.frame_id = 0
        self.ae = 0
        self.ag = 0
        self.packets = 0
        self.last_rx = 0.0
        self.running = True
        self._frames = {}
        self._cnt = {}
        self._metas = {}
        self._prof = None
        self._lo = None
        self._hi = None
        self._t_prev = 0.0
        self._t_last = 0.0
        self._gb = 1.0
        self._gr = 1.0
        self._need = 0

    def run(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
        except OSError:
            pass
        try:
            sock.bind(("0.0.0.0", self.port))
        except OSError as e:
            log(f"[preview] 绑定 UDP {self.port} 失败: {e}")
            return
        sock.settimeout(0.5)
        log(f"[preview] 监听 UDP :{self.port}")

        while self.running:
            try:
                data, _ = sock.recvfrom(2048)
            except socket.timeout:
                continue
            except OSError:
                break
            self.last_rx = time.time()
            if data[:2] != b"\xAA\x55" or len(data) < 1448:
                continue
            fid = (data[2] << 8) | data[3]
            pidx = (data[4] << 8) | data[5]
            if pidx == META_IDX:
                m = parse_meta(data[8:])
                if m:
                    self._metas[m["frame_id"]] = m
                continue
            if pidx >= PKT_TOTAL:
                continue
            fr = self._frames.get(fid)
            if fr is None:
                fr = self._frames[fid] = [None] * PKT_TOTAL
                self._cnt[fid] = 0
            if fr[pidx] is None:
                fr[pidx] = data[8:]
                self._cnt[fid] += 1
                self.packets += 1
                if self._cnt[fid] == PKT_TOTAL:
                    self._render(fid, fr)
                    for k in [k for k in self._frames if k < fid - 1]:
                        del self._frames[k]
                        self._cnt.pop(k, None)
                        self._metas.pop(k, None)
        sock.close()

    def _render(self, fid, fr):
        now = time.time()
        if now - self._t_prev < 0.09:      # 预览限速 ~11fps
            return
        self._t_prev = now
        try:
            px = unpack_raw10(b"".join(fr)[: W * H * 10 // 8])[: W * H].reshape(H, W)
            m = self._metas.get(fid)

            mode = AWB_MODE["mode"]
            if mode == "auto":
                gb, gr = awb_gains_from_meta(m) if m else awb_gains(px)
                self._gb, self._gr = gb, gr          # 记住最后一次，供 lock 用
            elif mode == "lock":
                gb, gr = self._gb, self._gr
            else:                                    # off
                gb, gr = 1.0, 1.0

            bal = apply_awb(px, gb, gr)

            cp = column_profile(bal)
            self._prof = cp if self._prof is None else self._prof * 0.9 + cp * 0.1
            bal -= column_correction(self._prof)[None, :]
            np.clip(bal, 0, 1023, out=bal)

            if self._lo is None:
                self._lo = float(np.percentile(bal, 0.5))
                self._hi = float(np.percentile(bal, 99.5))
            else:
                self._lo = self._lo * 0.9 + float(np.percentile(bal, 0.5)) * 0.1
                self._hi = self._hi * 0.9 + float(np.percentile(bal, 99.5)) * 0.1

            bgr = to_bgr(bal, self._lo, max(self._hi, self._lo + 16))
            bgr = denoise(bgr, 1)
            ok, jpg = cv2.imencode(".jpg", bgr, [cv2.IMWRITE_JPEG_QUALITY, 78])
            if ok:
                with self.lock:
                    self.latest = jpg.tobytes()
                self.frame_id = fid
                if self._t_last:
                    dt = now - self._t_last
                    if dt > 1e-3:
                        self.fps = 0.8 * self.fps + 0.2 * (1.0 / dt)
                self._t_last = now
                if m:
                    self.ae, self.ag = m["ae"], m["ag"]
        except Exception as e:
            log(f"[preview] 渲染失败: {e}")

    def snapshot(self):
        with self.lock:
            return self.latest


# ======================================================================
# 串口状态
# ======================================================================
class Uart(threading.Thread):
    def __init__(self, com):
        super().__init__(daemon=True)
        self.com = com
        self.running = True
        self.ok = False
        self.n = self.t = self.c = 0
        self.sid = 0
        self.v = 0
        self.last = 0.0

    def run(self):
        while self.running:
            try:
                import serial
                ser = serial.Serial(self.com, 115200, timeout=0.5)
                log(f"[uart] 打开 {self.com}")
                self.ok = True
                buf = ""
                while self.running:
                    chunk = ser.read(256)
                    if not chunk:
                        continue
                    buf += chunk.decode("ascii", errors="replace")
                    while "\n" in buf:
                        line, buf = buf.split("\n", 1)
                        self._parse(line.strip().replace("\r", ""))
                ser.close()
            except Exception as e:
                self.ok = False
                log(f"[uart] {self.com} 打开失败: {e}")
                time.sleep(5)

    def _parse(self, line):
        if not line.startswith("N="):
            return
        try:
            d = dict(tok.split("=", 1) for tok in line.split() if "=" in tok)
            self.n = int(d.get("N", "0"), 16)
            self.t = int(d.get("T", "0"), 16)
            self.c = int(d.get("C", "0"), 16)
            self.sid = int(d.get("S", "0"), 16)
            self.v = int(d.get("V", "0"), 16)
            self.last = time.time()
        except Exception:
            pass


# ======================================================================
# 录制 + 处理流水线
# ======================================================================
class Recorder:
    def __init__(self, iface, capture_dir):
        self.iface = iface
        self.dir = capture_dir
        self.proc = None
        self.name = ""
        self.path = ""
        self.started = 0.0
        self.packets = 0
        self.lock = threading.Lock()
        self.on_done = None

    def running(self):
        return self.proc is not None and self.proc.poll() is None

    def start(self, name, seconds):
        if self.running():
            return False, "已经在录制"
        if not os.path.isfile(DUMPCAP):
            return False, f"找不到 dumpcap: {DUMPCAP}"
        name = re.sub(r"[^0-9A-Za-z_\-\u4e00-\u9fa5]", "_", name).strip("_") or time.strftime("%Y%m%d_%H%M%S")
        d = os.path.join(self.dir, name)
        os.makedirs(d, exist_ok=True)
        pcap = os.path.join(d, "raw.pcapng")
        cmd = [DUMPCAP, "-i", self.iface, "-w", pcap, "-a", f"duration:{int(seconds)}"]
        log("[rec] " + " ".join(cmd))
        flags = subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
        env = dict(os.environ, PYTHONIOENCODING="utf-8")
        self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     text=True, encoding="utf-8", errors="replace",
                                     bufsize=1, creationflags=flags, env=env)
        self.name, self.path = name, d
        self.started = time.time()
        self.packets = 0
        threading.Thread(target=self._pump, daemon=True).start()
        return True, name

    def _pump(self):
        try:
            for line in self.proc.stdout:
                line = line.rstrip()
                if not line:
                    continue
                m = re.search(r"Packets captured:\s*(\d+)", line)
                if m:
                    self.packets = int(m.group(1))
                else:
                    log(f"[dumpcap] {line}")
        except Exception as e:
            log(f"[rec] 读取 dumpcap 输出失败: {e}")
        finally:
            try:
                rc = self.proc.wait(timeout=10)
            except Exception:
                rc = -1
            log(f"[rec] 结束 rc={rc}  {self.packets} 包")
            cb = self.on_done
            if cb:
                try:
                    cb(self.name, self.path)
                except Exception as e:
                    log(f"[rec] 后处理回调失败: {e}")

    def stop(self):
        if not self.running():
            return False
        try:
            if os.name == "nt":
                self.proc.send_signal(signal.CTRL_BREAK_EVENT)
            else:
                self.proc.terminate()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=6)
        except Exception:
            self.proc.kill()
        return True


JOBS = queue.Queue()
JOB_STATE = {"running": False, "label": "", "session": ""}


def worker():
    while True:
        label, session, steps = JOBS.get()
        JOB_STATE.update(running=True, label=label, session=session)
        log(f"[job] ▶ {label} ({session})")
        try:
            for name, cmd in steps:
                log(f"[job] · {name}")
                env = dict(os.environ, PYTHONIOENCODING="utf-8")
                p = subprocess.Popen(cmd, cwd=HERE, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True,
                                     encoding="utf-8", errors="replace",
                                     bufsize=1, env=env)
                for line in p.stdout:
                    line = line.rstrip()
                    if line:
                        log(f"        {line}")
                rc = p.wait()
                if rc != 0:
                    log(f"[job] ✗ {name} rc={rc}")
                    raise RuntimeError(f"{name} 失败 rc={rc}")
            log(f"[job] ✓ {label} 完成")
        except Exception as e:
            log(f"[job] ✗ {label}: {e}")
        finally:
            JOB_STATE.update(running=False, label="", session="")


def session_info(name):
    d = os.path.join(CAPTURES, name)
    pcap = os.path.join(d, "raw.pcapng")
    info = {"name": name, "dir": d, "has_pcap": os.path.exists(pcap),
            "has_meta": os.path.exists(os.path.join(d, "meta.jsonl")),
            "has_mp4": os.path.exists(os.path.join(d, "out_60fps.mp4")),
            "has_png": os.path.exists(os.path.join(d, "preview.png")),
            "has_raw": os.path.exists(os.path.join(d, "raw10.npy")),
            "bytes": 0, "mtime": 0, "frames": None, "fps": None}
    if os.path.exists(pcap):
        info["bytes"] = os.path.getsize(pcap)
        info["mtime"] = os.path.getmtime(pcap)
    rp = os.path.join(d, "run.json")
    if os.path.exists(rp):
        try:
            with open(rp, encoding="utf-8") as f:
                r = json.load(f)["capture"]
            info["frames"] = r.get("frames_complete")
            info["fps"] = r.get("fps")
        except Exception:
            pass
    return info


def list_sessions():
    if not os.path.isdir(CAPTURES):
        return []
    out = []
    for n in sorted(os.listdir(CAPTURES), reverse=True):
        if os.path.isdir(os.path.join(CAPTURES, n)):
            out.append(session_info(n))
    return out


def build_steps(session, opts):
    d = os.path.join(CAPTURES, session)
    pcap = os.path.join(d, "raw.pcapng")
    steps = []
    if opts.get("meta", True):
        steps.append(("meta.jsonl / run.json", [sys.executable, "pcap_meta.py", pcap]))
    if opts.get("png", True):
        steps.append(("preview.png", [sys.executable, "raw10_pcap_decode.py", pcap,
                                      os.path.join(d, "preview.png")]))
    if opts.get("mp4", True):
        steps.append(("out_60fps.mp4", [sys.executable, "make_video.py", pcap,
                                        os.path.join(d, "out_60fps.mp4")]))
    if opts.get("raw", False):
        steps.append(("raw10.npy (10bit 原始帧)", [sys.executable, "pcap_export_raw.py",
                                                   pcap, d]))
    return steps


# ======================================================================
# HTTP
# ======================================================================
class Handler(BaseHTTPRequestHandler):
    server_version = "CameraEthConsole/1.0"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj, ensure_ascii=False), "application/json; charset=utf-8")

    def do_GET(self):
        u = urlparse(self.path)
        p = u.path
        if p in ("/", "/index.html"):
            return self._file(os.path.join(WEB, "index.html"), "text/html; charset=utf-8")
        if p == "/app.css":
            return self._file(os.path.join(WEB, "app.css"), "text/css; charset=utf-8")
        if p == "/app.js":
            return self._file(os.path.join(WEB, "app.js"), "application/javascript; charset=utf-8")
        if p == "/api/status":
            return self._json(self.status())
        if p == "/api/sessions":
            return self._json({"sessions": list_sessions()})
        if p == "/api/log":
            q = parse_qs(u.query)
            since = int(q.get("since", ["0"])[0])
            lines, seq = logs_since(since)
            return self._json({"lines": lines, "seq": seq})
        if p == "/stream.mjpg":
            return self._stream()
        return self._send(404, "not found", "text/plain")

    def do_POST(self):
        u = urlparse(self.path)
        n = int(self.headers.get("Content-Length", "0") or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            body = {}
        if u.path == "/api/record/start":
            name = body.get("name") or time.strftime("%Y-%m-%d_%H%M%S")
            dur = int(body.get("duration", 10))
            AUTO_PROCESS["on"] = bool(body.get("auto", True))
            opts = body.get("options")
            if isinstance(opts, dict):
                AUTO_PROCESS["opts"] = {k: bool(opts.get(k, False))
                                        for k in ("meta", "png", "mp4", "raw")}
            ok, msg = REC.start(name, dur)
            return self._json({"ok": ok, "msg": msg})
        if u.path == "/api/record/stop":
            ok = REC.stop()
            return self._json({"ok": ok})
        if u.path == "/api/awb":
            mode = str(body.get("mode", "auto"))
            if mode not in ("auto", "lock", "off"):
                return self._json({"ok": False, "msg": "mode 必须是 auto/lock/off"}, 400)
            AWB_MODE["mode"] = mode
            log(f"[awb] 模式切换为 {mode}")
            return self._json({"ok": True, "mode": mode})
        if u.path == "/api/session/render":
            sess = body.get("session") or ""
            opts = body.get("options", {})
            if not os.path.isdir(os.path.join(CAPTURES, sess)):
                return self._json({"ok": False, "msg": "session 不存在"}, 400)
            steps = build_steps(sess, opts)
            if not steps:
                return self._json({"ok": False, "msg": "没有选择任何产物"}, 400)
            JOBS.put((f"process {sess}", sess, steps))
            return self._json({"ok": True})
        if u.path == "/api/open":
            sess = body.get("session") or ""
            d = os.path.join(CAPTURES, sess)
            if os.path.isdir(d):
                try:
                    os.startfile(d)
                    return self._json({"ok": True})
                except Exception as e:
                    return self._json({"ok": False, "msg": str(e)})
            return self._json({"ok": False, "msg": "not found"}, 404)
        return self._json({"ok": False, "msg": "unknown"}, 404)

    def _file(self, path, ctype):
        try:
            with open(path, "rb") as f:
                data = f.read()
        except FileNotFoundError:
            return self._send(404, "not found", "text/plain")
        self._send(200, data, ctype)

    def _stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            while True:
                jpg = PREVIEW.snapshot()
                if jpg:
                    self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\n")
                    self.wfile.write(f"Content-Length: {len(jpg)}\r\n\r\n".encode())
                    self.wfile.write(jpg)
                    self.wfile.write(b"\r\n")
                time.sleep(0.06)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    def status(self):
        now = time.time()
        with STATE_LOCK:
            return {
                "uart": {"ok": UART.ok, "n": UART.n, "t": UART.t, "c": UART.c,
                         "sid": f"{UART.sid:04X}", "v": UART.v,
                         "age": round(now - UART.last, 1) if UART.last else None},
                "live": {"ok": (now - PREVIEW.last_rx) < 3 if PREVIEW.last_rx else False,
                         "fps": round(PREVIEW.fps, 1), "frame": PREVIEW.frame_id,
                         "ae": PREVIEW.ae, "ag": PREVIEW.ag,
                         "awb": AWB_MODE["mode"],
                         "gb": round(PREVIEW._gb, 3), "gr": round(PREVIEW._gr, 3),
                         "packets": PREVIEW.packets},
                "rec": {"on": REC.running(), "name": REC.name,
                        "seconds": round(now - REC.started, 1) if REC.running() else 0,
                        "packets": REC.packets},
                "job": dict(JOB_STATE),
                "sessions": list_sessions()[:20],
                "iface": CFG.get("iface", ""),
            }


PREVIEW = None
UART = None
REC = None
CFG = None


def main():
    global PREVIEW, UART, REC, CFG
    ap = argparse.ArgumentParser()
    ap.add_argument("--iface", default="")
    ap.add_argument("--com", default="")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--udp", type=int, default=0)
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()

    CFG = load_config()
    if args.iface:
        CFG["iface"] = args.iface
    if args.com:
        CFG["com"] = args.com
    if args.port:
        CFG["port"] = args.port
    if args.udp:
        CFG["udp"] = args.udp
    if not CFG.get("iface"):
        CFG["iface"] = detect_iface()
    save_config(CFG)

    os.makedirs(CAPTURES, exist_ok=True)

    PREVIEW = Preview(CFG["udp"])
    PREVIEW.start()
    UART = Uart(CFG["com"])
    UART.start()
    REC = Recorder(CFG["iface"], CAPTURES)

    # 录制结束自动跑流水线
    def on_done(name, path):
        if AUTO_PROCESS["on"]:
            steps = build_steps(name, AUTO_PROCESS["opts"])
            if steps:
                JOBS.put((f"auto process {name}", name, steps))
    REC.on_done = on_done

    threading.Thread(target=worker, daemon=True).start()

    srv = ThreadingHTTPServer(("127.0.0.1", CFG["port"]), Handler)
    url = f"http://127.0.0.1:{CFG['port']}/"
    log(f"[web] {url}")
    if not args.no_browser:
        try:
            import webbrowser
            threading.Timer(0.8, lambda: webbrowser.open(url)).start()
        except Exception:
            pass
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log("[web] 退出")
    finally:
        PREVIEW.running = False
        UART.running = False
        if REC.running():
            REC.stop()
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
