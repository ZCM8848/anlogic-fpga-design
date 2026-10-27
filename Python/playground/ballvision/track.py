from __future__ import annotations

from dataclasses import dataclass, field

from .detect import Detection


@dataclass
class Track:
    id: int
    cx: int
    cy: int
    vx: int = 0
    vy: int = 0
    hits: int = 1
    misses: int = 0
    counted: bool = False
    prev_cx: int = 0
    prev_cy: int = 0
    box: tuple[int, int, int, int] = (0, 0, 0, 0)
    start_cx: int = 0
    start_cy: int = 0
    age: int = 1
    moved: int = 0
    min_move: int = 0
    hist_x: list[int] = field(default_factory=list)
    window_move: int = 0
    min_window: int = 0

    @property
    def confirmed(self) -> bool:
        return self.hits >= 2

    @property
    def visible(self) -> bool:
        """Only confirmed, consistently left-moving tracks are drawn/counted.

        A static 3D-print scratch can survive background subtraction after an
        exposure change and can even jitter by tens of pixels; requiring a
        *sustained* leftward displacement over the last 5 frames rejects it.
        """
        return (
            self.hits >= 2
            and self.misses == 0
            and self.moved >= self.min_move
            and self.window_move <= -self.min_window
            and self.vx <= -4
        )


class Tracker:
    def __init__(
        self,
        gate_px: int = 220,
        max_miss: int = 5,
        confirm_hits: int = 2,
        min_move_px: int = 0,
        min_window_px: int = 0,
        static_max_age: int = 30,
    ):
        self.gate_px = gate_px
        self.max_miss = max_miss
        self.confirm_hits = confirm_hits
        self.min_move_px = min_move_px
        self.min_window_px = min_window_px
        self.static_max_age = static_max_age
        self.tracks: list[Track] = []
        self.next_id = 1

    def reset(self) -> None:
        self.tracks = []
        self.next_id = 1

    def _move(self, t: Track) -> int:
        return max(abs(t.cx - t.start_cx), abs(t.cy - t.start_cy))

    @staticmethod
    def _window(t: Track) -> int:
        t.hist_x.append(t.cx)
        if len(t.hist_x) > 5:
            t.hist_x = t.hist_x[-5:]
        return t.hist_x[-1] - t.hist_x[0]

    def update(self, dets: list[Detection]) -> list[Track]:
        for t in self.tracks:
            t.prev_cx, t.prev_cy = t.cx, t.cy
            t.cx += t.vx
            t.cy += t.vy
            t.age += 1

        pairs = []
        for ti, t in enumerate(self.tracks):
            for di, d in enumerate(dets):
                dx = d.cx - t.cx
                dy = d.cy - t.cy
                dist2 = dx * dx + dy * dy
                if dist2 <= self.gate_px * self.gate_px:
                    pairs.append((dist2, ti, di))
        pairs.sort()

        used_t: set[int] = set()
        used_d: set[int] = set()
        for _dist2, ti, di in pairs:
            if ti in used_t or di in used_d:
                continue
            used_t.add(ti)
            used_d.add(di)
            t = self.tracks[ti]
            d = dets[di]
            # prev_* stays at the *measured* previous position (not prediction)
            old_cx, old_cy = t.prev_cx, t.prev_cy
            dvx = d.cx - old_cx
            dvy = d.cy - old_cy
            t.vx = (t.vx + dvx) // 2
            t.vy = (t.vy + dvy) // 2
            t.cx, t.cy = d.cx, d.cy
            t.box = d.box
            t.hits += 1
            t.misses = 0
            t.moved = self._move(t)
            t.window_move = self._window(t)

        new_start = len(self.tracks)
        for di, d in enumerate(dets):
            if di in used_d:
                continue
            self.tracks.append(
                Track(
                    id=self.next_id,
                    cx=d.cx,
                    cy=d.cy,
                    prev_cx=d.cx,
                    prev_cy=d.cy,
                    box=d.box,
                    hits=1,
                    misses=0,
                    start_cx=d.cx,
                    start_cy=d.cy,
                    age=1,
                    moved=0,
                    min_move=self.min_move_px,
                    hist_x=[d.cx],
                    window_move=0,
                    min_window=self.min_window_px,
                )
            )
            self.next_id += 1

        alive = []
        for ti, t in enumerate(self.tracks):
            if ti >= new_start:
                alive.append(t)
                continue
            if ti not in used_t:
                t.misses += 1
                t.moved = self._move(t)
                t.window_move = self._window(t)
                if t.misses > self.max_miss:
                    continue
            # A permanent static object (3D-print scratch, reflection) must not
            # occupy a track slot forever.
            if (
                t.age > self.static_max_age
                and t.moved < self.min_move_px
                and abs(t.window_move) < self.min_window_px
            ):
                continue
            alive.append(t)
        self.tracks = alive
        return self.tracks

    def confirmed(self) -> list[Track]:
        return [t for t in self.tracks if t.visible]
