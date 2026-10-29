#!/usr/bin/env python3
"""mdio_dbg.py — 监听 COM 口，直接打印 MDIO 调试串口输出。

用法：
    python mdio_dbg.py COM4            # 默认 115200 8N1
    python mdio_dbg.py COM4 --raw log.txt   # 同时把原始字节存文件

按 Ctrl+C 退出。
"""
import sys
import time

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

try:
    import serial
except ImportError:
    print("缺少 pyserial：pip install pyserial")
    sys.exit(1)


def main():
    if len(sys.argv) < 2:
        print("用法: python mdio_dbg.py <COM口> [--raw 文件名]")
        print("例: python mdio_dbg.py COM4")
        sys.exit(1)
    port = sys.argv[1]
    raw_path = None
    if "--raw" in sys.argv:
        i = sys.argv.index("--raw")
        raw_path = sys.argv[i + 1] if i + 1 < len(sys.argv) else "mdio_raw.log"

    ser = serial.Serial(port, 115200, timeout=0.1)
    print(f"[mdio_dbg] listening {port} @ 115200 8N1 (Ctrl+C to quit)")
    print("-" * 50)
    raw_f = open(raw_path, "wb") if raw_path else None
    if raw_f:
        print(f"[mdio_dbg] raw bytes also to: {raw_path}")
    try:
        buf = b""
        while True:
            chunk = ser.read(64)
            if chunk:
                if raw_f:
                    raw_f.write(chunk)
                    raw_f.flush()
                buf += chunk
                # 按行打印（以 \n 或 \r\n 分隔）
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    line = line.rstrip(b"\r").decode("ascii", errors="replace")
                    ts = time.strftime("%H:%M:%S")
                    print(f"[{ts}] {line}")
    except KeyboardInterrupt:
        print("\n[mdio_dbg] stopped by user")
    finally:
        ser.close()
        if raw_f:
            raw_f.close()


if __name__ == "__main__":
    main()
