# -*- coding: utf-8 -*-
"""
calibration.py -- 交互式标定：ROI / 计数线 / 运动方向 / 钢珠直径
============================================================
在摄像头实时画面上用鼠标 + 按键完成标定，结果写回 Config 并存成 json。

操作（在标定窗口里按键切换模式）：
  1 : 拖拽矩形 = 设定 ROI（钢珠滚动所在的轨道/横带）
  2 : 先后点两下 = 设定计数线（两点确定一条直线）
  3 : 先后点两下 = 设定运动方向（从第一点指向第二点）
  4 : 拖拽矩形框住一颗清晰的钢珠 = 自动测量钢珠直径(像素)
  r : 清除 ROI / 计数线       s : 保存并退出       q/ESC : 放弃退出
"""
import cv2
import numpy as np


class Calibrator(object):
    def __init__(self, cfg, frame):
        self.cfg = cfg
        self.base = frame.copy()
        self.img = frame.copy()
        self.mode = "roi"
        self.roi = list(cfg.roi) if cfg.roi else None
        self.line = [list(p) for p in cfg.line] if cfg.line else []
        self.direction = list(cfg.direction)
        self.ball_diam = float(cfg.ball_diam_px)
        self._start = None
        self._cur = None
        self._drag = None
        self.win = "calibrate"
        self.saved = False

    # ------------------------------------------------------------------
    def _redraw(self):
        img = self.base.copy()
        if self.roi:
            x, y, w, h = [int(v) for v in self.roi]
            cv2.rectangle(img, (x, y), (x + w, y + h), (255, 200, 0), 2)
            cv2.putText(img, "ROI", (x + 4, y + 20), cv2.FONT_HERSHEY_SIMPLEX,
                        0.6, (255, 200, 0), 2)
        for p in self.line:
            cv2.circle(img, (int(p[0]), int(p[1])), 4, (255, 0, 255), -1)
        if len(self.line) == 2:
            a = (int(self.line[0][0]), int(self.line[0][1]))
            b = (int(self.line[1][0]), int(self.line[1][1]))
            cv2.line(img, a, b, (255, 0, 255), 2)
        if self._start is not None and self._cur is not None:
            if self.mode in ("roi", "ball"):
                cv2.rectangle(img, self._start, self._cur, (0, 255, 255), 2)
            else:
                cv2.arrowedLine(img, self._start, self._cur, (0, 255, 255), 2)
        cv2.putText(img, "mode=%s diam=%.1fpx" % (self.mode, self.ball_diam),
                    (16, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 0), 2)
        cv2.putText(img, "1 ROI  2 line  3 dir  4 ball  r reset  s save  q quit",
                    (16, self.base.shape[0] - 16), cv2.FONT_HERSHEY_SIMPLEX,
                    0.6, (255, 255, 255), 2)
        self.img = img
        cv2.imshow(self.win, img)

    def _measure_diameter(self, p0, p1):
        x0, y0 = min(p0[0], p1[0]), min(p0[1], p1[1])
        x1, y1 = max(p0[0], p1[0]), max(p0[1], p1[1])
        x0 = max(0, x0); y0 = max(0, y0)
        x1 = min(self.base.shape[1], x1); y1 = min(self.base.shape[0], y1)
        if x1 - x0 < 3 or y1 - y0 < 3:
            return
        crop = self.base[y0:y1, x0:x1]
        gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
        # 光照归一化，抗亮度不均
        g = cv2.GaussianBlur(gray, (0, 0), 15)
        g = np.maximum(g, 1)
        norm = cv2.divide(gray, g, scale=128.0)
        _, bw = cv2.threshold(norm, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        # 前景可能是亮球也可能是暗球，取面积更接近“圆”的一侧
        best_d = None
        for mask in (bw, cv2.bitwise_not(bw)):
            cnts, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL,
                                       cv2.CHAIN_APPROX_SIMPLE)
            if not cnts:
                continue
            c = max(cnts, key=cv2.contourArea)
            area = cv2.contourArea(c)
            if area <= 4:
                continue
            per = cv2.arcLength(c, True)
            if per <= 0:
                continue
            circ = 4 * np.pi * area / (per * per)
            if best_d is None or circ > best_d[1]:
                best_d = (2.0 * np.sqrt(area / np.pi), circ)
        if best_d is not None:
            self.ball_diam = float(best_d[0])
            print("[calib] ball diameter = %.1f px (circ=%.2f)" % best_d)

    # ------------------------------------------------------------------
    def _on_mouse(self, event, x, y, flags, param):
        if event == cv2.EVENT_LBUTTONDOWN:
            self._start = (x, y)
            self._cur = (x, y)
        elif event == cv2.EVENT_MOUSEMOVE and self._start is not None:
            self._cur = (x, y)
        elif event == cv2.EVENT_LBUTTONUP and self._start is not None:
            self._cur = (x, y)
            p0, p1 = self._start, self._cur
            if self.mode == "roi":
                rx, ry = min(p0[0], p1[0]), min(p0[1], p1[1])
                rw, rh = abs(p1[0] - p0[0]), abs(p1[1] - p0[1])
                if rw > 4 and rh > 4:
                    self.roi = [rx, ry, rw, rh]
            elif self.mode == "line":
                self.line.append([p0[0], p0[1]])
                if len(self.line) > 2:
                    self.line = self.line[-2:]
            elif self.mode == "dir":
                if len(self.line) == 2:
                    self.line = self.line  # noop
                dx, dy = p1[0] - p0[0], p1[1] - p0[1]
                if abs(dx) + abs(dy) > 4:
                    n = (dx * dx + dy * dy) ** 0.5
                    self.direction = [dx / n, dy / n]
            elif self.mode == "ball":
                self._measure_diameter(p0, p1)
            self._start = None
            self._cur = None

    # ------------------------------------------------------------------
    def run(self):
        cv2.namedWindow(self.win, cv2.WINDOW_NORMAL)
        cv2.setMouseCallback(self.win, self._on_mouse)
        while True:
            self._redraw()
            k = cv2.waitKey(30) & 0xFF
            if k == 27 or k == ord("q"):
                self.saved = False
                break
            elif k == ord("1"):
                self.mode = "roi"
            elif k == ord("2"):
                self.mode = "line"
                self.line = []
            elif k == ord("3"):
                self.mode = "dir"
            elif k == ord("4"):
                self.mode = "ball"
            elif k == ord("r"):
                self.roi = None
                self.line = []
            elif k == ord("s"):
                self.cfg.roi = self.roi
                self.cfg.line = self.line if len(self.line) == 2 else None
                self.cfg.direction = self.direction
                self.cfg.ball_diam_px = self.ball_diam
                self.saved = True
                break
        cv2.destroyWindow(self.win)
        return self.saved
