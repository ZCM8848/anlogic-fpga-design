#!/usr/bin/env python3
"""带时间戳读取本工程串口（COM4, 115200 8N1），按 BCD 解析并计算相机帧率。

【踩过的坑，务必记住】
  status_report.v 输出的 F/L/W/G 四个统计字段是 **BCD 码**
  （RTL 里端口名就叫 D_fs_bcd / D_line_bcd / D_wpx_bcd / D_grp_bcd），
  不是十六进制！当数值只含 0-9 时两种解释恰好相同，看不出问题；一旦 F 变大
  （如 033245），按 hex 解析会得出完全错误的帧率（曾把 59.6fps 算成 7.6fps）。

用法:
  python serial_ts.py COM4 12      # 读 12 秒：逐条打印 + 用 ΔF(BCD)/Δt 算帧率
"""
import re
import sys
import time

import serial


def bcd(s):
    """BCD 字符串 → 整数（每位就是一个十进制位）。含非 0-9 字符返回 None。"""
    n = 0
    for ch in s:
        if ch not in "0123456789":
            return None
        n = n * 10 + int(ch)
    return n


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "COM4"
    dur = float(sys.argv[2]) if len(sys.argv) > 2 else 12.0

    s = serial.Serial(port, 115200, timeout=0.05)
    s.reset_input_buffer()
    t0 = time.time()
    buf = b""
    nlines = 0
    fvals = []  # (t, F_bcd, F_hex)
    while time.time() - t0 < dur:
        d = s.read(4096)
        if not d:
            continue
        buf += d
        while b"\n" in buf:
            raw, buf = buf.split(b"\n", 1)
            t = time.time() - t0
            txt = raw.decode("ascii", "replace").strip("\r")
            if not txt:
                continue
            nlines += 1
            m = re.search(r"F=([0-9A-Fa-f]{6})", txt)
            if m:
                fvals.append((t, bcd(m.group(1)), int(m.group(1), 16)))
    s.close()

    print(f"收到 {nlines} 行 / {dur:.0f}s")
    for t, fb, fh in fvals:
        print(f"  t={t:6.2f}s  F(BCD)={fb}   [若按 hex 读 = {fh}]")

    if len(fvals) >= 2 and fvals[-1][1] is not None and fvals[0][1] is not None:
        dt = fvals[-1][0] - fvals[0][0]
        df = fvals[-1][1] - fvals[0][1]
        if dt > 0:
            print(f"—— 帧率 = ΔF(BCD) {df} / {dt:.2f}s = {df / dt:.2f} fps ——")

    print("（报文节奏应约 0.50s；无数据时先确认没有别的程序占着 COM4）")


if __name__ == "__main__":
    main()
