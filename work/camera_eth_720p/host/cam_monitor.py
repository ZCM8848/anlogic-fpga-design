#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cam_monitor.py — 读取 camera_eth_720p 的 UART 状态行（COM4, 115200 8N1）

固件每秒打印一行：

    N=0012 T=0034 C=0035 S=56C0 V=3

      N = 以太网 RX 收到的主机帧数（PC 的 ARP 之类）
      T = 已发送的视频帧数（frame_id，正常 ~60/s）
      C = 摄像头 RAW10 帧计数（正常 ~60/s，比 T 略超前）
      S = 传感器 ID（I2C 读回，SC520CS 应为 56C0；0000 = 没读到）
      V = 状态位  bit0=cfg_done  bit1=sensor_ok  bit2=fifo_ovf  bit3=rx_alive

用法：
    python cam_monitor.py            # 自动找串口
    python cam_monitor.py COM4
"""
import sys
import time

try:
    import serial
    from serial.tools import list_ports
except ImportError:
    print("需要 pyserial:  pip install pyserial")
    sys.exit(1)


def pick_port():
    for p in list_ports.comports():
        desc = (p.description or "") + " " + (p.hwid or "")
        if "FTDI" in desc.upper() or "USB SERIAL" in desc.upper() or "CP210" in desc.upper():
            return p.device, p.description
    ports = list(list_ports.comports())
    if ports:
        return ports[0].device, ports[0].description
    return None, None


def parse(line):
    """N=0012 T=0034 C=0035 S=56C0 V=3 -> dict"""
    out = {}
    for tok in line.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            try:
                out[k] = int(v, 16)
            except ValueError:
                pass
    return out


def status_bits(v):
    names = []
    if v & 1:
        names.append("cfg_done")
    if v & 2:
        names.append("sensor_ok")
    if v & 4:
        names.append("FIFO_OVF")
    if v & 8:
        names.append("rx_alive")
    return ",".join(names) if names else "-"


def main():
    if len(sys.argv) > 1:
        port, desc = sys.argv[1], ""
    else:
        port, desc = pick_port()

    if not port:
        print("没有找到串口")
        return 1

    print(f"[open] {port}  {desc}  115200 8N1")
    print(f"{'t(s)':>7} {'N':>6} {'T':>6} {'T/s':>5} {'C':>6} {'C/s':>5} {'V':>3}  status")
    print("-" * 76)

    try:
        ser = serial.Serial(port, 115200, timeout=1)
    except Exception as e:
        print(f"打开失败: {e}")
        return 1

    buf = ""
    prev_t = prev_c = None
    t0 = time.time()

    try:
        while True:
            chunk = ser.read(256)
            if not chunk:
                continue
            buf += chunk.decode("ascii", errors="replace")
            while "\n" in buf:
                line, buf = buf.split("\n", 1)
                line = line.strip().replace("\r", "")
                if not line or not line.startswith("N="):
                    if line:
                        print(f"[raw] {line}")
                    continue
                d = parse(line)
                now = time.time() - t0
                dt_dn = None
                dt_dc = None
                if prev_t is not None:
                    dt_dn = (d.get("T", 0) - prev_t) & 0xFFFF
                if prev_c is not None:
                    dt_dc = (d.get("C", 0) - prev_c) & 0xFFFF
                prev_t = d.get("T", 0)
                prev_c = d.get("C", 0)
                print(
                    f"{now:7.2f} {d.get('N',0):6d} {d.get('T',0):6d} "
                    f"{(dt_dn if dt_dn is not None else 0):5d} "
                    f"{d.get('C',0):6d} {(dt_dc if dt_dc is not None else 0):5d} "
                    f"{d.get('V',0):3d}  {status_bits(d.get('V',0))}"
                )
    except KeyboardInterrupt:
        print("\n[exit]")
    finally:
        ser.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
