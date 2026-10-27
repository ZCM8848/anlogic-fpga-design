#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cam_frame_grab.py — 从抓包中按 frame_id 取出若干帧存 PNG（调试用）

用法：
    python cam_frame_grab.py cap.pcapng 223 267 311 ...
"""
import sys
from collections import defaultdict

import numpy as np
import cv2

from raw10_pcap_decode import read_pcap, unpack_raw10, PKT_BYTES, PKT_TOTAL, W, H


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    path = sys.argv[1]
    want = [int(x) for x in sys.argv[2:]]

    pkts = read_pcap(path)
    frames = defaultdict(dict)
    for ts, p in pkts:
        if len(p) < 42 or p[12:14] != b"\x08\x00" or p[23] != 17:
            continue
        ihl = (p[14] & 0x0F) * 4
        total = (p[16] << 8) | p[17]
        payload = p[14 + ihl + 8: 14 + total]
        if len(payload) < 8 or payload[0:2] != b"\xAA\x55":
            continue
        fid, pidx, ptot = int.from_bytes(payload[2:4], "big"), int.from_bytes(payload[4:6], "big"), int.from_bytes(payload[6:8], "big")
        if ptot != PKT_TOTAL or len(payload) - 8 != PKT_BYTES:
            continue
        frames[fid][pidx] = payload[8:]

    for fid in want:
        d = frames.get(fid)
        if not d or len(d) != PKT_TOTAL:
            print(f"[skip] frame {fid}: {0 if not d else len(d)} pkts")
            continue
        buf = b"".join(d[i] for i in range(PKT_TOTAL))
        px = unpack_raw10(buf)[:W * H].reshape(H, W)
        img8 = np.clip(px >> 2, 0, 255).astype(np.uint8)
        bgr = cv2.cvtColor(img8, cv2.COLOR_BayerBG2BGR)
        out = f"grab_{fid}.png"
        cv2.imwrite(out, bgr)
        print(f"[ok] frame {fid}: mean={px.mean():.1f} p99={np.percentile(px,99):.0f} max={px.max()} -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
