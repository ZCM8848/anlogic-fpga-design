# -*- coding: utf-8 -*-
"""
simulate.py -- 合成测试视频（无需硬件即可调通算法）
============================================================
生成一段 1280x720 的模拟视频，用来在没有摄像头/没有现场的情况下
验证“检测 -> 跟踪 -> 计数”整条链路：
  * 画面中部有一条轨道带（对应 ROI）
  * 银色钢珠从左侧进入、向右滚出（带高光，模拟金属反光）
  * 偶尔出现一个大的深色块（模拟人手/大物体，用来验证尺度过滤）
  * 整体亮度缓慢起伏（模拟光照变化，用来验证抗光照能力）

用法:
  python simulate.py --out sim_test.mp4 --seconds 20
  然后:  python main.py --video sim_test.mp4 --no-display --output out.mp4
"""
import argparse

import cv2
import numpy as np


def make_background(w, h):
    """带渐变与噪声的静态背景。"""
    bg = np.zeros((h, w, 3), np.float32)
    # 垂直渐变
    grad = np.linspace(70, 140, h).reshape(h, 1)
    bg[:, :, 0] = grad
    bg[:, :, 1] = grad
    bg[:, :, 2] = grad
    # 轨道带稍亮
    bg[int(h * 0.34):int(h * 0.66), :, :] += 25
    rng = np.random.default_rng(7)
    bg += rng.normal(0, 6, bg.shape)
    return np.clip(bg, 0, 255).astype(np.uint8)


def draw_ball(frame, x, y, r):
    """画一颗银色金属球：暗色球体 + 高亮高光 + 暗色边缘，形成明显对比。"""
    xi, yi, ri = int(x), int(y), max(2, int(r))
    # 暗色球体（相对浅色轨道形成对比）
    cv2.circle(frame, (xi, yi), ri, (70, 70, 70), -1, cv2.LINE_AA)
    # 暗色边缘，增强梯度
    cv2.circle(frame, (xi, yi), ri, (25, 25, 25), 1, cv2.LINE_AA)
    # 亮高光（金属反光）
    hx, hy = int(x - r * 0.30), int(y - r * 0.30)
    cv2.circle(frame, (hx, hy), max(1, int(r * 0.34)), (250, 250, 250), -1,
               cv2.LINE_AA)
    # 底部反光
    cv2.circle(frame, (int(x + r * 0.20), int(y + r * 0.35)),
               max(1, int(r * 0.20)), (200, 200, 200), -1, cv2.LINE_AA)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="sim_test.mp4")
    ap.add_argument("--seconds", type=float, default=20.0)
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--w", type=int, default=1280)
    ap.add_argument("--h", type=int, default=720)
    args = ap.parse_args()

    w, h, fps = args.w, args.h, args.fps
    total = int(args.seconds * fps)
    lane_top, lane_bot = int(h * 0.34) + 20, int(h * 0.66) - 20

    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    vw = cv2.VideoWriter(args.out, fourcc, fps, (w, h))

    bg = make_background(w, h)
    rng = np.random.default_rng(1)

    balls = []      # [x, y, r, vx]
    next_spawn = 10
    hand = None     # [x, y, r, vx]
    next_hand = 90
    gt_center = 0   # 真值：越过画面中线的钢珠数
    gt_exit = 0     # 真值：完全滚出画面的钢珠数

    for f in range(total):
        # 光照缓慢起伏 (0.85 ~ 1.15)
        gain = 1.0 + 0.15 * np.sin(2 * np.pi * f / (fps * 6.0))
        frame = np.clip(bg.astype(np.float32) * gain, 0, 255).astype(np.uint8)

        # 生成新钢珠
        if f >= next_spawn:
            r = rng.integers(35, 44)
            y = rng.uniform(lane_top, lane_bot)
            vx = rng.uniform(6, 11)
            balls.append([-r, float(y), float(r), float(vx)])
            next_spawn = f + int(rng.integers(40, 80))

        # 生成“人手”大块
        if f >= next_hand:
            hand = [-80.0, float(rng.uniform(140, h - 140)),
                    float(rng.uniform(90, 120)), float(rng.uniform(4, 7))]
            next_hand = f + int(rng.integers(120, 220))

        # 移动
        alive = []
        for b in balls:
            x_old = b[0]
            b[0] += b[2]
            if x_old < w * 0.5 <= b[0]:
                gt_center += 1
            if b[0] < w + b[2]:
                draw_ball(frame, b[0], b[1], b[2])
                alive.append(b)
            else:
                gt_exit += 1
        balls = alive

        if hand is not None:
            hand[0] += hand[3]
            cv2.ellipse(frame, (int(hand[0]), int(hand[1])),
                        (int(hand[2]), int(hand[2] * 0.7)), 0, 0, 360,
                        (35, 40, 45), -1, cv2.LINE_AA)
            if hand[0] > w + hand[2]:
                hand = None

        vw.write(frame)

    vw.release()
    print("[simulate] wrote %s  (%d frames, %dx%d @ %dfps)"
          % (args.out, total, w, h, fps))
    print("[simulate] ground truth: center-line crossings=%d, exits=%d"
          % (gt_center, gt_exit))


if __name__ == "__main__":
    main()
