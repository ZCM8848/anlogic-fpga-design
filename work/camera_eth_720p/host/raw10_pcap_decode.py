#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""raw10_pcap_decode.py — 从抓包还原一帧 RAW10 Bayer 并存成 PNG

用法：
    python raw10_pcap_decode.py cap.pcapng [out.png]

约定（与 FPGA 端 cam_raw10_rx.v 的打包一致）：
    每 5 字节 = 4 个 10bit 像素
    P0 = b0<<2 | (b4>>0 & 3)
    P1 = b1<<2 | (b4>>2 & 3)
    P2 = b2<<2 | (b4>>4 & 3)
    P3 = b3<<2 | (b4>>6 & 3)
    字节流顺序就是光栅顺序 P0,P1,P2,P3,...

Bayer 相位：SC520CS = BGGR（`cv2.COLOR_BayerBG2BGR`）
"""
import sys
import struct
import numpy as np
from collections import defaultdict

W, H = 1280, 720
PKT_BYTES = 1440
PKT_TOTAL = 800
FRAME_BYTES = W * H * 10 // 8          # 1,152,000


def read_pcap(path):
    data = open(path, "rb").read()
    magic = struct.unpack_from("<I", data, 0)[0]
    out = []
    if magic in (0xA1B2C3D4, 0xD4C3B2A1):
        endian = "<" if magic == 0xA1B2C3D4 else ">"
        off = 24
        while off + 16 <= len(data):
            ts, tus, incl, orig = struct.unpack_from(endian + "IIII", data, off)
            off += 16
            out.append((ts + tus / 1e6, data[off:off + incl]))
            off += incl
        return out
    if magic == 0x0A0D0D0A:
        off, endian, tsresol = 0, "<", 6
        while off + 12 <= len(data):
            btype = struct.unpack_from(endian + "I", data, off)[0]
            blen = struct.unpack_from(endian + "I", data, off + 4)[0]
            if blen < 12 or off + blen > len(data):
                break
            body = data[off + 8: off + blen - 4]
            if btype == 0x0A0D0D0A:
                bom = struct.unpack_from("<I", body, 0)[0]
                endian = "<" if bom == 0x1A2B3C4D else ">"
            elif btype == 0x00000001 and len(body) >= 10:
                o = 8
                while o + 4 <= len(body):
                    code, olen = struct.unpack_from(endian + "HH", body, o)
                    if code == 0:
                        break
                    if code == 9 and olen >= 1:
                        tsresol = body[o + 4] & 0x7F
                    o += 4 + ((olen + 3) & ~3)
            elif btype == 0x00000006:
                iface, tsh, tsl, cap, orig = struct.unpack_from(endian + "IIIII", body, 0)
                out.append((((tsh << 32) | tsl) / (10 ** tsresol), body[20:20 + cap]))
            off += blen
        return out
    raise SystemExit("无法识别的抓包格式")


def unpack_raw10(buf):
    """bytes → uint16 pixel array (raster)"""
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
    out_png = sys.argv[2] if len(sys.argv) > 2 else "raw10_frame.png"

    pkts = read_pcap(path)
    print(f"[load] {len(pkts)} packets")

    frames = defaultdict(dict)
    for ts, p in pkts:
        if len(p) < 14 + 20 + 8 + 8:
            continue
        if p[12:14] != b"\x08\x00" or p[23] != 17:
            continue
        ihl = (p[14] & 0x0F) * 4
        total = (p[16] << 8) | p[17]
        payload = p[14 + ihl + 8: 14 + total]
        if len(payload) < 8 or payload[0:2] != b"\xAA\x55":
            continue
        fid, pidx, ptot = struct.unpack(">HHH", payload[2:8])
        body = payload[8:]
        if len(body) != PKT_BYTES:
            continue
        frames[fid][pidx] = body

    complete = [f for f, d in frames.items() if len(d) == PKT_TOTAL]
    print(f"[frames] 收到 {len(frames)} 帧，完整 {len(complete)} 帧")
    if not complete:
        # 退而求其次：包最多的那帧
        best = max(frames.items(), key=lambda kv: len(kv[1]))
        print(f"[warn] 没有完整帧，用 frame {best[0]}（{len(best[1])}/{PKT_TOTAL} 包）")
        fid, d = best
    else:
        fid = complete[0]
        d = frames[fid]
        print(f"[use] frame_id={fid}")

    missing = [i for i in range(PKT_TOTAL) if i not in d]
    if missing:
        print(f"[missing] {len(missing)} 包，前 10 个: {missing[:10]}")

    buf = b"".join(d.get(i, bytes(PKT_BYTES)) for i in range(PKT_TOTAL))
    print(f"[bytes] {len(buf)}  (期望 {FRAME_BYTES})")

    px = unpack_raw10(buf)[: W * H].reshape(H, W)
    print(f"[raw] min={px.min()} max={px.max()} mean={px.mean():.1f}")

    # ---- 灰世界 AWB（BGGR：00=B, 01=G1, 10=G2, 11=R）+ 黑电平 + 自动拉伸 ----
    # RAW10 直出不带 ISP，颜色会严重偏色（补光灯下偏紫），必须先白平衡再转 8bit。
    pf = px.astype(np.float32)
    mb = pf[0::2, 0::2].mean()
    mg1 = pf[0::2, 1::2].mean()
    mg2 = pf[1::2, 0::2].mean()
    mr = pf[1::2, 1::2].mean()
    mg = 0.5 * (mg1 + mg2)

    # 黑电平：SC520CS 约 64
    bl = 64.0
    mb = max(mb - bl, 1e-3)
    mg = max(mg - bl, 1e-3)
    mr = max(mr - bl, 1e-3)

    bal = np.empty_like(pf)
    bal[0::2, 0::2] = (pf[0::2, 0::2] - bl) * (mg / mb)
    bal[0::2, 1::2] = (pf[0::2, 1::2] - bl)
    bal[1::2, 0::2] = (pf[1::2, 0::2] - bl)
    bal[1::2, 1::2] = (pf[1::2, 1::2] - bl) * (mg / mr)
    np.clip(bal, 0, 1023, out=bal)

    lo = float(np.percentile(bal, 0.5))
    hi = float(np.percentile(bal, 99.5))
    if hi - lo < 16:
        hi = lo + 16
    print(f"[awb] B/G/R mean = {mb+bl:.1f}/{mg+bl:.1f}/{mr+bl:.1f}  "
          f"gain B={mg/mb:.2f} R={mg/mr:.2f}")
    print(f"[level] stretch {lo:.0f}..{hi:.0f} -> 0..255")

    img8 = np.clip((bal - lo) * 255.0 / (hi - lo), 0, 255).astype(np.uint8)

    try:
        import cv2
        bgr = cv2.cvtColor(img8, cv2.COLOR_BayerBG2BGR)
        cv2.imwrite(out_png, bgr)
        print(f"[save] {out_png}  (demosaic BGGR + AWB + stretch)")
    except ImportError:
        from PIL import Image
        Image.fromarray(img8).save(out_png)
        print(f"[save] {out_png}  (灰度，未安装 cv2)")

    # 顺便存一份原始 10bit
    npy = out_png.rsplit(".", 1)[0] + "_raw10.npy"
    np.save(npy, px)
    print(f"[save] {npy}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
