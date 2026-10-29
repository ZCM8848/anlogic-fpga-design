# -*- coding: utf-8 -*-
"""
hw_track.py -- 定点多目标跟踪（对齐 cv_top.v 的 a-b 预测 + 贪心最近邻）
============================================================
每个 Track = 一组寄存器；内部坐标全部 Q8.8。
硬件映射：
  预测      pos + vel
  关联      Manhattan / 平方距离比较 + 贪心仲裁（小规模并行）
  EMA       (K*old + (256-K)*new) >> 8
"""
from hw_config import HWConfig


class Track(object):
    __slots__ = ("id", "x", "y", "vx", "vy", "r", "hits", "misses",
                 "age", "confirmed", "crossed", "first_side", "wrong_dir")

    def __init__(self, tid, x, y, r):
        self.id = tid
        self.x = x          # Q8.8
        self.y = y
        self.vx = 0
        self.vy = 0
        self.r = r          # Q8.8
        self.hits = 1
        self.misses = 0
        self.age = 1
        self.confirmed = False
        self.crossed = False
        self.first_side = None
        self.wrong_dir = 0

    def predict(self):
        return self.x + self.vx, self.y + self.vy


class HWTracker(object):
    def __init__(self, cfg=None):
        self.cfg = cfg or HWConfig()
        self.tracks = []
        self.next_id = 1

    def reset(self):
        self.tracks = []
        self.next_id = 1

    def update(self, dets, direction=None):
        """dets: [{'x','y','r', ...}]，坐标 Q8.8。返回已确认轨迹。"""
        cfg = self.cfg
        for t in self.tracks:
            t.age += 1
        preds = [t.predict() for t in self.tracks]

        matched_t, matched_d = set(), set()

        if self.tracks and dets:
            pairs = []
            for i, t in enumerate(self.tracks):
                px, py = preds[i]
                gate_base = t.r if t.r > (3 << 8) else (3 << 8)
                for j, d in enumerate(dets):
                    ga = (cfg.max_gate_q8 * (gate_base if gate_base > d["r"] else d["r"])) >> 8
                    dx = px - d["x"]
                    dy = py - d["y"]
                    dist2 = dx * dx + dy * dy
                    if dist2 <= ga * ga:
                        pairs.append((dist2, i, j))
            pairs.sort(key=lambda p: p[0])
            for _, i, j in pairs:
                if i in matched_t or j in matched_d:
                    continue
                matched_t.add(i)
                matched_d.add(j)
                t = self.tracks[i]
                d = dets[j]
                nvx = d["x"] - t.x
                nvy = d["y"] - t.y
                k = cfg.vel_ema_q8
                t.vx = (k * t.vx + (256 - k) * nvx) >> 8
                t.vy = (k * t.vy + (256 - k) * nvy) >> 8
                t.x = d["x"]
                t.y = d["y"]
                t.r = (179 * t.r + 77 * d["r"]) >> 8     # 0.7/0.3
                t.hits += 1
                t.misses = 0

        for i, t in enumerate(self.tracks):
            if i in matched_t:
                continue
            t.misses += 1
            t.x, t.y = preds[i]

        for j, d in enumerate(dets):
            if j in matched_d:
                continue
            self.tracks.append(Track(self.next_id, d["x"], d["y"], d["r"]))
            self.next_id += 1

        for t in self.tracks:
            if not t.confirmed and t.hits >= cfg.min_hits:
                t.confirmed = True

        if cfg.use_direction_filter and direction is not None:
            dx, dy = direction
            eps2 = cfg.speed_eps_q8 * cfg.speed_eps_q8
            for t in self.tracks:
                if t.vx * t.vx + t.vy * t.vy > eps2:
                    if t.vx * dx + t.vy * dy < 0:
                        t.wrong_dir += 1
                    else:
                        t.wrong_dir = max(0, t.wrong_dir - 1)
                if t.confirmed and t.wrong_dir > cfg.max_coast:
                    t.misses = cfg.max_coast + 1

        self.tracks = [t for t in self.tracks if t.misses <= cfg.max_coast]
        return [t for t in self.tracks if t.confirmed]
