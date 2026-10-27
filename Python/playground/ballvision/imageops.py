from __future__ import annotations

import cv2
import numpy as np


def green_channel(frame_bgr: np.ndarray) -> np.ndarray:
    """The RTL taps G directly; using G avoids an RGB matrix and colour cast."""
    return np.ascontiguousarray(frame_bgr[:, :, 1])


def downscale4(gray: np.ndarray) -> np.ndarray:
    """Exact 4x4 box average, integer rounding.

    (sum + 8) >> 4 matches the RTL adder tree.  Input dimensions must be
    multiples of 4 (1280x720 is).
    """
    h, w = gray.shape
    if h % 4 or w % 4:
        raise ValueError(f"dimensions must be multiples of 4, got {w}x{h}")
    a = gray.reshape(h // 4, 4, w // 4, 4).astype(np.uint16)
    s = a.sum(axis=(1, 3), dtype=np.uint16)
    return ((s + 8) >> 4).astype(np.uint8)


def open_mask(mask: np.ndarray, times: int = 1, ksize: int = 3) -> np.ndarray:
    if times <= 0:
        return mask
    k = np.ones((ksize, ksize), np.uint8)
    return cv2.morphologyEx(mask, cv2.MORPH_OPEN, k, iterations=times)


def close_mask(mask: np.ndarray, times: int = 1, ksize: int = 3) -> np.ndarray:
    if times <= 0:
        return mask
    k = np.ones((ksize, ksize), np.uint8)
    return cv2.morphologyEx(mask, cv2.MORPH_CLOSE, k, iterations=times)


def blackhat(gray: np.ndarray, win: int) -> np.ndarray:
    """Closing(gray) - gray: compact dark blobs (ball body / shadow)."""
    k = cv2.getStructuringElement(cv2.MORPH_RECT, (int(win), int(win)))
    return cv2.morphologyEx(gray, cv2.MORPH_BLACKHAT, k)
