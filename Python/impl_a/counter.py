# -*- coding: utf-8 -*-
"""
counter.py -- 单向计数线穿越计数
============================================================
规则：
  1) 只有“已确认”的轨迹参与计数
  2) 轨迹质心相对计数线的符号发生变化(即穿过线)，且
     运动方向与期望方向一致(vel·direction > 0) 时，计数 +1
  3) 每条轨迹只有一个 crossed 标志，越线后不会重复计数

FPGA 对照：
  - 侧向判定 = 直线方程 a*x + b*y + c 的符号 -> 一次乘加 + 比较
  - 越线 = “上一帧符号” 与 “当前符号” 不同 -> 一位触发器
  - 方向校验 = vel·direction > 0 -> 两次乘法 + 比较
"""
import numpy as np


class LineCounter(object):
    def __init__(self, p1, p2, direction, cfg=None):
        self.p1 = np.array(p1, dtype=np.float64)
        self.p2 = np.array(p2, dtype=np.float64)
        self.cfg = cfg
        self.count = 0
        dv = np.array(direction, dtype=np.float64)
        n = np.linalg.norm(dv)
        self.direction = dv / n if n > 0 else np.array([1.0, 0.0])

    def reset(self):
        self.count = 0

    def _side(self, p):
        """有向面积：>0 在线一侧，<0 在另一侧，=0 在线上。"""
        a = self.p2 - self.p1
        b = np.asarray(p, dtype=np.float64) - self.p1
        return a[0] * b[1] - a[1] * b[0]

    def update(self, tracks):
        """
        传入“全部轨迹”(含未确认)。只有确认的轨迹参与计数。
        采用“出生侧”判据：一条确认后的轨迹，只要当前所在侧与出生时的所在侧
        符号相反，就说明它已经越过了计数线。这样可补偿“轨迹在被确认之前就已
        越线”导致的漏计(常见于目标刚进画面就快速穿过计数线的情形)。
        """
        for t in tracks:
            s = self._side(t.pos)

            if t.first_side is None:
                t.first_side = s

            if t.confirmed and not t.crossed:
                crossed = (t.first_side < 0) != (s < 0)
                if crossed:
                    vdot = float(np.dot(t.vel, self.direction))
                    if vdot > 0.0:  # 运动方向与期望方向一致
                        self.count += 1
                        t.crossed = True

            t.prev_side = s


class ExitCounter(object):
    """
    按“已确认轨迹离开视野”计数：相机平移时比固定计数线更稳。
    一条轨迹必须被确认(min_hits 命中)后消失，才计入一次。
    """

    def __init__(self, cfg=None):
        self.cfg = cfg
        self.count = 0
        self._present = set()     # 当前帧仍存在的轨迹 id
        self._confirmed = set()   # 曾经被确认过的轨迹 id

    def reset(self):
        self.count = 0
        self._present = set()
        self._confirmed = set()

    def update(self, tracks):
        cur = set()
        for t in tracks:
            cur.add(t.id)
            if t.confirmed:
                self._confirmed.add(t.id)
        # 上一帧存在、这一帧消失 且 曾被确认 -> 记一次“离开”
        for tid in (self._present - cur):
            if tid in self._confirmed:
                self.count += 1
        self._present = cur
