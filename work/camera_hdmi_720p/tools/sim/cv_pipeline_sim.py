# -*- coding: utf-8 -*-
"""
cv_pipeline_sim.py — 当前 FPGA 检测/跟踪/计数管线的离线视频仿真（与 RTL 同参）
================================================================================
复刻当前 bit 的 CV 逻辑，用于在没有摄像头时对**录像**做验证：
  * 检测：块域(16x16)暗块  —— 对应 rtl/cv/cv_blkdet.v（DARK_THR 阈值 + 形状筛选）
  * 跟踪：cv_top 的 a-b 预测 + 贪心最近邻(GATE) + 丢失删轨(MISS_K)
  * 计数：轨迹消亡 +1 —— 对应 cv_top.O_count（可换成"出画面即计数"，见 --count-rule）

用法:
  python cv_pipeline_sim.py <video> <out.mp4> [GATE MISS_K DARK MIN_HITS] [--count-rule death|exit]

注意:
  * DARK_THR 与场景强相关（较亮场景要用更大的 DARK_THR）；上板可用 K3/K4 调偏置。
  * 块域判别与 RTL 用 4 连通近似；结果与 iverilog 集成仿真一致（钢珠5 frame200 检出 3 球）。
"""
import argparse
import cv2
import numpy as np

ALPHA = 0.5        # a-b 位置增益(≈cv_top ALPHA_Q/256)
BETA = 0.0625      # a-b 速度增益；原 0.1875 在 30fps(帧间位移大)下会让轨迹"跑飞"->重建轨->多计
MARGIN = 20        # exit 计数：预测位置超出画面 + MARGIN 视为"离开"
REC    = 2         # 只有"丢失 <= REC"帧的轨迹才画/才按 exit 计数(滑行幻影不画不计)


CB_DELTA = 20      # 局部对比：块均值须低于其大格背景这么多
AMIN = 8           # 连通域最小面积(块数)；与 cv_blkdet 的 MIN_BLKN 对应
PAIR_ASPECT = 150  # 长/短边比 >= 150% 判为"两颗贴在一起"
PAIR_MINAREA = 24  # 且面积 >= 这么多块


def detect(frame, dark, bg=None):
    """块域暗块检测 -> 检测框[像素(x,y,w,h)]列表（与 cv_blkdet 同参）。
    bg!=None 时用局部对比（块均值 < 大格背景 - CB_DELTA）。"""
    B = frame[:, :, 0].astype(np.uint16)
    G = frame[:, :, 1].astype(np.uint16)
    R = frame[:, :, 2].astype(np.uint16)
    wy = ((R >> 2) + (G >> 1) + (B >> 2)).astype(np.float32)
    bm = cv2.resize(wy, (80, 45), interpolation=cv2.INTER_AREA)  # 16x16 块均值
    if bg is None:
        m = (bm < dark).astype(np.uint8)
    else:
        m = ((bm < dark) & (bm < bg - CB_DELTA)).astype(np.uint8)
    n, lab, stats, cent = cv2.connectedComponentsWithStats(m, 4)
    out = []
    for i in range(1, n):
        x, y, w, h, a = stats[i]
        if a < AMIN or a > 400: continue
        if w > 16 or h > 16: continue                  # 剔除过宽/过高块(球~7块; 桌沿/长条几十块)
        if a * 100 < 30 * w * h: continue            # 填充率 >= 30%(容许运动模糊)
        if min(w, h) * 100 < 30 * max(w, h): continue # 长短比 >= 30%
        xl, xr, yt, yb = (x == 0), ((x + w) >= 80), (y == 0), ((y + h) >= 45)
        if xl or yt: continue                         # 左/上边(与 cv_blkdet 一致)
        if (xl and yt) or (xr and yt) or (xl and yb) or (xr and yb): continue  # 贴角
        if PAIR_MINAREA and a >= PAIR_MINAREA and max(w, h) * 100 >= PAIR_ASPECT * min(w, h):
            # 两颗贴在一起(细长团块) -> 沿长边拆成两个检测
            if h >= w:
                my = (y + (y + h)) // 2
                out.append((x * 16 + w * 8, y * 16 + h * 4, x * 16, y * 16, (x + w) * 16, my * 16))
                out.append((x * 16 + w * 8, my * 16 + h * 4, x * 16, my * 16, (x + w) * 16, (y + h) * 16))
            else:
                mx = (x + (x + w)) // 2
                out.append((x * 16 + w * 4, y * 16 + h * 8, x * 16, y * 16, mx * 16, (y + h) * 16))
                out.append((mx * 16 + w * 4, y * 16 + h * 8, mx * 16, y * 16, (x + w) * 16, (y + h) * 16))
        else:
            out.append((cent[i][0] * 16, cent[i][1] * 16, x * 16, y * 16, (x + w) * 16, (y + h) * 16))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("out")
    ap.add_argument("gate", type=int, nargs="?", default=240)
    ap.add_argument("miss_k", type=int, nargs="?", default=20)
    ap.add_argument("dark", type=int, nargs="?", default=100)
    ap.add_argument("min_hits", type=int, nargs="?", default=1)
    ap.add_argument("--count-rule", choices=["death", "exit", "combined"], default="combined")
    ap.add_argument("--amin", type=int, default=8)
    args = ap.parse_args()
    global AMIN
    AMIN = args.amin

    cap = cv2.VideoCapture(args.video)
    W = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)); H = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = cap.get(cv2.CAP_PROP_FPS) or 60
    vw = cv2.VideoWriter(args.out, cv2.VideoWriter_fourcc(*"mp4v"), fps, (W, H))

    tracks = []   # [cx,cy,vx,vy,missed,hits,box,counted]
    next_id = 0; count = 0; nf = 0; events = []
    prev_cells = None
    while True:
        ok, fr = cap.read()
        if not ok: break
        nf += 1
        # 上一帧大格(10x6, 每格 8x8 块)均值当局部背景
        Bf = fr[:, :, 0].astype(np.uint16); Gf = fr[:, :, 1].astype(np.uint16); Rf = fr[:, :, 2].astype(np.uint16)
        bmf = cv2.resize(((Rf >> 2) + (Gf >> 1) + (Bf >> 2)).astype(np.float32), (80, 45), interpolation=cv2.INTER_AREA)
        cells = cv2.resize(bmf, (10, 6), interpolation=cv2.INTER_AREA)
        if prev_cells is None: prev_cells = cells
        bg = cv2.resize(prev_cells, (80, 45), interpolation=cv2.INTER_NEAREST)
        dets = detect(fr, args.dark, bg)
        prev_cells = cells
        taken = [False] * len(dets); assigns = [-1] * len(tracks)
        for ti, t in enumerate(tracks):
            px, py = t[0] + t[2], t[1] + t[3]
            best = -1; bd = args.gate
            for j, d in enumerate(dets):
                if taken[j]: continue
                dd = abs(d[0] - px) + abs(d[1] - py)
                if dd < bd: bd = dd; best = j
            if best >= 0: taken[best] = True; assigns[ti] = best
        for ti, t in enumerate(tracks):
            if assigns[ti] >= 0:
                d = dets[assigns[ti]]; dx = d[0] - t[0]; dy = d[1] - t[1]
                t[2] += BETA * dx; t[3] += BETA * dy
                t[0] += t[2] + ALPHA * dx; t[1] += t[3] + ALPHA * dy
                t[4] = 0; t[5] += 1; t[6] = d[2:6]
            else:
                t[0] += t[2]; t[1] += t[3]; t[4] += 1
        for j, d in enumerate(dets):
            if not taken[j]:
                tracks.append([d[0], d[1], 0, 0, 0, 1, d[2:6], False, next_id]); next_id += 1
        # 出画面即时计数（exit / combined）
        for t in tracks:
            if args.count_rule in ("exit", "combined") and (not t[7]) and t[5] >= args.min_hits and \
               t[4] <= REC and \
               (t[0] < -MARGIN or t[0] > W + MARGIN or t[1] < -MARGIN or t[1] > H + MARGIN):
                t[7] = True; count += 1; events.append((nf, count))
        alive = []
        for t in tracks:
            if t[4] > args.miss_k:
                if args.count_rule == "death" or \
                   (args.count_rule == "combined" and (not t[7]) and t[5] >= args.min_hits):
                    t[7] = True; count += 1; events.append((nf, count))   # 消亡补计(去重)
            else:
                alive.append(t)
        tracks = alive
        for t in tracks:
            if t[4] > REC: continue          # 纯预测滑行的不画
            b = t[6]
            cv2.rectangle(fr, (int(b[0]), int(b[1])), (int(b[2]), int(b[3])), (0, 255, 0), 2)
            cv2.putText(fr, "ID%d" % t[8], (int(b[0]), max(12, int(b[1]) - 4)),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 2)
        cv2.putText(fr, "COUNT=%d frames=%d" % (count, nf), (10, 32),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 128, 255), 2)
        vw.write(fr)
    vw.release()
    print("video=%s frames=%d GATE=%d MISS_K=%d DARK=%d MIN_HITS=%d rule=%s -> COUNT=%d ids=%d"
          % (args.video, nf, args.gate, args.miss_k, args.dark, args.min_hits, args.count_rule, count, next_id))
    print("COUNT increments at frames:", [e[0] for e in events])


if __name__ == "__main__":
    main()
