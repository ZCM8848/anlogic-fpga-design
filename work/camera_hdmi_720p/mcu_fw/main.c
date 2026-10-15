/*
 * ph1p35_cv — MCU 固件：状态上报 + CV 后处理（CCL/跟踪/exit计数/overlay）
 * ============================================================
 * v2：CCL/形状筛选/a-b跟踪/exit计数 全部由本固件完成（cv_top 只留像素级前端）。
 *
 * 每帧 vsync 后（轮询 FRAME_REG 变化）：
 *   1) 读 META（run_cnt/min_y/max_y）
 *   2) 逐 run 读 run_mem（RUN_IDX/RUN_DAT 间接寻址）
 *   3) 软件 CCL（行 run 重叠合并 + union-find）→ feature（area/bbox/质心）
 *   4) 形状筛选（面积/填充率/长短比/贴边）→ det
 *   5) a-b 跟踪（预测/贪心 NN/coast/新建）+ exit 计数（出画面 + 消亡补计）
 *   6) 写 overlay（绿框 bbox + ID）+ count
 *
 * AL_LOG 走 al_simp_printf（支持 %d/%x，不支持 %0Nx；hex 字段用 putx）。
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

#define VER_MAGIC   0x4D435602U

/* ---- CV 参数（编译期；上板调参改这里）---- */
#define IMG_W       1280
#define IMG_H       720
#define MAX_RUNS    1024
#define MAX_LABELS  64
#define MAX_PREV    128
#define MAX_DET     8
#define MAX_TRK     8

#define MIN_AREA    8
#define MAX_AREA    20000
#define MIN_FILL    15      /* 填充率下限（百分比）*/
#define MIN_RATIO   25      /* 长短比下限（百分比，min/max）*/
#define EDGE_MG     4       /* 贴边剔除像素 */

#define ALPHA_Q     128     /* a-b 位置增益 *256 (0.5) */
#define BETA_Q      16      /* a-b 速度增益 *256 (0.0625) */
#define GATE        240     /* 配对最大 Manhattan 距离（像素）*/
#define MISS_K      20      /* 丢失删轨迹帧数 */
#define MIN_HITS_EX 4       /* 出画面计数命中门限 */
#define MIN_HITS_DT 5       /* 消亡补计命中门限 */
#define EXIT_MISS   10      /* 出画面允许丢失帧数 */
#define MARGIN      20      /* 出画面判定边距 */

#define ABS(x) ((x) < 0 ? -(x) : (x))

/* ---- 数据结构 ---- */
struct Feat { int valid; int area; int x0, y0, x1, y1; long sum_x, sum_y; };
struct PrevRun { int xs, xe, lbl; };
struct Det { int valid; int cx, cy; int x0, y0, x1, y1; };
struct Track {
    int valid; int id; int cx, cy; int vx, vy;
    int missed, hits; int confirmed; int counted;
    int x0, y0, x1, y1;
};

static struct Feat    feat[MAX_LABELS];
static int            label_parent[MAX_LABELS];
static struct PrevRun prev_r[MAX_PREV], cur_r[MAX_PREV];
static int            n_prev, n_cur, prev_y, next_label;
static struct Det     det[MAX_DET];
static int            n_det;
static struct Track   trk[MAX_TRK];
static int            next_id;
static int            count;

/* ---- hex 输出（al_simp_printf 不支持 %0Nx）---- */
static void putx(uint32_t val, int width)
{
    char b[8];
    int k;
    static const char hex[] = "0123456789ABCDEF";
    for (k = width - 1; k >= 0; k--) { b[k] = hex[val & 0xF]; val >>= 4; }
    for (k = 0; k < width; k++) al_simp_putchar(b[k]);
}

/* ---- run_mem 间接读：写 RUN_IDX 后 BRAM 同步读需数拍，丢第一次读 ---- */
static uint32_t read_run(int i)
{
    RUN_IDX = (uint32_t)i;
    (void)RUN_DAT;        /* 旧值，丢弃 */
    return RUN_DAT;       /* 新值（已过 cv_top B 口 + slave 锁存两拍）*/
}

/* ---- union-find ---- */
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

/* ---- CCL ---- */
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
}

static void ccl_step(uint32_t r)
{
    int y  = (r >> 22) & 0x3FF;
    int xs = (r >> 11) & 0x7FF;
    int xe = r & 0x7FF;
    int k, found = -1;

    if (y != prev_y) {
        if (y > prev_y + 1) {
            n_prev = 0;                       /* 隔行：prev 清空 */
        } else {
            for (k = 0; k < n_cur; k++) prev_r[k] = cur_r[k];
            n_prev = n_cur;
        }
        n_cur = 0; prev_y = y;
    }
    /* 与上一行重叠的 run 取其 label，多个则 union */
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
    }
}

static void ccl_finalize(void)
{
    int i;
    /* 合并 feature 到根 label */
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
    /* 形状筛选 → det */
    n_det = 0;
    for (i = 0; i < next_label; i++) {
        if (!feat[i].valid) continue;
        int area = feat[i].area;
        if (area < MIN_AREA || area > MAX_AREA) continue;
        int w = feat[i].x1 - feat[i].x0 + 1;
        int h = feat[i].y1 - feat[i].y0 + 1;
        int mn = w < h ? w : h, mx = w < h ? h : w;
        if (area * 100 < MIN_FILL * w * h) continue;       /* 填充率 */
        if (mn * 100 < MIN_RATIO * mx) continue;            /* 长短比 */
        if (feat[i].x0 < EDGE_MG || feat[i].y0 < EDGE_MG ||
            feat[i].x1 >= IMG_W - EDGE_MG || feat[i].y1 >= IMG_H - EDGE_MG) continue;
        if (n_det >= MAX_DET) break;
        det[n_det].valid = 1;
        det[n_det].cx = (int)(feat[i].sum_x / area);
        det[n_det].cy = (int)(feat[i].sum_y / area);
        det[n_det].x0 = feat[i].x0; det[n_det].y0 = feat[i].y0;
        det[n_det].x1 = feat[i].x1; det[n_det].y1 = feat[i].y1;
        n_det++;
    }
}

/* ---- a-b 跟踪 + exit 计数 ---- */
static void track_update(void)
{
    int assigned[MAX_DET];
    int asg[MAX_TRK];
    int i, j;
    for (j = 0; j < MAX_DET; j++) assigned[j] = 0;

    /* 贪心最近邻：每 track 找最近未占 det */
    for (i = 0; i < MAX_TRK; i++) {
        asg[i] = -1;
        if (!trk[i].valid) continue;
        int px = trk[i].cx + trk[i].vx;
        int py = trk[i].cy + trk[i].vy;
        int best = -1, bd = GATE;
        for (j = 0; j < n_det; j++) {
            if (assigned[j]) continue;
            int d = ABS(det[j].cx - px) + ABS(det[j].cy - py);
            if (d < bd) { bd = d; best = j; }
        }
        if (best >= 0) { assigned[best] = 1; asg[i] = best; }
    }

    /* 更新 */
    for (i = 0; i < MAX_TRK; i++) {
        if (!trk[i].valid) continue;
        if (asg[i] >= 0) {
            j = asg[i];
            int dx = det[j].cx - trk[i].cx;
            int dy = det[j].cy - trk[i].cy;
            trk[i].vx += (BETA_Q * dx) >> 8;
            trk[i].vy += (BETA_Q * dy) >> 8;
            trk[i].cx += trk[i].vx + ((ALPHA_Q * dx) >> 8);
            trk[i].cy += trk[i].vy + ((ALPHA_Q * dy) >> 8);
            trk[i].missed = 0;
            trk[i].hits++;
            trk[i].x0 = det[j].x0; trk[i].y0 = det[j].y0;
            trk[i].x1 = det[j].x1; trk[i].y1 = det[j].y1;
            if (trk[i].hits >= MIN_HITS_EX) trk[i].confirmed = 1;
        } else {
            /* coast：纯预测推进 */
            trk[i].cx += trk[i].vx;
            trk[i].cy += trk[i].vy;
            trk[i].missed++;
        }
        /* exit 计数：出画面 */
        if (trk[i].confirmed && !trk[i].counted &&
            trk[i].hits >= MIN_HITS_EX && trk[i].missed <= EXIT_MISS &&
            (trk[i].cx < -MARGIN || trk[i].cx > IMG_W + MARGIN ||
             trk[i].cy < -MARGIN || trk[i].cy > IMG_H + MARGIN)) {
            trk[i].counted = 1;
            count++;
        }
        /* 删除：超 MISS_K */
        if (trk[i].missed > MISS_K) {
            if (!trk[i].counted && trk[i].hits >= MIN_HITS_DT) {
                trk[i].counted = 1;     /* 消亡补计 */
                count++;
            }
            trk[i].valid = 0;
        }
    }

    /* 新建：未占 det 找空槽 */
    for (j = 0; j < n_det; j++) {
        if (assigned[j]) continue;
        for (i = 0; i < MAX_TRK; i++) {
            if (!trk[i].valid) {
                trk[i].valid = 1;
                trk[i].id = next_id++;
                trk[i].cx = det[j].cx; trk[i].cy = det[j].cy;
                trk[i].vx = 0; trk[i].vy = 0;
                trk[i].missed = 0; trk[i].hits = 1;
                trk[i].confirmed = 0; trk[i].counted = 0;
                trk[i].x0 = det[j].x0; trk[i].y0 = det[j].y0;
                trk[i].x1 = det[j].x1; trk[i].y1 = det[j].y1;
                break;
            }
        }
    }
}

/* ---- overlay 写（绿框 bbox + ID；count 单独写 OV_COUNT）---- */
static void write_overlay(void)
{
    int i, oi;
    /* 先清全部 overlay（valid=0）*/
    for (i = 0; i < 8; i++) {
        OV_IDX = (uint32_t)i;
        OV_W0 = 0u;
        OV_W1 = 0u;
    }
    /* 写有效轨迹（已确认且近期命中）*/
    oi = 0;
    for (i = 0; i < MAX_TRK && oi < 8; i++) {
        if (!trk[i].valid || !trk[i].confirmed || trk[i].missed > 2) continue;
        /* W0: bit31 valid, 30:27 id, 26:15 x0, 14:3 y0, 2:0 pad */
        uint32_t w0 = (1u << 31)
                    | ((uint32_t)(trk[i].id & 0xF) << 27)
                    | ((uint32_t)(trk[i].x0 & 0xFFF) << 15)
                    | ((uint32_t)(trk[i].y0 & 0xFFF) << 3);
        /* W1: bit31:20 x1, 19:8 y1, 7:0 pad */
        uint32_t w1 = ((uint32_t)(trk[i].x1 & 0xFFF) << 20)
                    | ((uint32_t)(trk[i].y1 & 0xFFF) << 8);
        OV_IDX = (uint32_t)oi;
        OV_W0 = w0;
        OV_W1 = w1;
        oi++;
    }
}

/* ---- 串口上报（每 ~0.5s 一次，与原 status_report 节奏一致）---- */
static void report_serial(void)
{
    uint32_t cam = CAM_REG;
    uint32_t cv  = CV_REG;
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
    al_simp_printf(" OK=%d E=%d CFG=%d DDR=%d SW4=%d SW3=%d CV=%d TH=", ok, err, cfg, ddr, sw4, sw3, cvon);
    putx(thr, 2);
    al_simp_printf(" CNT=%d\r\n", count);
}

int main(void)
{
    uint32_t ver = VER_REG;
    if (ver != VER_MAGIC) {
        al_simp_printf("ahb_status_slave NOT found (ver=");
        putx(ver, 8);
        al_simp_printf(")\r\n");
    }

    int i;
    for (i = 0; i < MAX_TRK; i++) trk[i].valid = 0;
    next_id = 0;
    count = 0;

    uint32_t last_frame = FRAME_REG;
    uint32_t hb = 0;
    int report_div = 0;

    while (1) {
        uint32_t fr = FRAME_REG;
        if (fr != last_frame) {
            last_frame = fr;
            uint32_t meta = META_REG;
            int run_cnt = (int)((meta >> 21) & 0x7FF);
            if (run_cnt > MAX_RUNS) run_cnt = MAX_RUNS;
            ccl_init();
            for (i = 0; i < run_cnt; i++) ccl_step(read_run(i));
            ccl_finalize();
            track_update();
            write_overlay();
            OV_COUNT = (uint32_t)count;
            if (++report_div >= 30) {       /* 每 30 帧 ≈ 0.5s 上报 */
                report_div = 0;
                report_serial();
            }
        }
        HEARTBEAT = ++hb;
    }
    return 0;
}
