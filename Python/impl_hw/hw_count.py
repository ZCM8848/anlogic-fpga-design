# -*- coding: utf-8 -*-
"""
hw_count.py -- 计数（整数：直线方程符号 + 点积方向校验）
============================================================
硬件映射：
  侧向判定 = a*x + b*y + c 的符号 -> 1 次乘加 + 比较
  越线     = 上一帧符号与当前符号不同 -> 1 位触发器
  方向校验 = vx*dx + vy*dy > 0     -> 2 乘 + 1 加 + 比较
"""


class HWLineCounter(object):
    def __init__(self, p1, p2, direction, cfg=None):
        # p1/p2：处理分辨率下的整数坐标(x,y)
        self.p1x, self.p1y = int(p1[0]), int(p1[1])
        self.ax = int(p2[0]) - self.p1x
        self.ay = int(p2[1]) - self.p1y
        self.dx, self.dy = int(direction[0]), int(direction[1])
        self.cfg = cfg
        self.count = 0

    def reset(self):
        self.count = 0

    def _side(self, x_q8, y_q8):
        bx = x_q8 - (self.p1x << 8)
        by = y_q8 - (self.p1y << 8)
        return self.ax * by - self.ay * bx

    def update(self, tracks):
        for t in tracks:
            s = self._side(t.x, t.y)
            if t.first_side is None:
                t.first_side = s
            if t.confirmed and not t.crossed:
                if (t.first_side < 0) != (s < 0):
                    if t.vx * self.dx + t.vy * self.dy > 0:
                        self.count += 1
                        t.crossed = True


class HWExitCounter(object):
    """按"已确认轨迹离开视野"计数（相机平移时更稳）。"""

    def __init__(self, cfg=None):
        self.cfg = cfg
        self.count = 0
        self._present = set()
        self._confirmed = set()

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
        for tid in (self._present - cur):
            if tid in self._confirmed:
                self.count += 1
        self._present = cur
