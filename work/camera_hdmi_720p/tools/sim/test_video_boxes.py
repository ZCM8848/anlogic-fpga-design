# -*- coding: utf-8 -*-
"""在录像上检查检测框尺寸：画面内部的识别框应全部为 160x160。"""
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cv_pipeline_sim as sim


def main():
    path = sys.argv[1]
    dark = int(sys.argv[2]) if len(sys.argv) > 2 else 100
    wide = dark >= sim.WIDE_THR
    cap = cv2.VideoCapture(path)
    hist = []
    frames = 0
    boxes = 0
    bad = 0
    close_pairs = 0
    while True:
        ok, fr = cap.read()
        if not ok:
            break
        frames += 1
        B = fr[:, :, 0].astype(np.uint16)
        G = fr[:, :, 1].astype(np.uint16)
        R = fr[:, :, 2].astype(np.uint16)
        bm = cv2.resize(((R >> 2) + (G >> 1) + (B >> 2)).astype(np.float32),
                        (80, 45), interpolation=cv2.INTER_AREA)
        if len(hist) >= sim.BG_DELAY:
            bg = hist[-sim.BG_DELAY]
            m = ((bm < dark) & (bm < bg - sim.CB_DELTA)).astype(np.uint8)
            dets = sim.detect_blocks(m, wide)
            for i, (cx, cy, x0, y0, x1, y1) in enumerate(dets):
                boxes += 1
                if x0 == 0 or y0 == 0 or x1 == sim.FRAME_W - 1 or y1 == sim.FRAME_H - 1:
                    continue
                if (x1 - x0 + 1) != sim.BOX_BLK * 16 or (y1 - y0 + 1) != sim.BOX_BLK * 16:
                    bad += 1
                    print("bad box f%d: %s" % (frames, (cx, cy, x0, y0, x1, y1)))
            for i in range(len(dets)):
                for j in range(i + 1, len(dets)):
                    if abs(dets[i][0] - dets[j][0]) + abs(dets[i][1] - dets[j][1]) < sim.DUP_DIST:
                        close_pairs += 1
        hist.append(bm)
        if len(hist) > sim.BG_DELAY:
            hist.pop(0)
    cap.release()
    print("video=%s frames=%d boxes=%d bad_inner=%d close_pairs=%d"
          % (path, frames, boxes, bad, close_pairs))
    if bad:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
