from __future__ import annotations

from dataclasses import dataclass

from .track import Track


@dataclass
class CountEvent:
    frame: int
    track_id: int
    cx: int
    cy: int
    count_after: int


class GateCounter:
    """Counts confirmed tracks crossing the fixed gate from right to left.

    No reverse rolling in the target scene, so a track is counted at most once.
    """

    def __init__(self, x_gate: int, y0: int, y1: int, confirm_hits: int = 2):
        self.x_gate = x_gate
        self.y0 = y0
        self.y1 = y1
        self.confirm_hits = confirm_hits
        self.count = 0
        self.events: list[CountEvent] = []

    def reset(self) -> None:
        self.count = 0
        self.events = []

    def update(self, tracks: list[Track], frame_idx: int) -> int:
        for t in tracks:
            if t.counted or t.misses != 0 or not t.visible:
                continue
            if not (self.y0 <= t.cy <= self.y1):
                continue
            if t.prev_cx > self.x_gate >= t.cx:
                t.counted = True
                self.count += 1
                self.events.append(
                    CountEvent(frame_idx, t.id, t.cx, t.cy, self.count)
                )
                if len(self.events) > 200:
                    self.events = self.events[-200:]
        return self.count
