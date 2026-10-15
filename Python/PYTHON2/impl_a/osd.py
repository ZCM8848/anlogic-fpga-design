# -*- coding: utf-8 -*-
"""
osd.py -- OSD 叠加绘制（方框 / ID / 计数 / 计数线 / Logo）
============================================================
全部用 OpenCV 画在帧上模拟 FPGA 的 OSD 叠加层。

坐标约定：内部一律使用“处理分辨率”坐标，绘制时用 inv_scale 换算回全分辨率。

FPGA 对照：这些矩形/文字最终由硬件图形发生器在 HDMI 输出上叠加，
           ID 数字用字模 ROM，方框用计数器生成的矩形波门。
"""
import cv2

# 颜色 (BGR)
C_BOX = (0, 255, 0)      # 已确认目标：绿
C_BOX_NEW = (0, 200, 255)  # 未确认候选：橙黄
C_COUNT = (0, 255, 255)  # 计数：黄
C_LINE = (255, 0, 255)   # 计数线：紫
C_ROI = (255, 200, 0)    # ROI：青蓝
C_LOGO = (255, 255, 255)


def draw_track(frame, track, inv, color=C_BOX, thickness=2):
    """画一颗钢珠的方框，并在框的右上角标注 ID。"""
    cx = int(track.pos[0] * inv)
    cy = int(track.pos[1] * inv)
    r = max(4, int(track.r * inv * 1.25) + 2)  # 略微放大，完整包住钢珠
    x1, y1 = cx - r, cy - r
    x2, y2 = cx + r, cy + r

    cv2.rectangle(frame, (x1, y1), (x2, y2), color, thickness)

    label = str(track.id)
    (tw, th), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.6, 2)
    tx = x2 - tw                      # 右上角对齐
    ty = y1 - 4
    if ty - th < 0:                   # 太靠上时画到框内顶部
        ty = y1 + th + 4
    cv2.rectangle(frame, (tx - 3, ty - th - 3), (tx + tw + 3, ty + 3), color, -1)
    cv2.putText(frame, label, (tx, ty), cv2.FONT_HERSHEY_SIMPLEX, 0.6,
                (0, 0, 0), 2, cv2.LINE_AA)
    return frame


def draw_trail(frame, track, inv, color=C_BOX):
    pts = [(int(p[0] * inv), int(p[1] * inv)) for p in track.trail]
    for i in range(1, len(pts)):
        cv2.line(frame, pts[i - 1], pts[i], color, 1, cv2.LINE_AA)


def draw_count(frame, count):
    text = "Count: %d" % count
    cv2.putText(frame, text, (24, 56), cv2.FONT_HERSHEY_SIMPLEX, 1.4,
                (0, 0, 0), 6, cv2.LINE_AA)
    cv2.putText(frame, text, (24, 56), cv2.FONT_HERSHEY_SIMPLEX, 1.4,
                C_COUNT, 2, cv2.LINE_AA)
    return frame


def draw_line(frame, p1, p2, direction, inv, color=C_LINE):
    a = (int(p1[0] * inv), int(p1[1] * inv))
    b = (int(p2[0] * inv), int(p2[1] * inv))
    cv2.line(frame, a, b, color, 2, cv2.LINE_AA)
    mid = ((a[0] + b[0]) // 2, (a[1] + b[1]) // 2)
    tip = (int(mid[0] + direction[0] * 50), int(mid[1] + direction[1] * 50))
    cv2.arrowedLine(frame, mid, tip, color, 2, cv2.LINE_AA, tipLength=0.25)
    return frame


def draw_roi(frame, roi, color=C_ROI):
    x, y, w, h = [int(v) for v in roi]
    cv2.rectangle(frame, (x, y), (x + w, y + h), color, 2)
    return frame


def draw_logo(frame):
    """预留的“安路”标识位（FPGA 版用硬件叠加真实 Logo）。"""
    h, w = frame.shape[:2]
    text = "AL / Anlogic"
    (tw, th), _ = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, 0.7, 2)
    org = (w - tw - 20, h - 20)
    cv2.rectangle(frame, (org[0] - 8, org[1] - th - 8),
                  (org[0] + tw + 8, org[1] + 8), (0, 0, 0), -1)
    cv2.putText(frame, text, org, cv2.FONT_HERSHEY_SIMPLEX, 0.7,
                C_LOGO, 2, cv2.LINE_AA)
    return frame


def draw_fps(frame, fps, procfps):
    txt = "%.1f fps (proc %.1f)" % (fps, procfps)
    cv2.putText(frame, txt, (24, frame.shape[0] - 24),
                cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 0), 5, cv2.LINE_AA)
    cv2.putText(frame, txt, (24, frame.shape[0] - 24),
                cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 2, cv2.LINE_AA)
    return frame


def draw_status(frame, confirmed, total_candidates):
    txt = "tracks: %d/%d" % (confirmed, total_candidates)
    cv2.putText(frame, txt, (24, 100), cv2.FONT_HERSHEY_SIMPLEX, 0.7,
                (0, 0, 0), 5, cv2.LINE_AA)
    cv2.putText(frame, txt, (24, 100), cv2.FONT_HERSHEY_SIMPLEX, 0.7,
                (255, 255, 255), 2, cv2.LINE_AA)
    return frame
