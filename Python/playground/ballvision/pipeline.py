from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from .count import CountEvent, GateCounter
from .detect import DetectResult, Detector
from .params import Params
from .track import Track, Tracker


@dataclass
class FrameResult:
    frame_idx: int
    mode: str
    frame_mean: int
    det: DetectResult
    tracks: list[Track]
    count: int
    events: list[CountEvent]
    score: np.ndarray
    mask: np.ndarray
    reset: bool = False


class Pipeline:
    def __init__(self, params: Params, width: int = 1280, height: int = 720,
                 bg: np.ndarray | None = None):
        self.params = params
        self.width = width
        self.height = height
        self.gate_x = int(round(width * params.gate_x_ratio))
        self.detector = Detector(params, bg)
        self.tracker = Tracker(
            gate_px=params.track_gate_px,
            max_miss=params.track_max_miss,
            confirm_hits=params.track_confirm_hits,
            min_move_px=int(round(params.min_move_ratio * params.ball_diameter_px)),
            min_window_px=int(round(params.min_window_ratio * params.ball_diameter_px)),
            static_max_age=params.static_max_age,
        )
        self.counter = GateCounter(
            self.gate_x,
            int(round(height * params.gate_y0_ratio)),
            int(round(height * params.gate_y1_ratio)),
            confirm_hits=params.track_confirm_hits,
        )
        self.last_idx: int | None = None

    def reset(self) -> None:
        self.detector.reset()
        self.tracker.reset()
        self.counter.reset()
        self.last_idx = None

    def process(self, frame_bgr: np.ndarray, frame_idx: int) -> FrameResult:
        reset = self.last_idx is None or frame_idx != self.last_idx + 1
        if reset:
            self.detector.reset()
            self.tracker.reset()
            self.counter.reset()

        det = self.detector.detect(frame_bgr)
        tracks = self.tracker.update(det.detections)
        count = self.counter.update(tracks, frame_idx)
        self.last_idx = frame_idx
        return FrameResult(
            frame_idx=frame_idx,
            mode=det.mode,
            frame_mean=det.frame_mean,
            det=det,
            tracks=tracks,
            count=count,
            events=list(self.counter.events),
            score=det.score,
            mask=det.mask,
            reset=reset,
        )
