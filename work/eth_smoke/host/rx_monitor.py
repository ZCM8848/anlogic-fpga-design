#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rx_monitor.py — 读取 eth_smoke 的 UART 状态行

固件每秒打印一行：
    N=0123 A=0045 M=A82BDD29A4CE
      N = 收到的帧总数 (hex)
      A = ARP reply 命中次数 (hex)
      M = 学到的对端 MAC (hex)

用法：
    python rx_monitor.py            # 自动找 COM 口
    python rx_monitor.py COM4
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


def fmt_mac(h):
    if not h or len(h) != 12:
        return "?"
    return ":".join(h[i:i + 2] for i in range(0, 12, 2))


def main():
    if len(sys.argv) > 1:
        port = sys.argv[1]
        desc = ""
    else:
        port, desc = pick_port()

    if not port:
        print("没有找到串口")
        return 1

    print(f"[open] {port}  {desc}  115200 8N1")
    print("-" * 56)

    try:
        ser = serial.Serial(port, 115200, timeout=1)
    except Exception as e:
        print(f"打开失败: {e}")
        return 1

    buf = ""
    last_rx = time.time()
    t0 = time.time()
    try:
        while True:
            chunk = ser.read(256)
            if chunk:
                last_rx = time.time()
                buf += chunk.decode("ascii", errors="replace")
                while "\n" in buf:
                    line, buf = buf.split("\n", 1)
                    line = line.strip().replace("\r", "")
                    if not line:
                        continue
                    ts = time.time() - t0
                    print(f"[{ts:8.2f}s] {line}", end="")
                    if line.startswith("N=") and " M=" in line:
                        mac = line.split("M=")[-1].strip()
                        print(f"   -> MAC {fmt_mac(mac)}")
                    else:
                        print()
            elif buf and (time.time() - last_rx) > 1.0:
                # 没有换行符也把残留打出来（便于排查波特率/乱码）
                print(f"[raw] {buf!r}")
                buf = ""
    except KeyboardInterrupt:
        print("\n[exit]")
    finally:
        ser.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
