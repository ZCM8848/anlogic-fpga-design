#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cam_proc.py — camera_eth_720p 的 RAW10 图像处理公共函数

被 make_video.py / cam_view.py / raw10_pcap_decode.py 复用。

处理链（与 FPGA 无关，全在 PC 上）：
    RAW10 解包 → 黑电平 → 灰世界 AWB → 列固定图案噪声校正 → 自动拉伸 → demosaic
"""
import numpy as np

W, H = 1280, 720
PKT_BYTES = 1440
PKT_TOTAL = 800
FRAME_BYTES = W * H * 10 // 8

BLACK_LEVEL = 64.0


def unpack_raw10(buf):
    """MIPI RAW10 字节流 → uint16 像素（光栅顺序）

    每 5 字节 = 4 像素：
        P0 = b0<<2 | (b4>>0 & 3)
        P1 = b1<<2 | (b4>>2 & 3)
        P2 = b2<<2 | (b4>>4 & 3)
        P3 = b3<<2 | (b4>>6 & 3)
    """
    n = len(buf) // 5 * 5
    a = np.frombuffer(buf[:n], dtype=np.uint8).reshape(-1, 5).astype(np.uint16)
    out = np.empty(a.shape[0] * 4, dtype=np.uint16)
    out[0::4] = (a[:, 0] << 2) | ((a[:, 4] >> 0) & 0x03)
    out[1::4] = (a[:, 1] << 2) | ((a[:, 4] >> 2) & 0x03)
    out[2::4] = (a[:, 2] << 2) | ((a[:, 4] >> 4) & 0x03)
    out[3::4] = (a[:, 3] << 2) | ((a[:, 4] >> 6) & 0x03)
    return out


def frame_pixels(buf):
    """整帧字节 → (H, W) uint16"""
    return unpack_raw10(buf[:FRAME_BYTES])[:W * H].reshape(H, W)


def awb_gains(px, bl=BLACK_LEVEL):
    """灰世界 AWB（BGGR）：返回 (gainB, gainR)，G 归一化为 1"""
    mb = float(px[0::2, 0::2].mean()) - bl
    mg1 = float(px[0::2, 1::2].mean()) - bl
    mg2 = float(px[1::2, 0::2].mean()) - bl
    mr = float(px[1::2, 1::2].mean()) - bl
    mg = 0.5 * (mg1 + mg2)
    mb = max(mb, 1e-3)
    mr = max(mr, 1e-3)
    mg = max(mg, 1e-3)
    return mg / mb, mg / mr


def apply_awb(px, gb, gr, bl=BLACK_LEVEL):
    pf = px.astype(np.float32)
    out = np.empty_like(pf)
    out[0::2, 0::2] = (pf[0::2, 0::2] - bl) * gb
    out[0::2, 1::2] = (pf[0::2, 1::2] - bl)
    out[1::2, 0::2] = (pf[1::2, 0::2] - bl)
    out[1::2, 1::2] = (pf[1::2, 1::2] - bl) * gr
    np.clip(out, 0, 1023, out=out)
    return out


def column_profile(img):
    """每列均值（float32）"""
    return img.mean(axis=0)


def column_correction(profile, k=65):
    """从列均值里提取高频固定图案（去掉缓慢的镜头阴影/场景渐变）"""
    pad = k // 2
    p = np.pad(profile, pad, mode="edge")
    ker = np.ones(k, dtype=np.float32) / k
    smooth = np.convolve(p, ker, mode="same")[pad:pad + len(profile)]
    return profile - smooth


def to_bgr(bal, lo, hi):
    """AWB 后的 10bit 浮点 → 8bit Bayer → BGR"""
    import cv2
    img8 = np.clip((bal - lo) * 255.0 / max(hi - lo, 1e-6), 0, 255).astype(np.uint8)
    return cv2.cvtColor(img8, cv2.COLOR_BayerBG2BGR)


def denoise(bgr, strength=1):
    """轻量降噪：双边滤波（保边，适合后续视觉算法）"""
    import cv2
    if strength <= 0:
        return bgr
    d = 5 if strength == 1 else 7
    return cv2.bilateralFilter(bgr, d, 25 * strength, 5 * strength)


# ======================================================================
# 每帧元数据包（pkt_idx = 0xFFFF，UDP 载荷前 32 字节）
# ======================================================================
META_IDX = 0xFFFF


def parse_meta(p):
    """元数据包 UDP 载荷 → dict；不是元数据包返回 None"""
    if len(p) < 32 or p[0:2] != b"\xA5\x5A":
        return None
    return {
        "frame_id": int.from_bytes(p[2:4], "big"),
        "ae": int.from_bytes(p[4:6], "big"),
        "ag": int.from_bytes(p[6:8], "big"),
        "sensor_id": int.from_bytes(p[8:10], "big"),
        "status": p[10],
        "version": p[11],
        "sum_b": int.from_bytes(p[12:16], "big"),
        "sum_g": int.from_bytes(p[16:20], "big"),
        "sum_r": int.from_bytes(p[20:24], "big"),
        "total_px": int.from_bytes(p[24:28], "big"),
    }


def awb_gains_from_meta(m, bl=BLACK_LEVEL):
    """用 FPGA 统计的 B/G/R 累加和算灰世界增益（扣黑电平）"""
    n = m.get("total_px") or (W * H)
    nb, ng, nr = n // 4, n // 2, n // 4
    sb = max(m["sum_b"] - bl * nb, 1e-3)
    sg = max(m["sum_g"] - bl * ng, 1e-3)
    sr = max(m["sum_r"] - bl * nr, 1e-3)
    return sg / sb, sg / sr
