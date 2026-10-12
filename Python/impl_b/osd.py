# -*- coding: utf-8 -*-
"""
osd.py -- OSD 叠加（绿框 + ID + 机器视角）+ HUD（计数/状态）
===========================================================
核心叠加（框 + 5x7 ID + 机器视角）等价 cv_top.v 第 394~450 行：

  - 框：绿色边框，线宽 FBOX_W=2（等价 r_border 的门控逻辑）。
  - ID：5x7 字模画在框的**左上角**（与 FPGA 一致；bit4=最左列）。
  - 机器视角：MASK_VIEW=1 时底图 = 掩膜二值（亮=白/暗=黑）。
  - 优先级：ID(白) > 框(绿) > 底图。

HUD（计数 / 状态 / 帧率 / 计数线）是显示层便利，用 cv2 文本；
其中计数线在 FPGA Phase C 由图形发生器画，计数经串口上报。
"""
import cv2
import numpy as np

from font5x7 import render_digit, render_decimal

# 颜色 (BGR)
C_BOX = (0, 255, 0)        # 绿框
C_ID = (255, 255, 255)     # ID 数字（白）
C_COUNT = (0, 255, 255)    # 计数（黄）
C_LINE = (255, 0, 255)     # 计数线（紫）


def render_overlay(base_bgr, mask, tracks, cfg):
    """
    base_bgr: 原始 BGR 帧 (H,W,3)
    mask:     bool (H,W) 掩膜（机器视角用）
    tracks:   有效轨迹快照列表（来自 Tracker.snapshot()，已含 1 帧延迟）
    返回叠加后的 BGR 帧。
    """
    H, W = base_bgr.shape[:2]
    if cfg.mask_view:
        vis = np.zeros((H, W, 3), np.uint8)
        vis[mask] = 255
    else:
        vis = base_bgr.copy()

    fw = cfg.fbox_w
    for t in tracks:
        x0 = max(0, int(t["minx"]))
        x1 = min(W - 1, int(t["maxx"]))
        y0 = max(0, int(t["miny"]))
        y1 = min(H - 1, int(t["maxy"]))
        if x1 < x0 or y1 < y0:
            continue
        # 绿框（上/下横边 + 左/右竖边）
        vis[y0:min(y0 + fw, y1 + 1), x0:x1 + 1] = C_BOX
        vis[max(y0, y1 - fw + 1):y1 + 1, x0:x1 + 1] = C_BOX
        vis[y0:y1 + 1, x0:min(x0 + fw, x1 + 1)] = C_BOX
        vis[y0:y1 + 1, max(x0, x1 - fw + 1):x1 + 1] = C_BOX
        # ID 数字（左上角 5x7）
        render_digit(vis, t["id"], x0, y0, C_ID)

    return vis


def draw_line(frame, a, b, c, color=C_LINE):
    """按 a*x + b*y + c = 0 画计数线（只画落在画面内的部分）。"""
    H, W = frame.shape[:2]
    if abs(b) > abs(a):
        # 水平方向为主：对每个 x 求 y
        xs = [0, W - 1]
        ys = [int(-(a * x + c) / b) for x in xs]
    else:
        # 垂直方向为主：对每个 y 求 x
        ys = [0, H - 1]
        xs = [int(-(b * y + c) / a) for y in ys]
    p1 = (max(0, min(W - 1, xs[0])), max(0, min(H - 1, ys[0])))
    p2 = (max(0, min(W - 1, xs[1])), max(0, min(H - 1, ys[1])))
    cv2.line(frame, p1, p2, color, 2, cv2.LINE_AA)
    return frame


def draw_hud(frame, count, ntrack, fps):
    """显示层 HUD：计数（5x7）、轨迹数、帧率。"""
    render_decimal(frame, count, 12, 12, C_COUNT)
    cv2.putText(frame, "count", (12, 46), cv2.FONT_HERSHEY_SIMPLEX, 0.55,
                (0, 0, 0), 4, cv2.LINE_AA)
    cv2.putText(frame, "count", (12, 46), cv2.FONT_HERSHEY_SIMPLEX, 0.55,
                C_COUNT, 1, cv2.LINE_AA)
    txt = "tracks: %d" % ntrack
    cv2.putText(frame, txt, (12, 70), cv2.FONT_HERSHEY_SIMPLEX, 0.55,
                (0, 0, 0), 4, cv2.LINE_AA)
    cv2.putText(frame, txt, (12, 70), cv2.FONT_HERSHEY_SIMPLEX, 0.55,
                (255, 255, 255), 1, cv2.LINE_AA)
    if fps is not None:
        cv2.putText(frame, "%.1f fps" % fps, (12, frame.shape[0] - 12),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 0), 4, cv2.LINE_AA)
        cv2.putText(frame, "%.1f fps" % fps, (12, frame.shape[0] - 12),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 1, cv2.LINE_AA)
    return frame
