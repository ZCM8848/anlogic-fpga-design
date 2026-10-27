#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cam_stream_check.py — 统计摄像头 UDP 流的帧完整性 / 帧率 / 带宽

用法：
    python cam_stream_check.py cap.pcapng

与 udp_pcap_check.py 的区别：载荷是摄像头 RAW10 数据，不是可预测的测试图样，
所以只校验「包头 + 帧号/包号连续性 + 帧完整性 + 速率」，内容用 raw10_pcap_decode.py 看。
"""
import sys
import struct
from collections import defaultdict

from raw10_pcap_decode import read_pcap, PKT_BYTES, PKT_TOTAL, FRAME_BYTES, W, H


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    path = sys.argv[1]

    pkts = read_pcap(path)
    print(f"[load] {len(pkts)} packets")

    frames = defaultdict(dict)
    t_first = t_last = None
    n_video = 0
    n_bad_len = 0
    n_meta = 0

    for ts, p in pkts:
        if len(p) < 42 or p[12:14] != b"\x08\x00" or p[23] != 17:
            continue
        ihl = (p[14] & 0x0F) * 4
        total = (p[16] << 8) | p[17]
        if total < ihl + 8 + 8:
            n_bad_len += 1
            continue
        payload = p[14 + ihl + 8: 14 + total]
        if len(payload) < 8 or payload[0:2] != b"\xAA\x55":
            continue
        fid, pidx, ptot = struct.unpack(">HHH", payload[2:8])
        if ptot != PKT_TOTAL:
            n_bad_len += 1
            continue
        body = payload[8:]
        if pidx == 0xFFFF:
            n_meta += 1
            continue
        if len(body) != PKT_BYTES:
            n_bad_len += 1
            continue
        if pidx >= PKT_TOTAL:
            n_bad_len += 1
            continue
        frames[fid][pidx] = body
        n_video += 1
        if t_first is None:
            t_first = ts
        t_last = ts

    print(f"[video] {n_video} 个视频包，{n_meta} 个元数据包"
          + (f"，{n_bad_len} 个长度异常" if n_bad_len else ""))

    if not frames:
        print("[error] 没有解出任何视频帧")
        return 1

    counts = {f: len(d) for f, d in frames.items()}
    complete = [f for f, c in counts.items() if c == PKT_TOTAL]
    partial = [(f, c) for f, c in counts.items() if c != PKT_TOTAL]

    print(f"[frames] 共 {len(frames)} 帧，完整 {len(complete)} 帧，残帧 {len(partial)} 帧")
    if partial:
        partial.sort(key=lambda kv: -kv[1])
        print("        最大的残帧: " + ", ".join(f"#{f}:{c}/{PKT_TOTAL}" for f, c in partial[:5]))

    # 帧号连续性（按 16 位回绕）
    fids = sorted(counts.keys())
    gaps = 0
    for a, b in zip(fids, fids[1:]):
        if ((b - a) & 0xFFFF) != 1:
            gaps += 1
    print(f"[order] 帧号断点 {gaps} 处" + ("  <-- 有丢帧" if gaps else "  (连续)"))

    if t_first is not None and t_last is not None and t_last > t_first:
        dur = t_last - t_first
        fps = (len(fids) - 1) / dur if dur > 0 else 0.0
        mbps = n_video * (PKT_BYTES + 8) * 8 / dur / 1e6
        print(f"[rate] {dur:.3f} s  {fps:.1f} fps  {mbps:.1f} Mbps"
              f"  (期望 60 fps / ~553 Mbps)")

    if complete:
        print(f"[ok] frame_id={complete[0]} 完整，可用 raw10_pcap_decode.py 出图")
    return 0


if __name__ == "__main__":
    sys.exit(main())
