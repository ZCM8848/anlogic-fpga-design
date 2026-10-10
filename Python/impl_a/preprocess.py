# -*- coding: utf-8 -*-
"""
preprocess.py -- 图像预处理：灰度化 / 光照归一化 / CLAHE
============================================================
目的：把“对外界环境光敏感”的程度尽量压低。

核心思想：绝对亮度不可信，相对亮度才可靠。
  illumination_normalize():  gray / (大核高斯模糊)  ->  消除光照不均与整体明暗漂移。
  CLAHE:                    可选局部对比度增强。

FPGA 对照：
  - 灰度化: 定点系数 Y ≈ (77*R + 150*G + 29*B) >> 8
  - 大核模糊: 可用“降采样背景缓存 + 双线性插值”近似，避免真正的 25x25 卷积
  - 除法:    可用“倒数查找表 + 乘法”实现
  - CLAHE:   需要直方图统计与重映射，资源较大，硬件上为可选/降级方案
"""
import cv2
import numpy as np


def illumination_normalize(gray, sigma=25, target=128.0):
    """
    用大核高斯模糊估计低频照度，再用当前像素除以该照度。
    结果：局部灰度差异被保留，而缓慢的光照梯度/整体明暗变化被消除。
    """
    bg = cv2.GaussianBlur(gray, (0, 0), sigma)
    bg = np.maximum(bg, 1)                     # 防止除零
    norm = cv2.divide(gray, bg, scale=target)  # 让“等于局部均值”的像素回到 target
    return norm


class Preprocessor(object):
    def __init__(self, cfg):
        self.cfg = cfg
        self.clahe = None
        if cfg.use_clahe:
            self.clahe = cv2.createCLAHE(clipLimit=cfg.clahe_clip,
                                         tileGridSize=(8, 8))

    def process(self, gray):
        cfg = self.cfg
        if cfg.use_illum_norm:
            gray = illumination_normalize(gray, cfg.illum_sigma)
        if self.clahe is not None:
            gray = self.clahe.apply(gray)
        return gray
