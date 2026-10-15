# -*- coding: utf-8 -*-
"""
detector.py -- 钢珠检测：运动前景 + 形状/尺度筛选
============================================================
思路（针对复杂背景、反光、其他运动物体的场景）：
  1) 背景建模(MOG2, 建在“光照归一化图”上) [+可选帧差]  ->  只保留“运动”的东西，
     且全局亮度/曝光变化不会把整片区域误判为前景
  2) ROI 掩膜限制在轨道/横带内                   ->  压制静止背景与反光
  3) 形态学开/闭 + 竖向开运算去水平细条           ->  清理碎点与高对比边界伪影
  4) 连通域 + 面积/圆度/填充率/长宽比筛选        ->  只留“圆形 + 合适大小”的块
     其中“合适大小”由钢珠直径推出：面积 ∈ π(d/2)²·(1±tol)
     人手等大物体因面积超上限被剔除；细长条带因长宽比超限被剔除
  5) 颜色门(可选): 金属钢珠低饱和，人手/彩色物体高饱和 -> 剔除
  6) 图像矩求质心，r=√(A/π) 估半径

FPGA 对照：
  - MOG2 -> 用 IIR 滑动均值背景 (bg = bg*(1-a) + cur*a)，absdiff 后阈值
  - 帧差 -> 行缓存保存 N-2 帧的若干行 (取决于行数) 或整帧缓存
  - 连通域 -> 一行一行的 run-length 标记 + 并查集合并；同时统计面积/包围盒/周长
  - 圆度/填充率 -> 定点乘除比较
"""
import cv2
import numpy as np

from collections import deque as _deque

from preprocess import Preprocessor


class Detection(object):
    __slots__ = ("x", "y", "r", "area", "circularity")

    def __init__(self, x, y, r, area, circ):
        self.x = float(x)
        self.y = float(y)
        self.r = float(r)
        self.area = float(area)
        self.circularity = float(circ)


class BallDetector(object):
    def __init__(self, cfg):
        self.cfg = cfg
        self.pre = Preprocessor(cfg)
        self.bg = None
        self.prev_proc = None
        self.frame_idx = 0
        self.diam_hist = _deque(maxlen=60)
        self.est_diam_px = None
        self._make_bg()

    # ------------------------------------------------------------------
    def _make_bg(self):
        if self.cfg.use_mog2:
            self.bg = cv2.createBackgroundSubtractorMOG2(
                history=self.cfg.bg_history,
                varThreshold=self.cfg.var_threshold,
                detectShadows=self.cfg.detect_shadows,
            )

    def reset(self):
        """切换视频/摄像头或重新开始时清空背景模型。"""
        self._make_bg()
        self.prev_proc = None
        self.frame_idx = 0
        self.diam_hist.clear()
        self.est_diam_px = None

    # ------------------------------------------------------------------
    def _effective_diam(self):
        """当前采用的钢珠直径(全分辨率像素)：优先自动估计值，否则用配置值。"""
        if self.cfg.auto_diam and self.est_diam_px is not None:
            return self.est_diam_px
        return self.cfg.ball_diam_px

    # ------------------------------------------------------------------
    def _detect_hough(self, proc_frame, roi_mask=None):
        """
        外观(霍夫圆)检测：适合“深色球在浅色背景、相机可能平移、球快或相互接触”的场景。
        步骤：光照归一化 -> 霍夫圆 -> “圆内must be暗且基本填满”校验(压制木纹误检)。
        """
        cfg = self.cfg
        gray = cv2.cvtColor(proc_frame, cv2.COLOR_BGR2GRAY)
        norm = self.pre.process(gray)
        dark = cv2.threshold(norm, 128 - cfg.hough_dark_offset, 255,
                             cv2.THRESH_BINARY_INV)[1]
        blur = cv2.medianBlur(norm, 5)
        h, w = norm.shape[:2]

        cs = cv2.HoughCircles(blur, cv2.HOUGH_GRADIENT, dp=cfg.hough_dp,
                              minDist=int(cfg.hough_min_dist),
                              param1=cfg.hough_param1, param2=cfg.hough_param2,
                              minRadius=int(cfg.hough_min_radius),
                              maxRadius=int(cfg.hough_max_radius))
        dets = []
        if cs is None:
            return dets, dark
        for (x, y, r) in np.round(cs[0]).astype(float):
            if x - r < 1 or y - r < 1 or x + r >= w - 1 or y + r >= h - 1:
                continue
            cx, cy = int(x), int(y)
            if roi_mask is not None and roi_mask[cy, cx] == 0:
                continue
            m = np.zeros((h, w), np.uint8)
            cv2.circle(m, (cx, cy), max(3, int(r * 0.75)), 255, -1)
            mean_g = cv2.mean(norm, mask=m)[0]
            dark_frac = cv2.mean(dark, mask=m)[0] / 255.0
            if mean_g < cfg.hough_dark_mean and dark_frac > cfg.hough_dark_frac:
                dets.append(Detection(x, y, r, np.pi * r * r, 1.0))
        return dets, dark

    # ------------------------------------------------------------------
    def detect(self, proc_frame, roi_mask=None):
        """
        proc_frame: 处理分辨率下的 BGR 帧
        roi_mask:   处理分辨率下的 ROI 掩膜(0/255)，None 表示全画面
        返回: (detections, fg_mask)
        """
        cfg = self.cfg
        self.frame_idx += 1
        if cfg.detector_mode == "hough":
            return self._detect_hough(proc_frame, roi_mask)
        gray = cv2.cvtColor(proc_frame, cv2.COLOR_BGR2GRAY)
        proc = self.pre.process(gray)

        mask = None
        # --- 1) 背景建模 ---
        # 关键: 背景模型跑在“光照归一化”后的图上，这样全局亮度/自动曝光变化
        #       不会把整片区域误判成前景(否则会出现巨大前景块把钢珠淹没)
        if self.bg is not None:
            m = self.bg.apply(proc)
            # 只保留前景(阴影为 127 灰阶, 已被阈值掉)
            m = cv2.threshold(m, 200, 255, cv2.THRESH_BINARY)[1]
            mask = m

        # --- 2) 帧差法 ---
        if cfg.use_frame_diff and self.prev_proc is not None:
            d = cv2.absdiff(proc, self.prev_proc)
            _, db = cv2.threshold(d, cfg.diff_threshold, 255, cv2.THRESH_BINARY)
            mask = db if mask is None else cv2.max(mask, db)

        self.prev_proc = proc

        if mask is None:
            return [], np.zeros_like(gray)

        # --- 3) ROI ---
        if roi_mask is not None:
            mask = cv2.bitwise_and(mask, roi_mask)

        # --- 4) 形态学去噪 ---
        k_open = cv2.getStructuringElement(cv2.MORPH_ELLIPSE,
                                           (cfg.morph_open, cfg.morph_open))
        k_close = cv2.getStructuringElement(cv2.MORPH_ELLIPSE,
                                            (cfg.morph_close, cfg.morph_close))
        mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, k_open)
        mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, k_close)

        # 去水平细条：竖向开运算。木纹/桌沿等强边界在光照微变下会产生
        # 又细又长的水平前景条，与钢珠粘连后会把圆块“拉长”。竖向开运算
        # 只保留在竖直方向上有足够厚度的结构(钢珠)，去掉细条。
        if cfg.destreak:
            kd = max(5, int(cfg.ball_diam_px * cfg.proc_scale * 0.35))
            kv = cv2.getStructuringElement(cv2.MORPH_RECT, (1, kd))
            mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kv)

        # 背景模型冷启动：前若干帧不输出检测，避免误检
        if self.frame_idx <= cfg.warmup_frames:
            return [], mask

        # --- 5) 连通域筛选 ---
        cnts, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL,
                                   cv2.CHAIN_APPROX_SIMPLE)
        proc_scale = max(1e-6, cfg.proc_scale)
        full_w = proc_frame.shape[1] / proc_scale
        max_diam_full = cfg.max_ball_diam_frac * full_w

        # 先收集每个块的几何量(含平均饱和度)
        shapes = []
        hsv = (cv2.cvtColor(proc_frame, cv2.COLOR_BGR2HSV)
               if cfg.use_color_gate else None)
        for c in cnts:
            area = cv2.contourArea(c)
            if area < 6.0:
                continue
            per = cv2.arcLength(c, True)
            if per <= 1e-6:
                continue
            circ = 4.0 * np.pi * area / (per * per)
            x, y, w, h = cv2.boundingRect(c)
            fill = area / float(w * h + 1e-6)
            diam_full = 2.0 * np.sqrt(area / np.pi) / proc_scale
            aspect = max(w, h) / float(max(1, min(w, h)))
            # 颜色门：金属钢珠是低饱和(灰/银)，人手/彩色物体饱和度高 -> 剔除
            sat = 0.0
            if hsv is not None:
                cm = np.zeros(mask.shape, np.uint8)
                cv2.drawContours(cm, [c], -1, 255, -1)
                sat = float(cv2.mean(hsv[:, :, 1], mask=cm)[0])
            shapes.append((c, area, circ, fill, diam_full, sat, aspect))

        # 自动估计钢珠直径：只统计“够圆、填充够、够大、够银、不太大”的块
        if cfg.auto_diam:
            for c, area, circ, fill, diam_full, sat, aspect in shapes:
                if (circ >= cfg.min_circularity and fill >= cfg.min_fill
                        and cfg.min_diam_floor_px <= diam_full <= max_diam_full
                        and aspect <= cfg.max_aspect
                        and (not cfg.use_color_gate or sat <= cfg.max_sat)):
                    self.diam_hist.append(diam_full)
            if len(self.diam_hist) >= 15:
                # 取偏上的分位数：钢珠块通常比“拖影碎块”大，用高分位更接近真实尺寸
                self.est_diam_px = float(np.percentile(self.diam_hist, 70))

        # 由（自动/配置的）直径推出面积上下限
        d = self._effective_diam() * proc_scale
        a_nom = np.pi * (d / 2.0) ** 2
        a_min = a_nom * (1.0 - cfg.area_tol)
        a_max = a_nom * (1.0 + cfg.area_tol)

        dets = []
        for c, area, circ, fill, diam_full, sat, aspect in shapes:
            if area < a_min or area > a_max:
                continue
            if circ < cfg.min_circularity:
                continue
            if fill < cfg.min_fill:
                continue
            if aspect > cfg.max_aspect:
                continue
            if cfg.use_color_gate and sat > cfg.max_sat:
                continue
            M = cv2.moments(c)
            if M["m00"] <= 0:
                continue
            cx = M["m10"] / M["m00"]
            cy = M["m01"] / M["m00"]
            r = np.sqrt(area / np.pi)
            dets.append(Detection(cx, cy, r, area, circ))

        return dets, mask
