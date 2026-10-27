#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pcap_meta.py — 从抓包生成 meta.jsonl / run.json，并打印体检统计

用法：
    python pcap_meta.py cap.pcapng [输出目录]

产物（输出目录默认是 pcap 所在目录）：
    meta.jsonl   每帧一行：frame_id / ae / ag / sensor_id / status / BGR 累加和 / AWB 增益
    run.json     本次录制的"配方"：时长、帧率、带宽、完整性、bit md5、git commit、工具版本

不写视频、不写图片，只做元数据，几秒就能跑完。
"""
import sys
import os
import json
import time
import hashlib
import subprocess
from collections import defaultdict

from raw10_pcap_decode import read_pcap
from cam_proc import (parse_meta, awb_gains_from_meta, PKT_TOTAL, PKT_BYTES,
                      META_IDX)

TOOL_VERSION = "1.0"


def git_rev():
    try:
        root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
        out = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"],
                                      cwd=root, text=True, stderr=subprocess.DEVNULL)
        return out.strip()
    except Exception:
        return "?"


def md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def bit_md5():
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    p = os.path.join(root, "td_project", "m1_Runs", "phy_1", "m1.bit")
    if os.path.exists(p):
        return md5_file(p)
    return None


def analyze(path):
    """返回 (stats, metas)。metas: frame_id -> dict"""
    pkts = read_pcap(path)
    n_all = len(pkts)
    t_first = t_last = None
    n_video = n_meta = n_bad = 0
    frames = defaultdict(int)
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
        if pidx == META_IDX:
            m = parse_meta(pl[8:])
            if m:
                metas[m["frame_id"]] = m
            n_meta += 1
            continue
        if ptot != PKT_TOTAL or len(pl) - 8 != PKT_BYTES or pidx >= PKT_TOTAL:
            n_bad += 1
            continue
        if fid not in frames:
            order.append(fid)
        frames[fid] += 1
        n_video += 1
        if t_first is None:
            t_first = ts
        t_last = ts

    complete = [f for f in order if frames[f] == PKT_TOTAL]
    partial = [(f, frames[f]) for f in order if frames[f] != PKT_TOTAL]
    gaps = 0
    for a, b in zip(order, order[1:]):
        if ((b - a) & 0xFFFF) != 1:
            gaps += 1

    dur = (t_last - t_first) if (t_first and t_last and t_last > t_first) else 0.0
    fps = (len(order) - 1) / dur if dur > 0 else 0.0
    mbps = n_video * (PKT_BYTES + 8) * 8 / dur / 1e6 if dur > 0 else 0.0

    awb = None
    m0 = next((metas[f] for f in order if f in metas), None)
    if m0:
        gb, gr = awb_gains_from_meta(m0)
        awb = {"b": round(gb, 4), "r": round(gr, 4)}

    stats = {
        "packets": n_all,
        "video_packets": n_video,
        "meta_packets": n_meta,
        "bad_packets": n_bad,
        "frames_total": len(order),
        "frames_complete": len(complete),
        "frames_partial": len(partial),
        "partial_top": sorted(partial, key=lambda x: -x[1])[:5],
        "frame_gaps": gaps,
        "first_frame": order[0] if order else None,
        "last_frame": order[-1] if order else None,
        "duration_s": round(dur, 3),
        "fps": round(fps, 2),
        "mbps": round(mbps, 1),
        "awb": awb,
        "meta_frames": len(metas),
    }
    return stats, metas


def write_outputs(pcap, outdir, stats, metas):
    mp = os.path.join(outdir, "meta.jsonl")
    with open(mp, "w", encoding="utf-8") as f:
        for fid in sorted(metas):
            m = metas[fid]
            rec = {
                "frame_id": fid,
                "ae": m["ae"],
                "ag": m["ag"],
                "sensor_id": f"0x{m['sensor_id']:04X}",
                "status": m["status"],
                "sum_b": m["sum_b"],
                "sum_g": m["sum_g"],
                "sum_r": m["sum_r"],
            }
            if stats["awb"]:
                rec["awb_b"] = stats["awb"]["b"]
                rec["awb_r"] = stats["awb"]["r"]
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")

    run = {
        "tool_version": TOOL_VERSION,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "pcap": os.path.basename(pcap),
        "pcap_bytes": os.path.getsize(pcap),
        "pcap_md5": md5_file(pcap),
        "fingerprint": {
            "git": git_rev(),
            "bit_md5": bit_md5(),
            "resolution": "1280x720",
            "bayer": "BGGR",
            "black_level": 64,
            "pkt_bytes": PKT_BYTES,
            "pkt_total": PKT_TOTAL,
        },
        "capture": stats,
    }
    rp = os.path.join(outdir, "run.json")
    with open(rp, "w", encoding="utf-8") as f:
        json.dump(run, f, ensure_ascii=False, indent=2)
    return mp, rp


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    pcap = sys.argv[1]
    outdir = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.abspath(pcap))
    os.makedirs(outdir, exist_ok=True)

    t0 = time.time()
    stats, metas = analyze(pcap)

    print(f"[pcap] {os.path.basename(pcap)}  {os.path.getsize(pcap)/1e6:.1f} MB  "
          f"{stats['duration_s']:.2f}s")
    print(f"[video] {stats['video_packets']} 包 / {stats['frames_total']} 帧 "
          f"(完整 {stats['frames_complete']}, 残 {stats['frames_partial']}, "
          f"断点 {stats['frame_gaps']})")
    print(f"[meta]  {stats['meta_packets']} 个元数据包，覆盖 {stats['meta_frames']} 帧")
    print(f"[rate]  {stats['fps']} fps / {stats['mbps']} Mbps")
    if stats["awb"]:
        print(f"[awb]   B={stats['awb']['b']} R={stats['awb']['r']}")

    mp, rp = write_outputs(pcap, outdir, stats, metas)
    print(f"[save] {mp}")
    print(f"[save] {rp}")
    print(f"[done] {time.time()-t0:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
