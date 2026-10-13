# -*- coding: utf-8 -*-
"""
hw_pipeline.py -- 端到端硬件流水线（整数/定点）
============================================================
数据流（与 RTL 逐级对应）：
  采集 BGR -> 2x2 下采样 -> 灰度 -> 光照归一化 -> IIR 背景/阈值 -> ROI
    -> 形态学(开/闭/竖开) -> run-length 连通域 -> 形状/颜色筛选
    -> 定点跟踪 -> 计数 -> (OSD)
注意：真硬件里 640x360@60 每帧只用 ~13.8 Mpixel/s，域时钟 75~100MHz，
      有 ~5~7 拍/像素余量，故 CCL/跟踪这类"慢"逻辑允许串行/时间复用。
"""
import numpy as np

from hw_config import HWConfig
from hw_fixed import isqrt
from hw_ops import (resize_proc, to_gray, illum_norm, iir_update, fg_mask,
                    morph_open, morph_close, v_open, build_roi_mask, sat_approx)
from hw_cc import label_runs, blob_features, radius_q8, circularity_q10
from hw_track import HWTracker
from hw_count import HWLineCounter, HWExitCounter


def _default_line(direction, w, h):
    cx, cy = w // 2, h // 2
    dx, dy = direction
    if abs(dx) >= abs(dy):
        return [[cx, 0], [cx, h]]
    return [[0, cy], [w, cy]]


class HWPipeline(object):
    def __init__(self, cfg=None):
        self.cfg = cfg or HWConfig()
        self.bg = None
        self.frame_idx = 0
        self.tracker = HWTracker(self.cfg)
        self.counter = None
        self.line_full = None
        self._build_counter(1280, 720)

    # -------------------------------------------------------------- counter
    def _build_counter(self, frame_w, frame_h):
        cfg = self.cfg
        if cfg.count_mode == "exit":
            self.counter = HWExitCounter(cfg)
            self.line_full = None
            return
        line = cfg.line if (cfg.line and len(cfg.line) == 2) else \
            _default_line(cfg.direction, frame_w, frame_h)
        p1 = [line[0][0] * cfg.scale_num // cfg.scale_den,
              line[0][1] * cfg.scale_num // cfg.scale_den]
        p2 = [line[1][0] * cfg.scale_num // cfg.scale_den,
              line[1][1] * cfg.scale_num // cfg.scale_den]
        self.counter = HWLineCounter(p1, p2, cfg.direction, cfg)
        self.line_full = line

    def reset(self):
        self.bg = None
        self.frame_idx = 0
        self.tracker.reset()
        if self.counter is not None:
            self.counter.reset()

    # -------------------------------------------------------------- select
    def _nominal_area(self):
        cfg = self.cfg
        d_px = int(round(cfg.ball_diam_px * cfg.scale_num / cfg.scale_den))
        return (31416 * d_px * d_px) // (10000 * 4)     # pi*d^2/4

    def _select(self, feats, cfg):
        a_nom = self._nominal_area()
        a_min = (a_nom * (256 - cfg.area_tol_q8)) >> 8
        a_max = (a_nom * (256 + cfg.area_tol_q8)) >> 8
        area = feats["area"]
        dets = []
        for k in range(1, len(area)):
            A = int(area[k])
            if A < cfg.min_area_px:
                continue
            w = int(feats["x_max"][k] - feats["x_min"][k] + 1)
            h = int(feats["y_max"][k] - feats["y_min"][k] + 1)
            if A < a_min or A > a_max:
                continue
            if circularity_q10(A, int(feats["perim"][k])) < cfg.min_circ_q10:
                continue
            if (A * 256) // max(1, w * h) < cfg.min_fill_q8:
                continue
            if (max(w, h) * 256) // max(1, min(w, h)) > cfg.max_aspect_q8:
                continue
            if cfg.use_color_gate:
                sat_mean = int(feats["sum_sat"][k]) // A
                if sat_mean > cfg.max_sat:
                    continue
            cx = (int(feats["sum_x"][k]) << 8) // A
            cy = (int(feats["sum_y"][k]) << 8) // A
            dets.append({"x": cx, "y": cy, "r": radius_q8(A),
                         "area": A, "circ": circularity_q10(A, int(feats["perim"][k]))})
        return dets

    # -------------------------------------------------------------- process
    def process(self, bgr):
        """输入一帧 BGR(uint8)，返回 dict：
        dets / tracks / count / mask / proc(frame)"""
        cfg = self.cfg
        self.frame_idx += 1

        proc = resize_proc(bgr, cfg)
        gray = to_gray(proc, cfg)
        proc_img = illum_norm(gray, cfg) if cfg.use_illum_norm else gray

        if self.bg is None:
            self.bg = proc_img.copy()
            mask = np.zeros_like(gray, dtype=np.uint8)
            return {"dets": [], "tracks": [], "count": 0,
                    "mask": mask, "proc": proc}

        mask = fg_mask(proc_img, self.bg, cfg.fg_thresh)
        self.bg = iir_update(self.bg, proc_img, cfg.bg_alpha_q8)

        roi = build_roi_mask(gray.shape, cfg.roi, cfg.scale_num, cfg.scale_den)
        if roi is not None:
            mask = (mask & roi).astype(np.uint8)

        mask = morph_open(mask, cfg.open_k)
        mask = morph_close(mask, cfg.close_k)
        if cfg.destreak:
            mask = v_open(mask, cfg.destreak_len)

        if self.frame_idx <= cfg.warmup_frames:
            return {"dets": [], "tracks": [], "count": 0,
                    "mask": mask, "proc": proc}

        label_img, nlab = label_runs(mask, cfg.connectivity)
        sat = sat_approx(proc) if cfg.use_color_gate else None
        feats = blob_features(mask, label_img, nlab, sat)
        dets = self._select(feats, cfg)

        tracks = self.tracker.update(
            dets, cfg.direction if cfg.use_direction_filter else None)
        self.counter.update(self.tracker.tracks)

        return {"dets": dets, "tracks": tracks,
                "count": self.counter.count, "mask": mask, "proc": proc}
