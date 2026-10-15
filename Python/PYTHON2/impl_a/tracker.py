# -*- coding: utf-8 -*-
"""
tracker.py -- 多目标跟踪（匀速预测 + 最近邻/匈牙利匹配 + 遮挡补位）
============================================================
目标：任何一颗钢珠从进入视野到离开视野，始终是同一个 ID、同一个框。

要点：
  * 每个 Track 保存: ID / 位置 / 速度(EMA) / 半径 / 命中 / 丢失 / 状态
  * 预测:   pred = pos + vel
  * 关联:   预测点与检测点做“带门限的贪心最近邻匹配”(目标少、等价于匈牙利)
  * 生命周期: 连续 min_hits 帧命中 -> 确认并分配 ID；连续 max_coast 帧未命中 -> 删除
  * 遮挡:   未匹配的轨迹用预测位置“滑行”，摩接分离后能重新关联，ID 不丢
  * 方向:   单方向场景下，抑制持续反向运动的干扰轨迹

FPGA 对照：
  - 每个轨迹 = 一组寄存器 (id, x, y, vx, vy, r, hits, miss, state)
  - 预测/更新 = 定点乘加
  - 匹配 = 距离平方比较 + 优先级仲裁(小规模可并行)
  - 计数线穿越 = 坐标符号比较(见 counter.py)
"""
import numpy as np


class Track(object):
    def __init__(self, tid, det, cfg):
        self.id = int(tid)
        self.pos = np.array([det.x, det.y], dtype=np.float64)
        self.vel = np.zeros(2, dtype=np.float64)
        self.r = float(det.r)
        self.hits = 1
        self.misses = 0
        self.age = 1
        self.confirmed = False
        self.crossed = False          # 是否已越过计数线(防重复计数)
        self.prev_side = None         # 上一帧在计数线哪一侧
        self.first_side = None        # 出生时在计数线哪一侧(用于补偿“确认前已越线”)
        self.wrong_dir = 0            # 连续反向运动帧数
        self.trail = [tuple(self.pos)]  # 轨迹尾巴(可视化用)

    def predict(self):
        return self.pos + self.vel


class Tracker(object):
    def __init__(self, cfg):
        self.cfg = cfg
        self.tracks = []
        self.next_id = 1

    def reset(self):
        self.tracks = []
        self.next_id = 1

    # ------------------------------------------------------------------
    def update(self, dets, direction=None):
        """
        dets: 检测列表(处理分辨率坐标)
        direction: 期望运动方向(单位向量) 或 None
        返回: 已确认的轨迹列表
        """
        cfg = self.cfg

        # --- 预测 & 匈牙利前处理 ---
        for t in self.tracks:
            t.age += 1
        preds = [t.predict() for t in self.tracks]

        matched_t = set()
        matched_d = set()

        # --- 贪心最近邻匹配(带门限) ---
        if self.tracks and dets:
            pairs = []
            for i, t in enumerate(self.tracks):
                px, py = preds[i]
                gate_base = max(t.r, 3.0)
                for j, d in enumerate(dets):
                    ga = cfg.max_gate * max(gate_base, d.r)
                    dx = px - d.x
                    dy = py - d.y
                    dist2 = dx * dx + dy * dy
                    # 方向一致性软约束：已建立速度时，优先匹配同向检测
                    if dist2 <= ga * ga:
                        pairs.append((dist2, i, j))
            pairs.sort(key=lambda p: p[0])
            for dist2, i, j in pairs:
                if i in matched_t or j in matched_d:
                    continue
                matched_t.add(i)
                matched_d.add(j)
                t = self.tracks[i]

                new = np.array([dets[j].x, dets[j].y], dtype=np.float64)
                newvel = new - t.pos
                t.vel = cfg.vel_ema * newvel + (1.0 - cfg.vel_ema) * t.vel
                t.pos = new
                t.r = 0.7 * t.r + 0.3 * dets[j].r
                t.hits += 1
                t.misses = 0
                t.trail.append(tuple(t.pos))
                if len(t.trail) > 60:
                    t.trail.pop(0)

        # --- 未匹配轨迹：预测滑行 ---
        for i, t in enumerate(self.tracks):
            if i in matched_t:
                continue
            t.misses += 1
            t.pos = preds[i]
            t.trail.append(tuple(t.pos))
            if len(t.trail) > 60:
                t.trail.pop(0)

        # --- 未匹配检测：新建候选轨迹 ---
        for j, d in enumerate(dets):
            if j in matched_d:
                continue
            self.tracks.append(Track(self.next_id, d, cfg))
            self.next_id += 1

        # --- 状态机：确认 ---
        for t in self.tracks:
            if not t.confirmed and t.hits >= cfg.min_hits:
                t.confirmed = True

        # --- 方向一致性：抑制持续反向的干扰轨迹 ---
        if cfg.use_direction_filter and direction is not None:
            dv = np.array(direction, dtype=np.float64)
            n = np.linalg.norm(dv)
            if n > 0:
                dv = dv / n
                for t in self.tracks:
                    if np.linalg.norm(t.vel) > cfg.speed_eps:
                        if float(np.dot(t.vel, dv)) < 0.0:
                            t.wrong_dir += 1
                        else:
                            t.wrong_dir = max(0, t.wrong_dir - 1)
                    if t.confirmed and t.wrong_dir > cfg.max_coast:
                        t.misses = cfg.max_coast + 1  # 交给下方统一删除

        # --- 删除失效轨迹 ---
        self.tracks = [t for t in self.tracks if t.misses <= cfg.max_coast]

        return [t for t in self.tracks if t.confirmed]
