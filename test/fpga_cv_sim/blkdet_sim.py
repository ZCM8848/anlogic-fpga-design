#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
blkdet_sim.py — 块域检测管线（PYTHON2/cv_pipeline_sim.py）的视频仿真 + FPGA 风格 OSD
================================================================================

为什么需要这个脚本：
  仓库当前的 M9 RTL（rtl/cv/cv_top.v：Sobel + run_mem 1024 + 固件 64 label）
  在这条手机录像上每帧 run 溢出、label 饱和，钢珠永远进不了 CCL——见
  fpga_cv_sim.py 的基线输出。本脚本改用仓库 Python/PYTHON2 里那套
  **块域暗块检测 + a-b 跟踪** 管线（其 README 称与 cv_blkdet RTL 同参），
  用于观察"识别结果"本身。

算法与参数直接沿用 Python/PYTHON2/sim/cv_pipeline_sim.py：
  * 16x16 块均值（80x45），DARK_THR + 上一帧 10x6 大格局部对比
  * 4 连通块域 CCL，面积/长宽/贴边筛选，贴球拆分
  * a-b 预测 + 贪心 NN（GATE）+ 丢失删轨（MISS_K）
  * 计数规则 exit / death / combined
只把 PC 风格的 "IDn / COUNT=" 注释换成 M9 cv_top 的 OSD 风格：
绿色 2px 框 + 5x7 白色 ID + 左上 4 位 hex Count。

用法：
    python test/fpga_cv_sim/blkdet_sim.py                     # exit 计数
    python test/fpga_cv_sim/blkdet_sim.py --count-rule combined
    python test/fpga_cv_sim/blkdet_sim.py --dark 100 --amin 14 --gate 240

注意：cv_blkdet 的 RTL 不在本仓库（只有 Python/PYTHON2 的仿真），
      所以本视频是"该算法在 PC 上的识别结果"，不是 M9 bit 的逐周期输出。
"""
from __future__ import annotations

import argparse
import os
import sys
import time

import numpy as np
import cv2

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
from fpga_cv_sim import VideoSink, draw_digit  # noqa: E402

ALPHA = 0.5
BETA = 0.0625
MARGIN = 20
REC = 2                    # 丢失 <= REC 帧的轨迹才画
CB_DELTA = 20
PAIR_ASPECT = 150
PAIR_MINAREA = 24
EXIT_MISS = 10
MIN_HITS_EX = 4
MIN_HITS_DT = 5


def detect(frame, dark, bg=None, amin=14):
    """块域暗块检测 → [(cx, cy, x0, y0, x1, y1), ...]（像素坐标）。"""
    B = frame[:, :, 0].astype(np.uint16)
    G = frame[:, :, 1].astype(np.uint16)
    R = frame[:, :, 2].astype(np.uint16)
    wy = ((R >> 2) + (G >> 1) + (B >> 2)).astype(np.float32)
    bm = cv2.resize(wy, (80, 45), interpolation=cv2.INTER_AREA)
    if bg is None:
        m = (bm < dark).astype(np.uint8)
    else:
        m = ((bm < dark) & (bm < bg - CB_DELTA)).astype(np.uint8)
    n, _lab, stats, cent = cv2.connectedComponentsWithStats(m, 4)
    out = []
    for i in range(1, n):
        x, y, w, h, a = stats[i]
        if a < amin or a > 400:
            continue
        if w > 16 or h > 16:
            continue
        if a * 100 < 30 * w * h:
            continue
        if min(w, h) * 100 < 30 * max(w, h):
            continue
        xl, xr, yt, yb = (x == 0), ((x + w) >= 80), (y == 0), ((y + h) >= 45)
        if xl or yt:
            continue
        if (xl and yt) or (xr and yt) or (xl and yb) or (xr and yb):
            continue
        if PAIR_MINAREA and a >= PAIR_MINAREA and max(w, h) * 100 >= PAIR_ASPECT * min(w, h):
            # 两颗贴在一起（细长团块）→ 沿长边拆成两个
            if h >= w:
                my = (y + (y + h)) // 2
                out.append((x * 16 + w * 8, y * 16 + h * 4, x * 16, y * 16,
                            (x + w) * 16, my * 16))
                out.append((x * 16 + w * 8, my * 16 + h * 4, x * 16, my * 16,
                            (x + w) * 16, (y + h) * 16))
            else:
                mx = (x + (x + w)) // 2
                out.append((x * 16 + w * 4, y * 16 + h * 8, x * 16, y * 16,
                            mx * 16, (y + h) * 16))
                out.append((mx * 16 + w * 4, y * 16 + h * 8, mx * 16, y * 16,
                            (x + w) * 16, (y + h) * 16))
        else:
            out.append((cent[i][0] * 16, cent[i][1] * 16, x * 16, y * 16,
                        (x + w) * 16, (y + h) * 16))
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description="块域检测管线 + FPGA 风格 OSD 视频仿真")
    ap.add_argument("video", nargs="?", default=os.path.join(_HERE, "..", "video_20261020_183037.mp4"))
    ap.add_argument("-o", "--out", default=None)
    ap.add_argument("--gate", type=int, default=240)
    ap.add_argument("--miss-k", type=int, default=35)
    ap.add_argument("--dark", type=int, default=120)
    ap.add_argument("--amin", type=int, default=14)
    ap.add_argument("--count-rule", choices=["exit", "death", "combined"], default="exit")
    ap.add_argument("--start", type=int, default=0)
    ap.add_argument("--end", type=int, default=-1)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    src = os.path.abspath(args.video)
    if not os.path.isfile(src):
        print("input not found:", src, file=sys.stderr)
        return 2
    base = os.path.splitext(os.path.basename(src))[0]
    outdir = os.path.join(_HERE, "out")
    os.makedirs(outdir, exist_ok=True)
    out_path = args.out or os.path.join(
        outdir, f"{base}_blkdet_{args.count_rule}.mp4")

    cap = cv2.VideoCapture(src)
    if not cap.isOpened():
        print("cannot open video:", src, file=sys.stderr)
        return 2
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = cap.get(cv2.CAP_PROP_FPS) or 60.0
    n_total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    end = n_total if args.end < 0 else min(args.end, n_total)

    sink = VideoSink(out_path, fps, w, h, codec="auto", crf=24)
    tracks = []
    next_id = 1
    count = 0
    prev_cells = None
    nf = 0
    frames_used = 0
    t0 = time.time()
    events = []

    while True:
        ok, fr = cap.read()
        if not ok or nf >= end:
            break
        if nf < args.start:
            nf += 1
            continue
        nf += 1
        frames_used += 1

        # 局部背景：上一帧 10x6 大格均值
        Bf = fr[:, :, 0].astype(np.uint16)
        Gf = fr[:, :, 1].astype(np.uint16)
        Rf = fr[:, :, 2].astype(np.uint16)
        bmf = cv2.resize(((Rf >> 2) + (Gf >> 1) + (Bf >> 2)).astype(np.float32),
                         (80, 45), interpolation=cv2.INTER_AREA)
        cells = cv2.resize(bmf, (10, 6), interpolation=cv2.INTER_AREA)
        if prev_cells is None:
            prev_cells = cells
        bg = cv2.resize(prev_cells, (80, 45), interpolation=cv2.INTER_NEAREST)
        dets = detect(fr, args.dark, bg, args.amin)
        prev_cells = cells

        # 跟踪（与 cv_pipeline_sim.py 相同顺序）
        taken = [False] * len(dets)
        assigns = [-1] * len(tracks)
        for ti, t in enumerate(tracks):
            px, py = t[0] + t[2], t[1] + t[3]
            best, bd = -1, args.gate
            for j, d in enumerate(dets):
                if taken[j]:
                    continue
                dist = abs(d[0] - px) + abs(d[1] - py)
                if dist < bd:
                    bd = dist
                    best = j
            if best >= 0:
                taken[best] = True
                assigns[ti] = best
        for ti, t in enumerate(tracks):
            if assigns[ti] >= 0:
                d = dets[assigns[ti]]
                dx, dy = d[0] - t[0], d[1] - t[1]
                t[2] += BETA * dx
                t[3] += BETA * dy
                t[0] += t[2] + ALPHA * dx
                t[1] += t[3] + ALPHA * dy
                t[4] = 0
                t[5] += 1
                t[6] = d[2:6]
            else:
                t[0] += t[2]
                t[1] += t[3]
                t[4] += 1
        for j, d in enumerate(dets):
            if not taken[j]:
                tracks.append([d[0], d[1], 0.0, 0.0, 0, 1, d[2:6], False, next_id])
                next_id += 1

        # exit 计数
        if args.count_rule in ("exit", "combined"):
            for t in tracks:
                if (not t[7]) and t[5] >= MIN_HITS_EX and t[4] <= EXIT_MISS and (
                        t[0] < -MARGIN or t[0] > w + MARGIN or
                        t[1] < -MARGIN or t[1] > h + MARGIN):
                    t[7] = True
                    count += 1
                    events.append((nf, count))

        # 删除 / death 补计
        alive = []
        for t in tracks:
            if t[4] > args.miss_k:
                if args.count_rule == "death" or (
                        args.count_rule == "combined" and (not t[7]) and t[5] >= MIN_HITS_DT):
                    t[7] = True
                    count += 1
                    events.append((nf, count))
            else:
                alive.append(t)
        tracks = alive

        # OSD：绿框 + 白色 5x7 ID（M9 cv_top 风格）
        for t in tracks:
            if t[4] > REC:
                continue
            b = t[6]
            x0, y0, x1, y1 = int(b[0]), int(b[1]), int(b[2]), int(b[3])
            x0 = max(0, min(w - 1, x0)); x1 = max(0, min(w - 1, x1))
            y0 = max(0, min(h - 1, y0)); y1 = max(0, min(h - 1, y1))
            if x0 >= x1 or y0 >= y1:
                continue
            cv2.rectangle(fr, (x0, y0), (x1, y1), (0, 255, 0), 2)
            draw_digit(fr, t[8] & 0xF, x0, y0)

        # Count：左上 (24,56)，4 位 hex
        for k in range(4):
            draw_digit(fr, (count >> (12 - 4 * k)) & 0xF, 24 + 8 * k, 56)

        sink.write(fr)
        if not args.quiet and frames_used % 120 == 0:
            el = time.time() - t0
            print(f"  frame {nf:4d} tracks={len(tracks):2d} count={count:3d} [{frames_used/el:.1f} fps]")

    cap.release()
    sink.close()
    if not args.quiet:
        print(f"done: {frames_used} frames, COUNT={count}, ids={next_id-1}, "
              f"rule={args.count_rule}, out={out_path}")
        print("count events:", [e[0] for e in events])
    return 0


if __name__ == "__main__":
    sys.exit(main())
