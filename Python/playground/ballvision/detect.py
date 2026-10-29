from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .background import Background
from .ccl import Blob, connected_components, filter_blobs
from .imageops import blackhat, close_mask, downscale4, green_channel, open_mask
from .params import Params


@dataclass
class Detection:
    cx: int          # full-resolution centre
    cy: int
    box: tuple[int, int, int, int]  # x0, y0, x1, y1 (exclusive)
    area_full: int   # area scaled back to full resolution
    area_small: int
    mode: str
    blob: Blob


@dataclass
class DetectResult:
    mode: str
    frame_mean: int
    small: np.ndarray
    score: np.ndarray       # uint8, what the detector actually thresholded
    mask: np.ndarray        # uint8 0/1
    detections: list[Detection] = field(default_factory=list)


def _choose_mode(frame_mean: int, params: Params) -> str:
    if params.mode in ("bright", "dark"):
        return params.mode
    return "bright" if frame_mean < params.auto_split_threshold else "dark"


def _merge_close(dets: list[Detection], min_dist: float, diameter: int,
                 width: int, height: int) -> list[Detection]:
    """Merge split pieces of one ball; distinct balls are >= ~1 diameter apart."""
    keep: list[Detection] = []
    d2 = min_dist * min_dist
    for d in sorted(dets, key=lambda x: x.area_small, reverse=True):
        target = None
        for k in keep:
            if (d.cx - k.cx) ** 2 + (d.cy - k.cy) ** 2 < d2:
                target = k
                break
        if target is None:
            keep.append(d)
            continue
        total = target.area_small + d.area_small
        cx = (target.cx * target.area_small + d.cx * d.area_small) // max(1, total)
        cy = (target.cy * target.area_small + d.cy * d.area_small) // max(1, total)
        half = diameter // 2
        x0 = max(0, min(width - diameter, cx - half))
        y0 = max(0, min(height - diameter, cy - half))
        target.cx, target.cy = cx, cy
        target.area_small = total
        target.area_full = total * 16
        target.box = (int(x0), int(y0), int(x0 + diameter), int(y0 + diameter))
    keep.sort(key=lambda d: (d.cy, d.cx))
    return keep


class Detector:
    """Stateful detector; holds the background model when use_bg is on."""

    def __init__(self, params: Params, bg: np.ndarray | None = None):
        self.params = params
        self.background = Background(params.bg_shift, params.bg_update_thr)
        if bg is not None:
            self.background.set_image(bg)

    def reset(self) -> None:
        self.background.reset()

    def detect(self, frame_bgr: np.ndarray) -> DetectResult:
        p = self.params
        gray = green_channel(frame_bgr)
        small = downscale4(gray)
        frame_mean = int(small.mean())

        if p.use_bg:
            mode = "bg"
            score = self.background.apply(small)
            mask = (score >= p.bg_thr).astype(np.uint8)
            mask = close_mask(mask, 1)
            # A light opening removes isolated noise while keeping the bar.
            mask = open_mask(mask, p.bright_open)
        else:
            mode = _choose_mode(frame_mean, p)
            if mode == "bright":
                mask = (small >= p.bright_thr).astype(np.uint8)
                mask = open_mask(mask, p.bright_open)
                score = (mask * 255).astype(np.uint8)
            else:
                score = blackhat(small, p.dark_win)
                mask = (score >= p.dark_thr).astype(np.uint8)
                mask = close_mask(mask, p.dark_close)

        blobs = filter_blobs(
            connected_components(mask),
            p.min_area,
            p.max_area,
            p.min_width,
            p.max_width,
            p.min_height,
            p.max_height,
        )

        s = p.scale
        diameter = p.ball_diameter_px
        half = diameter // 2
        h, w = gray.shape
        dets: list[Detection] = []
        for b in blobs:
            cx = b.cx * s + p.offset_x_px
            cy = b.cy * s + p.offset_y_px
            x0 = max(0, min(w - diameter, cx - half))
            y0 = max(0, min(h - diameter, cy - half))
            dets.append(
                Detection(
                    cx=cx,
                    cy=cy,
                    box=(int(x0), int(y0), int(x0 + diameter), int(y0 + diameter)),
                    area_full=b.area * s * s,
                    area_small=b.area,
                    mode=mode,
                    blob=b,
                )
            )

        dets = _merge_close(dets, p.merge_distance_ratio * diameter,
                            diameter, w, h)
        return DetectResult(mode, frame_mean, small, score, mask, dets)
