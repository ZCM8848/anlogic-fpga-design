# -*- coding: utf-8 -*-
"""
count.py -- 单向计数线穿越计数（Phase C）
========================================
这是 FPGA cv_top.v 目前**还没有**的功能，本文件既是黄金参考实现，也承载
「FPGA 计数线设计规格」（详见函数 docstring 与 README）。

规则（与 impl_a 的 counter.py 同一思想，但更贴近硬件）：
  1. 直线 a*x + b*y + c = 0 把画面分成两侧，side = sign(a*x + b*y + c)。
  2. 轨迹「上一帧侧」与「当前帧侧」不同 = 越过线。
  3. 越线且运动方向与期望方向一致（vel·direction > 0）时 count+1。
  4. 每条轨迹一个 crossed 标志，越线后不再重复计数。

FPGA 设计规格（将加入 cv_top.v）：
  - 每个 track 增补 2 位寄存器：prev_side(1b)、crossed(1b)。
  - 计数线为编译期常量 (a,b,c) 与方向 (dx,dy)，来自现场标定。
  - 每帧 vblank、跟踪器更新后，顺序对每个 track 算：
        side = (a*cx + b*cy + c) > 0            -> 1 次乘加 + 比较
        vdot = vx*dx + vy*dy                     -> 2 次乘 + 加法
    越线且 vdot>0 -> cnt++、置 crossed。
  - 资源：每 track 2 位 FF + 复用 1 个乘加器，约 20 LUT，几乎免费。
  - cnt 经 status_report 串口输出 "CNT=" 字段。
"""


def count_crossings(tracks, a, b, c, dx, dy):
    """
    对 tracks 做一次计数更新。tracks 为 Tracker.tracks（含无效槽）。
    原地更新每个轨迹的 prev_side/crossed，返回本帧新增计数。
    """
    inc = 0
    for t in tracks:
        if not t["valid"]:
            t["prev_side"] = None      # 空槽复位，避免复用后读到旧状态
            continue
        side = (a * t["cx"] + b * t["cy"] + c) > 0
        if t["prev_side"] is None:
            t["prev_side"] = side
            continue
        if side != t["prev_side"] and not t["crossed"]:
            if t["vx"] * dx + t["vy"] * dy > 0:   # 方向一致
                inc += 1
                t["crossed"] = True
        t["prev_side"] = side
    return inc
