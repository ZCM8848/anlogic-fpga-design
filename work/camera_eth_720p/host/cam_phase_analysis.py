#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cam_phase_analysis.py — 按帧内标记字节分组，比较各增益档位的画面统计

固件在每帧第 0 包的第 1 个数据字节塞了 {5'b0, 增益档位}，这里用它把帧分组。
对每组取一帧，输出：均值 / p99 / Bayer 四相均值 / 列均值起伏（判断竖条纹周期）/ PNG。

用法：
    python cam_phase_analysis.py cap.pcapng
"""
import sys
from collections import defaultdict

import numpy as np
import cv2

from raw10_pcap_decode import read_pcap, unpack_raw10, PKT_BYTES, PKT_TOTAL, W, H


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    path = sys.argv[1]

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
        fid = int.from_bytes(payload[2:4], "big")
        pidx = int.from_bytes(payload[4:6], "big")
        ptot = int.from_bytes(payload[6:8], "big")
        if ptot != PKT_TOTAL or len(payload) - 8 != PKT_BYTES:
            continue
        frames[fid][pidx] = payload[8:]

    # 每个 marker 取第一帧完整的
    picked = {}
    for fid in sorted(frames):
        d = frames[fid]
        if len(d) != PKT_TOTAL:
            continue
        mark = d[0][0]
        if mark in picked:
            continue
        picked[mark] = fid

    print(f"[load] {len(frames)} frames, markers: {sorted(picked)}")
    for mark, fid in sorted(picked.items()):
        d = frames[fid]
        buf = b"".join(d[i] for i in range(PKT_TOTAL))
        px = unpack_raw10(buf)[:W * H].reshape(H, W).astype(np.float32)

        b = px[0::2, 0::2].mean()
        g1 = px[0::2, 1::2].mean()
        g2 = px[1::2, 0::2].mean()
        r = px[1::2, 1::2].mean()

        col = px.mean(axis=0)
        col_ac = col - col.mean()
        spec = np.abs(np.fft.rfft(col_ac))
        spec[0] = 0
        peak = int(np.argmax(spec))
        period = (W / peak) if peak else 0

        print(f"\n[mark={mark}] frame {fid}  mean={px.mean():.1f} p99={np.percentile(px,99):.0f} "
              f"max={px.max():.0f}")
        print(f"   Bayer B/G1/G2/R = {b:.1f}/{g1:.1f}/{g2:.1f}/{r:.1f}")
        print(f"   列均值 std={col_ac.std():.2f}  峰值周期={period:.2f}px (bin {peak})")

        img8 = np.clip(px / 4, 0, 255).astype(np.uint8)
        cv2.imwrite(f"phase_{mark}.png", cv2.cvtColor(img8, cv2.COLOR_BayerBG2BGR))
    return 0


if __name__ == "__main__":
    sys.exit(main())
