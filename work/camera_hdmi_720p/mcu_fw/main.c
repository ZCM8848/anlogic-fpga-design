/*
 * ph1p35_cv — MCU 固件：钢珠检测参数 + CCL/跟踪/门线计数/overlay
 * ============================================================
 * 所有可调参数集中在下面「调参区」的 VISION_PARAMS 结构体；RTL 不含任何
 * 业务阈值，只执行 MCU 写入的背景阈值/使能/背景采集命令。
 *
 * 数据流：
 *   cv_top（pixel）: G 4x4 -> 320x180 -> |G-BG| -> run_mem
 *   MCU（本文件） : 读 run -> CCL -> 形状筛选 -> 合并碎块
 *                   -> 轨迹跟踪（最近邻 + 运动门控） -> 门线计数
 *                   -> overlay（固定 2R 框，坐标 x4 回 1280x720）
 *
 * 调参流程：只改 VISION_PARAMS，重新编译 MCU 固件，不需要重新综合 FPGA。
 */
#include <stdio.h>
#include <stdint.h>
#include "al_core.h"

extern int  al_simp_printf(const char *format, ...);
extern void al_simp_putchar(char c);

#define AHB_STATUS_BASE  0x80000000UL
#define CAM_REG     (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x00))
#define CV_REG      (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x04))
#define FRAME_REG   (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x08))
#define VER_REG     (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x0C))
#define HEARTBEAT   (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x10))
#define RUN_IDX     (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x18))
#define RUN_DAT     (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x1C))
#define OV_IDX      (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x20))
#define OV_W0       (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x24))
#define OV_W1       (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x28))
#define META_REG    (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x2C))
#define OV_COUNT    (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x30))
#define BALL_CTRL   (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x34))
#define BALL_THR    (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x38))
#define BALL_STATUS (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x3C))
#define SW_STAT     (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x40))
#define BCD_COUNT   (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x44))
#define BALL_RUN_CFG (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x48))
#define SKIP_CNT    (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x4C))

#define VER_MAGIC   0x4D435602U

/* =====================================================================
 *                        调 参 区（只改这里）
 * ---------------------------------------------------------------------
 * 坐标/面积全部是 320x180 检测分辨率；overlay 输出时自动 x4 回 720p。
 * 检测流程：4x4 平均 -> |G-BG| >= bg_thr -> run -> CCL -> 形状筛选
 *           -> 合并距离 merge_dist 内的碎块 -> 跟踪 -> 门线计数。
 * 轨迹可见条件（与 Python 参考实现一致）：
 *   hits >= min_hits
 *   且 misses == 0
 *   且 总位移 moved >= min_move
 *   且 最近 5 帧位移 <= -min_window
 *   且 vx <= vx_max（vx_max 为负数）
 * 只有可见轨迹才画框、才可能计数；只有从右向左穿过 gate_x 才计数。
 * ===================================================================== */
typedef struct {
    /* ---- 前端 / 背景 ---- */
    int enable;                 /* 1=启用钢珠前端；0=只保留直通画面 */
    int bg_thr;                 /* 背景差分阈值（0..255） */
    int min_run;                /* run 最短长度（320 尺度；1=不过滤，2=去孤立点） */
    int bg_capture_delay;       /* 相机配置/DDR 就绪后再等多少帧采背景 */
    int bg_settle_frames;       /* 采背景前先让 edge/OSD 关闭并清空流水线的帧数 */

    /* ---- 连通域筛选（320x180）---- */
    int min_area;               /* 面积下限 */
    int max_area;               /* 面积上限 */
    int min_w;                  /* bbox 宽下限 */
    int max_w;                  /* bbox 宽上限 */
    int min_h;                  /* bbox 高下限 */
    int max_h;                  /* bbox 高上限 */
    int min_fill;               /* 填充率下限（百分比，0=不检查） */
    int min_ratio;              /* 短边/长边 下限（百分比，0=不检查） */
    int edge_margin;            /* 贴边剔除像素（320 尺度，0=不剔除） */
    int merge_dist;             /* 碎块合并半径（320 尺度，约 0.8*D） */
    int max_run_len;            /* 单行 run 最大长度，超过丢弃（0=不过滤） */

    /* ---- 几何 ---- */
    int box_w_small;            /* 固定框边长（320 尺度，约 D/4 = 43） */
    int gate_x;                 /* 门线 x（320 尺度，0.30*320=96） */
    int gate_y0, gate_y1;       /* 门线 y 范围（320 尺度） */
    int roi_y1;                 /* CCL 只处理 y<=roi_y1；<0 或 >=180 表示不过滤 */

    /* ---- 跟踪 ---- */
    int track_gate;             /* 最近邻关联半径（320 尺度，欧氏距离） */
    int max_miss;               /* 连续丢失多少帧删轨迹 */
    int min_hits;               /* 确认所需命中数 */
    int min_move;               /* 总位移门限（320 尺度，约 0.2D=9） */
    int min_window;             /* 最近 5 帧位移门限（320 尺度，约 0.5D=21） */
    int vx_max;                 /* 左向速度门限（320 尺度，负数，约 -1） */
    int static_max_age;         /* 静态轨迹最多存活帧数 */

    /* ---- 调试 ---- */
    int debug;                  /* 1=输出 D 行调试信息 */
    int debug_div;              /* 每多少帧输出一行 D */
} vision_params_t;

static const vision_params_t VISION_PARAMS = {
    .enable              = 1,
    .bg_thr              = 30,
    .min_run             = 2,
    .bg_capture_delay    = 120,   /* ≈2s @60fps，等相机/补光稳定 */
    .bg_settle_frames    = 10,    /* 关 edge/OSD 后清 4 帧 DDR 流水线 */

    .min_area            = 100,
    .max_area            = 1500,
    .min_w               = 18,
    .max_w               = 100,
    .min_h               = 5,
    .max_h               = 50,
    .min_fill            = 0,     /* 参考实现不做填充率筛选 */
    .min_ratio           = 0,     /* 参考实现不做长短比筛选 */
    .edge_margin         = 0,
    .merge_dist          = 34,    /* 0.8 * 43 ≈ 34 */
    .max_run_len         = 200,   /* 大于 4 个球宽的横向 run 丢弃 */

    .box_w_small         = 43,
    .gate_x              = 96,
    .gate_y0             = 14,
    .gate_y1             = 166,
    .roi_y1              = 166,   /* 与门线底部一致；底部球堆不参与 CCL */

    .track_gate          = 55,    /* 220 / 4 */
    .max_miss            = 5,
    .min_hits            = 2,
    .min_move            = 9,     /* 0.2 * 171 / 4 */
    .min_window          = 21,    /* 0.5 * 171 / 4 */
    .vx_max              = -1,
    .static_max_age      = 30,

    .debug               = 1,
    .debug_div           = 30,
};
/* ============================ 调参区结束 ============================ */

#define IMG_W       320
#define IMG_H       180
#define OUT_W       1280
#define OUT_H       720
#define OUT_SCALE   4
#define MAX_RUNS    1024
#define MAX_LABELS  96
#define MAX_PREV    160
#define MAX_DET     8
#define MAX_TRK     8

#define DBG_TOPK    3
#define BKT1        100
#define BKT2        500

#define ABS(x) ((x) < 0 ? -(x) : (x))
#define V_CLAMP(v, lo, hi) ((v) < (lo) ? (lo) : ((v) > (hi) ? (hi) : (v)))

struct Feat { int valid; int area; int x0, y0, x1, y1; long sum_x, sum_y; };
struct PrevRun { int xs, xe, lbl; };
struct Det { int valid; int cx, cy; int area; };
struct Track {
    int valid; int id;
    int cx, cy; int vx, vy;
    int prev_cx, prev_cy;
    int missed, hits, counted;
    int start_cx, start_cy;
    int age;
    int moved, window_move;
    int hist[5]; int hist_n;
    int visible;
};
struct Pair { uint16_t d2; uint8_t ti, di; };

static struct Feat    feat[MAX_LABELS];
static int            label_parent[MAX_LABELS];
static struct PrevRun prev_r[MAX_PREV], cur_r[MAX_PREV];
static int            n_prev, n_cur, prev_y, next_label;
static struct Det     det[MAX_DET];
static int            n_det;
static struct Track   trk[MAX_TRK];
static int            next_id;
static int            count;
static int            ccl_overflow;
static int            skip_roi_cnt, skip_len_cnt;

struct DbgComp { int area, x0, y0, x1, y1, pass; };
static struct DbgComp dbg[DBG_TOPK];
static int            n_dbg;
static int            bkt_a, bkt_b, bkt_c;

static void putx(uint32_t val, int width)
{
    char b[8];
    int k;
    static const char hex[] = "0123456789ABCDEF";
    for (k = width - 1; k >= 0; k--) { b[k] = hex[val & 0xF]; val >>= 4; }
    for (k = 0; k < width; k++) al_simp_putchar(b[k]);
}

static uint32_t read_run(int i)
{
    RUN_IDX = (uint32_t)i;
    (void)RUN_DAT;        /* 旧值，丢弃 */
    (void)RUN_DAT;        /* B 口地址寄存器多一拍 */
    return RUN_DAT;       /* 新值 */
}

static int half_floor(int v)
{
    if (v >= 0) return v >> 1;
    return -(((-v) + 1) >> 1);   /* 与 Python 的 //2 一致（向负无穷取整） */
}

static int find_l(int l)
{
    while (label_parent[l] != l) {
        label_parent[l] = label_parent[label_parent[l]];
        l = label_parent[l];
    }
    return l;
}
static void uni_l(int a, int b)
{
    a = find_l(a); b = find_l(b);
    if (a != b) label_parent[b] = a;
}

static void ccl_init(void)
{
    int i;
    for (i = 0; i < MAX_LABELS; i++) {
        feat[i].valid = 0; feat[i].area = 0;
        feat[i].x0 = IMG_W; feat[i].x1 = 0;
        feat[i].y0 = IMG_H; feat[i].y1 = 0;
        feat[i].sum_x = 0; feat[i].sum_y = 0;
        label_parent[i] = i;
    }
    n_prev = 0; n_cur = 0; prev_y = -1; next_label = 0;
    ccl_overflow = 0;
    skip_roi_cnt = 0; skip_len_cnt = 0;
}

static void ccl_step(uint32_t r)
{
    int y  = (r >> 22) & 0x3FF;
    int xs = (r >> 11) & 0x7FF;
    int xe = r & 0x7FF;
    int k, found = -1, len;

    if (y != prev_y) {
        if (y > prev_y + 1) {
            n_prev = 0;
        } else {
            for (k = 0; k < n_cur; k++) prev_r[k] = cur_r[k];
            n_prev = n_cur;
        }
        n_cur = 0; prev_y = y;
    }
    len = xe - xs + 1;
    if (VISION_PARAMS.roi_y1 >= 0 && VISION_PARAMS.roi_y1 < IMG_H &&
        y > VISION_PARAMS.roi_y1) {
        skip_roi_cnt++;
        return;
    }
    if (VISION_PARAMS.max_run_len > 0 && len > VISION_PARAMS.max_run_len) {
        skip_len_cnt++;
        return;
    }
    for (k = 0; k < n_prev; k++) {
        if (prev_r[k].xs <= xe && prev_r[k].xe >= xs) {
            int pl = find_l(prev_r[k].lbl);
            if (found < 0) found = pl;
            else uni_l(found, pl);
        }
    }
    int lbl;
    if (found < 0) {
        if (next_label < MAX_LABELS) {
            lbl = next_label;
            label_parent[next_label] = next_label;
            next_label++;
        } else {
            lbl = MAX_LABELS - 1;
            ccl_overflow = 1;
        }
    } else {
        lbl = find_l(found);
    }
    int seg = xe - xs + 1;
    feat[lbl].valid = 1;
    feat[lbl].area += seg;
    if (xs < feat[lbl].x0) feat[lbl].x0 = xs;
    if (xe > feat[lbl].x1) feat[lbl].x1 = xe;
    if (y  < feat[lbl].y0) feat[lbl].y0 = y;
    if (y  > feat[lbl].y1) feat[lbl].y1 = y;
    feat[lbl].sum_x += (long)(xs + xe) * seg / 2;
    feat[lbl].sum_y += (long)y * seg;
    if (n_cur < MAX_PREV) {
        cur_r[n_cur].xs = xs; cur_r[n_cur].xe = xe; cur_r[n_cur].lbl = lbl;
        n_cur++;
    } else {
        ccl_overflow = 1;
    }
}

static void sort_dets_by_area(void)
{
    int i, j;
    struct Det key;
    for (i = 1; i < n_det; i++) {
        key = det[i];
        j = i - 1;
        while (j >= 0 && det[j].area < key.area) {
            det[j + 1] = det[j];
            j--;
        }
        det[j + 1] = key;
    }
}

/* Merge split pieces of one ball; distinct balls are >= ~1 diameter apart. */
static void merge_close_dets(void)
{
    struct Det keep[MAX_DET];
    int nk = 0, i, k;
    int md = VISION_PARAMS.merge_dist;
    if (n_det <= 1 || md <= 0) return;

    sort_dets_by_area();
    for (i = 0; i < n_det; i++) {
        int merged = 0;
        for (k = 0; k < nk; k++) {
            int dx = det[i].cx - keep[k].cx;
            int dy = det[i].cy - keep[k].cy;
            if (dx * dx + dy * dy < md * md) {
                int total = keep[k].area + det[i].area;
                keep[k].cx = (keep[k].cx * keep[k].area +
                              det[i].cx * det[i].area) / total;
                keep[k].cy = (keep[k].cy * keep[k].area +
                              det[i].cy * det[i].area) / total;
                keep[k].area = total;
                merged = 1;
                break;
            }
        }
        if (!merged) keep[nk++] = det[i];
    }
    for (i = 0; i < nk; i++) det[i] = keep[i];
    n_det = nk;
}

static void insert_det_sorted(int cx, int cy, int area)
{
    struct Det d;
    int k;
    d.valid = 1; d.cx = cx; d.cy = cy; d.area = area;

    if (n_det < MAX_DET) {
        k = n_det;
        while (k > 0 && det[k - 1].area < area) {
            det[k] = det[k - 1];
            k--;
        }
        det[k] = d;
        n_det++;
    } else if (area > det[MAX_DET - 1].area) {
        det[MAX_DET - 1] = d;
        k = MAX_DET - 1;
        while (k > 0 && det[k - 1].area < det[k].area) {
            struct Det tmp = det[k - 1];
            det[k - 1] = det[k];
            det[k] = tmp;
            k--;
        }
    }
}

static void ccl_finalize(void)
{
    int i;
    if (ccl_overflow) {
        n_det = 0;
        n_dbg = 0;
        bkt_a = bkt_b = bkt_c = 0;
        return;
    }
    for (i = 0; i < next_label; i++) {
        if (!feat[i].valid) continue;
        int root = find_l(i);
        if (root != i) {
            feat[root].valid = 1;
            feat[root].area += feat[i].area;
            if (feat[i].x0 < feat[root].x0) feat[root].x0 = feat[i].x0;
            if (feat[i].x1 > feat[root].x1) feat[root].x1 = feat[i].x1;
            if (feat[i].y0 < feat[root].y0) feat[root].y0 = feat[i].y0;
            if (feat[i].y1 > feat[root].y1) feat[root].y1 = feat[i].y1;
            feat[root].sum_x += feat[i].sum_x;
            feat[root].sum_y += feat[i].sum_y;
            feat[i].valid = 0;
        }
    }
    n_det = 0;
    n_dbg = 0;
    bkt_a = bkt_b = bkt_c = 0;
    for (i = 0; i < next_label; i++) {
        int area, w, h, mn, mx, pass;
        if (!feat[i].valid || find_l(i) != i) continue;
        area = feat[i].area;
        w = feat[i].x1 - feat[i].x0 + 1;
        h = feat[i].y1 - feat[i].y0 + 1;
        mn = w < h ? w : h; mx = w < h ? h : w;
        pass = 1;
        if (area < VISION_PARAMS.min_area || area > VISION_PARAMS.max_area) pass = 0;
        else if (w < VISION_PARAMS.min_w || w > VISION_PARAMS.max_w)        pass = 0;
        else if (h < VISION_PARAMS.min_h || h > VISION_PARAMS.max_h)        pass = 0;
        else if (VISION_PARAMS.min_fill > 0 &&
                 area * 100 < VISION_PARAMS.min_fill * w * h)               pass = 0;
        else if (VISION_PARAMS.min_ratio > 0 &&
                 mn * 100 < VISION_PARAMS.min_ratio * mx)                   pass = 0;
        else if (VISION_PARAMS.edge_margin > 0 &&
                 (feat[i].x0 < VISION_PARAMS.edge_margin ||
                  feat[i].y0 < VISION_PARAMS.edge_margin ||
                  feat[i].x1 >= IMG_W - VISION_PARAMS.edge_margin ||
                  feat[i].y1 >= IMG_H - VISION_PARAMS.edge_margin))         pass = 0;

        if (area < BKT1) bkt_a++;
        else if (area < BKT2) bkt_b++;
        else bkt_c++;

        if (n_dbg < DBG_TOPK) {
            int k = n_dbg;
            while (k > 0 && dbg[k - 1].area < area) { dbg[k] = dbg[k - 1]; k--; }
            dbg[k].area = area; dbg[k].x0 = feat[i].x0; dbg[k].y0 = feat[i].y0;
            dbg[k].x1 = feat[i].x1; dbg[k].y1 = feat[i].y1; dbg[k].pass = pass;
            n_dbg++;
        } else if (area > dbg[DBG_TOPK - 1].area) {
            int k = DBG_TOPK - 1;
            while (k > 0 && dbg[k - 1].area < area) { dbg[k] = dbg[k - 1]; k--; }
            dbg[k].area = area; dbg[k].x0 = feat[i].x0; dbg[k].y0 = feat[i].y0;
            dbg[k].x1 = feat[i].x1; dbg[k].y1 = feat[i].y1; dbg[k].pass = pass;
        }

        if (pass) {
            int cx = (int)(feat[i].sum_x / area);
            int cy = (int)(feat[i].sum_y / area);
            insert_det_sorted(cx, cy, area);
        }
    }
    merge_close_dets();
}

static void push_hist(struct Track *t, int x)
{
    int k;
    for (k = 4; k > 0; k--) t->hist[k] = t->hist[k - 1];
    t->hist[0] = x;
    if (t->hist_n < 5) t->hist_n++;
    t->window_move = t->hist[0] - t->hist[t->hist_n - 1];
}

static void track_update(void)
{
    int used_t[MAX_TRK];
    int used_d[MAX_DET];
    int was_valid[MAX_TRK];
    struct Pair pairs[MAX_TRK * MAX_DET];
    int np = 0;
    int i, j, k;
    int gate = VISION_PARAMS.track_gate;
    int gate2;
    if (gate > 181) gate = 181;          /* keep d2 in uint16_t */
    gate2 = gate * gate;

    for (i = 0; i < MAX_TRK; i++) {
        used_t[i] = 0;
        was_valid[i] = trk[i].valid;
        if (trk[i].valid) {
            trk[i].prev_cx = trk[i].cx;
            trk[i].prev_cy = trk[i].cy;
            trk[i].cx += trk[i].vx;
            trk[i].cy += trk[i].vy;
            trk[i].age++;
        }
    }
    for (j = 0; j < MAX_DET; j++) used_d[j] = 0;

    /* All track/detection pairs inside the Euclidean gate, nearest first. */
    for (i = 0; i < MAX_TRK; i++) {
        if (!trk[i].valid) continue;
        for (j = 0; j < n_det; j++) {
            int dx = det[j].cx - trk[i].cx;
            int dy = det[j].cy - trk[i].cy;
            int d2 = dx * dx + dy * dy;
            if (d2 <= gate2) {
                pairs[np].d2 = d2;
                pairs[np].ti = i;
                pairs[np].di = j;
                np++;
            }
        }
    }
    for (i = 1; i < np; i++) {
        struct Pair key = pairs[i];
        j = i - 1;
        while (j >= 0 && pairs[j].d2 > key.d2) {
            pairs[j + 1] = pairs[j];
            j--;
        }
        pairs[j + 1] = key;
    }

    for (k = 0; k < np; k++) {
        int ti = pairs[k].ti;
        int di = pairs[k].di;
        int old_cx, old_cy, dvx, dvy;
        if (used_t[ti] || used_d[di]) continue;
        used_t[ti] = 1;
        used_d[di] = 1;

        old_cx = trk[ti].prev_cx;
        old_cy = trk[ti].prev_cy;
        dvx = det[di].cx - old_cx;
        dvy = det[di].cy - old_cy;
        trk[ti].vx = half_floor(trk[ti].vx + dvx);
        trk[ti].vy = half_floor(trk[ti].vy + dvy);
        trk[ti].cx = det[di].cx;
        trk[ti].cy = det[di].cy;
        trk[ti].missed = 0;
        trk[ti].hits++;
        trk[ti].moved = ABS(trk[ti].cx - trk[ti].start_cx);
        {
            int dy0 = ABS(trk[ti].cy - trk[ti].start_cy);
            if (dy0 > trk[ti].moved) trk[ti].moved = dy0;
        }
        push_hist(&trk[ti], trk[ti].cx);
        trk[ti].visible = (trk[ti].hits >= VISION_PARAMS.min_hits) &&
                          (trk[ti].missed == 0) &&
                          (trk[ti].moved >= VISION_PARAMS.min_move) &&
                          (trk[ti].window_move <= -VISION_PARAMS.min_window) &&
                          (trk[ti].vx <= VISION_PARAMS.vx_max);

        if (trk[ti].visible && !trk[ti].counted &&
            old_cx > VISION_PARAMS.gate_x &&
            trk[ti].cx <= VISION_PARAMS.gate_x &&
            trk[ti].cy >= VISION_PARAMS.gate_y0 &&
            trk[ti].cy <= VISION_PARAMS.gate_y1) {
            trk[ti].counted = 1;
            count++;
        }
    }

    /* New tracks for unassigned detections (det is area-sorted, like Python). */
    for (j = 0; j < n_det; j++) {
        if (used_d[j]) continue;
        for (i = 0; i < MAX_TRK; i++) {
            if (!trk[i].valid) {
                trk[i].valid = 1;
                trk[i].id = next_id;
                next_id++;
                if (next_id > 15) next_id = 1;
                trk[i].cx = det[j].cx;
                trk[i].cy = det[j].cy;
                trk[i].vx = 0; trk[i].vy = 0;
                trk[i].prev_cx = det[j].cx;
                trk[i].prev_cy = det[j].cy;
                trk[i].missed = 0;
                trk[i].hits = 1;
                trk[i].counted = 0;
                trk[i].start_cx = det[j].cx;
                trk[i].start_cy = det[j].cy;
                trk[i].age = 1;
                trk[i].moved = 0;
                trk[i].window_move = 0;
                trk[i].hist[0] = det[j].cx;
                trk[i].hist_n = 1;
                trk[i].visible = 0;
                break;
            }
        }
    }

    /* Age unmatched old tracks, then apply miss / static-track removal. */
    for (i = 0; i < MAX_TRK; i++) {
        if (!was_valid[i]) continue;
        if (!used_t[i]) {
            trk[i].missed++;
            trk[i].visible = 0;
            trk[i].moved = ABS(trk[i].cx - trk[i].start_cx);
            {
                int dy0 = ABS(trk[i].cy - trk[i].start_cy);
                if (dy0 > trk[i].moved) trk[i].moved = dy0;
            }
            push_hist(&trk[i], trk[i].cx);
        }
        if (trk[i].missed > VISION_PARAMS.max_miss) {
            trk[i].valid = 0;
            trk[i].visible = 0;
        } else if (trk[i].age > VISION_PARAMS.static_max_age &&
                   trk[i].moved < VISION_PARAMS.min_move &&
                   ABS(trk[i].window_move) < VISION_PARAMS.min_window) {
            trk[i].valid = 0;
            trk[i].visible = 0;
        }
    }
}

static void write_overlay(void)
{
    int i, oi;
    for (i = 0; i < 8; i++) {
        OV_IDX = (uint32_t)i;
        OV_W0 = 0u;
        OV_W1 = 0u;
    }
    oi = 0;
    for (i = 0; i < MAX_TRK && oi < 8; i++) {
        int x0s, y0s, x1s, y1s, x0, y0, x1, y1;
        uint32_t w0, w1;
        if (!trk[i].valid || !trk[i].visible || trk[i].missed > 0) continue;

        /* Fixed 2R box, kept fully inside the 320x180 image. */
        x0s = V_CLAMP(trk[i].cx - VISION_PARAMS.box_w_small / 2,
                      0, IMG_W - VISION_PARAMS.box_w_small);
        y0s = V_CLAMP(trk[i].cy - VISION_PARAMS.box_w_small / 2,
                      0, IMG_H - VISION_PARAMS.box_w_small);
        x1s = x0s + VISION_PARAMS.box_w_small - 1;
        y1s = y0s + VISION_PARAMS.box_w_small - 1;
        x0 = x0s * OUT_SCALE;
        y0 = y0s * OUT_SCALE;
        x1 = x1s * OUT_SCALE + (OUT_SCALE - 1);
        y1 = y1s * OUT_SCALE + (OUT_SCALE - 1);

        w0 = (1u << 31)
           | ((uint32_t)(trk[i].id & 0xF) << 27)
           | ((uint32_t)(x0 & 0xFFF) << 15)
           | ((uint32_t)(y0 & 0xFFF) << 3);
        w1 = ((uint32_t)(x1 & 0xFFF) << 20)
           | ((uint32_t)(y1 & 0xFFF) << 8);
        OV_IDX = (uint32_t)oi;
        OV_W0 = w0;
        OV_W1 = w1;
        oi++;
    }
}

static void report_params(void)
{
    al_simp_printf("VP en=%d thr=%d minrun=%d capd=%d settle=%d\r\n",
                   VISION_PARAMS.enable, VISION_PARAMS.bg_thr,
                   VISION_PARAMS.min_run, VISION_PARAMS.bg_capture_delay,
                   VISION_PARAMS.bg_settle_frames);
    al_simp_printf("VP area=%d..%d wh=%d..%d,%d..%d fill=%d ratio=%d edge=%d merge=%d roi=%d runmax=%d\r\n",
                   VISION_PARAMS.min_area, VISION_PARAMS.max_area,
                   VISION_PARAMS.min_w, VISION_PARAMS.max_w,
                   VISION_PARAMS.min_h, VISION_PARAMS.max_h,
                   VISION_PARAMS.min_fill, VISION_PARAMS.min_ratio,
                   VISION_PARAMS.edge_margin, VISION_PARAMS.merge_dist,
                   VISION_PARAMS.roi_y1, VISION_PARAMS.max_run_len);
    al_simp_printf("VP box=%d gate=%d,%d..%d trk=%d miss=%d hit=%d mv=%d win=%d vx=%d age=%d\r\n",
                   VISION_PARAMS.box_w_small, VISION_PARAMS.gate_x,
                   VISION_PARAMS.gate_y0, VISION_PARAMS.gate_y1,
                   VISION_PARAMS.track_gate, VISION_PARAMS.max_miss,
                   VISION_PARAMS.min_hits, VISION_PARAMS.min_move,
                   VISION_PARAMS.min_window, VISION_PARAMS.vx_max,
                   VISION_PARAMS.static_max_age);
}

static void report_serial(void)
{
    uint32_t cam = CAM_REG;
    uint32_t cv  = CV_REG;
    uint32_t st  = BALL_STATUS;
    uint32_t cam_id = (cam >> 16) & 0xFFFF;
    int ok  = (cam >> 15) & 1;
    int err = (cam >> 14) & 1;
    int cfg = (cam >> 13) & 1;
    int ddr = (cam >> 12) & 1;
    int sw4 = (cam >> 11) & 1;
    int sw3 = (cam >> 10) & 1;
    int cvon = (cam >> 9) & 1;
    int thr = (cv >> 24) & 0xFF;

    al_simp_printf("CAM ID=");
    putx(cam_id, 4);
    al_simp_printf(" OK=%d E=%d CFG=%d DDR=%d SW4=%d SW3=%d CV=%d TH=",
                   ok, err, cfg, ddr, sw4, sw3, cvon);
    putx(thr, 2);
    al_simp_printf(" BG=%d OVF=%d LBL=%d CNT=%d\r\n",
                   (int)(st & 1), (int)((st >> 2) & 1), ccl_overflow, count);
}

static void report_switches(void)
{
    uint32_t sw = SW_STAT;
    al_simp_printf("SW1=%d SW2=%d SW3=%d SW4=%d SW5=NA SW6=NA\r\n",
                   (int)(sw & 1u),
                   (int)((sw >> 1) & 1u),
                   (int)((sw >> 2) & 1u),
                   (int)((sw >> 3) & 1u));
}

static void write_count_bcd(void)
{
    uint32_t bcd = 0;
    int v = count;
    int i;
    for (i = 0; i < 5; i++) {
        bcd |= (uint32_t)(v % 10) << (4 * i);
        v /= 10;
    }
    BCD_COUNT = bcd;
}

static void report_debug(uint32_t frame, int run_cnt, int ovf)
{
    int i;
    uint32_t sk = SKIP_CNT;
    int sr = (int)(sk & 0xFFFFu);
    int sl = (int)((sk >> 16) & 0xFFFFu);
    al_simp_printf("D F=%d RUN=%d NC=%d DET=%d OVF=%d LBL=%d SR=%d SL=%d B=%d,%d,%d | ",
                   (int)(frame & 0xFFFFFFu), run_cnt, next_label, n_det, ovf,
                   ccl_overflow, sr, sl,
                   bkt_a, bkt_b, bkt_c);
    for (i = 0; i < n_dbg; i++) {
        al_simp_putchar(dbg[i].pass ? '*' : '.');
        al_simp_printf("%d,%d,%d,%d,%d ",
                       dbg[i].area, dbg[i].x0, dbg[i].y0, dbg[i].x1, dbg[i].y1);
    }
    al_simp_printf("\r\n");
}

static void wait_frames(uint32_t n, uint32_t *hb)
{
    uint32_t f0 = FRAME_REG;
    uint32_t guard = 0;
    while ((uint32_t)(FRAME_REG - f0) < n && guard < 60000000u) {
        HEARTBEAT = ++(*hb);
        guard++;
    }
}

int main(void)
{
    uint32_t ver = VER_REG;
    uint32_t hb = 0;
    int i;
    int report_div = 0;
    int dbg_div = 0;
    int dbg_step = VISION_PARAMS.debug_div > 0 ? VISION_PARAMS.debug_div : 30;

    if (ver != VER_MAGIC) {
        al_simp_printf("ahb_status_slave NOT found (ver=");
        putx(ver, 8);
        al_simp_printf(")\r\n");
    }

    for (i = 0; i < MAX_TRK; i++) trk[i].valid = 0;
    next_id = 1;
    count = 0;
    n_det = 0;
    BCD_COUNT = 0u;

    report_params();

    /* MCU 是调参唯一入口：写 RTL 背景阈值/最短 run/ROI/max run/使能/采背景命令 */
    BALL_THR = (uint32_t)((VISION_PARAMS.bg_thr & 0xFF) |
                          ((VISION_PARAMS.min_run & 0xFF) << 8));
    BALL_RUN_CFG = (uint32_t)((VISION_PARAMS.roi_y1 & 0x1FF) |
                              ((VISION_PARAMS.max_run_len & 0x3FF) << 10));
    BALL_CTRL = 0u;

    if (VISION_PARAMS.enable) {
        /* 等相机配置和 DDR 校准完成，再让曝光稳定 */
        {
            uint32_t guard = 0;
            while ((((CAM_REG >> 13) & 1u) == 0u || ((CAM_REG >> 12) & 1u) == 0u) &&
                   guard < 60000000u) {
                HEARTBEAT = ++hb;
                guard++;
            }
        }
        wait_frames((uint32_t)VISION_PARAMS.bg_capture_delay, &hb);

        /* 先 enable（关 edge/OSD、切摄像头），清掉 DDR/OSD 流水线后再采背景 */
        BALL_CTRL = 1u;
        wait_frames((uint32_t)VISION_PARAMS.bg_settle_frames, &hb);

        BALL_CTRL = 3u;                      /* enable=1, capture=1 */
        {
            uint32_t guard = 0;
            while (!(BALL_STATUS & 1u) && guard < 60000000u) {
                HEARTBEAT = ++hb;
                guard++;
            }
        }
        BALL_CTRL = 1u;                      /* enable=1, capture=0 */
        al_simp_printf("BALL BG ready=%d\r\n", (int)(BALL_STATUS & 1u));
    } else {
        al_simp_printf("BALL disabled\r\n");
    }

    uint32_t last_frame = FRAME_REG;

    while (1) {
        uint32_t fr = FRAME_REG;
        if (fr != last_frame) {
            last_frame = fr;
            uint32_t status = BALL_STATUS;
            uint32_t meta = META_REG;
            int run_cnt = (int)((meta >> 21) & 0x7FF);
            int ovf = (int)((status >> 2) & 1);
            if (run_cnt > MAX_RUNS) run_cnt = MAX_RUNS;

            if (ovf) {
                /* run_mem truncated: age tracks instead of using partial CCL */
                n_det = 0;
                n_dbg = 0;
                next_label = 0;
                ccl_overflow = 0;
                skip_roi_cnt = 0; skip_len_cnt = 0;
                bkt_a = bkt_b = bkt_c = 0;
            } else {
                ccl_init();
                for (i = 0; i < run_cnt; i++) ccl_step(read_run(i));
                ccl_finalize();
            }
            track_update();
            write_overlay();
            OV_COUNT = (uint32_t)count;
            write_count_bcd();

            if (VISION_PARAMS.debug && (++dbg_div >= dbg_step)) {
                dbg_div = 0;
                report_debug(fr, run_cnt, ovf);
            }
            if (++report_div >= 30) {
                report_div = 0;
                report_serial();
                report_switches();
            }
        }
        HEARTBEAT = ++hb;
    }
    return 0;
}
