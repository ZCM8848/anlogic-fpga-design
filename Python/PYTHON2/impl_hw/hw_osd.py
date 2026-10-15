# -*- coding: utf-8 -*-
"""
hw_osd.py -- OSD 叠加（方框 / ID / 计数 / 计数线 / Logo）
============================================================
注意：OSD 只是"显示"层，不属于要上板的检测算法；这里用 OpenCV 画，
与 impl_a/osd.py 一致（坐标换算成整数）。硬件侧用：
  方框 -> 计数器生成的矩形波门；ID -> 字模 ROM；Logo -> 位图 ROM。
"""
import cv2

C_BOX = (0, 255, 0)
C_BOX_NEW = (0, 200, 255)
C_COUNT = (0, 255, 255)
C_LINE = (255, 0, 255)
C_ROI = (255, 200, 0)
C_LOGO = (255, 255, 255)


def draw_track(frame, track, inv_num, inv_den, color=C_BOX, thickness=2):
    cx = int((track.x * inv_num) // (256 * inv_den))
    cy = int((track.y * inv_num) // (256 * inv_den))
    r = int((track.r * inv_num) // (256 * inv_den))
    r = max(4, int(r * 1.25) + 2)
    x1, y1, x2, y2 = cx - r, cy - r, cx + r, cy + r
    cv2.rectangle(frame, (x1, y1), (x2, y2), color, thickness)
    label = str(track.id)
    (tw, th), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.6, 2)
    tx = x2 - tw
    ty = y1 - 4
    if ty - th < 0:
        ty = y1 + th + 4
    cv2.rectangle(frame, (tx - 3, ty - th - 3), (tx + tw + 3, ty + 3), color, -1)
    cv2.putText(frame, label, (tx, ty), cv2.FONT_HERSHEY_SIMPLEX, 0.6,
                (0, 0, 0), 2, cv2.LINE_AA)
    return frame


def draw_count(frame, count):
    text = "Count: %d" % count
    cv2.putText(frame, text, (24, 56), cv2.FONT_HERSHEY_SIMPLEX, 1.4,
                (0, 0, 0), 6, cv2.LINE_AA)
    cv2.putText(frame, text, (24, 56), cv2.FONT_HERSHEY_SIMPLEX, 1.4,
                C_COUNT, 2, cv2.LINE_AA)
    return frame


def draw_line(frame, p1, p2, direction, color=C_LINE):
    a = (int(p1[0]), int(p1[1]))
    b = (int(p2[0]), int(p2[1]))
    cv2.line(frame, a, b, color, 2, cv2.LINE_AA)
    mid = ((a[0] + b[0]) // 2, (a[1] + b[1]) // 2)
    tip = (int(mid[0] + direction[0] * 50), int(mid[1] + direction[1] * 50))
    cv2.arrowedLine(frame, mid, tip, color, 2, cv2.LINE_AA, tipLength=0.25)
    return frame


def draw_roi(frame, roi, color=C_ROI):
    x, y, w, h = [int(v) for v in roi]
    cv2.rectangle(frame, (x, y), (x + w, y + h), color, 2)
    return frame


def draw_status(frame, confirmed, total):
    txt = "tracks: %d/%d" % (confirmed, total)
    cv2.putText(frame, txt, (24, 100), cv2.FONT_HERSHEY_SIMPLEX, 0.7,
                (0, 0, 0), 5, cv2.LINE_AA)
    cv2.putText(frame, txt, (24, 100), cv2.FONT_HERSHEY_SIMPLEX, 0.7,
                (255, 255, 255), 2, cv2.LINE_AA)
    return frame
