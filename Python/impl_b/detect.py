# -*- coding: utf-8 -*-
"""
detect.py -- 阈值 -> run 提取 -> 简化 CCL -> 特征筛选 -> detections
=================================================================
逐算法镜像 cv_top.v（第 79~325 行）。关键对齐点（详见 README「对齐清单」）：

  1. 默认 MASK_SRC=1：掩膜 = Sobel 幅值 > (EDGE_THR + user_off)
     （自适应中点 (min+max)>>1 只在 MASK_SRC=0 亮阈值回退时用）
  2. run 顺序 = 从上到下、从左到右（与 FPGA run_mem 写入顺序一致）
  3. 简化 CCL：只查「上一行」第一个重叠 run，**无 union-find**，
     与 FPGA 完全一致（对凹/间隙 blob 会同样地过分割）
  4. 特征筛选：面积/填充率(5%)/长短边比(60%)/贴边剔除
"""
import numpy as np

from preprocess import luma, sobel_magnitude


def extract_runs(mask, max_runs=1024):
    """
    run 提取（行序扫描，等价 cv_top.v 第 243~257 行）。
    mask: bool (H,W)。返回 (runs, overflow)。
    runs: [(y, xs, xe)]，xe 为闭区间，顺序为从上到下、从左到右。
    """
    H, W = mask.shape
    # 每行左右各补一个 False 哨兵，diff 找到 0->1(=+1) 与 1->0(=-1) 的跳变
    padded = np.zeros((H, W + 2), bool)
    padded[:, 1:W + 1] = mask
    changes = np.diff(padded.astype(np.int8), axis=1)  # (H, W+1)

    runs = []
    overflow = False
    for y in range(H):
        starts = np.flatnonzero(changes[y] == 1)      # run 起点 x
        ends = np.flatnonzero(changes[y] == -1) - 1   # run 终点 x（闭区间）
        for xs, xe in zip(starts, ends):
            runs.append((y, int(xs), int(xe)))
            if len(runs) >= max_runs:
                overflow = len(runs) > max_runs
                return runs[:max_runs], overflow
    return runs, False


def ccl(runs, max_labels=32, max_rpr=32):
    """
    简化连通域标记（两行 run-length，等价 cv_top.v 第 298~316 行）。
    无 union-find：每个 run 只继承「上一行第一个重叠 run」的 label，
    无重叠则新建 label。返回 feature 字典：
        label -> [valid, minx, maxx, miny, maxy, area]
    area = 该 label 所有 run 的像素长度之和（即边缘像素数）。
    """
    feature = {}                     # label -> [valid,minx,maxx,miny,maxy,area]
    rca = [(0, 0, 0)] * (2 * max_rpr)  # ping-pong 行缓存: (pxs, pxe, plbl)
    prev_sel = 0
    prev_len = 0
    cur_len = 0
    cur_row_y = 0x7FF                # 初值即"行变化"触发
    next_label = 0

    for (ry, rxs, rxe) in runs:
        # ---- 行变化：切 bank、继承相邻行的 run 数 ----
        if ry != cur_row_y:
            adj = (ry == cur_row_y + 1)
            prev_sel ^= 1
            prev_len = cur_len if adj else 0
            cur_len = 0
            cur_row_y = ry

        # ---- 扫描上一行 run，取第一个重叠的 label ----
        found_any = False
        cur_lbl = 0
        j = 0
        while j < prev_len:
            pxs, pxe, plbl = rca[prev_sel * max_rpr + j]
            overlap = (rxs <= pxe) and (pxs <= rxe)
            if overlap:
                if not found_any:
                    cur_lbl = plbl
                    found_any = True
                j += 1
            elif pxs > rxe:          # 上一行 run 已越过当前 run，提前结束
                break
            else:
                j += 1

        if found_any:
            final_lbl = cur_lbl
        else:
            final_lbl = next_label
            if next_label < max_labels:
                next_label += 1

        # ---- 更新 feature 表 ----
        if final_lbl < max_labels:
            feat = feature.get(final_lbl)
            if feat is None:
                feat = [0, rxs, rxe, ry, ry, 0]
                feature[final_lbl] = feat
            feat[0] = 1
            feat[1] = min(feat[1], rxs)
            feat[2] = max(feat[2], rxe)
            feat[3] = min(feat[3], ry)
            feat[4] = max(feat[4], ry)
            feat[5] += (rxe - rxs + 1)

        # ---- 把当前 run 存进"下一行可见"的 bank ----
        if cur_len < max_rpr:
            rca[(1 - prev_sel) * max_rpr + cur_len] = (rxs, rxe, final_lbl)
            cur_len += 1
        # 超出 max_rpr 的 run 被丢弃（与 FPGA 一致）

    return feature


def filter_features(feature, cfg):
    """
    特征筛选（等价 cv_top.v 第 165~183 行 w_pass）。
    返回 dets 列表（按 label 顺序），每个 dict:
        {cx, cy, minx, maxx, miny, maxy, area}
    上限 cfg.max_blobs（与 FPGA S_DCOLLECT 的 r_collect<MAX_BLOBS 一致）。
    """
    W, H = cfg.frame_w, cfg.frame_h
    dets = []
    for lbl in sorted(feature.keys()):
        valid, mnx, mxx, mny, mxy, area = feature[lbl]
        if not valid:
            continue
        w = mxx - mnx + 1
        h = mxy - mny + 1
        box = w * h
        if area < cfg.min_area or area > cfg.max_area:
            continue
        if area * 100 < cfg.min_fill * box:        # 填充率下限
            continue
        mn = min(w, h)
        mx = max(w, h)
        if mn * 100 < cfg.min_ratio * mx:          # 长短边比下限
            continue
        if (mnx < cfg.edge_mg or mny < cfg.edge_mg
                or mxx >= W - cfg.edge_mg or mxy >= H - cfg.edge_mg):
            continue
        dets.append({
            "cx": (mnx + mxx) >> 1,
            "cy": (mny + mxy) >> 1,
            "minx": mnx, "maxx": mxx,
            "miny": mny, "maxy": mxy,
            "area": area,
        })
        if len(dets) >= cfg.max_blobs:
            break
    return dets


class Detector(object):
    """持跨帧状态的检测器（上一帧 min/max 供 MASK_SRC=0 的中点阈值用）。"""

    def __init__(self, cfg):
        self.cfg = cfg
        self.prev_min = 0xFF
        self.prev_max = 0x00

    def reset(self):
        self.prev_min = 0xFF
        self.prev_max = 0x00

    def process(self, bgr):
        """
        输入 BGR (H,W,3) uint8。返回 (dets, mask, Y, mag)。
        mask 为 bool (H,W)，用于机器视角显示。
        """
        cfg = self.cfg
        Y = luma(bgr)
        mag = sobel_magnitude(Y)

        # 当前帧全帧 min/max（供下帧 MASK_SRC=0 中点阈值，等价 cv_top.v 243~245 行）
        cur_min = int(Y.min())
        cur_max = int(Y.max())

        # 有效阈值（等价 cv_top.v 83~85 行）：默认 MASK_SRC=1 用 EDGE_THR+偏置
        if cfg.mask_src == 1:
            thr = cfg.edge_thr + cfg.user_off
            mask = mag > thr
        else:
            midpoint = (self.prev_min + self.prev_max) >> 1
            thr = midpoint + cfg.user_off
            mask = Y > thr

        # 边界掩掉（等价 cv_top.v 第 103 行 r_x>=2 && r_y>=2）
        mask[:2, :] = False
        mask[:, :2] = False

        self.prev_min = cur_min
        self.prev_max = cur_max

        runs, overflow = extract_runs(mask, cfg.max_runs)
        feature = ccl(runs, cfg.max_labels, cfg.max_rpr)
        dets = filter_features(feature, cfg)
        return dets, mask, Y, mag
