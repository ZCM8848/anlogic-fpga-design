from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from ballvision.ccl import connected_components  # noqa: E402
from ballvision.count import GateCounter  # noqa: E402
from ballvision.imageops import downscale4  # noqa: E402
from ballvision.track import Track  # noqa: E402


def test_downscale_rounding():
    g = np.full((8, 8), 255, np.uint8)
    assert downscale4(g).tolist() == [[255, 255], [255, 255]]
    g = np.zeros((8, 8), np.uint8)
    g[0, 0] = 1
    # sum=1 -> (1+8)>>4 = 0
    assert downscale4(g)[0, 0] == 0
    g[0:2, 0:4] = 1
    # sum=8 -> (8+8)>>4 = 1
    assert downscale4(g)[0, 0] == 1


def test_ccL_metrics():
    m = np.zeros((20, 20), np.uint8)
    m[2:6, 3:9] = 1       # 4x6, area 24, centre (5, 3)
    m[10:12, 15:18] = 1   # 2x3, area 6, centre (16, 10)
    blobs = connected_components(m)
    assert len(blobs) == 2
    b = blobs[0]
    assert b.area == 24
    assert (b.cx, b.cy) == (5, 3)
    assert (b.w, b.h) == (6, 4)


def test_gate_crossing_once():
    t = Track(id=1, cx=380, cy=100, prev_cx=400, hits=3, vx=-20)
    gate = GateCounter(384, 0, 720, confirm_hits=2)
    gate.update([t], 10)
    assert gate.count == 1
    gate.update([t], 11)  # stays left, no double count
    assert gate.count == 1


def test_gate_requires_confirmation():
    t = Track(id=1, cx=380, cy=100, prev_cx=400, hits=1)
    gate = GateCounter(384, 0, 720, confirm_hits=2)
    gate.update([t], 10)
    assert gate.count == 0


def test_static_scratch_is_not_counted():
    # A 3D-print scratch: many hits, almost no net displacement.
    t = Track(id=1, cx=380, cy=100, prev_cx=400, hits=20, moved=4, min_move=38)
    assert not t.visible
    gate = GateCounter(384, 0, 720, confirm_hits=2)
    gate.update([t], 10)
    assert gate.count == 0


def test_jitter_not_visible():
    # Initial jitter can exceed the total-move threshold, but not a sustained
    # 5-frame leftward displacement.
    t = Track(id=1, cx=380, cy=100, prev_cx=400, hits=20, moved=100,
              min_move=38, vx=-10, window_move=-10, min_window=57)
    assert not t.visible


