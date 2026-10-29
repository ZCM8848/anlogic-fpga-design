"""Integer IIR background model at reduced resolution.

Static bright spots (chute texture, ring-light reflections) are learned into
the background; moving balls produce a large difference.  The model only
updates where the difference is small, so a passing ball does not pollute it.
"""
from __future__ import annotations

from pathlib import Path

import cv2
import numpy as np

BG_DIR = Path(__file__).resolve().parents[1] / "data" / "backgrounds"


def load_clip_background(stem: str) -> np.ndarray | None:
    p = BG_DIR / f"{stem}_bg.png"
    if not p.exists():
        return None
    img = cv2.imread(str(p), cv2.IMREAD_GRAYSCALE)
    return img


class Background:
    def __init__(self, shift: int = 4, update_thr: int = 10):
        self.shift = int(shift)
        self.update_thr = int(update_thr)
        self.bg: np.ndarray | None = None
        self.initial: np.ndarray | None = None

    def reset(self) -> None:
        self.bg = None if self.initial is None else self.initial.copy()

    def set_image(self, bg: np.ndarray) -> None:
        self.initial = np.ascontiguousarray(bg.astype(np.uint8)).copy()
        self.bg = self.initial.copy()

    def load(self, path: str) -> bool:
        img = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
        if img is None:
            return False
        self.set_image(img)
        return True

    def apply(self, gray: np.ndarray) -> np.ndarray:
        if self.bg is None:
            self.bg = gray.copy()
            return np.zeros_like(gray)
        diff = cv2.absdiff(gray, self.bg)
        upd = diff < self.update_thr
        if upd.any():
            delta = gray.astype(np.int16) - self.bg.astype(np.int16)
            step = delta >> self.shift
            new = self.bg.astype(np.int16) + step
            new = np.clip(new, 0, 255).astype(np.uint8)
            self.bg[upd] = new[upd]
        return diff
