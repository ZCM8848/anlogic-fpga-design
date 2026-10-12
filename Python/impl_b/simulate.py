# -*- coding: utf-8 -*-
"""
simulate.py -- 合成滚珠测试视频（无需硬件即可调通链路）
==========================================================
生成 1280x720 的模拟视频，验证「检测 -> 跟踪 -> 计数 -> OSD」整条链路：
  * 亮色钢珠（带柔和边缘 -> Sobel 边缘环）从左侧进入、向右滚出
  * 偶尔一个大尺寸深色块（模拟人手/大物体，验证尺度/长宽比过滤）
  * 整体亮度缓慢起伏（模拟光照变化）
  * 真值：越过画面中线 x=640 的钢珠数

用法:
  python simulate.py --out sim_test.mp4 --seconds 20
  然后:  python main.py --video sim_test.mp4 --no-display --output out.mp4
"""
import argparse

import cv2
import numpy as np


def make_background(w, h, seed=7):
    """几乎均匀的浅灰背景 + 极轻噪声（Sobel 只对钢珠边缘有强响应）。"""
    rng = np.random.default_rng(seed)
    bg = np.full((h, w), 108, np.float32)
    grad = np.linspace(0, 8, h).reshape(h, 1).astype(np.float32)  # 极缓垂直渐变
    bg += np.repeat(grad, w, axis=1)
    bg += rng.normal(0, 2, (h, w)).astype(np.float32)
    return np.clip(bg, 0, 255).astype(np.uint8)


def draw_ball(frame, x, y, r):
    """画一颗亮色反光钢珠：单一亮盘（柔和边缘 -> Sobel 得到单连通边缘环）。"""
    xi, yi, ri = int(x), int(y), max(5, int(r))
    cv2.circle(frame, (xi, yi), ri, (228, 228, 228), -1, cv2.LINE_AA)   # 亮盘


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="sim_test.mp4")
    ap.add_argument("--seconds", type=float, default=20.0)
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--w", type=int, default=1280)
    ap.add_argument("--h", type=int, default=720)
    ap.add_argument("--ball-r", type=int, default=26,
                    help="钢珠半径(px)。合成球边缘较厚，取较小值使其边缘环面积落入 FPGA MAX_AREA=500")
    args = ap.parse_args()

    w, h, fps = args.w, args.h, args.fps
    total = int(args.seconds * fps)
    lane_top, lane_bot = int(h * 0.30) + 30, int(h * 0.70) - 30

    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    vw = cv2.VideoWriter(args.out, fourcc, fps, (w, h))

    bg = make_background(w, h)
    rng = np.random.default_rng(1)

    balls = []            # [x, y, r, vx]
    next_spawn = 8
    hand = None           # [x, y, r, vx]
    next_hand = 90
    gt_center = 0         # 真值：越过 x=640 的钢珠数

    for f in range(total):
        # 光照缓慢起伏 (0.85 ~ 1.15)
        gain = 1.0 + 0.15 * np.sin(2 * np.pi * f / (fps * 6.0))
        gray = np.clip(bg.astype(np.float32) * gain, 0, 255).astype(np.uint8)

        # 生成新钢珠
        if f >= next_spawn:
            r = args.ball_r
            y = float(rng.uniform(lane_top, lane_bot))
            vx = float(rng.uniform(5, 9))
            balls.append([-r, y, float(r), vx])
            next_spawn = f + int(rng.integers(30, 55))

        # 生成"人手"大块
        if f >= next_hand:
            hand = [-90.0, float(rng.uniform(140, h - 140)),
                    float(rng.uniform(80, 110)), float(rng.uniform(3, 5))]
            next_hand = f + int(rng.integers(140, 240))

        # 移动并绘制钢珠
        alive = []
        for b in balls:
            x_old = b[0]
            b[0] += b[3]
            if x_old < w * 0.5 <= b[0]:
                gt_center += 1
            if b[0] < w + b[2]:
                draw_ball(gray, b[0], b[1], b[2])
                alive.append(b)
        balls = alive

        # 绘制"人手"
        if hand is not None:
            hand[0] += hand[3]
            cv2.ellipse(gray, (int(hand[0]), int(hand[1])),
                        (int(hand[2]), int(hand[2] * 0.7)), 0, 0, 360,
                        (45, 45, 45), -1, cv2.LINE_AA)
            if hand[0] > w + hand[2]:
                hand = None

        # 不额外模糊：cv2 抗锯齿已使边缘过渡柔和，Sobel 得到单连通边缘环
        frame = cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR)
        vw.write(frame)

    vw.release()
    print("[simulate] wrote %s  (%d frames, %dx%d @ %dfps)"
          % (args.out, total, w, h, fps))
    print("[simulate] ground truth: center-line crossings=%d" % gt_center)


if __name__ == "__main__":
    main()
