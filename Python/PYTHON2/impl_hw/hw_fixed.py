# -*- coding: utf-8 -*-
"""
hw_fixed.py -- 定点基础算子（每个函数 = 一个可综合的硬件单元）
============================================================
这里只保留 FPGA 上"能直接落"的运算：乘、加、移位、比较、min/max、整数开方、
倒数查找表。**没有 float**。

硬件映射：
  RECIP_Q16   -> 256x16 的单口 ROM（倒数 LUT）
  div_recip    -> LUT 查表 + 1 个乘法器 + 右移
  ema          -> 1 乘 + 1 加 + 1 算术右移（IIR 一阶）
  isqrt        -> CORDIC / 逐位开方（或 LUT + 迭代）
  clamp        -> 2 个比较器的饱和逻辑
"""
import math

# ---- 倒数查找表：RECIP_Q16[d] ≈ 65536 / d，d = 1..255 ----
RECIP_Q16 = [0] * 256
for _i in range(1, 256):
    RECIP_Q16[_i] = (1 << 16) // _i


def div_recip(num, den):
    """num / den 的硬件实现：num * RECIP[den] >> 16。den∈[1,255] 查表，其它退化整数除。"""
    if den <= 0:
        den = 1
    if den > 255:
        return num // den
    return (num * RECIP_Q16[den]) >> 16


def ema(prev, cur, alpha_q8, shift=8):
    """一阶 IIR：prev + ((cur-prev)*alpha)>>shift。支持标量或 numpy 数组。"""
    return prev + (((cur - prev) * alpha_q8) >> shift)


def clamp(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)


def clip_arr(a, lo, hi):
    import numpy as np
    return np.clip(a, lo, hi)


def isqrt(v):
    """整数开方（硬件为逐位/CORDIC）。v<=0 返回 0。"""
    if v <= 0:
        return 0
    return math.isqrt(int(v))


def q8(v):
    """标量 -> Q8.8 定点整数（编译期常量用）。"""
    return int(round(v * 256.0))


def mul_q8(a, b):
    """两个 Q8.8 相乘 -> Q8.8（右移 8 位）。"""
    return (a * b) >> 8


def div_q8(a, b):
    """两个 Q8.8 相除 -> Q8.8。"""
    if b == 0:
        return 0
    return (a << 8) // b
