from __future__ import annotations

import cv2
import numpy as np

from .params import Params
from .pipeline import FrameResult


def processed_overlay(frame: np.ndarray, result: FrameResult) -> np.ndarray:
    """The frame the detector actually used, 50% over the original."""
    h, w = frame.shape[:2]
    score = cv2.resize(result.score, (w, h), interpolation=cv2.INTER_NEAREST)
    if result.mode == "bright":
        colour = np.zeros_like(frame)
        colour[:, :, 1] = score  # green
    else:
        colour = cv2.applyColorMap(score, cv2.COLORMAP_TURBO)
    return cv2.addWeighted(frame, 0.5, colour, 0.5, 0)


def score_full(result: FrameResult, size: tuple[int, int] = (1280, 720)) -> np.ndarray:
    """100% processed score map (what the threshold sees)."""
    score = cv2.resize(result.score, size, interpolation=cv2.INTER_NEAREST)
    return cv2.applyColorMap(score, cv2.COLORMAP_TURBO)


def mask_full(result: FrameResult, size: tuple[int, int] = (1280, 720)) -> np.ndarray:
    """100% binary mask after morphology (before CCL filtering)."""
    mask = cv2.resize((result.mask * 255).astype(np.uint8), size,
                      interpolation=cv2.INTER_NEAREST)
    return cv2.cvtColor(mask, cv2.COLOR_GRAY2BGR)


def draw_osd(frame: np.ndarray, result: FrameResult, params: Params) -> np.ndarray:
    vis = frame.copy()
    h, w = vis.shape[:2]
    gate_x = int(round(w * params.gate_x_ratio))
    gate_y0 = int(round(h * params.gate_y0_ratio))
    gate_y1 = int(round(h * params.gate_y1_ratio))
    cv2.line(vis, (gate_x, gate_y0), (gate_x, gate_y1), (0, 0, 255), 2)
    cv2.putText(vis, "GATE", (gate_x + 6, min(h - 10, gate_y0 + 22)),
                cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 255), 2)

    for t in result.tracks:
        if not t.visible:
            continue
        x0, y0, x1, y1 = t.box
        colour = (0, 220, 0) if t.confirmed else (0, 220, 220)
        cv2.rectangle(vis, (x0, y0), (x1, y1), colour, 2)
        cv2.putText(vis, f"#{t.id}", (x0 + 4, max(18, y0 - 6)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, colour, 2)

    nvis = sum(1 for t in result.tracks if t.visible)
    cv2.putText(vis, f"COUNT {result.count}", (12, 40),
                cv2.FONT_HERSHEY_SIMPLEX, 1.1, (0, 255, 255), 3)
    cv2.putText(vis, f"{result.mode} mean={result.frame_mean} trk={nvis}",
                (12, 74), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 2)
    return vis
