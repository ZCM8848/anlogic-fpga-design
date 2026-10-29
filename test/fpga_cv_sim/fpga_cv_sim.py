#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fpga_cv_sim.py — 用当前 RTL/固件复刻 M9 的 FPGA CV 输出（离线视频仿真）
================================================================================

模型来源（与仓库代码逐条对应）：

  1) rtl/cv/cv_top.v
     - 亮度  : w_y = {2'b0,R[7:2]} + {1'b0,G[7:1]} + {2'b0,B[7:2]}
     - Sobel : 3x3（top=y-2 / mid=y-1 / bot=y，输出中心在 (x-1,y-1)）
     - 阈值  : MASK_SRC=1 → EDGE_THR(default 80) + r_user_off；比较为严格 >
     - run   : 每行连续 mask 段，按 raster 序写 run_mem，最多 MAX_RUNS=1024
               （忠实复刻两处 RTL 边界行为：x=1279 的 row_last 分支会丢掉
                 该像素；只有 x=1279 单点起的 run 会跨行/在 vsync 以 y=720 落盘）
     - 叠加  : MASK_VIEW=1 → 输出黑白机器视角；绿框 FBOX_W=2；5x7 ID；
               左上 (24,56) 4 位 hex Count

  2) mcu_fw/main.c（MCU 每帧 vsync 后跑一次）
     - run_mem 只读前 1024 条（RUN 恒 1024 = 溢出）
     - union-find CCL（MAX_LABELS=64，MAX_PREV=128）
     - 形状筛选：面积 8..20000 / 填充率>=15% / 长短比>=25% / 去贴边 4px
     - a-b 跟踪（GATE=240, ALPHA=0.5, BETA=0.0625, MISS_K=20）
     - exit / death 计数，overlay 只画 confirmed 且 missed<=2 的轨迹（最多 8）

  3) 时序关系
     - 第 k 帧的 run 在 vsync 后由 MCU 处理，overlay/count 从第 k+1 帧开始生效
       （--latency 1，默认；--latency 0 可关闭该帧延迟便于对照）

输出：1280x720 / 输入同帧率 mp4（默认机器视角 + 叠加），以及每帧 stats.csv。

用法：
    python fpga_cv_sim.py
    python fpga_cv_sim.py ..\\video_20261020_183037.mp4 --thr 80
    python fpga_cv_sim.py --view image --latency 0
    python fpga_cv_sim.py --selftest

注意：
  - 本模型不模拟 DDR2/HDMI 时序、ISP、跨时钟域，也不模拟 MCU 处理耗时；
    输入视频被当作 cv_top 看到的 1280x720 RGB 像素流。
  - 默认 EDGE_THR=80（仓库参数）。上板记录里串口曾显示 TH=50；可用 --thr 50
    复现，但注意当前 cv_top 的 r_user_off 是高 8 位无符号相加，负偏置会置
    eff_thr=0（见 README 的说明），所以 50 只能通过直接改参数得到。
"""

from __future__ import annotations

import argparse
import csv
import os
import random
import shutil
import subprocess
import sys
import time

import numpy as np

# ---------------------------------------------------------------------------
# 参数（与 cv_top #(...) / main.c #define 一一对应）
# ---------------------------------------------------------------------------


class Cfg:
    img_w = 1280
    img_h = 720

    # cv_top
    edge_thr = 80          # EDGE_THR
    mask_src = 1           # 1=Sobel, 0=亮度阈值（Otsu midpoint）
    max_runs = 1024        # MAX_RUNS
    mask_view = 1          # 1=机器视角（黑白 mask）
    fbox_w = 2             # FBOX_W

    # mcu_fw/main.c
    max_labels = 64
    max_prev = 128
    max_det = 8
    max_trk = 8
    min_area = 8
    max_area = 20000
    min_fill = 15
    min_ratio = 25
    edge_mg = 4
    alpha_q = 128
    beta_q = 16
    gate = 240
    miss_k = 20
    min_hits_ex = 4
    min_hits_dt = 5
    exit_miss = 10
    margin = 20


CFG = Cfg()

# 5x7 字模（与 cv_top.v f_digit 完全一致；bit4 = 最左列）
DIGITS = [
    [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110],  # 0
    [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],  # 1
    [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111],  # 2
    [0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110],  # 3
    [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010],  # 4
    [0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110],  # 5
    [0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110],  # 6
    [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000],  # 7
    [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110],  # 8
    [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b11100],  # 9
    [0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],  # A
    [0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110],  # B
    [0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110],  # C
    [0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110],  # D
    [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111],  # E
    [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000],  # F
]


# ---------------------------------------------------------------------------
# cv_top 像素前端
# ---------------------------------------------------------------------------


def luma(bgr: np.ndarray) -> np.ndarray:
    """cv_top.v: w_y = R[7:2] + G[7:1] + B[7:2]（注意不是标准灰度！）"""
    b = bgr[:, :, 0].astype(np.int32)
    g = bgr[:, :, 1].astype(np.int32)
    r = bgr[:, :, 2].astype(np.int32)
    return (r >> 2) + (g >> 1) + (b >> 2)


def sobel_mag(y: np.ndarray) -> np.ndarray:
    """复刻 cv_top 的 3x3 Sobel 窗口与流水延迟。

    输出对应当前扫描像素 (x,y)：窗口为
        rows  y-2, y-1, y   ×   cols x-2, x-1, x
    但 |gx|/|gy| 的组合只用到 top/bot 行与左/右列（标准 Sobel 核），
    中心实际在 (x-1, y-1)，与 RTL 一致（run 仍按扫描坐标 (x,y) 存储）。
    """
    h, w = y.shape
    mag = np.zeros((h, w), np.int32)
    top = y[:-2]          # 行 y-2
    mid = y[1:-1]         # 行 y-1
    bot = y[2:]           # 行 y
    tl, tc, tr = top[:, :-2], top[:, 1:-1], top[:, 2:]
    ml = mid[:, :-2]
    mr = mid[:, 2:]
    bl, bc, br = bot[:, :-2], bot[:, 1:-1], bot[:, 2:]

    # gx（RTL 命名）= top 行加权 - bot 行加权
    vert = np.abs((tl + 2 * tc + tr) - (bl + 2 * bc + br))
    # gy（RTL 命名）= 左列加权 - 右列加权
    horiz = np.abs((tl + 2 * ml + bl) - (tr + 2 * mr + br))
    mag[2:, 2:] = vert + horiz
    return mag


def frontend_mask(bgr: np.ndarray, thr_eff: int) -> np.ndarray:
    y = luma(bgr)
    if CFG.mask_src:
        return sobel_mag(y) > thr_eff
    return y > thr_eff


def _emit(out, item, max_runs):
    """返回 True 表示已溢出（RTL 里 r_run_overflow 置 1）。"""
    if len(out) < max_runs:
        out.append(item)
        return False
    return True


def extract_runs(mask: np.ndarray, max_runs: int = None):
    """逐像素复刻 cv_top 的 run 提取（含 x=1279 / 跨行 / vsync 的 RTL 边界行为）。

    返回 (runs, overflow)。runs 只保留前 max_runs 条（MCU 也只读这么多），
    因此一旦确定溢出即可停止扫描——后续写入不会改变 run_mem[0:1024]。
    """
    if max_runs is None:
        max_runs = CFG.max_runs
    h, w = mask.shape
    out = []
    overflow = False

    # 一次性算出行内连续 True 段（避免逐像素 Python 循环）
    pad = np.zeros((h, w + 2), np.int8)
    pad[:, 1:w + 1] = mask
    d = np.diff(pad, axis=1)
    start_y, starts_all = np.nonzero(d == 1)
    end_y, ends_all = np.nonzero(d == -1)
    ends_all = ends_all - 1          # d 的 -1 下标 = 结束列 + 1

    p = 0
    act = False
    xs = xe = 0

    for y in range(h):
        q = p
        while q < len(start_y) and start_y[q] == y:
            q += 1

        i = p
        # 上一行 x=1279 起的 run 会跨到本行（RTL 的 act 不跨行清零）
        if act:
            if i < q and starts_all[i] == 0:
                e = int(ends_all[i])
                if e == w - 1:
                    # row_last 分支：写入的是「本像素之前」的 xe（= w-2）
                    overflow |= _emit(out, (y, xs, e - 1), max_runs)
                    if overflow:
                        return out, True
                else:
                    overflow |= _emit(out, (y, xs, e), max_runs)
                    if overflow:
                        return out, True
                act = False
                i += 1
            else:
                # 本行 x=0 无 mask → 在 x=0 关闭跨行 run（y 用本行）
                overflow |= _emit(out, (y, xs, xe), max_runs)
                if overflow:
                    return out, True
                act = False

        # 本行剩余段
        while i < q:
            s = int(starts_all[i])
            e = int(ends_all[i])
            i += 1
            if e == w - 1:
                if s == w - 1:
                    # 单点起于最后一个像素：不关闭，带到下一行 / vsync
                    act = True
                    xs = s
                    xe = e
                else:
                    # row_last 丢掉 x=1279
                    overflow |= _emit(out, (y, s, w - 2), max_runs)
                    if overflow:
                        return out, True
            else:
                overflow |= _emit(out, (y, s, e), max_runs)
                if overflow:
                    return out, True
        p = q

    # vsync：还挂着一条 run（只可能起于最后一行 x=1279）
    if act:
        # RTL 在最后一行 row_last 把 r_y 加到 720，vsync 写入 y=720
        overflow |= _emit(out, (h, xs, xe), max_runs)
    return out, overflow


def literal_runs(mask: np.ndarray, max_runs: int = 100000):
    """逐像素直译 RTL（仅用于 --selftest 对拍，慢）。"""
    h, w = mask.shape
    out = []
    act = False
    xs = xe = 0
    for y in range(h):
        for x in range(w):
            row_last = (x == w - 1)
            if row_last and act:
                if len(out) < max_runs:
                    out.append((y, xs, xe))
                act = False
            else:
                if mask[y, x]:
                    if not act:
                        act = True
                        xs = x
                        xe = x
                    else:
                        xe = x
                elif act:
                    if len(out) < max_runs:
                        out.append((y, xs, xe))
                    act = False
    if act and len(out) < max_runs:
        out.append((h, xs, xe))
    return out


# ---------------------------------------------------------------------------
# MCU 固件（main.c）
# ---------------------------------------------------------------------------


class Mcu:
    def __init__(self):
        self.count = 0
        self.next_id = 0
        self.trk = [None] * CFG.max_trk

    # ---- CCL + 形状筛选（ccl_init / ccl_step / ccl_finalize） ----
    def _ccl(self, runs):
        C = CFG
        W, H, L = C.img_w, C.img_h, C.max_labels
        valid = [False] * L
        area = [0] * L
        x0 = [W] * L
        x1 = [0] * L
        y0 = [H] * L
        y1 = [0] * L
        sx = [0] * L
        sy = [0] * L
        parent = list(range(L))
        next_label = 0
        prev = []
        cur = []
        prev_y = -1

        def find(a):
            while parent[a] != a:
                parent[a] = parent[parent[a]]
                a = parent[a]
            return a

        for (y, rxs, rxe) in runs:
            if y != prev_y:
                if y > prev_y + 1:
                    prev = []
                else:
                    prev = cur[:]
                cur = []
                prev_y = y

            found = -1
            for (pxs, pxe, pl) in prev:
                if pxs <= rxe and pxe >= rxs:
                    r = find(pl)
                    if found < 0:
                        found = r
                    else:
                        a = find(found)
                        if a != r:
                            parent[r] = a

            if found < 0:
                if next_label < L:
                    lbl = next_label
                    parent[next_label] = next_label
                    next_label += 1
                else:
                    lbl = L - 1          # 饱和到最后一个 label
            else:
                lbl = find(found)

            seg = rxe - rxs + 1
            valid[lbl] = True
            area[lbl] += seg
            if rxs < x0[lbl]:
                x0[lbl] = rxs
            if rxe > x1[lbl]:
                x1[lbl] = rxe
            if y < y0[lbl]:
                y0[lbl] = y
            if y > y1[lbl]:
                y1[lbl] = y
            sx[lbl] += (rxs + rxe) * seg // 2
            sy[lbl] += y * seg
            if len(cur) < C.max_prev:
                cur.append((rxs, rxe, lbl))

        # ccl_finalize：把非根 label 合并到根
        for i in range(next_label):
            if not valid[i]:
                continue
            root = find(i)
            if root != i:
                valid[root] = True
                area[root] += area[i]
                if x0[i] < x0[root]:
                    x0[root] = x0[i]
                if x1[i] > x1[root]:
                    x1[root] = x1[i]
                if y0[i] < y0[root]:
                    y0[root] = y0[i]
                if y1[i] > y1[root]:
                    y1[root] = y1[i]
                sx[root] += sx[i]
                sy[root] += sy[i]
                valid[i] = False

        # 形状筛选 → det
        det = []
        for i in range(next_label):
            if not valid[i]:
                continue
            a = area[i]
            w = x1[i] - x0[i] + 1
            h = y1[i] - y0[i] + 1
            mn = w if w < h else h
            mx = h if w < h else w
            ok = True
            if a < C.min_area or a > C.max_area:
                ok = False
            elif a * 100 < C.min_fill * w * h:
                ok = False
            elif mn * 100 < C.min_ratio * mx:
                ok = False
            elif (x0[i] < C.edge_mg or y0[i] < C.edge_mg or
                  x1[i] >= W - C.edge_mg or y1[i] >= H - C.edge_mg):
                ok = False
            if ok and len(det) < C.max_det:
                det.append({
                    "cx": sx[i] // a,
                    "cy": sy[i] // a,
                    "x0": x0[i], "y0": y0[i],
                    "x1": x1[i], "y1": y1[i],
                })
        return det, next_label

    # ---- a-b 跟踪 + exit/death 计数（track_update） ----
    def _track(self, det):
        C = CFG
        assigned = [False] * C.max_det
        asg = [-1] * C.max_trk

        for i in range(C.max_trk):
            t = self.trk[i]
            if t is None:
                continue
            px = t["cx"] + t["vx"]
            py = t["cy"] + t["vy"]
            best = -1
            bd = C.gate
            for j, d in enumerate(det):
                if assigned[j]:
                    continue
                dist = abs(d["cx"] - px) + abs(d["cy"] - py)
                if dist < bd:
                    bd = dist
                    best = j
            if best >= 0:
                assigned[best] = True
                asg[i] = best

        for i in range(C.max_trk):
            t = self.trk[i]
            if t is None:
                continue
            j = asg[i]
            if j >= 0:
                d = det[j]
                dx = d["cx"] - t["cx"]
                dy = d["cy"] - t["cy"]
                t["vx"] += (C.beta_q * dx) >> 8
                t["vy"] += (C.beta_q * dy) >> 8
                t["cx"] += t["vx"] + ((C.alpha_q * dx) >> 8)
                t["cy"] += t["vy"] + ((C.alpha_q * dy) >> 8)
                t["missed"] = 0
                t["hits"] += 1
                t["x0"], t["y0"], t["x1"], t["y1"] = d["x0"], d["y0"], d["x1"], d["y1"]
                if t["hits"] >= C.min_hits_ex:
                    t["confirmed"] = True
            else:
                t["cx"] += t["vx"]
                t["cy"] += t["vy"]
                t["missed"] += 1

            # exit：出画面计数
            if (t["confirmed"] and not t["counted"] and
                    t["hits"] >= C.min_hits_ex and t["missed"] <= C.exit_miss and
                    (t["cx"] < -C.margin or t["cx"] > C.img_w + C.margin or
                     t["cy"] < -C.margin or t["cy"] > C.img_h + C.margin)):
                t["counted"] = True
                self.count += 1

            # 删除：超时消亡补计
            if t["missed"] > C.miss_k:
                if not t["counted"] and t["hits"] >= C.min_hits_dt:
                    t["counted"] = True
                    self.count += 1
                self.trk[i] = None

        # 新建轨迹（未占用的 det → 空槽）
        for j, d in enumerate(det):
            if assigned[j]:
                continue
            for i in range(C.max_trk):
                if self.trk[i] is None:
                    self.trk[i] = {
                        "id": self.next_id,
                        "cx": d["cx"], "cy": d["cy"],
                        "vx": 0, "vy": 0,
                        "missed": 0, "hits": 1,
                        "confirmed": False, "counted": False,
                        "x0": d["x0"], "y0": d["y0"], "x1": d["x1"], "y1": d["y1"],
                    }
                    self.next_id += 1
                    break

    def step(self, runs):
        det, n_labels = self._ccl(runs)
        self._track(det)
        overlay = []
        for t in self.trk:                    # 槽位顺序 = write_overlay 顺序
            if t is None or not t["confirmed"] or t["missed"] > 2:
                continue
            overlay.append((t["id"] & 0xF, t["x0"], t["y0"], t["x1"], t["y1"]))
            if len(overlay) >= 8:
                break
        n_trk = sum(1 for t in self.trk if t is not None)
        return overlay, self.count, {
            "n_labels": n_labels,
            "n_det": len(det),
            "n_trk": n_trk,
            "n_overlay": len(overlay),
        }


# ---------------------------------------------------------------------------
# 叠加渲染（cv_top 的组合逻辑）
# ---------------------------------------------------------------------------


def draw_digit(img, nib, x, y):
    """5x7 白色字模；bit4 = 最左列。"""
    glyph = DIGITS[nib & 0xF]
    h, w = img.shape[:2]
    for row in range(7):
        bits = glyph[row]
        yy = y + row
        if yy < 0 or yy >= h:
            continue
        for col in range(5):
            if bits & (1 << (4 - col)):
                xx = x + col
                if 0 <= xx < w:
                    img[yy, xx] = (255, 255, 255)


def render(frame_bgr, mask, overlay, count):
    """MASK_VIEW=1：黑白 mask；绿框 2px；白 ID；左上 4 位 hex Count。"""
    h, w = mask.shape
    if CFG.mask_view:
        img = np.repeat((mask.astype(np.uint8) * 255)[:, :, None], 3, axis=2)
    else:
        img = frame_bgr.copy()

    fw = CFG.fbox_w
    green = (0, 255, 0)                        # BGR
    for (_tid, x0, y0, x1, y1) in overlay:
        x0 = max(0, min(w - 1, x0)); x1 = max(0, min(w - 1, x1))
        y0 = max(0, min(h - 1, y0)); y1 = max(0, min(h - 1, y1))
        if x0 > x1 or y0 > y1:
            continue
        # 左/右竖边：x∈[x0,x0+fw-1] / [x1-fw+1,x1]
        img[y0:y1 + 1, x0:min(w, x0 + fw)] = green
        img[y0:y1 + 1, max(0, x1 - fw + 1):x1 + 1] = green
        # 上/下横边：y∈[y0,y0+fw-1] / [y1-fw+1,y1]
        img[y0:min(h, y0 + fw), x0:x1 + 1] = green
        img[max(0, y1 - fw + 1):y1 + 1, x0:x1 + 1] = green
        # ID（左上角，5x7）
        draw_digit(img, _tid, x0, y0)

    # Count：左上 (24,56)，4 位 hex，每位 8px（5 字模 + 3 间隙）
    cx, cy = 24, 56
    for k in range(4):
        nib = (count >> (12 - 4 * k)) & 0xF
        draw_digit(img, nib, cx + 8 * k, cy)
    return img


# ---------------------------------------------------------------------------
# 视频写出：优先 ffmpeg(libx264)，否则退回 OpenCV mp4v
# ---------------------------------------------------------------------------


class VideoSink:
    def __init__(self, path, fps, w, h, codec="auto", crf=26):
        self.proc = None
        self.writer = None
        self.path = path
        if codec in ("auto", "h264"):
            exe = shutil.which("ffmpeg")
            if exe:
                cmd = [exe, "-y", "-loglevel", "error",
                       "-f", "rawvideo", "-pix_fmt", "bgr24",
                       "-s", f"{w}x{h}", "-r", f"{fps}", "-i", "-",
                       "-an", "-c:v", "libx264", "-preset", "veryfast",
                       "-crf", str(crf), "-pix_fmt", "yuv420p",
                       "-movflags", "+faststart", path]
                self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        if self.proc is None:
            import cv2
            fourcc = cv2.VideoWriter_fourcc(*"mp4v")
            self.writer = cv2.VideoWriter(path, fourcc, fps, (w, h))
            if not self.writer.isOpened():
                raise RuntimeError(f"cannot open writer: {path}")

    def write(self, img):
        if self.proc is not None:
            self.proc.stdin.write(np.ascontiguousarray(img, dtype=np.uint8).tobytes())
        else:
            self.writer.write(img)

    def close(self):
        if self.proc is not None:
            self.proc.stdin.close()
            rc = self.proc.wait()
            if rc != 0:
                raise RuntimeError(f"ffmpeg exited with {rc}")
        else:
            self.writer.release()


# ---------------------------------------------------------------------------
# 自检：向量化 run 提取 vs 逐像素直译
# ---------------------------------------------------------------------------


def selftest(rounds=300):
    rng = random.Random(1234)
    for t in range(rounds):
        w = rng.randint(3, 15)
        h = rng.randint(2, 9)
        p = rng.choice([0.05, 0.2, 0.5, 0.8])
        mask = np.array([[rng.random() < p for _ in range(w)] for _ in range(h)], bool)
        maxr = rng.randint(1, 40)
        a, ov_a = extract_runs(mask, maxr)
        b = literal_runs(mask, maxr + 1)
        ov_b = len(b) > maxr
        b = b[:maxr]
        if a != b or ov_a != ov_b:
            print("SELFTEST FAIL round", t, "w,h,maxr", w, h, maxr)
            print(mask.astype(int))
            print("vector:", a, "ov", ov_a)
            print("literal:", b, "ov", ov_b)
            return False
    print(f"selftest: {rounds}/{rounds} PASS")
    return True


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------


def main(argv=None):
    ap = argparse.ArgumentParser(description="M9 FPGA CV 行为级视频仿真")
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("video", nargs="?", default=os.path.join(here, "..", "video_20261020_183037.mp4"))
    ap.add_argument("-o", "--out", default=None, help="输出 mp4（默认 out/<name>_fpga.mp4）")
    ap.add_argument("--thr", type=int, default=CFG.edge_thr,
                    help="有效阈值 eff_thr（默认 80；MASK_SRC=1 时即 EDGE_THR）")
    ap.add_argument("--src", choices=["sobel", "bright"], default="sobel",
                    help="MASK_SRC：sobel(1) / bright(0)")
    ap.add_argument("--view", choices=["mask", "image"], default="mask",
                    help="MASK_VIEW：mask(1)=机器视角 / image(0)=原画")
    ap.add_argument("--latency", type=int, default=1, choices=[0, 1],
                    help="overlay 相对 mask 的帧延迟（RTL=1）")
    ap.add_argument("--preblur", type=int, default=0,
                    help="高斯预模糊核（奇数）。0=RTL 原始；手机录像比 SC520 锐，"
                         "可用 7~9 模拟相机光学低通后再跑同一套 RTL")
    ap.add_argument("--max-runs", type=int, default=CFG.max_runs,
                    help="仿真 RTL 改法时用（默认 1024）")
    ap.add_argument("--max-labels", type=int, default=CFG.max_labels,
                    help="仿真固件改法时用（默认 64）")
    ap.add_argument("--max-det", type=int, default=CFG.max_det,
                    help="仿真固件改法时用（默认 8）")
    ap.add_argument("--start", type=int, default=0, help="起始帧")
    ap.add_argument("--end", type=int, default=-1, help="结束帧（不含）")
    ap.add_argument("--max-frames", type=int, default=-1)
    ap.add_argument("--stats", default=None, help="每帧统计 CSV（默认 out/<name>_stats.csv）")
    ap.add_argument("--codec", choices=["auto", "h264", "mp4v"], default="auto",
                    help="auto=有 ffmpeg 就用 libx264，否则 mp4v")
    ap.add_argument("--crf", type=int, default=26, help="libx264 CRF（越小越清晰/越大文件）")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return 0 if selftest() else 1

    import cv2

    CFG.edge_thr = args.thr
    CFG.mask_src = 1 if args.src == "sobel" else 0
    CFG.mask_view = 1 if args.view == "mask" else 0
    CFG.max_runs = args.max_runs
    CFG.max_labels = args.max_labels
    CFG.max_det = args.max_det
    if args.preblur and args.preblur % 2 == 0:
        print("--preblur must be odd", file=sys.stderr)
        return 2

    src = os.path.abspath(args.video)
    if not os.path.isfile(src):
        print("input not found:", src, file=sys.stderr)
        return 2
    base = os.path.splitext(os.path.basename(src))[0]
    outdir = os.path.join(here, "out")
    os.makedirs(outdir, exist_ok=True)
    tag = ""
    if args.preblur:
        tag += f"_b{args.preblur}"
    if args.max_runs != 1024:
        tag += f"_r{args.max_runs}"
    if args.max_labels != 64:
        tag += f"_l{args.max_labels}"
    out_path = args.out or os.path.join(
        outdir, f"{base}_fpga_th{args.thr}_{args.view}{tag}.mp4")
    stats_path = args.stats or os.path.join(
        outdir, f"{base}_fpga_th{args.thr}_{args.view}{tag}_stats.csv")

    cap = cv2.VideoCapture(src)
    if not cap.isOpened():
        print("cannot open video:", src, file=sys.stderr)
        return 2
    fps = cap.get(cv2.CAP_PROP_FPS)
    if not fps or fps != fps:
        fps = 60.0
    n_total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    end = n_total if args.end < 0 else min(args.end, n_total)
    start = max(0, args.start)
    if args.max_frames > 0:
        end = min(end, start + args.max_frames)

    if not args.quiet:
        print(f"input : {src}")
        print(f"output: {out_path}")
        print(f"stats : {stats_path}")
        print(f"frames: {start}..{end} @ {fps:.3f} fps  thr={args.thr} src={args.src} view={args.view} latency={args.latency}")

    sink = VideoSink(out_path, fps, CFG.img_w, CFG.img_h, codec=args.codec, crf=args.crf)
    mcu = Mcu()
    prev_ov, prev_cnt = [], 0
    t0 = time.time()
    n_done = 0
    sum_runs = 0
    n_ovf = 0

    csv_f = open(stats_path, "w", newline="", encoding="utf-8")
    csv_w = csv.writer(csv_f)
    csv_w.writerow(["frame", "run_cnt", "overflow", "n_labels", "n_det",
                    "n_trk", "n_overlay", "count", "boxes"])

    idx = -1
    while True:
        ok, frame = cap.read()
        idx += 1
        if not ok or idx >= end:
            break
        if idx < start:
            continue
        if frame.shape[1] != CFG.img_w or frame.shape[0] != CFG.img_h:
            frame = cv2.resize(frame, (CFG.img_w, CFG.img_h), interpolation=cv2.INTER_AREA)
        if args.preblur:
            frame = cv2.GaussianBlur(frame, (args.preblur, args.preblur), 0)

        # --- cv_top 前端 ---
        mask = frontend_mask(frame, args.thr)
        runs, overflow = extract_runs(mask, CFG.max_runs)

        # --- MCU：处理上一帧结束时写满的 run_mem ---
        if args.latency:
            ov_draw, cnt_draw = prev_ov, prev_cnt
            new_ov, new_cnt, st = mcu.step(runs)
            prev_ov, prev_cnt = new_ov, new_cnt
        else:
            new_ov, new_cnt, st = mcu.step(runs)
            ov_draw, cnt_draw = new_ov, new_cnt

        # --- 输出显示 ---
        img = render(frame, mask, ov_draw, cnt_draw)
        sink.write(img)

        boxes = ";".join(f"{tid}:{x0},{y0},{x1},{y1}" for tid, x0, y0, x1, y1 in new_ov)
        csv_w.writerow([idx, len(runs), int(overflow), st["n_labels"], st["n_det"],
                        st["n_trk"], st["n_overlay"], new_cnt, boxes])
        n_done += 1
        sum_runs += len(runs)
        n_ovf += int(overflow)

        if not args.quiet and (n_done % 60 == 0):
            el = time.time() - t0
            print(f"  frame {idx:4d}  run={len(runs):4d}{' (overflow)' if overflow else ''} "
                  f"labels={st['n_labels']:2d} det={st['n_det']} trk={st['n_trk']} "
                  f"ov={st['n_overlay']} cnt={new_cnt}  [{n_done/el:.1f} fps]")

    cap.release()
    sink.close()
    csv_f.close()
    if not args.quiet:
        el = time.time() - t0
        print(f"done: {n_done} frames in {el:.1f}s ({n_done/el:.1f} fps), "
              f"avg run={sum_runs/max(1,n_done):.1f}, overflow frames={n_ovf}/{n_done}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
