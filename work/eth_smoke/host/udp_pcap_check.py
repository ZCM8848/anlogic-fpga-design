#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""udp_pcap_check.py — 离线校验 FPGA 的 UDP 视频流

读 dumpcap/tshark 抓的 pcap 或 pcapng，逐包检查：
  - Ethernet: src = 02:00:00:00:00:01, type = 0x0800
  - IPv4:      proto = 17, 头校验和正确, src/dst IP, 总长
  - UDP:       端口 4660, 长度正确
  - 应用头:    AA 55 | frame_id | pkt_idx | pkt_total
  - 负载:      pay[i] == (i ^ pkt_idx ^ frame_id) & 0xFF
  - 帧完整性:  每个 frame_id 是否 800 个包齐全

用法：
    python udp_pcap_check.py capture.pcapng
"""
import sys
import struct
from collections import defaultdict


def read_pcap(path):
    """返回 [(ts_sec_float, bytes_packet)]，支持 classic pcap 和 pcapng。"""
    data = open(path, "rb").read()
    magic = struct.unpack_from("<I", data, 0)[0]
    out = []

    if magic in (0xA1B2C3D4, 0xD4C3B2A1):
        # classic pcap
        endian = "<" if magic == 0xA1B2C3D4 else ">"
        _, _, _, _, snaplen, linktype = struct.unpack_from(endian + "IHHiIII", data, 0)
        off = 24
        while off + 16 <= len(data):
            ts, tus, incl, orig = struct.unpack_from(endian + "IIII", data, off)
            off += 16
            pkt = data[off:off + incl]
            off += incl
            out.append((ts + tus / 1e6, pkt))
        return out, linktype

    if magic == 0x0A0D0D0A:
        # pcapng
        off = 0
        endian = "<"
        tsresol = 6
        linktype = 1
        while off + 12 <= len(data):
            btype = struct.unpack_from(endian + "I", data, off)[0]
            blen = struct.unpack_from(endian + "I", data, off + 4)[0]
            if blen < 12 or off + blen > len(data):
                break
            body = data[off + 8: off + blen - 4]
            if btype == 0x0A0D0D0A:
                bom = struct.unpack_from("<I", body, 0)[0]
                endian = "<" if bom == 0x1A2B3C4D else ">"
            elif btype == 0x00000001:
                linktype = struct.unpack_from(endian + "H", body, 0)[0]
                if len(body) >= 10:
                    opts_off = 8
                    while opts_off + 4 <= len(body):
                        code, olen = struct.unpack_from(endian + "HH", body, opts_off)
                        if code == 0:
                            break
                        if code == 9 and olen >= 1:      # if_tsresol
                            v = body[opts_off + 4]
                            tsresol = v & 0x7F
                        opts_off += 4 + ((olen + 3) & ~3)
            elif btype == 0x00000006:
                iface, tsh, tsl, cap, orig = struct.unpack_from(endian + "IIIII", body, 0)
                pkt = body[20:20 + cap]
                ts = ((tsh << 32) | tsl) / (10 ** tsresol)
                out.append((ts, pkt))
            off += blen
        return out, linktype

    raise SystemExit("无法识别的抓包格式")


def csum16(b):
    s = 0
    for i in range(0, len(b), 2):
        s += (b[i] << 8) | b[i + 1]
        s = (s & 0xFFFF) + (s >> 16)
    return s


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    path = sys.argv[1]
    pkts, linktype = read_pcap(path)
    print(f"[load] {path}: {len(pkts)} packets, linktype={linktype}")
    if linktype != 1:
        print("只支持 Ethernet 链路类型")
        return 1

    # 预生成 256 种图案（pay = i ^ (pkt_idx ^ frame_id) 的低 8 位）
    PAT = [bytes(((i ^ k) & 0xFF) for i in range(1440)) for k in range(256)]

    SRC = bytes.fromhex("020000000001")
    n_ok = 0
    n_bad = 0
    bad_reason = defaultdict(int)

    frames = defaultdict(int)          # frame_id -> 收到的包数
    seen = defaultdict(set)            # frame_id -> pkt_idx 集合
    first_ts = None
    last_ts = None

    for ts, p in pkts:
        if len(p) < 14 + 20 + 8 + 8:
            bad_reason["too_short"] += 1
            n_bad += 1
            continue
        if p[6:12] != SRC:            # 源 MAC 在字节 6..11（0..5 是目的 MAC）
            bad_reason["src_mac"] += 1
            n_bad += 1
            continue
        if p[12:14] != b"\x08\x00":
            bad_reason["ethertype"] += 1
            n_bad += 1
            continue

        ip = p[14:34]
        if ip[9] != 17:
            bad_reason["not_udp"] += 1
            n_bad += 1
            continue
        if csum16(ip) != 0xFFFF:
            bad_reason["ip_csum"] += 1
            n_bad += 1
            continue
        ihl = (ip[0] & 0x0F) * 4
        ip_total = (ip[2] << 8) | ip[3]
        if ip[12:16] != bytes([192, 168, 1, 200]) or ip[16:20] != bytes([192, 168, 1, 100]):
            bad_reason["ip_addr"] += 1
            n_bad += 1
            continue

        udp = p[14 + ihl: 14 + ihl + 8]
        sport, dport, ulen, uck = struct.unpack(">HHHH", udp)
        if sport != 4660 or dport != 4660:
            bad_reason["udp_port"] += 1
            n_bad += 1
            continue
        payload = p[14 + ihl + 8: 14 + ip_total]
        if len(payload) != ulen - 8:
            bad_reason["udp_len"] += 1
            n_bad += 1
            continue

        if payload[0:2] != b"\xAA\x55":
            bad_reason["magic"] += 1
            n_bad += 1
            continue
        fid, pidx, ptot = struct.unpack(">HHH", payload[2:8])
        body = payload[8:]

        # 图案校验（预生成的 256 种之一）
        k = (pidx ^ fid) & 0xFF
        if body != PAT[k]:
            bad_reason["payload_pattern"] += 1
            n_bad += 1
            continue

        n_ok += 1
        frames[fid] += 1
        seen[fid].add(pidx)
        if first_ts is None:
            first_ts = ts
        last_ts = ts

    print(f"[ok]   {n_ok} 包通过全部检查")
    print(f"[bad]  {n_bad} 包被拒: {dict(bad_reason)}")
    if not frames:
        return 0

    fids = sorted(frames)
    span = (last_ts - first_ts) if last_ts and first_ts else 0
    print(f"[frames] {len(fids)} 个 frame_id: {fids[0]}..{fids[-1]}"
          + (f"  span={span:.3f}s  => {len(fids)/span:.1f} fps" if span > 0 else ""))
    full = sum(1 for f in fids if len(seen[f]) == 800)
    print(f"[complete] {full}/{len(fids)} 帧是完整的 800 包")
    miss = [(f, 800 - len(seen[f])) for f in fids if len(seen[f]) != 800]
    if miss[:10]:
        print(f"[missing] 前 10 个缺包的帧: {miss[:10]}")
    lo = min(min(s) for s in seen.values())
    hi = max(max(s) for s in seen.values())
    print(f"[pkt_idx] {lo}..{hi}（期望 0..799）")
    nbytes = sum(len(p) for _, p in pkts)
    if span > 0:
        wire = nbytes + len(pkts) * (4 + 8 + 12)   # FCS + 前导码 + IFG
        print(f"[rate]   {wire*8/span/1e6:.1f} Mbps 在线速率  ({wire/span/1e6:.1f} MB/s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
