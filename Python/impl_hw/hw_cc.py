# -*- coding: utf-8 -*-
"""
hw_cc.py -- 连通域（run-length + 并查集）+ 逐块特征
============================================================
与 work/camera_hdmi_720p/rtl/cv/cv_top.v 的 CCL 同一思路：
  逐行提取 run（连续前景段）-> 与上一行重叠的 run 做并查集合并 ->
  收集每块的 面积 / 包围盒 / 边界像素数(周长近似) / 矩(质心)

硬件映射：
  run 提取      -> 行扫描 + 边沿检测（1 位）
  并查集        -> 标签 RAM + find/union 小状态机
  面积/矩       -> 累加器（Σ1, Σx, Σy）
  包围盒        -> min/max 寄存器组
  周长近似      -> 4 邻域腐蚀后取边界像素计数（移位 + 与 + 计数）
"""
import numpy as np

from hw_fixed import isqrt


def label_runs(mask, connectivity=8):
    """run-length 标记 + 并查集，返回 (label_img[int32, 0=背景], 标签数)。"""
    H, W = mask.shape
    b = (mask > 0)
    parent = []

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def union(a, c):
        ra, rb = find(a), find(c)
        if ra != rb:
            if ra < rb:
                parent[rb] = ra
            else:
                parent[ra] = rb

    runs = []          # [y, x0, x1_exclusive, label]
    prev = []          # 上一行 run 的下标
    eight = (connectivity == 8)

    for y in range(H):
        row = b[y].astype(np.int8)
        pad = np.concatenate(([0], row, [0]))
        d = np.diff(pad)
        starts = np.flatnonzero(d == 1)      # x0
        ends = np.flatnonzero(d == -1)       # x1 (exclusive)
        cur = []
        pi = 0
        for k in range(len(starts)):
            x0 = int(starts[k])
            x1 = int(ends[k])
            idx = len(runs)
            parent.append(idx)
            runs.append([y, x0, x1, idx])
            cur.append(idx)
            # 跳过完全在左边的上一行 run（8 连通留 1 像素余量）
            while pi < len(prev) and runs[prev[pi]][2] <= x0 - 1:
                pi += 1
            pj = pi
            while pj < len(prev) and runs[prev[pj]][1] <= x1:
                pp = runs[prev[pj]]
                if (pp[2] >= x0) if eight else (pp[2] > x0):
                    union(idx, prev[pj])
                pj += 1
        prev = cur

    # 重映射为紧密标签
    remap = {}
    nxt = 1
    for i in range(len(runs)):
        r = find(i)
        if r not in remap:
            remap[r] = nxt
            nxt += 1
    for i in range(len(runs)):
        runs[i][3] = remap[find(i)]

    label_img = np.zeros((H, W), np.int32)
    for y, x0, x1, lab in runs:
        label_img[y, x0:x1] = lab
    return label_img, nxt - 1


def blob_features(mask, label_img, num, sat_img=None):
    """逐块特征：面积/包围盒/矩/周长近似(边界像素计数)/[可选]饱和度和。"""
    H, W = mask.shape
    fg = mask > 0
    out = {
        "area": np.zeros(num + 1, np.int64),
        "sum_x": np.zeros(num + 1, np.int64),
        "sum_y": np.zeros(num + 1, np.int64),
        "x_min": np.full(num + 1, W, np.int64),
        "x_max": np.full(num + 1, -1, np.int64),
        "y_min": np.full(num + 1, H, np.int64),
        "y_max": np.full(num + 1, -1, np.int64),
        "perim": np.zeros(num + 1, np.int64),
        "sum_sat": np.zeros(num + 1, np.int64),
    }
    ys, xs = np.nonzero(fg)
    if len(ys) == 0:
        return out
    labs = label_img[ys, xs]

    out["area"] = np.bincount(labs, minlength=num + 1)
    out["sum_x"] = np.bincount(labs, weights=xs, minlength=num + 1).astype(np.int64)
    out["sum_y"] = np.bincount(labs, weights=ys, minlength=num + 1).astype(np.int64)
    np.minimum.at(out["x_min"], labs, xs)
    np.maximum.at(out["x_max"], labs, xs)
    np.minimum.at(out["y_min"], labs, ys)
    np.maximum.at(out["y_max"], labs, ys)

    # 4 邻域腐蚀 -> 边界像素
    er = fg.copy()
    er[1:, :] &= fg[:-1, :]
    er[:-1, :] &= fg[1:, :]
    er[:, 1:] &= fg[:, :-1]
    er[:, :-1] &= fg[:, 1:]
    edge = fg & ~er
    eys, exs = np.nonzero(edge)
    if len(eys):
        elabs = label_img[eys, exs]
        out["perim"] = np.bincount(elabs, minlength=num + 1)

    if sat_img is not None:
        out["sum_sat"] = np.bincount(
            labs, weights=sat_img[ys, xs].astype(np.int64),
            minlength=num + 1).astype(np.int64)
    return out


def radius_q8(area):
    """r = sqrt(area/pi)，返回 Q8.8。硬件：逐位开方 / CORDIC。"""
    return isqrt((area * 100 * 65536) // 314)


def circularity_q10(area, perim):
    """圆度 4*pi*A/P^2，Q10。"""
    p2 = perim * perim
    if p2 <= 0:
        return 0
    return (12566 * area * 1024) // (1000 * p2)
