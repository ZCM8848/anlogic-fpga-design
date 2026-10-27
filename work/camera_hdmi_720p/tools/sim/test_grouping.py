# -*- coding: utf-8 -*-
"""块域碎片分组/固定框的合成用例。"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cv_pipeline_sim as sim


def make_mask(rects):
    m = np.zeros((45, 80), np.uint8)
    for x, y, w, h in rects:
        m[y:y + h, x:x + w] = 1
    return m


def check(name, rects, exp_n, exp_side=sim.BOX_BLK * 16):
    boxes = sim.detect_blocks(make_mask(rects), wide=False)
    got = len(boxes)
    if got != exp_n:
        raise AssertionError("%s: count=%d exp=%d boxes=%s" % (name, got, exp_n, boxes))
    for cx, cy, x0, y0, x1, y1 in boxes:
        side_x, side_y = x1 - x0 + 1, y1 - y0 + 1
        if (x0 > 0 and side_x != exp_side) or (y0 > 0 and side_y != exp_side):
            raise AssertionError("%s: box not fixed size (%d,%d) %s" %
                                 (name, side_x, side_y, boxes))
    print("PASS %-18s count=%d boxes=%s" % (name, got, boxes))
    return boxes


def main():
    check("complete", [(35, 18, 9, 9)], 1)
    check("split_h2", [(35, 18, 9, 4), (35, 24, 9, 3)], 1)
    check("split_v2", [(35, 18, 4, 9), (42, 18, 3, 9)], 1)
    check("frag4_cross", [(35, 18, 3, 3), (41, 18, 3, 3),
                          (35, 24, 3, 3), (41, 24, 3, 3)], 1)
    check("frag5_diag", [(35, 18, 3, 3), (38, 21, 3, 3), (41, 24, 3, 3),
                         (35, 22, 3, 3), (41, 18, 3, 3)], 1)
    check("touch2", [(20, 18, 9, 9), (29, 18, 9, 9)], 2)
    check("touch3", [(20, 18, 27, 9)], 3)
    check("noise3", [(10, 10, 3, 3)], 0)
    check("texture5x5", [(10, 10, 5, 5)], 0)
    check("sliver9x3", [(10, 10, 9, 3)], 0)
    check("line30x5", [(10, 10, 30, 5)], 0)
    check("wide12x9", [(10, 10, 12, 9)], 1)
    check("wide14x9", [(10, 10, 14, 9)], 0)

    # 碎片先后顺序不利时，分组之间的合并兜底
    boxes = sim.detect_blocks(make_mask([(35, 18, 3, 3), (41, 24, 3, 3),
                                         (35, 24, 3, 3), (41, 18, 3, 3)]), wide=True)
    if len(boxes) != 1:
        raise AssertionError("wide order: %s" % (boxes,))
    print("PASS wide_order        count=1")
    print("ALL PASS")


if __name__ == "__main__":
    main()
