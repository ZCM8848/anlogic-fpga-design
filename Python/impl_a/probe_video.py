# -*- coding: utf-8 -*-
"""
probe_video.py -- 检查任意视频的分辨率/帧率/编码，并判断是否满足赛题基准
============================================================
用法:
  python probe_video.py "C:\\path\\to\\video.mp4"
判据: 分辨率 1280x720 且 帧率 >= 55fps 视为合规。
"""
import argparse

import cv2


def probe(path):
    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        print("[error] cannot open:", path)
        return
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = float(cap.get(cv2.CAP_PROP_FPS))
    fourcc = int(cap.get(cv2.CAP_PROP_FOURCC))
    codec = "".join([chr((fourcc >> 8 * i) & 0xFF) for i in range(4)])
    cap.release()

    ok_res = (w == 1280 and h == 720)
    ok_fps = fps >= 55.0
    print("file    :", path)
    print("size    : %dx%d" % (w, h))
    print("fps     : %.2f" % fps)
    print("frames  : %d  (%.2fs)" % (n, n / max(fps, 1)))
    print("codec   : %s" % codec)
    print("=" * 48)
    print("resolution 1280x720 : %s" % ("PASS" if ok_res else "FAIL"))
    print("frame rate >=55fps  : %s (%.1f)" % ("PASS" if ok_fps else "FAIL", fps))
    print("verdict             : %s" % ("[OK] compliant 1280x720@60"
                                         if (ok_res and ok_fps) else
                                         "[NO] not compliant"))
    return w, h, fps


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    args = ap.parse_args()
    probe(args.file)


if __name__ == "__main__":
    main()
