# -*- coding: utf-8 -*-
"""
hw_ops.py -- 像素级流式算子（逐行可流水线化）
============================================================
每个函数对应 RTL 里的一个流水级。处理顺序与硬件一致：

  resize_proc   : 2x2 盒平均下采样          -> 2 行缓存 + 1 个加法树
  to_gray       : BT.601 定点灰度            -> 3 乘 + 加法树 + 移位
  illum_norm    : 块均值背景 + 双线性 + 除法 -> 块缓存 + 双线性 + 倒数 LUT
  iir_update    : IIR 背景更新               -> 1 乘 + 1 加 + 移位
  fg_mask       : |cur-bg| > thr             -> 1 减 + 取绝对值 + 比较
  erode/dilate  : 窗口 min/max               -> 移位寄存器 + 比较树
  morph_open/close/v_open                    -> 腐蚀/膨胀级联
  build_roi_mask: 窗口比较
  sat_approx    : RGB -> 饱和度近似          -> 3 比较 + 1 减 + 倒数 LUT
注意：这里用 numpy 数组表示"整帧"，仅为了在 PC 上可运行；
硬件里同一段代码是**逐行**流过行缓存/窗口寄存器的。
"""
import numpy as np

from hw_fixed import RECIP_Q16, ema


# ----------------------------------------------------------------------------
# 下采样（2x2 盒平均；其它比例退化为 nearest，保留接口）
# ----------------------------------------------------------------------------
def resize_proc(bgr, cfg):
    if cfg.scale_den == 2 and cfg.scale_num == 1:
        h, w = bgr.shape[:2]
        h2, w2 = (h // 2) * 2, (w // 2) * 2
        a = bgr[:h2:2, :w2:2].astype(np.int32)
        b = bgr[1:h2:2, :w2:2].astype(np.int32)
        c = bgr[:h2:2, 1:w2:2].astype(np.int32)
        d = bgr[1:h2:2, 1:w2:2].astype(np.int32)
        return ((a + b + c + d) >> 2).astype(np.uint8)
    # 通用：整数最近邻（非 1/2 比例时；仅作占位，硬件用行/列计数器抽取）
    h, w = bgr.shape[:2]
    nh = h * cfg.scale_num // cfg.scale_den
    nw = w * cfg.scale_num // cfg.scale_den
    yi = (np.arange(nh) * h // nh)
    xi = (np.arange(nw) * w // nw)
    return bgr[np.ix_(yi, xi)].copy()


# ----------------------------------------------------------------------------
# 灰度
# ----------------------------------------------------------------------------
def to_gray(bgr, cfg):
    b = bgr[:, :, 0].astype(np.int32)
    g = bgr[:, :, 1].astype(np.int32)
    r = bgr[:, :, 2].astype(np.int32)
    y = (cfg.GY_R * r + cfg.GY_G * g + cfg.GY_B * b) >> 8
    return np.clip(y, 0, 255).astype(np.uint8)


# ----------------------------------------------------------------------------
# 光照归一化：块均值背景 + 整数双线性放大 + 倒数 LUT 除法
# ----------------------------------------------------------------------------
def _block_mean(img, block):
    h, w = img.shape
    hh, ww = h // block, w // block
    if hh == 0 or ww == 0:
        return img.astype(np.int32)
    crop = img[:hh * block, :ww * block].astype(np.int32)
    s = crop.reshape(hh, block, ww, block).sum(axis=(1, 3))
    sh = 2 * (block.bit_length() - 1)     # block 为 2 的幂：/block^2 = >> (2*log2(block))
    return s >> sh


def _upsample_bilinear_int(small, H, W):
    hh, ww = small.shape
    xs = (np.arange(W) * (ww << 8)) // W
    ys = (np.arange(H) * (hh << 8)) // H
    x0 = np.clip(xs >> 8, 0, ww - 1)
    y0 = np.clip(ys >> 8, 0, hh - 1)
    x1 = np.clip(x0 + 1, 0, ww - 1)
    y1 = np.clip(y0 + 1, 0, hh - 1)
    fx = (xs & 0xFF)[None, :]
    fy = (ys & 0xFF)[:, None]
    s = small.astype(np.int32)
    v00 = s[np.ix_(y0, x0)]
    v01 = s[np.ix_(y0, x1)]
    v10 = s[np.ix_(y1, x0)]
    v11 = s[np.ix_(y1, x1)]
    top = (v00 * (256 - fx) + v01 * fx) >> 8
    bot = (v10 * (256 - fx) + v11 * fx) >> 8
    return (top * (256 - fy) + bot * fy) >> 8


def illum_norm(gray, cfg):
    small = _block_mean(gray, cfg.illum_block)
    bg = _upsample_bilinear_int(small, gray.shape[0], gray.shape[1])
    den = np.clip(bg, 1, 255)
    recip = np.array(RECIP_Q16, dtype=np.int64)[den]
    # norm = gray * TARGET * RECIP[den] >> 16
    norm = (gray.astype(np.int64) * cfg.norm_target * recip) >> 16
    return np.clip(norm, 0, 255).astype(np.uint8)


# ----------------------------------------------------------------------------
# IIR 背景 + 前景阈值
# ----------------------------------------------------------------------------
def iir_update(bg, cur, alpha_q8):
    bg_i = bg.astype(np.int32)
    out = ema(bg_i, cur.astype(np.int32), alpha_q8)
    return np.clip(out, 0, 255).astype(np.uint8)


def fg_mask(cur, bg, thresh):
    d = np.abs(cur.astype(np.int32) - bg.astype(np.int32))
    return (d > thresh).astype(np.uint8)


# ----------------------------------------------------------------------------
# 形态学（窗口 min/max）
# ----------------------------------------------------------------------------
def _se_offsets(k, shape="ellipse"):
    r = k // 2
    offs = []
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            if shape == "rect" or (dx * dx + dy * dy) <= (r * r + r):
                offs.append((dy, dx))
    return offs


def _shift(mask, dy, dx, fill):
    out = np.full(mask.shape, fill, dtype=mask.dtype)
    H, W = mask.shape
    ys_src = slice(max(0, dy), H + min(0, dy))
    xs_src = slice(max(0, dx), W + min(0, dx))
    ys_dst = slice(max(0, -dy), H + min(0, -dy))
    xs_dst = slice(max(0, -dx), W + min(0, -dx))
    out[ys_dst, xs_dst] = mask[ys_src, xs_src]
    return out


def erode(mask, offs):
    acc = mask.copy()
    for dy, dx in offs:
        if dy == 0 and dx == 0:
            continue
        acc = np.minimum(acc, _shift(mask, dy, dx, 1))
    return acc


def dilate(mask, offs):
    acc = mask.copy()
    for dy, dx in offs:
        if dy == 0 and dx == 0:
            continue
        acc = np.maximum(acc, _shift(mask, dy, dx, 0))
    return acc


def morph_open(mask, k, shape="ellipse"):
    offs = _se_offsets(k, shape)
    return dilate(erode(mask, offs), offs)


def morph_close(mask, k, shape="ellipse"):
    offs = _se_offsets(k, shape)
    return erode(dilate(mask, offs), offs)


def v_open(mask, length):
    """竖向开运算：仅在列方向有足够厚度的结构（钢珠）保留，细长水平条被去掉。"""
    half = length // 2
    offs = [(dy, 0) for dy in range(-half, half + 1)]
    return dilate(erode(mask, offs), offs)


# ----------------------------------------------------------------------------
# ROI
# ----------------------------------------------------------------------------
def build_roi_mask(shape, roi, scale_num, scale_den):
    H, W = shape
    if not roi:
        return None
    x, y, w, h = roi
    x = x * scale_num // scale_den
    y = y * scale_num // scale_den
    w = w * scale_num // scale_den
    h = h * scale_num // scale_den
    x = max(0, min(W - 1, x))
    y = max(0, min(H - 1, y))
    w = max(1, min(W - x, w))
    h = max(1, min(H - y, h))
    m = np.zeros((H, W), np.uint8)
    m[y:y + h, x:x + w] = 1
    return m


# ----------------------------------------------------------------------------
# 颜色门：RGB -> 饱和度近似（HSV 的 S，整数）
# ----------------------------------------------------------------------------
def sat_approx(bgr):
    b = bgr[:, :, 0].astype(np.int32)
    g = bgr[:, :, 1].astype(np.int32)
    r = bgr[:, :, 2].astype(np.int32)
    mx = np.maximum(np.maximum(r, g), b)
    mn = np.minimum(np.minimum(r, g), b)
    recip = np.array(RECIP_Q16, dtype=np.int64)[np.clip(mx, 1, 255)]
    s = ((mx - mn) * 255 * recip) >> 16
    return np.clip(s, 0, 255).astype(np.uint8)
