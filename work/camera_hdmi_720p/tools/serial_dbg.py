#!/usr/bin/env python3
"""解析 CV 调试串口流（固件 main.c 的 "D ..." 行），帮助推断检测情况。

固件每 DBG_DIV 帧输出一行（默认 30Hz）：
  D F=<帧号> RUN=<本帧run数> NC=<连通域数> DET=<通过筛选数> B=<lt100,100_500,gt500> | [.*]area,x0,y0,x1,y1 ...

  [*] = 通过当前筛选（会被画框）；[.] = 被筛掉。
  由 bbox 推出 w/h，并算 fill=area/(w*h)、ratio=min/max。

用法:
  python serial_dbg.py COM4 15                 # 实时读 COM4 15 秒
  python serial_dbg.py COM4 15 --raw log.txt   # 另存原始行
  python serial_dbg.py --file log.txt          # 解析已保存的日志
  python serial_dbg.py COM4 15 --echo          # 逐行展开打印

依赖: pyserial（仅实时串口模式需要）:  pip install pyserial
"""
import re
import sys
import time

try:  # Windows GBK 控制台下避免中文输出崩溃
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# D 行头
HDR = re.compile(
    r"^D F=(\d+) RUN=(\d+) NC=(\d+) DET=(\d+) B=(\d+),(\d+),(\d+) \|(.*)$"
)
# 单个连通域 token: [.*]area,x0,y0,x1,y1
COMP = re.compile(r"([.*])(\d+),(\d+),(\d+),(\d+),(\d+)")


def parse_line(txt):
    m = HDR.match(txt.strip())
    if not m:
        return None
    rec = {
        "F": int(m.group(1)),
        "RUN": int(m.group(2)),
        "NC": int(m.group(3)),
        "DET": int(m.group(4)),
        "B": (int(m.group(5)), int(m.group(6)), int(m.group(7))),
        "comps": [],
    }
    for cm in COMP.finditer(m.group(8)):
        area, x0, y0, x1, y1 = (int(cm.group(i)) for i in range(2, 7))
        w, h = x1 - x0 + 1, y1 - y0 + 1
        rec["comps"].append({
            "pass": cm.group(1) == "*",
            "area": area, "x0": x0, "y0": y0, "x1": x1, "y1": y1,
            "w": w, "h": h,
            "fill": 100.0 * area / (w * h) if w * h else 0.0,
            "ratio": 100.0 * min(w, h) / max(w, h) if max(w, h) else 0.0,
            "cx": (x0 + x1) // 2, "cy": (y0 + y1) // 2,
        })
    return rec


def collect(lines):
    recs = []
    for txt in lines:
        r = parse_line(txt)
        if r:
            recs.append(r)
    return recs


def report(recs, echo=False, topn=8):
    if not recs:
        print("没有解析到任何 'D ...' 调试行。请确认：① CV 模式已开启(CV=1)；"
              "② 固件已更新；③ 波特率 115200 / 端口正确。")
        return

    n = len(recs)
    print(f"=== 解析到 {n} 条调试行 ===")
    if n >= 2:
        t0, t1 = recs[0]["F"], recs[-1]["F"]
        print(f"帧号范围 F={t0}..{t1}  (ΔF={t1 - t0})")

    runs = [r["RUN"] for r in recs]
    ncs = [r["NC"] for r in recs]
    dets = [r["DET"] for r in recs]
    print(f"RUN  本帧run数 : min={min(runs)} max={max(runs)} avg={sum(runs)/n:.0f}"
          + ("   ⚠ RUN==1024 可能溢出(run_mem 满，后面的 run 被丢!)"
             if max(runs) >= 1024 else ""))
    print(f"NC   连通域数   : min={min(ncs)} max={max(ncs)} avg={sum(ncs)/n:.0f}"
          + ("   ⚠ NC 触顶 64：MAX_LABELS 饱和，超出的碎块会并进同一 label，"
             "分桶/NC 都被压低" if max(ncs) >= 64 else ""))
    print(f"DET  通过筛选数 : min={min(dets)} max={max(dets)}   "
          f"其中 DET==0 的行 {sum(1 for d in dets if d == 0)}/{n}")
    ba = sum(r["B"][0] for r in recs) / n
    bb = sum(r["B"][1] for r in recs) / n
    bc = sum(r["B"][2] for r in recs) / n
    print(f"面积分桶(平均/帧): <100px={ba:.1f}   100-500={bb:.1f}   >500={bc:.1f}")

    passed = [c for r in recs for c in r["comps"] if c["pass"]]
    print(f"通过筛选的连通域(框选目标)总数: {len(passed)}")
    for c in passed[:topn]:
        print(f"   *A={c['area']:6d} bbox({c['x0']},{c['y0']})-({c['x1']},{c['y1']}) "
              f"w={c['w']:4d} h={c['h']:4d} fill={c['fill']:5.1f}% ratio={c['ratio']:5.1f}%")

    # 面积最大的若干（很可能是球环/横线）——看它们的 fill/ratio 判断为何没通过
    allc = [c for r in recs for c in r["comps"]]
    allc.sort(key=lambda c: c["area"], reverse=True)
    print(f"\n--- 面积最大的前 {topn} 个连通域（含未通过的，看它被哪条卡住）---")
    print("   pass A      x0   y0   x1   y1    w    h   fill%  ratio%")
    for c in allc[:topn]:
        print(f"   {'*' if c['pass'] else '.'}  {c['area']:6d} {c['x0']:4d} {c['y0']:4d} "
              f"{c['x1']:4d} {c['y1']:4d} {c['w']:4d} {c['h']:4d} "
              f"{c['fill']:6.1f} {c['ratio']:6.1f}")
    print("\n判据提示: 通过需 面积∈[MIN_AREA,MAX_AREA] ∧ fill≥MIN_FILL(15%) ∧ "
          "ratio≥MIN_RATIO(25%) ∧ 不贴边。环的 fill 通常只有个位数%。")

    if echo:
        print("\n--- 逐行 ---")
        for r in recs:
            comps = " ".join(
                f"{'*' if c['pass'] else '.'}{c['area']}@({c['x0']},{c['y0']},{c['x1']},{c['y1']})"
                for c in r["comps"])
            print(f"F={r['F']} RUN={r['RUN']} NC={r['NC']} DET={r['DET']} "
                  f"B={r['B'][0]},{r['B'][1]},{r['B'][2]} | {comps}")


def read_serial(port, dur, raw_path=None):
    try:
        import serial
    except ImportError:
        sys.exit("实时串口模式需要 pyserial:  pip install pyserial\n"
                 "（或把串口日志存成文件后用 --file 解析）")
    s = serial.Serial(port, 115200, timeout=0.05)
    s.reset_input_buffer()
    t0 = time.time()
    buf, lines, raw = b"", [], []
    while time.time() - t0 < dur:
        d = s.read(8192)
        if not d:
            continue
        buf += d
        while b"\n" in buf:
            chunk, buf = buf.split(b"\n", 1)
            txt = chunk.decode("ascii", "replace").strip("\r")
            if txt:
                lines.append(txt)
                raw.append(txt)
    s.close()
    if raw_path:
        with open(raw_path, "w", encoding="utf-8") as f:
            f.write("\n".join(raw) + "\n")
        print(f"原始行已存: {raw_path}  ({len(raw)} 行)")
    return lines


def main():
    args = sys.argv[1:]
    port, dur, echo, raw_path, file_path = "COM4", 15.0, False, None, None
    i = 0
    pos = []
    while i < len(args):
        a = args[i]
        if a == "--file":
            i += 1; file_path = args[i]
        elif a == "--raw":
            i += 1; raw_path = args[i]
        elif a == "--echo":
            echo = True
        else:
            pos.append(a)
        i += 1
    if pos:
        port = pos[0]
    if len(pos) > 1:
        dur = float(pos[1])

    if file_path:
        with open(file_path, encoding="utf-8", errors="replace") as f:
            lines = [ln for ln in f.read().splitlines() if ln.strip()]
        print(f"从文件读取 {len(lines)} 行: {file_path}")
    else:
        print(f"从 {port} 读取 {dur:.0f}s (115200 8N1) ...")
        lines = read_serial(port, dur, raw_path)

    report(collect(lines), echo=echo)


if __name__ == "__main__":
    main()
