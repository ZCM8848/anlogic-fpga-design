"""Run-length connected components with integer metrics.

The RTL implementation is a two-pass run-length labeller with a union-find
table; this module mirrors that structure so area/bbox/centroid are bit-exact.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass
class Blob:
    label: int
    area: int
    x0: int
    y0: int
    x1: int  # exclusive
    y1: int  # exclusive
    sum_x: int
    sum_y: int

    @property
    def cx(self) -> int:
        return self.sum_x // self.area

    @property
    def cy(self) -> int:
        return self.sum_y // self.area

    @property
    def w(self) -> int:
        return self.x1 - self.x0

    @property
    def h(self) -> int:
        return self.y1 - self.y0


def _row_runs(row: np.ndarray):
    """Return [(start, end_exclusive), ...] for runs of non-zero pixels."""
    b = np.r_[0, (row != 0).view(np.int8), 0]
    d = np.diff(b)
    starts = np.flatnonzero(d == 1)
    ends = np.flatnonzero(d == -1)
    return list(zip(starts.tolist(), ends.tolist()))


def connected_components(mask: np.ndarray) -> list[Blob]:
    mask = np.ascontiguousarray(mask)
    h, _w = mask.shape

    parent: list[int] = []

    def new_label() -> int:
        parent.append(len(parent))
        return len(parent) - 1

    def find(a: int) -> int:
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def union(a: int, b: int) -> None:
        ra, rb = find(a), find(b)
        if ra == rb:
            return
        if ra < rb:
            parent[rb] = ra
        else:
            parent[ra] = rb

    prev: list[tuple[int, int, int]] = []
    rows: list[list[tuple[int, int, int]]] = []

    for y in range(h):
        cur: list[tuple[int, int, int]] = []
        for s, e in _row_runs(mask[y]):
            lab = new_label()
            for ps, pe, pl in prev:
                if s < pe and e > ps:
                    union(lab, pl)
            cur.append((s, e, lab))
        rows.append(cur)
        prev = cur

    n = len(parent)
    area = [0] * n
    sx = [0] * n
    sy = [0] * n
    x0 = [1 << 30] * n
    y0 = [1 << 30] * n
    x1 = [-1] * n
    y1 = [-1] * n

    for y, runs in enumerate(rows):
        for s, e, lab in runs:
            r = find(lab)
            length = e - s
            area[r] += length
            sx[r] += (s + e - 1) * length // 2
            sy[r] += y * length
            if s < x0[r]:
                x0[r] = s
            if e > x1[r]:
                x1[r] = e
            if y < y0[r]:
                y0[r] = y
            y1[r] = y + 1

    out = []
    for r in range(n):
        if area[r] == 0:
            continue
        out.append(Blob(r, area[r], x0[r], y0[r], x1[r], y1[r], sx[r], sy[r]))
    out.sort(key=lambda b: (-b.area, b.x0, b.y0))
    return out


def filter_blobs(
    blobs: list[Blob],
    min_area: int,
    max_area: int,
    min_w: int,
    max_w: int,
    min_h: int,
    max_h: int,
) -> list[Blob]:
    keep = []
    for b in blobs:
        if not (min_area <= b.area <= max_area):
            continue
        if not (min_w <= b.w <= max_w):
            continue
        if not (min_h <= b.h <= max_h):
            continue
        keep.append(b)
    return keep
