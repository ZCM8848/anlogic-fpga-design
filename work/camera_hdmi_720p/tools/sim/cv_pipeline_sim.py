# -*- coding: utf-8 -*-
"""
cv_pipeline_sim.py — 当前 FPGA 检测/跟踪/计数管线的离线视频仿真（与 RTL 同参）
================================================================================
复刻当前 bit 的 CV 逻辑，用于在没有摄像头时对**录像**做验证：
  * 检测：块域(16x16)暗块 —— 对应 rtl/cv/cv_blkdet.v
          （DARK_THR + 与 5 帧前的块背景比较 + 按已知直径合并碎片）
  * 跟踪：cv_top 的 a-b 预测 + 贪心最近邻(GATE) + 丢失删轨(MISS_K)
  * 计数：红框轨迹预测出画面时 +1 —— 对应 cv_top.O_count（不做消亡补计）

用法:
  python cv_pipeline_sim.py <video> <out.mp4> [GATE MISS_K DARK] [--amin N]

注意:
  * 背景取 5 帧前的 80x45 块均值：静止暗块不进掩膜，运动球离开旧位置后必然与背景不同。
  * 钢珠直径 151 px -> 约 9 个块单元。碎片按"并集包围盒 <= 13x13 块"合并，
    分组支撑面积 >= 14 块、短边 >= 4 块、长边 >= 7 块；识别框固定 10x10 块
    （160x160 px），贴近钢珠并剔除长边不足 7 块的阴影/纹理小块。
  * 接触钢珠：长边超过 15 块的分组按长边拆成 2~4 颗；不再凭长宽比拆分。
  * 块域判别与 RTL 用 4 连通近似。
"""
import argparse
import cv2
import numpy as np

ALPHA = 0.5            # a-b 位置增益(≈cv_top ALPHA_Q/256)
BETA = 0.1875          # a-b 速度增益(≈cv_top BETA_Q/256)；GATE 配合吸收快球
BG_DELAY = 5           # 块背景取 5 帧前(与 cv_blkdet 的 BG_FRAMES 对应)
REC = 1                # 丢检只保留 1 帧，避免框闪烁，也避免离场后长残影

CB_DELTA = 20          # 块均值须比 5 帧前的背景低这么多才判暗
AMIN = 14              # 分组最小支撑面积(块数)；与 cv_blkdet 的 MIN_BLKN 对应
WIDE_THR = 130         # DARK_THR >= 此值时放宽左侧入场的紧凑团块(亮场景快球更大)
MIN_HITS_EX = 3        # 窄场景左/右边缘出画面门限；亮场景用 2（并排第二颗命中少）
MIN_HITS_V = 6         # 上/下边缘出画面门限(顶边真球 6；4 次命中的阴影仍被滤掉)
EXIT_MISS = 8          # 出画面计数允许的丢失帧数；短时丢检仍可计数

# 钢珠直径为 151 px，块域 16x16 -> 约 9 个块单元；识别框固定 10x10 个块单元。
BALL_BLK = 9           # 钢珠直径对应的块数(四舍五入)
GROUP_GATE_BLK = 13    # 同一颗钢珠全部碎片的最大并集包围盒
GROUP_MAX_SIDE = 13    # 单颗钢珠分组的最大边长，14 块以上不成单球
GROUP_MIN_SIDE = 4     # 分组短边下限，剔除细长残片
GROUP_MIN_LONG = 7     # 分组长边下限，剔除 5x5/6x6 阴影与纹理小块
BOX_BLK = 10           # 固定识别框边长(块)，160px，贴近 151px 钢珠
BOX_HALF = BOX_BLK * 8 # 固定识别框半边长(像素) = 80
DRAW_OFFSET_Y = 0      # 球心已由亮部峰直接求出，不再做固定下移
FRAG_MIN = 3           # 参与合并的碎片最小面积(块)
MAX_RAWWH = 36         # 原始连通域宽/高上限(块)，超过按背景长条剔除
MAX_BLKN = 400         # 原始连通域面积上限(块)
SPLIT_SIDE = 15        # 长边超过此值按多颗接触钢珠拆分
SPLIT_MIN_SIDE = 6     # 拆分时长边垂直方向的短边下限
DUP_DIST = 136         # 同一颗钢珠重复轨迹去重距离 = 0.9 * 151 px
FRAME_W = 1280
FRAME_H = 720
ROI_Y0 = 200           # 上方纹理区不输出识别框，保留左侧入场高度


def _union_box(a, b):
    """块坐标包围盒 (minx,maxx,miny,maxy,area) 的并集(坐标含端点)。"""
    return (min(a[0], b[0]), max(a[1], b[1]),
            min(a[2], b[2]), max(a[3], b[3]), a[4] + b[4])


def _box_wh(box):
    return box[1] - box[0] + 1, box[3] - box[2] + 1


def _edge_reject(x, y, w, h, a, wide):
    """入场边缘用近边窗口判定；刚露头的小块不再被普通尺寸门限挡住。"""
    xl, xr = (x <= 2), ((x + w) >= 78)
    yt, yb = (y == 0), ((y + h) >= 43)
    if yt:
        return True
    if (xl and yt) or (xr and yt) or (xl and yb) or (xr and yb):
        if not (wide and xl and w >= 2 and h >= 2 and a >= 8):
            return True
    if xl and (not wide or not (w >= 2 and h >= 2 and a >= 8)):
        return True
    return False


def _fixed_box(cx, cy):
    """以 (cx,cy) 为中心输出 208x208 的识别框(端点包含)。"""
    x0 = max(0, int(round(cx)) - BOX_HALF)
    x1 = min(FRAME_W - 1, int(round(cx)) + BOX_HALF - 1)
    y0 = max(0, int(round(cy)) - BOX_HALF)
    y1 = min(FRAME_H - 1, int(round(cy)) + BOX_HALF - 1)
    return (int(round(cx)), int(round(cy)), x0, y0, x1, y1)


def _group_fragments(frags):
    """任意数量碎片 -> 分组。合并条件只看并集包围盒是否装得进一颗钢珠。"""
    groups = []
    for f in frags:
        best = -1
        best_delta = None
        best_box = None
        for gi, g in enumerate(groups):
            u = _union_box(g, f)
            uw, uh = _box_wh(u)
            if uw <= GROUP_GATE_BLK and uh <= GROUP_GATE_BLK:
                gw, gh = _box_wh(g)
                delta = uw * uh - gw * gh
                if best < 0 or delta < best_delta:
                    best, best_delta, best_box = gi, delta, u
        if best < 0:
            groups.append(f)
        else:
            groups[best] = best_box

    # 分组之间再合并：处理碎片先后顺序造成的一颗钢珠分成多个分组。
    changed = True
    while changed:
        changed = False
        for i in range(len(groups)):
            j = i + 1
            while j < len(groups):
                u = _union_box(groups[i], groups[j])
                uw, uh = _box_wh(u)
                if uw <= GROUP_GATE_BLK and uh <= GROUP_GATE_BLK:
                    groups[i] = u
                    groups.pop(j)
                    changed = True
                else:
                    j += 1
    return groups


def _split_boxes(minx, maxx, miny, maxy, n):
    """把长条形分组沿长边等分成 n 颗钢珠，每颗输出固定识别框。"""
    w, h = maxx - minx + 1, maxy - miny + 1
    if w >= h:
        start, seg = minx, w / float(n)
        cy = (miny + maxy + 1) * 8.0
        return [_fixed_box((start + seg * (i + 0.5)) * 16.0, cy)
                for i in range(n)]
    start, seg = miny, h / float(n)
    cx = (minx + maxx + 1) * 8.0
    return [_fixed_box(cx, (start + seg * (i + 0.5)) * 16.0)
            for i in range(n)]


def _group_boxes(g, bm=None, ring=None, center_bright=False, offset_y=0.0,
                 edge_allow=False, dog_score=None):
    """分组 -> 固定识别框。超过一颗钢珠范围的分组按接触钢珠拆分。"""
    minx, maxx, miny, maxy, a = g
    w, h = _box_wh(g)
    edge = edge_allow and (minx <= 2)
    min_area = 10 if edge else AMIN
    min_side = 3 if edge else GROUP_MIN_SIDE
    min_long = 3 if edge else GROUP_MIN_LONG
    if a < min_area or min(w, h) < min_side or max(w, h) < min_long:
        return []
    if max(w, h) <= GROUP_MAX_SIDE:
        if edge:
            if max(w, h) * 5 > min(w, h) * 11:
                return []
        elif max(w, h) * 5 > min(w, h) * 9:
            return []
        cx = (minx + maxx + 1) * 8.0
        cy = (miny + maxy + 1) * 8.0
        if center_bright and bm is not None and ring is not None:
            # 分组常落在球旁的阴影上；向四周扩 6 个块再按亮部加权，把中心拉回球体。
            ex0, ex1 = max(0, minx - 6), min(79, maxx + 6)
            ey0, ey1 = max(0, miny - 6), min(44, maxy + 6)
            sub_bm = bm[ey0:ey1 + 1, ex0:ex1 + 1]
            sub_rg = ring[ey0:ey1 + 1, ex0:ex1 + 1]
            wgt = np.clip(sub_bm.astype(np.float32) - sub_rg, 0.0, None)
            sw = float(wgt.sum())
            if sw > 1.0:
                yy, xx = np.mgrid[0:wgt.shape[0], 0:wgt.shape[1]]
                bcx = ex0 + float((xx * wgt).sum()) / sw
                bcy = ey0 + float((yy * wgt).sum()) / sw
                cx = (bcx + 0.5) * 16.0
                cy = (bcy + 0.5) * 16.0
        if dog_score is not None:
            # 阴影分组附近找球体亮部的中心-环绕峰，直接把框心放到球体上
            ex0, ex1 = max(0, minx - 8), min(79, maxx + 8)
            ey0, ey1 = max(0, miny - 8), min(44, maxy + 8)
            sub = dog_score[ey0:ey1 + 1, ex0:ex1 + 1]
            iy, ix = np.unravel_index(int(np.argmax(sub)), sub.shape)
            if float(sub[iy, ix]) > 8.0:
                cx = (ex0 + ix + 0.5) * 16.0
                cy = (ey0 + iy + 0.5) * 16.0
        return [_fixed_box(cx, cy + offset_y)]
    if max(w, h) < SPLIT_SIDE:
        return []

    long_side, short_side = max(w, h), min(w, h)
    n = (long_side + 4) // BALL_BLK
    n = max(2, min(4, n))
    if short_side < SPLIT_MIN_SIDE or short_side > GROUP_MAX_SIDE:
        return []
    if a < n * AMIN:
        return []
    return _split_boxes(minx, maxx, miny, maxy, n)


def detect_blocks(m, wide=False, bm=None, ring=None, center_bright=False,
                  center_offset_y=0.0, dog_score=None):
    """输入 80x45 块掩膜(1=前景)，输出固定识别框[(cx,cy,minx,miny,maxx,maxy)]。"""
    n, _lab, stats, _cent = cv2.connectedComponentsWithStats(m, 4)
    frags = []
    for i in range(1, n):
        x, y, w, h, a = [int(v) for v in stats[i]]
        if a < FRAG_MIN or a > MAX_BLKN:
            continue
        if w > MAX_RAWWH or h > MAX_RAWWH:
            continue
        if _edge_reject(x, y, w, h, a, wide):
            continue
        frags.append((x, x + w - 1, y, y + h - 1, a))

    out = []
    for g in _group_fragments(frags):
        for b in _group_boxes(g, bm, ring, center_bright, center_offset_y,
                              wide, dog_score):
            if b[1] >= ROI_Y0 or (b[0] <= 240 and b[1] >= 150):
                out.append(b)
    return out


def _ring_mean(bm):
    """每块周围 21x21 环带（去掉中心 11x11）的均值。"""
    p = 10
    # 左侧边界反射画面内侧的桌面亮度，避免把画外黑边当成背景；其它边保持原样
    pad = np.pad(bm.astype(np.float32), ((p, p), (p, p)), mode="edge")
    pad[p:p + bm.shape[0], :p] = bm[:, p:0:-1]
    ii = cv2.integral(pad)
    s21 = ii[21:66, 21:101] - ii[0:45, 21:101] - ii[21:66, 0:80] + ii[0:45, 0:80]
    s11 = ii[16:61, 16:96] - ii[5:50, 16:96] - ii[16:61, 5:85] + ii[5:50, 5:85]
    return (s21 - s11).astype(np.float32) / 320.0


def _local_mask(bm, bg, cb, local_delta, bright=False, both=False):
    """块均值与周围环带背景比较，消除中间亮、四周暗的光照梯度。"""
    ring = _ring_mean(bm)
    if bright:
        return ((bm > bg + cb) & (bm > ring + local_delta)).astype(np.uint8)
    if both:
        return ((np.abs(bm - bg) > cb) & (np.abs(bm - ring) > local_delta)).astype(np.uint8)
    return ((bm + cb < bg) & (bm + local_delta < ring)).astype(np.uint8)


def mask_from_bm(bm, bg, dark, mode="abs", cb=None, local_delta=20):
    cb = CB_DELTA if cb is None else cb
    if mode == "local":
        return _local_mask(bm, bg, cb, local_delta)
    if mode == "bright":
        return _local_mask(bm, bg, cb, local_delta, bright=True)
    if mode == "both":
        return _local_mask(bm, bg, cb, local_delta, both=True)
    if mode == "temporal":
        return (bm + cb < bg).astype(np.uint8)
    return ((bm < dark) & (bm + cb < bg)).astype(np.uint8)


def _dog_response(bm, bg, thr=6.0, s1=1.5, s2=5.0):
    """中心-环绕差分：球体亮部为正峰，阴影/背景纹理接近 0 或负值。"""
    blur1 = cv2.GaussianBlur(bm.astype(np.float32), (0, 0), s1)
    blur2 = cv2.GaussianBlur(bm.astype(np.float32), (0, 0), s2)
    score = blur1 - blur2
    cand = ((score > thr) & (bm > bg + 5.0)).astype(np.uint8)
    return score, cand


def detect_dog(bm, bg, thr=6.0, s1=1.5, s2=5.0, nms=5):
    if bg is None:
        return [], np.zeros((45, 80), np.uint8)
    score, cand = _dog_response(bm, bg, thr, s1, s2)
    # 局部极大值 + 按球直径做非极大值抑制
    mx = cv2.dilate(score, np.ones((2 * nms + 1, 2 * nms + 1), np.uint8))
    ys, xs = np.nonzero(cand & (score >= mx - 1e-6))
    order = np.argsort(-score[ys, xs])
    kept = []
    for k in order:
        x, y = int(xs[k]), int(ys[k])
        ok = True
        for px, py in kept:
            if abs(x - px) + abs(y - py) < nms:
                ok = False
                break
        if ok:
            kept.append((x, y))
    out = []
    for x, y in kept:
        b = _fixed_box((x + 0.5) * 16.0, (y + 0.5) * 16.0)
        if b[1] >= ROI_Y0:
            out.append(b)
    return out, cand


def detect(frame, dark, bg=None, mode="abs", cb=None, local_delta=20):
    """块域暗块检测 -> 固定识别框[像素(cx,cy,minx,miny,maxx,maxy)]。
    bg 为 5 帧前的 80x45 块均值；None 表示背景尚未建立。"""
    B = frame[:, :, 0].astype(np.uint16)
    G = frame[:, :, 1].astype(np.uint16)
    R = frame[:, :, 2].astype(np.uint16)
    wy = ((R >> 2) + (G >> 1) + (B >> 2)).astype(np.float32)
    bm = cv2.resize(wy, (80, 45), interpolation=cv2.INTER_AREA)  # 16x16 块均值
    if bg is None:
        return []
    if mode == "dog":
        return detect_dog(bm, bg, thr=float(local_delta))[0]
    m = mask_from_bm(bm, bg, dark, mode, cb, local_delta)
    ring = _ring_mean(bm)
    score, _ = _dog_response(bm, bg, 6.0)
    return detect_blocks(m, dark >= WIDE_THR, bm, ring, False, 0.0, score)


FONT5x7 = {
    0x0: ("01110", "10001", "10011", "10101", "11001", "10001", "01110"),
    0x1: ("00100", "01100", "00100", "00100", "00100", "00100", "01110"),
    0x2: ("01110", "10001", "00001", "00010", "00100", "01000", "11111"),
    0x3: ("11110", "00001", "00001", "01110", "00001", "00001", "11110"),
    0x4: ("00010", "00110", "01010", "10010", "11111", "00010", "00010"),
    0x5: ("11111", "10000", "11110", "00001", "00001", "10001", "01110"),
    0x6: ("00110", "01000", "10000", "11110", "10001", "10001", "01110"),
    0x7: ("11111", "00001", "00010", "00100", "01000", "01000", "01000"),
    0x8: ("01110", "10001", "10001", "01110", "10001", "10001", "01110"),
    0x9: ("01110", "10001", "10001", "01111", "00001", "00010", "11100"),
    0xa: ("01110", "10001", "10001", "11111", "10001", "10001", "10001"),
    0xb: ("11110", "10001", "10001", "11110", "10001", "10001", "11110"),
    0xc: ("01110", "10001", "10000", "10000", "10000", "10001", "01110"),
    0xd: ("11110", "10001", "10001", "10001", "10001", "10001", "11110"),
    0xe: ("11111", "10000", "10000", "11110", "10000", "10000", "11111"),
    0xf: ("11111", "10000", "10000", "11110", "10000", "10000", "10000"),
}


def draw_id(frame, x, y, tid):
    rows = FONT5x7.get(tid & 0xF)
    h, w = frame.shape[:2]
    for r, bits in enumerate(rows):
        for c, ch in enumerate(bits):
            if ch == '1' and 0 <= y + r < h and 0 <= x + c < w:
                frame[y + r, x + c] = (255, 255, 255)


def draw_count(frame, n):
    """左上角实时显示累计计数（与硬件 OSD 的 BALL 字段对应）。"""
    text = "BALL: %d" % int(n)
    cv2.rectangle(frame, (8, 8), (220, 52), (0, 0, 0), -1)
    cv2.putText(frame, text, (16, 41), cv2.FONT_HERSHEY_SIMPLEX,
                0.9, (0, 255, 255), 2, cv2.LINE_AA)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("out")
    ap.add_argument("gate", type=int, nargs="?", default=320)
    ap.add_argument("miss_k", type=int, nargs="?", default=35)
    ap.add_argument("dark", type=int, nargs="?", default=100)
    ap.add_argument("--amin", type=int, default=14, help="分组最小支撑面积(块数)")
    ap.add_argument("--mask-mode",
                    choices=["abs", "temporal", "local", "bright", "both", "dog"],
                    default="abs",
                    help="abs=绝对暗阈值+5帧背景；temporal=5帧背景；local=暗+环带；"
                         "bright=亮+环带；both=亮暗都取+环带；dog=球尺度中心-环绕亮斑")
    ap.add_argument("--cb", type=int, default=20, help="块均值低于背景的门限")
    ap.add_argument("--local-delta", type=int, default=20, help="local 模式：块均值低于周围环带均值的门限")
    ap.add_argument("--mask", action="store_true", help="输出内部 80x45 块掩膜（白=暗块，黑=背景，无叠加）")
    ap.add_argument("--mask-osd", action="store_true", help="输出块掩膜并叠加红框/白色 ID（对应 K2 状态 2）")
    ap.add_argument("--overlay", action="store_true",
                    help="原视频打底，白色二值区域 50% 透明叠加，并叠加红框/白色 ID")
    args = ap.parse_args()
    mask_view = args.mask or args.mask_osd or args.overlay
    global AMIN
    AMIN = args.amin
    wide = args.dark >= WIDE_THR

    cap = cv2.VideoCapture(args.video)
    W = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)); H = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = cap.get(cv2.CAP_PROP_FPS) or 60
    if args.overlay:
        vw = cv2.VideoWriter(args.out, cv2.VideoWriter_fourcc(*"mp4v"), fps, (W, H))
    elif mask_view:
        if not args.out.lower().endswith(".mkv"):
            raise SystemExit("mask 视图使用 FFV1 无损编码，输出文件请用 .mkv")
        vw = cv2.VideoWriter(args.out, cv2.VideoWriter_fourcc(*"FFV1"), fps, (W, H))
    else:
        vw = cv2.VideoWriter(args.out, cv2.VideoWriter_fourcc(*"mp4v"), fps, (W, H))

    tracks = []   # [cx,cy,vx,vy,missed,hits,box,counted,id]
    next_id = 0; count = 0; nf = 0; events = []; recent = []
    suppressed = 0
    hist = []     # 最近 BG_DELAY 帧的 80x45 块均值
    while True:
        ok, fr = cap.read()
        if not ok: break
        nf += 1
        Bf = fr[:, :, 0].astype(np.uint16); Gf = fr[:, :, 1].astype(np.uint16); Rf = fr[:, :, 2].astype(np.uint16)
        bmf = cv2.resize(((Rf >> 2) + (Gf >> 1) + (Bf >> 2)).astype(np.float32), (80, 45), interpolation=cv2.INTER_AREA)
        bg = hist[-BG_DELAY] if len(hist) >= BG_DELAY else None
        dets = detect(fr, args.dark, bg, args.mask_mode, args.cb, args.local_delta)
        if mask_view:
            if bg is None:
                m = np.zeros((45, 80), np.uint8)
            elif args.mask_mode == "dog":
                m = _dog_response(bmf, bg, float(args.local_delta))[1]
            else:
                m = mask_from_bm(bmf, bg, args.dark, args.mask_mode,
                                 args.cb, args.local_delta)
            m3 = cv2.cvtColor(cv2.resize(m * 255, (W, H), interpolation=cv2.INTER_NEAREST),
                              cv2.COLOR_GRAY2BGR)
            if args.overlay:
                out_fr = fr.copy()
                sel = m3[:, :, 0] > 127
                white = np.full_like(fr, 255)
                out_fr[sel] = cv2.addWeighted(fr, 0.5, white, 0.5, 0)[sel]
            else:
                out_fr = m3
        else:
            out_fr = fr
        hist.append(bmf)
        if len(hist) > BG_DELAY: hist.pop(0)
        taken = [False] * len(dets); assigns = [-1] * len(tracks)
        for ti, t in enumerate(tracks):
            px, py = t[0] + t[2], t[1] + t[3]
            best = -1; bd = args.gate
            for j, d in enumerate(dets):
                if taken[j]: continue
                dd = abs(d[0] - px) + abs(d[1] - py)
                if dd < bd: bd = dd; best = j
            if best >= 0: taken[best] = True; assigns[ti] = best
        for ti, t in enumerate(tracks):
            if assigns[ti] >= 0:
                d = dets[assigns[ti]]; dx = d[0] - t[0]; dy = d[1] - t[1]
                t[2] += BETA * dx; t[3] += BETA * dy
                t[0] += t[2] + ALPHA * dx; t[1] += t[3] + ALPHA * dy
                t[4] = 0; t[5] += 1; t[6] = _fixed_box(t[0], t[1])[2:6]
            else:
                t[0] += t[2]; t[1] += t[3]; t[4] += 1
                t[6] = _fixed_box(t[0], t[1])[2:6]
        for j, d in enumerate(dets):
            if not taken[j]:
                # 同一颗钢珠的残余碎片不再新建轨迹：已有轨迹最近 2 帧有检测且中心距离过近
                dup = any(t[4] <= 2 and
                          abs(d[0] - t[0]) + abs(d[1] - t[1]) < DUP_DIST
                          for t in tracks)
                if dup:
                    suppressed += 1
                    continue
                tracks.append([d[0], d[1], 0, 0, 0, 1, d[2:6], False, next_id]); next_id += 1

        # 同一颗钢珠的重复轨迹：中心距离小于 113 px 时只保留命中数更多的轨迹
        keep = [True] * len(tracks)
        for i in range(len(tracks)):
            if not keep[i] or tracks[i][4] > 2:
                continue
            for j in range(i + 1, len(tracks)):
                if not keep[j] or tracks[j][4] > 2:
                    continue
                if (abs(tracks[i][0] - tracks[j][0]) +
                        abs(tracks[i][1] - tracks[j][1]) < DUP_DIST):
                    if (tracks[i][5], -tracks[i][8]) >= (tracks[j][5], -tracks[j][8]):
                        keep[j] = False
                    else:
                        keep[i] = False
                        break
        tracks = [t for t, k in zip(tracks, keep) if k]

        # 红框轨迹预测出画面 -> +1（左右边缘命中≥4；上下边缘需≥8，滤阴影/反光）
        for t in tracks:
            # 球心越过“画面边界 + 半径”才算离开，避免钢珠还有半个身子在画面内就计数
            out_x = t[0] < -BOX_HALF or t[0] >= W + BOX_HALF
            out_y = t[1] < -BOX_HALF or t[1] >= H + BOX_HALF
            need = (2 if wide else MIN_HITS_EX) if out_x else MIN_HITS_V
            if t[1] > 650 and t[0] < 700:
                need = 8   # 底部左侧反光带：阴影/倒影，要求更高命中
            if (not t[7]) and t[5] >= need and t[4] <= EXIT_MISS and (out_x or out_y):
                t[7] = True
                corner = (t[1] < 100 or t[1] > 650)
                dup = corner and any(nf - rf <= 3 and (ry < 100 or ry > 650) and
                                     abs(t[0] - rx) + abs(t[1] - ry) <= 150
                                     for rf, rx, ry in recent)
                short = t[5] <= 3
                dup2 = short and any(nf - rf <= 2 and
                                     abs(t[0] - rx) + abs(t[1] - ry) <= 80
                                     for rf, rx, ry in recent)
                shadow2 = short and t[1] > 550 and any(nf - rf <= 15 and
                                     abs(t[0] - rx) + abs(t[1] - ry) <= 300
                                     for rf, rx, ry in recent)
                dup = dup or dup2 or shadow2
                if not dup:
                    count += 1
                    events.append((nf, count, int(t[0]), int(t[1]), t[5]))
                    recent.append((nf, t[0], t[1]))
                    recent = recent[-8:]
        tracks = [t for t in tracks if t[4] <= args.miss_k]
        if (not args.mask) or args.mask_osd or args.overlay:
            for t in tracks:
                if t[4] > REC: continue          # 纯预测滑行的不画
                b = t[6]
                y0 = max(0, min(H - 1, int(b[1]) + DRAW_OFFSET_Y))
                y1 = max(0, min(H - 1, int(b[3]) + DRAW_OFFSET_Y))
                cv2.rectangle(out_fr, (int(b[0]), y0), (int(b[2]), y1), (0, 0, 255), 2)
                # 与 bit 的叠加一致：白色 5x7 ID 数字画在框左上角，不使用调试文字
                draw_id(out_fr, int(b[0]), y0, t[8] & 0xF)
        if not args.mask:
            draw_count(out_fr, count)
        vw.write(out_fr)
    vw.release()
    print("video=%s frames=%d GATE=%d MISS_K=%d DARK=%d MODE=%s CB=%d LD=%d "
          "-> COUNT=%d ids=%d suppressed=%d"
          % (args.video, nf, args.gate, args.miss_k, args.dark,
             args.mask_mode, args.cb, args.local_delta, count,
             next_id, suppressed))
    print("COUNT events (frame,count,x,y,hits):", events)


if __name__ == "__main__":
    main()
