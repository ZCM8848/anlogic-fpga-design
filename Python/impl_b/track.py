# -*- coding: utf-8 -*-
"""
track.py -- α-β 跟踪器（预测 + 贪心最近邻(Manhattan) + 补位 + 新建）
=====================================================================
逐算法镜像 cv_top.v 第 185~383 行。与 impl_a 的关键差异（务必注意）：

  1. 关联代价是 **Manhattan 距离** |dx|+|dy|，不是欧氏距离。
  2. **没有 min_hits 确认**：新检测立即成为有效轨迹、立即分配 ID。
  3. 匹配是「track 顺序贪心」：track 0..7 依次取各自最近的 det，
     每个 det 只被抢占一次（等价于小规模最近邻，非全局匈牙利）。
  4. 未命中轨迹用预测值「滑行」，missed+1，超过 MISS_K 才删除。

FPGA 对照：
  - 每条轨迹 = 一组寄存器 (id,cx,cy,vx,vy,missed,bbox)。
  - 预测/更新 = 定点乘加（α、β 各一次乘法，Q8 右移）。
  - 匹配 = Manhattan 距离比较 + 小规模并行仲裁。
"""


def _empty_track():
    return {
        "valid": 0,
        "id": 0,
        "cx": 0, "cy": 0,
        "vx": 0, "vy": 0,
        "missed": 0,
        "minx": 0, "maxx": 0, "miny": 0, "maxy": 0,
        "crossed": False,
        "prev_side": None,
    }


class Tracker(object):
    def __init__(self, cfg):
        self.cfg = cfg
        self.tracks = [_empty_track() for _ in range(cfg.max_blobs)]
        self.next_id = 0          # 4 位 ID，回绕 0~f（等价 cv_top.v r_next_id）

    def reset(self):
        self.tracks = [_empty_track() for _ in range(self.cfg.max_blobs)]
        self.next_id = 0

    # ------------------------------------------------------------------
    def update(self, dets):
        """
        dets: 检测列表（来自 detect.filter_features）。
        直接原地更新 self.tracks（固定 max_blobs 个槽，含空槽）。
        """
        cfg = self.cfg
        nb = cfg.max_blobs
        det_taken = [False] * len(dets)
        assign = [-1] * nb

        # ---- 1) 预测 + 贪心最近邻匹配（track 顺序） ----
        for ti in range(nb):
            t = self.tracks[ti]
            if not t["valid"]:
                continue
            px = t["cx"] + t["vx"]
            py = t["cy"] + t["vy"]
            min_cost = None
            min_j = -1
            for j, d in enumerate(dets):
                manh = abs(d["cx"] - px) + abs(d["cy"] - py)
                if manh <= cfg.gate and (min_cost is None or manh < min_cost):
                    min_cost = manh
                    min_j = j
            if min_j >= 0 and not det_taken[min_j]:
                assign[ti] = min_j
                det_taken[min_j] = True

        # ---- 2) 更新（命中 / 滑行） ----
        for ti in range(nb):
            t = self.tracks[ti]
            if not t["valid"]:
                continue
            px = t["cx"] + t["vx"]
            py = t["cy"] + t["vy"]
            if assign[ti] >= 0:
                d = dets[assign[ti]]
                rx = d["cx"] - px          # 预测误差
                ry = d["cy"] - py
                t["cx"] = px + ((cfg.alpha_q * rx) >> 8)
                t["cy"] = py + ((cfg.alpha_q * ry) >> 8)
                t["vx"] = t["vx"] + ((cfg.beta_q * rx) >> 8)
                t["vy"] = t["vy"] + ((cfg.beta_q * ry) >> 8)
                t["missed"] = 0
                t["minx"], t["maxx"] = d["minx"], d["maxx"]
                t["miny"], t["maxy"] = d["miny"], d["maxy"]
            else:
                # 滑行：预测推进 + 老化
                t["cx"] = px
                t["cy"] = py
                t["missed"] += 1
                if t["missed"] > cfg.miss_k:
                    t["valid"] = 0

        # ---- 3) 新建：未占 det 写入空槽 ----
        free = 0
        for j, d in enumerate(dets):
            if det_taken[j]:
                continue
            while free < nb and self.tracks[free]["valid"]:
                free += 1
            if free >= nb:
                break
            t = self.tracks[free]
            t["valid"] = 1
            t["id"] = self.next_id & 0xF
            self.next_id = (self.next_id + 1) & 0xF
            t["cx"], t["cy"] = d["cx"], d["cy"]
            t["vx"], t["vy"] = 0, 0
            t["missed"] = 0
            t["minx"], t["maxx"] = d["minx"], d["maxx"]
            t["miny"], t["maxy"] = d["miny"], d["maxy"]
            t["crossed"] = False
            t["prev_side"] = None
            free += 1

    # ------------------------------------------------------------------
    def snapshot(self):
        """返回当前有效轨迹的浅拷贝（用于 1 帧延迟的叠加）。"""
        return [dict(t) for t in self.tracks if t["valid"]]
