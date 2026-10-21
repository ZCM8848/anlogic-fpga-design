# -*- coding: utf-8 -*-
"""
cv_pipeline_sim.py — 当前 FPGA 检测/跟踪/计数管线的离线视频仿真（与 RTL 同参）
================================================================================
复刻当前 bit 的 CV 逻辑，用于在没有摄像头时对**录像**做验证：
  * 检测：块域(16x16)暗块 —— 对应 rtl/cv/cv_blkdet.v
          （DARK_THR + 与 5 帧前的块背景比较 + 形状筛选）
  * 跟踪：cv_top 的 a-b 预测 + 贪心最近邻(GATE) + 丢失删轨(MISS_K)
  * 计数：绿框轨迹预测出画面时 +1 —— 对应 cv_top.O_count（不做消亡补计）

用法:
  python cv_pipeline_sim.py <video> <out.mp4> [GATE MISS_K DARK] [--amin N]

注意:
  * 背景取 5 帧前的 80x45 块均值：静止暗块不进掩膜，运动球离开旧位置后必然与背景不同。
  * 形状筛选与 cv_blkdet 同参：MIN_FILL=40%、MIN_RATIO=50%、MIN_BLKN=14、贴球对拆分；
    亮场景(DARK_THR>=130)放宽为 32 块 / 35%，贴球对拆分要求填充率>=60%。
  * 块域判别与 RTL 用 4 连通近似。
"""
import argparse
import cv2
import numpy as np

ALPHA = 0.5            # a-b 位置增益(≈cv_top ALPHA_Q/256)
BETA = 0.1875          # a-b 速度增益(≈cv_top BETA_Q/256)；GATE 配合吸收快球
BG_DELAY = 5           # 块背景取 5 帧前(与 cv_blkdet 的 BG_FRAMES 对应)
REC = 2                # 只有"丢失 <= REC"帧的轨迹才画(滑行幻影不画)

CB_DELTA = 20          # 块均值须比 5 帧前的背景低这么多才判暗
AMIN = 14              # 连通域最小面积(块数)；与 cv_blkdet 的 MIN_BLKN 对应
MFILL = 40             # 填充率下限 %，对应 cv_blkdet 的 MIN_FILL
MFILL_BIG = 35         # 高阈值(亮场景)下宽团块的填充率下限
MRATIO = 50            # 长短边比下限 %，对应 cv_blkdet 的 MIN_RATIO
WIDE_THR = 130         # DARK_THR >= 此值时放宽块宽/高上限(亮场景快球更大)
MIN_HITS_EX = 3        # 窄场景左/右边缘出画面门限；亮场景用 2（并排第二颗命中少）
MIN_HITS_V = 6         # 上/下边缘出画面门限(顶边真球 6；4 次命中的阴影仍被滤掉)
PAIR_ASPECT = 150      # 长/短边比 >= 150% 判为"两颗贴在一起"
PAIR_MINAREA = 24      # 且面积 >= 这么多块
EXIT_MISS = 10         # 出画面计数允许的丢失帧数(与 cv_top EXIT_MISS 对应)


def detect(frame, dark, bg=None):
    """块域暗块检测 -> 检测框[像素(x,y,w,h)]列表（与 cv_blkdet 同参）。
    bg 为 5 帧前的 80x45 块均值；None 表示背景尚未建立。"""
    B = frame[:, :, 0].astype(np.uint16)
    G = frame[:, :, 1].astype(np.uint16)
    R = frame[:, :, 2].astype(np.uint16)
    wy = ((R >> 2) + (G >> 1) + (B >> 2)).astype(np.float32)
    bm = cv2.resize(wy, (80, 45), interpolation=cv2.INTER_AREA)  # 16x16 块均值
    if bg is None:
        return []
    m = ((bm < dark) & (bm < bg - CB_DELTA)).astype(np.uint8)
    wide = dark >= WIDE_THR
    maxwh = 32 if wide else 16
    n, lab, stats, cent = cv2.connectedComponentsWithStats(m, 4)
    out = []
    for i in range(1, n):
        x, y, w, h, a = stats[i]
        if a < AMIN or a > 400: continue
        if w > maxwh or h > maxwh: continue            # 剔除过宽/过高块(球~7块; 桌沿/长条几十块)
        lim = MFILL_BIG if wide else MFILL
        if a * 100 < lim * w * h: continue            # 填充率下限
        if min(w, h) * 100 < MRATIO * max(w, h): continue  # 长短边比下限
        xl, xr, yt, yb = (x == 0), ((x + w) >= 80), (y == 0), ((y + h) >= 45)
        if xl and (not wide or not (w >= 6 and h >= 6 and a * 100 >= 50 * w * h)): continue  # 左边仅亮场景放行紧凑团块
        if yt: continue                               # 上边(与 cv_blkdet 一致)
        if (xl and yt) or (xr and yt) or (xl and yb) or (xr and yb): continue  # 贴角
        big_pair = wide and (w >= 20 or h >= 20) and a >= 100
        if (big_pair or (a >= PAIR_MINAREA and a * 100 >= (60 if wide else 0) * w * h)) and \
                max(w, h) * 100 >= PAIR_ASPECT * min(w, h):
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
    ap.add_argument("gate", type=int, nargs="?", default=320)
    ap.add_argument("miss_k", type=int, nargs="?", default=35)
    ap.add_argument("dark", type=int, nargs="?", default=100)
    ap.add_argument("--amin", type=int, default=14)
    args = ap.parse_args()
    global AMIN
    AMIN = args.amin
    wide = args.dark >= WIDE_THR

    cap = cv2.VideoCapture(args.video)
    W = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)); H = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = cap.get(cv2.CAP_PROP_FPS) or 60
    vw = cv2.VideoWriter(args.out, cv2.VideoWriter_fourcc(*"mp4v"), fps, (W, H))

    tracks = []   # [cx,cy,vx,vy,missed,hits,box,counted,id]
    next_id = 0; count = 0; nf = 0; events = []; recent = []
    hist = []     # 最近 BG_DELAY 帧的 80x45 块均值
    while True:
        ok, fr = cap.read()
        if not ok: break
        nf += 1
        Bf = fr[:, :, 0].astype(np.uint16); Gf = fr[:, :, 1].astype(np.uint16); Rf = fr[:, :, 2].astype(np.uint16)
        bmf = cv2.resize(((Rf >> 2) + (Gf >> 1) + (Bf >> 2)).astype(np.float32), (80, 45), interpolation=cv2.INTER_AREA)
        bg = hist[-BG_DELAY] if len(hist) >= BG_DELAY else None
        dets = detect(fr, args.dark, bg)
        hist.append(bmf)
        if len(hist) > BG_DELAY: hist.pop(0)
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
        # 绿框轨迹预测出画面 -> +1（左右边缘命中≥4；上下边缘需≥8，滤阴影/反光）
        for t in tracks:
            out_x = t[0] < 0 or t[0] >= W
            out_y = t[1] < 0 or t[1] >= H
            need = (2 if wide else MIN_HITS_EX) if out_x else MIN_HITS_V
            if t[1] > 650 and t[0] < 700:
                need = 8   # 底部左侧反光带：阴影/倒影，要求更高命中
            if (not t[7]) and t[5] >= need and t[4] <= EXIT_MISS and (out_x or out_y):
                t[7] = True
                corner = (t[1] < 100 or t[1] > 650)
                dup = corner and any(nf - rf <= 3 and (ry < 100 or ry > 650) and
                                     abs(t[0] - rx) + abs(t[1] - ry) <= 150
                                     for rf, rx, ry in recent)
                short = t[5] <= 3
                dup2 = short and any(nf - rf <= 2 and
                                     abs(t[0] - rx) + abs(t[1] - ry) <= 80
                                     for rf, rx, ry in recent)
                shadow2 = short and t[1] > 550 and any(nf - rf <= 15 and
                                     abs(t[0] - rx) + abs(t[1] - ry) <= 300
                                     for rf, rx, ry in recent)
                dup = dup or dup2 or shadow2
                if not dup:
                    count += 1
                    events.append((nf, count, int(t[0]), int(t[1]), t[5]))
                    recent.append((nf, t[0], t[1]))
                    recent = recent[-8:]
        tracks = [t for t in tracks if t[4] <= args.miss_k]
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
    print("video=%s frames=%d GATE=%d MISS_K=%d DARK=%d -> COUNT=%d ids=%d"
          % (args.video, nf, args.gate, args.miss_k, args.dark, count, next_id))
    print("COUNT events (frame,count,x,y,hits):", events)


if __name__ == "__main__":
    main()
