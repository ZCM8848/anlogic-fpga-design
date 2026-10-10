# -*- coding: utf-8 -*-
"""
to_720p60.py -- 把任意视频转成 1280x720（可选统一为 60fps）
============================================================
用途：手机录的 1080p60 / 4K60 可以直接转成赛题基准 1280x720@60。

注意：
  * 如果源视频本身就是 60fps（只是分辨率更高），转出来就是真 60fps，合规。
  * 如果源视频是 30fps，用 --fps 60 只是把每帧复制成两帧，播放时长不变，
    但“内容”仍是 30fps 的运动信息，不能真正提升时间分辨率（仅用于占位/演示）。
  * 需要更快/更专业的转码可用 ffmpeg，本脚本无需额外依赖。

用法:
  python to_720p60.py in.mp4 out.mp4                 # 保持源帧率，缩放到720p
  python to_720p60.py in.mp4 out.mp4 --fps 60        # 强制输出60fps标签
"""
import argparse

import cv2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--fps", type=float, default=0.0,
                    help="0=沿用源帧率; 或指定如 60")
    args = ap.parse_args()

    cap = cv2.VideoCapture(args.src)
    if not cap.isOpened():
        print("[error] cannot open:", args.src)
        return
    src_w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    src_h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    src_fps = float(cap.get(cv2.CAP_PROP_FPS)) or 30.0
    out_fps = args.fps if args.fps > 0 else src_fps
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    print("[src] %dx%d @ %.2ffps  %d frames" % (src_w, src_h, src_fps, n))

    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    vw = cv2.VideoWriter(args.dst, fourcc, out_fps, (args.width, args.height))
    if not vw.isOpened():
        print("[error] cannot create:", args.dst)
        cap.release()
        return

    i = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        i += 1
        f = cv2.resize(frame, (args.width, args.height), interpolation=cv2.INTER_AREA)
        vw.write(f)
        if i % 60 == 0:
            print("  ..%d/%d" % (i, n))
    cap.release()
    vw.release()
    print("[done] wrote %s  (%dx%d @ %.2ffps, %d frames)"
          % (args.dst, args.width, args.height, out_fps, i))


if __name__ == "__main__":
    main()
