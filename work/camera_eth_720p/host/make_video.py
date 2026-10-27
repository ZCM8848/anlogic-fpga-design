#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""make_video.py — 把抓包里的 RAW10 帧渲染成 mp4

用法：
    python make_video.py cap.pcapng out.mp4 [max_frames] [fps]

处理：AWB（前 30 帧统计，全片固定，避免闪烁）
      + 列固定图案噪声校正（前 30 帧时间平均得到列剖面，只减高频）
      + 自动拉伸（前 30 帧 0.5%~99.5%）
      + demosaic + 双边滤波
"""
import sys
from collections import defaultdict

import numpy as np
import cv2

from cam_proc import (PKT_BYTES, PKT_TOTAL, W, H, frame_pixels, awb_gains,
                      awb_gains_from_meta, apply_awb, column_profile,
                      column_correction, to_bgr, denoise, parse_meta)
from raw10_pcap_decode import read_pcap


def load_frames(path):
    pkts = read_pcap(path)
    frames = defaultdict(dict)
    metas = {}
    order = []
    for ts, p in pkts:
        if len(p) < 42 or p[12:14] != b"\x08\x00" or p[23] != 17:
            continue
        ihl = (p[14] & 0x0F) * 4
        total = (p[16] << 8) | p[17]
        pl = p[14 + ihl + 8: 14 + total]
        if len(pl) < 8 or pl[0:2] != b"\xAA\x55":
            continue
        fid = int.from_bytes(pl[2:4], "big")
        pidx = int.from_bytes(pl[4:6], "big")
        ptot = int.from_bytes(pl[6:8], "big")
        if pidx == 0xFFFF:
            m = parse_meta(pl[8:])
            if m:
                metas[m["frame_id"]] = m
            continue
        if ptot != PKT_TOTAL or len(pl) - 8 != PKT_BYTES or pidx >= PKT_TOTAL:
            continue
        if fid not in frames:
            order.append(fid)
        frames[fid][pidx] = pl[8:]
    return frames, order, metas


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    pcap, out = sys.argv[1], sys.argv[2]
    max_frames = int(sys.argv[3]) if len(sys.argv) > 3 else 100000
    fps = float(sys.argv[4]) if len(sys.argv) > 4 else 60.0

    frames, order, metas = load_frames(pcap)
    good = [f for f in order if len(frames[f]) == PKT_TOTAL][:max_frames]
    print(f"[load] {len(order)} frames, 用 {len(good)} 帧渲染")

    def get(fid):
        d = frames[fid]
        return frame_pixels(b"".join(d[i] for i in range(PKT_TOTAL)))

    # ---- 前 30 帧统计 ----
    n0 = min(30, len(good))
    acc = None
    for fid in good[:n0]:
        px = get(fid)
        acc = px.astype(np.float32) if acc is None else acc + px
    acc /= n0

    gb, gr = awb_gains(acc.astype(np.uint16))
    m0 = next((metas[f] for f in good if f in metas), None)
    if m0 is not None:
        gb, gr = awb_gains_from_meta(m0)
        print(f"[meta] 用 FPGA 统计: ae={m0['ae']} ag={m0['ag']} "
              f"sid={m0['sensor_id']:04X} status={m0['status']:X}")
    bal0 = apply_awb(acc.astype(np.uint16), gb, gr)
    colfix = column_correction(column_profile(bal0)).astype(np.float32)

    lo = float(np.percentile(bal0, 0.5))
    hi = float(np.percentile(bal0, 99.5))
    print(f"[awb] B={gb:.2f} R={gr:.2f}  [level] {lo:.0f}..{hi:.0f}  "
          f"[colfix] std={colfix.std():.2f}")

    vw = cv2.VideoWriter(out, cv2.VideoWriter_fourcc(*"mp4v"), fps, (W, H))
    if not vw.isOpened():
        print(f"[error] 打不开 VideoWriter: {out}")
        return 1

    for i, fid in enumerate(good):
        px = get(fid)
        bal = apply_awb(px, gb, gr)
        bal -= colfix[None, :]
        np.clip(bal, 0, 1023, out=bal)
        bgr = to_bgr(bal, lo, hi)
        bgr = denoise(bgr, 1)
        vw.write(bgr)
        if i % 60 == 0:
            print(f"  {i+1}/{len(good)} (frame {fid})", flush=True)

    vw.release()
    print(f"[done] {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
