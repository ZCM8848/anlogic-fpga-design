#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pcap_export_raw.py — 把抓包导出成无损 10bit 原始帧（.npy）

用法：
    python pcap_export_raw.py raw.pcapng [输出目录] [--limit N]

产物：
    raw10.npy        (N, 720, 1280) uint16，内存映射友好，算法可直接 np.load(..., mmap_mode='r')
    raw10_index.json 帧号列表、shape/dtype、bayer、黑电平、帧率

这是"原始流"的像素级导出：10bit、无 AWB、无拉伸、无压缩。
缺点是体积大（1.84 MB/帧，10 秒约 1.1 GB），按需生成。
"""
import sys
import os
import json
import time
from collections import defaultdict

import numpy as np

from raw10_pcap_decode import read_pcap
from cam_proc import (unpack_raw10, PKT_TOTAL, PKT_BYTES, META_IDX, W, H,
                      FRAME_BYTES)


def collect(path, limit=0):
    pkts = read_pcap(path)
    frames = defaultdict(dict)
    order = []
    t_first = t_last = None
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
        if pidx == META_IDX:
            continue
        if ptot != PKT_TOTAL or len(pl) - 8 != PKT_BYTES or pidx >= PKT_TOTAL:
            continue
        if fid not in frames:
            order.append(fid)
        frames[fid][pidx] = pl[8:]
        if t_first is None:
            t_first = ts
        t_last = ts

    good = [f for f in order if len(frames[f]) == PKT_TOTAL]
    if limit:
        good = good[:limit]
    dur = (t_last - t_first) if (t_last and t_first and t_last > t_first) else 0.0
    return frames, good, dur, len(order)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    pcap = sys.argv[1]
    outdir = os.path.dirname(os.path.abspath(pcap))
    limit = 0
    args = sys.argv[2:]
    i = 0
    while i < len(args):
        if args[i] == "--limit" and i + 1 < len(args):
            limit = int(args[i + 1]); i += 2
        else:
            outdir = args[i]; i += 1
    os.makedirs(outdir, exist_ok=True)

    t0 = time.time()
    frames, good, dur, total = collect(pcap, limit)
    n = len(good)
    print(f"[load] {total} 帧，完整 {n} 帧，{dur:.2f}s")

    npy = os.path.join(outdir, "raw10.npy")
    mm = np.lib.format.open_memmap(npy, mode="w+", dtype=np.uint16, shape=(n, H, W))

    for k, fid in enumerate(good):
        buf = b"".join(frames[fid][j] for j in range(PKT_TOTAL))[:FRAME_BYTES]
        mm[k] = unpack_raw10(buf)[: W * H].reshape(H, W)
        if k % 50 == 0:
            print(f"  {k+1}/{n} (frame {fid})", flush=True)
    mm.flush()
    del mm

    fps = (n - 1) / dur if dur > 0 else 0.0
    idx = {
        "source_pcap": os.path.basename(pcap),
        "frames": good,
        "count": n,
        "shape": [n, H, W],
        "dtype": "uint16",
        "bit_depth": 10,
        "bayer": "BGGR",
        "black_level": 64,
        "fps": round(fps, 2),
        "duration_s": round(dur, 3),
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    with open(os.path.join(outdir, "raw10_index.json"), "w", encoding="utf-8") as f:
        json.dump(idx, f, ensure_ascii=False, indent=2)

    size = os.path.getsize(npy)
    print(f"[save] {npy}  {size/1e9:.2f} GB  ({n} × {H} × {W} uint16)")
    print(f"[save] {os.path.join(outdir, 'raw10_index.json')}")
    print(f"[done] {time.time()-t0:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
