from __future__ import annotations

import threading
from pathlib import Path

import cv2
import numpy as np


class VideoReader:
    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.cap = cv2.VideoCapture(str(self.path))
        if not self.cap.isOpened():
            raise IOError(f"cannot open video: {self.path}")
        self.width = int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        self.height = int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        self.fps = float(self.cap.get(cv2.CAP_PROP_FPS) or 60.0)
        self.frames = int(self.cap.get(cv2.CAP_PROP_FRAME_COUNT))
        # Some H.264 files report one frame more than OpenCV can decode.
        if self.frames > 1:
            self.cap.set(cv2.CAP_PROP_POS_FRAMES, self.frames - 1)
            ok, _ = self.cap.read()
            if not ok:
                self.frames -= 1
            self.cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
        self._next = 0
        self._lock = threading.Lock()

    def read(self, index: int) -> np.ndarray:
        index = max(0, min(self.frames - 1, int(index)))
        with self._lock:
            if index != self._next:
                self.cap.set(cv2.CAP_PROP_POS_FRAMES, index)
            ok, frame = self.cap.read()
            if not ok:
                # retry once after an explicit seek
                self.cap.set(cv2.CAP_PROP_POS_FRAMES, index)
                ok, frame = self.cap.read()
            if not ok:
                raise IOError(f"cannot read frame {index} of {self.path.name}")
            self._next = index + 1
            return frame

    def release(self) -> None:
        self.cap.release()

    def info(self) -> dict:
        return {
            "name": self.path.name,
            "width": self.width,
            "height": self.height,
            "fps": self.fps,
            "frames": self.frames,
            "duration": self.frames / self.fps if self.fps else 0.0,
        }
