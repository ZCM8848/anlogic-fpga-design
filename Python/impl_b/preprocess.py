# -*- coding: utf-8 -*-
"""
preprocess.py -- 亮度提取 + Sobel 3x3 边缘幅值（定点，逐位对齐 cv_top.v）
=====================================================================
纯 numpy 整数运算，无任何 cv2 黑盒。每个函数都注明对应 cv_top.v 的 RTL 行号，
保证 PC 端与 FPGA 端得到**相同的像素级中间结果**。

FPGA 对照：
  - luma : 组合逻辑，Y=(R>>2)+(G>>1)+(B>>2)，0 资源，无溢出(<=253)。
  - sobel: 2 行缓存 BRAM(每行 1280x8b) + 加法器，~150 LUT。
"""
import numpy as np


def luma(bgr):
    """
    亮度提取，等价 cv_top.v 第 80 行：
        w_y = {2'b0,I_data[23:18]} + {1'b0,I_data[15:9]} + {2'b0,I_data[7:2]}
            = (R>>2) + (G>>1) + (B>>2)
    输入 bgr 为 OpenCV 读入的 BGR 顺序 uint8 (H,W,3)：
        R = bgr[...,2], G = bgr[...,1], B = bgr[...,0]
    输出 uint8 (H,W)，范围 0..253。
    """
    R = bgr[..., 2].astype(np.uint16)
    G = bgr[..., 1].astype(np.uint16)
    B = bgr[..., 0].astype(np.uint16)
    Y = (R >> 2) + (G >> 1) + (B >> 2)
    return Y.astype(np.uint8)


def sobel_magnitude(Y):
    """
    Sobel 3x3 边缘幅值，等价 cv_top.v 第 87~103 行：
        gx = (上排加权和) - (下排加权和)，中列权 2
        gy = (左列加权和) - (右列加权和)，中行权 2
        mag = |gx| + |gy|
    返回 int32 (H,W)，中心像素与输入对齐（FPGA 因流水中断有 1px 偏移，不可见）。
    """
    H, W = Y.shape
    y = Y.astype(np.int32)
    # 边界补 0：cv_top 的 edge_mask 要求 x>=2 && y>=2，边界像素不参与，
    # 故补零边界不影响结果（边界被掩掉）。
    p = np.zeros((H + 2, W + 2), np.int32)
    p[1:-1, 1:-1] = y

    a = p[0:-2, 0:-2]   # 左上
    b = p[0:-2, 1:-1]   # 上中
    c = p[0:-2, 2:]     # 右上
    d = p[1:-1, 0:-2]   # 中左
    f = p[1:-1, 2:]     # 中右
    g = p[2:, 0:-2]     # 下左
    h = p[2:, 1:-1]     # 下中
    i = p[2:, 2:]       # 下右

    gx = (a + 2 * b + c) - (g + 2 * h + i)
    gy = (a + 2 * d + g) - (c + 2 * f + i)
    mag = np.abs(gx) + np.abs(gy)
    return mag
