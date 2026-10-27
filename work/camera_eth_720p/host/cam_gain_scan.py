#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cam_gain_scan.py — 按帧统计 RAW10 亮度，用来看增益扫描/曝光是否生效

用法：
    python cam_gain_scan.py cap.pcapng [每帧采样包数]

输出每个（完整）帧的：frame_id、相对时间、均值、p99、最大值。
做增益扫描时，均值会台阶式变化，台阶边界就是每一档的切换点。
"""
import sys
import struct
from collections import defaultdict

import numpy as np

from raw10_pcap_decode import read_pcap, PKT_BYTES, PKT_TOTAL


def unpack_mean(buf):
    a = np.frombuffer(buf[:len(buf) // 5 * 5], dtype=np.uint8).reshape(-1, 5).astype(np.uint16)
    out = np.empty(a.shape[0] * 4, dtype=np.uint16)
    out[0::4] = (a[:, 0] << 2) | ((a[:, 4] >> 0) & 0x03)
    out[1::4] = (a[:, 1] << 2) | ((a[:, 4] >> 2) & 0x03)
    out[2::4] = (a[:, 2] << 2) | ((a[:, 4] >> 4) & 0x03)
    out[3::4] = (a[:, 3] << 2) | ((a[:, 4] >> 6) & 0x03)
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    path = sys.argv[1]
    n_sample = int(sys.argv[2]) if len(sys.argv) > 2 else 6

    pkts = read_pcap(path)
    frames = defaultdict(dict)
    t_first = None
    fts = {}

    for ts, p in pkts:
        if len(p) < 42 or p[12:14] != b"\x08\x00" or p[23] != 17:
            continue
        ihl = (p[14] & 0x0F) * 4
        total = (p[16] << 8) | p[17]
        payload = p[14 + ihl + 8: 14 + total]
        if len(payload) < 8 or payload[0:2] != b"\xAA\x55":
            continue
        fid, pidx, ptot = struct.unpack(">HHH", payload[2:8])
        if len(payload) - 8 != PKT_BYTES or ptot != PKT_TOTAL:
            continue
        frames[fid][pidx] = payload[8:]
        fts[fid] = ts
        if t_first is None:
            t_first = ts

    print(f"[load] {len(frames)} frames")
    print(f"{'frame':>6} {'t(s)':>7} {'pkts':>5} {'mark':>4} {'mean':>7} {'p99':>6} {'max':>6}")
    print("-" * 52)

    complete = [f for f in frames if len(frames[f]) == PKT_TOTAL]
    step = max(1, len(complete) // 120)          # 最多打 120 行
    for fid in sorted(complete)[::step]:
        d = frames[fid]
        mark = d[0][0]                            # 固件塞的增益档位标记
        idxs = [int(i * PKT_TOTAL / n_sample) for i in range(n_sample)]
        px = np.concatenate([unpack_mean(d[i]) for i in idxs])
        print(f"{fid:6d} {fts[fid]-t_first:7.3f} {len(d):5d} {mark:4d} "
              f"{px.mean():7.1f} {np.percentile(px,99):6.0f} {px.max():6.0f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
