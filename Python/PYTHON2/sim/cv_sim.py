#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cv_sim.py — cv_top CCL 算法行为级仿真（M7 Phase A 上板前验证手段）

本机无 iverilog，用 Python 忠实复刻 cv_top.v 的 CCL 算法（run 提取 → 两遍法 CCL
→ 过滤），在合成测试图上验证检测正确性，并与独立 BFS 参考实现对比。

用法：python cv_sim.py
"""
import random

IMG_W, IMG_H = 1280, 720
BIN_THR = 120
MIN_AREA, MAX_AREA = 8, 20000
MIN_FILL, MIN_RATIO = 15, 25
EDGE_MG = 4


# --------------------------------------------------------------------------
# 参考实现：BFS 连通域（地面真值）
# --------------------------------------------------------------------------
def ref_ccl(mask):
    """mask: set of (x,y) bright pixels. 返回 list of blob dicts。"""
    seen = set()
    blobs = []
    pxset = set(mask)
    for p in pxset:
        if p in seen:
            continue
        # BFS
        q = [p]; seen.add(p); comp = []
        while q:
            x, y = q.pop()
            comp.append((x, y))
            for dx, dy in ((1,0),(-1,0),(0,1),(0,-1)):
                np = (x+dx, y+dy)
                if np in pxset and np not in seen:
                    seen.add(np); q.append(np)
        xs = [c[0] for c in comp]; ys = [c[1] for c in comp]
        blobs.append({
            "min_x": min(xs), "max_x": max(xs),
            "min_y": min(ys), "max_y": max(ys),
            "area": len(comp),
        })
    return blobs


def filter_blobs(blobs):
    out = []
    for b in blobs:
        w = b["max_x"] - b["min_x"] + 1
        h = b["max_y"] - b["min_y"] + 1
        box = w * h
        fill = b["area"] * 100 // box if box else 0
        mn, mx = min(w, h), max(w, h)
        ratio = mn * 100 // mx if mx else 0
        edge = (b["min_x"] < EDGE_MG or b["min_y"] < EDGE_MG or
                b["max_x"] >= IMG_W - EDGE_MG or b["max_y"] >= IMG_H - EDGE_MG)
        if (b["area"] >= MIN_AREA and b["area"] <= MAX_AREA and
                fill >= MIN_FILL and ratio >= MIN_RATIO and not edge):
            out.append(b)
    return out


# --------------------------------------------------------------------------
# RTL 忠实复刻：run 提取 + 两遍法 CCL
# --------------------------------------------------------------------------
def extract_runs(mask):
    """mask: set of (x,y). 返回 runs=[(y,xs,xe)] 按 raster 序。"""
    rows = {}
    for x, y in mask:
        rows.setdefault(y, []).append(x)
    runs = []
    for y in sorted(rows):
        xs = sorted(rows[y])
        start = prev = xs[0]
        for x in xs[1:]:
            if x == prev + 1:
                prev = x
            else:
                runs.append((y, start, prev))
                start = prev = x
        runs.append((y, start, prev))
    return runs


def overlap(a_xs, a_xe, b_xs, b_xe):
    return a_xs <= b_xe and b_xs <= a_xe


def rtl_ccl(runs):
    """复刻 cv_top 简化 CCL（无 union-find：取第一个 x 重叠的 prev label 或新 label，
    直接累加 feature[label]）。有内部间隙的 blob 可能过分割（圆球无间隙→不受影响）。"""
    MAX_LABELS = 32
    feature = [{"valid": False, "min_x": 0, "max_x": 0, "min_y": 0, "max_y": 0, "area": 0}
               for _ in range(MAX_LABELS)]
    next_label = 0
    prev_cache = []   # list of (xs,xe,label)
    cur_cache = []
    cur_row_y = -1

    for i, (y, rxs, rxe) in enumerate(runs):
        if y != cur_row_y:
            if cur_row_y != -1 and y == cur_row_y + 1:
                prev_cache = cur_cache
            else:
                prev_cache = []
            cur_cache = []
            cur_row_y = y
        cur_lbl = 0
        found_any = False
        for (pxs, pxe, plbl) in prev_cache:
            if pxs > rxe:
                break
            if overlap(rxs, rxe, pxs, pxe):
                if not found_any:
                    cur_lbl = plbl
                    found_any = True
                # 无 union：只取第一个
        if not found_any:
            if next_label < MAX_LABELS:
                cur_lbl = next_label
                next_label += 1
            else:
                cur_lbl = 0
        cur_cache.append((rxs, rxe, cur_lbl))
        # 累加 feature[cur_lbl]
        seg = rxe - rxs + 1
        f = feature[cur_lbl]
        if not f["valid"]:
            f.update(valid=True, min_x=rxs, max_x=rxe, min_y=y, max_y=y, area=seg)
        else:
            f["min_x"] = min(f["min_x"], rxs)
            f["max_x"] = max(f["max_x"], rxe)
            f["min_y"] = min(f["min_y"], y)
            f["max_y"] = max(f["max_y"], y)
            f["area"] += seg

    blobs = [f for f in feature if f["valid"]]
    return blobs


# --------------------------------------------------------------------------
# 测试用例
# --------------------------------------------------------------------------
def disc(cx, cy, r):
    """圆盘亮斑（钢珠反光近似）。"""
    s = set()
    for y in range(cy - r, cy + r + 1):
        for x in range(cx - r, cx + r + 1):
            if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                s.add((x, y))
    return s


def make_mask(*shapes):
    m = set()
    for sh in shapes:
        m |= sh
    return m


def blobs_equal(a, b):
    """比较两个 blob 集合（按 bbox+area 近似匹配）。"""
    if len(a) != len(b):
        return False
    a = sorted(a, key=lambda z: (z["min_x"], z["min_y"]))
    b = sorted(b, key=lambda z: (z["min_x"], z["min_y"]))
    for x, y in zip(a, b):
        if (x["min_x"] != y["min_x"] or x["max_x"] != y["max_x"] or
                x["min_y"] != y["min_y"] or x["max_y"] != y["max_y"] or
                x["area"] != y["area"]):
            return False
    return True


def run_case(name, mask):
    runs = extract_runs(mask)
    rtl = filter_blobs(rtl_ccl(runs))
    ref = filter_blobs(ref_ccl(mask))
    ok = blobs_equal(rtl, ref)
    print("  [%s] runs=%d rtl_blobs=%d ref_blobs=%d  %s" %
          ("PASS" if ok else "FAIL", len(runs), len(rtl), len(ref), name))
    if not ok:
        print("    RTL:", rtl)
        print("    REF:", ref)
    return ok


def main():
    random.seed(42)
    all_ok = True

    print("== cv_top CCL 算法仿真 ==")

    # 1. 单球
    all_ok &= run_case("单球 r=15 @ (200,300)",
                       make_mask(disc(200, 300, 15)))

    # 2. 两个分离球
    all_ok &= run_case("两球 r=12 @ (100,100),(900,600)",
                       make_mask(disc(100, 100, 12), disc(900, 600, 12)))

    # 3. 多球（32 个随机）
    balls = []
    for _ in range(32):
        cx = random.randint(60, IMG_W - 60)
        cy = random.randint(60, IMG_H - 60)
        r = random.randint(8, 20)
        balls.append(disc(cx, cy, r))
    all_ok &= run_case("32 个随机球", make_mask(*balls))

    # 4. 贴边球（应被 EDGE_MG 剔除）
    all_ok &= run_case("贴边球 r=10 @ (2,300)",
                       make_mask(disc(2, 300, 10)))

    # 5. 小噪声点（应被 MIN_AREA 剔除）
    noise = {(random.randint(10, IMG_W - 10), random.randint(10, IMG_H - 10)) for _ in range(50)}
    all_ok &= run_case("单球 + 50 孤立噪声点", make_mask(disc(400, 400, 14), noise))

    # 6. 两个近挨球（接近合并，验证 union-find）
    all_ok &= run_case("近挨两球 r=10 @ (300,400),(322,400)",
                       make_mask(disc(300, 400, 10), disc(322, 400, 10)))

    # 7. 垂直叠加球（上下行重叠）
    all_ok &= run_case("垂直近挨两球 r=10 @ (500,300),(500,322)",
                       make_mask(disc(500, 300, 10), disc(500, 322, 10)))

    print()
    print("结论：%s" % ("全部通过" if all_ok else "有失败用例，需修复 cv_top 算法"))


if __name__ == "__main__":
    main()
