#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mipi_sim.py — M3 链路行为级仿真（M3 自研件的"无 iverilog"验证手段）

逐拍建模（对照 RTL 逻辑）：
  lane_deint.v   —— D-PHY 原始拍流（lane0/lane1 并行字节）→ 标准 CSI-2 字节流
  csi2_pkt_rx.v  —— CSI-2 包解析（包起始 = HS valid 上升沿；每拍 2 字节，高字节先到）
  raw10_unpack.v —— RAW10 解包（5 字节 → {P3,P2,P1,P0}，MIPI/V4L2 Y10P 位序）
  mipi_stats.v   —— 字节域计数（BCD）→ 快照

激励按真实硬件行为构造：包字节先按「每 2 字节一段、lane 轮转」编码成原始拍流
（实测 RAW10 行包 WC=0x0640 的原始流 = 2B 40 06 3B，2026-09-27 上板核对）。

用例：
  1) 一帧 720 行完整往返：921600 个像素逐点比对 + 统计核对
  2) 错误注入：WC 不符 / 未知 DT / 包体截断 / 疑似同步码 —— 错误位图与恢复
  3) 空闲→有流：HS_SEEN 与计数起点

运行：python tools/sim/mipi_sim.py
"""
import sys

DT_FS, DT_FE, DT_LS, DT_LE, DT_EMB, DT_RAW10 = 0x00, 0x01, 0x02, 0x03, 0x12, 0x2B
WC_720P = 1600
SYNC_B8 = 0xB8
COLS, ROWS = 1280, 720
GRP_PER_LINE = 320          # 1600 / 5

# 错误位（与 mipi_stats.v 一致）
E_LANE, E_DT, E_WC, E_HDR, E_LINES, E_WPX, E_PAIR, E_RSV = 0, 1, 2, 3, 4, 5, 6, 7


# ============================================================ 激励：构筑 CSI-2 字节流
def raw10_pack(px4):
    """4 个 10bit 像素 → 5 字节（b0..b3 高 8 位，b4 = 各像素低 2 位，P0 在 bit1:0）"""
    b = [(px4[0] >> 2) & 0xFF, (px4[1] >> 2) & 0xFF,
         (px4[2] >> 2) & 0xFF, (px4[3] >> 2) & 0xFF,
         ((px4[3] & 3) << 6) | ((px4[2] & 3) << 4) | ((px4[1] & 3) << 2) | (px4[0] & 3)]
    return b


def raw10_unpack_ref(b5):
    """参考解包（用于自检打包器）"""
    return [((b5[i] << 2) | ((b5[4] >> (2 * i)) & 3)) for i in range(4)]


def to_raw_beats(bs):
    """真正的 CSI-2 字节流 → D-PHY 原始拍流（2 字节一段、lane0/lane1 轮转）。

    硬件行为（BYTE_NUM=1、2-lane）：每个字节时钟给出 lane0 与 lane1 各 1 字节，
    拍 = (lane0[k] << 8) | lane1[k]。实测行包 WC 字段位于「上一拍低字节 + 当拍高字节」，
    即原始流配对为 (b0,b2), (b1,b3), (b4,b6), ...，与本函数一致。
    """
    lanes = [[], []]
    for c in range(0, len(bs), 2):
        lanes[(c // 2) % 2] += bs[c:c + 2]
    n = max(len(lanes[0]), len(lanes[1]))
    out = []
    for k in range(n):
        hi = lanes[0][k] if k < len(lanes[0]) else 0
        lo = lanes[1][k] if k < len(lanes[1]) else 0
        out.append((1, (hi << 8) | lo))
    return out


def pkt_beats(dt, wc, payload, crc=(0x00, 0x00), ecc=0x00, gap=2):
    """一个 CSI-2 包 → D-PHY 原始拍流（4 字节头 + 负载 + 2 字节 CRC + 包间空隙）"""
    b = [dt & 0xFF, (wc >> 8) & 0xFF, wc & 0xFF, ecc & 0xFF] + list(payload) + list(crc)
    if len(b) % 2:
        b.append(0)
    out = to_raw_beats(b)
    out += [(0, 0)] * gap          # 包间 HS valid 拉低（真实 IP 在包与包之间有 LP 间隔）
    return out


def line_payload(pix_row):
    """一行 1280 像素 → RAW10 负载字节"""
    out = []
    for i in range(0, COLS, 4):
        out += raw10_pack(pix_row[i:i + 4])
    return out


def build_frame(rows=ROWS, pixel_fn=None, wc_lines=None, drop_last_line=False):
    """→ (源像素二维表, 拍流)"""
    if pixel_fn is None:
        pixel_fn = lambda r, c: ((r * COLS + c) * 3 + (r % 7) * 5) & 0x3FF

    src = [[pixel_fn(r, c) for c in range(COLS)] for r in range(rows)]
    beats = [(0, 0)] * 2                                   # 包间空隙（valid 拉低）
    beats += pkt_beats(DT_FS, 1, [0x00])                   # FS
    for r in range(rows):
        if drop_last_line and r == rows - 1:
            break
        pay = line_payload(src[r])
        wc = WC_720P if wc_lines is None else (wc_lines if isinstance(wc_lines, int) else wc_lines(r))
        beats += pkt_beats(DT_RAW10, wc, pay)
    beats += pkt_beats(DT_FE, 1, [0x00])                   # FE
    beats += [(0, 0)] * 2
    return src, beats


# ============================================================ 模型：lane_deint.v
class LaneDeint:
    """原始拍流 → 标准 CSI-2 字节流。

    规则：每「拍对 (A,B)」输出两拍 —— {A高,B高} 然后 {A低,B低}；
    包首（valid 上升沿）重置配对相位；包尾欠配对的孤拍丢弃。
    """
    def __init__(self):
        self.v1d = 0
        self.ph = 0
        self.a_d = 0
        self.q = []
        self.max_q = 0

    def tick(self, valid, data):
        out_v, out_d = 0, 0
        if self.q:                       # 发射：先消费队头
            out_v, out_d = 1, self.q.pop(0)
        if valid and not self.v1d:       # 包首
            self.ph, self.a_d = 1, data
        elif valid and self.ph == 0:
            self.ph, self.a_d = 1, data
        elif valid and self.v1d and self.ph == 1:      # 拍对收齐 → 入队 2 拍
            self.ph = 0
            self.q.append(((self.a_d >> 8) & 0xFF) << 8 | ((data >> 8) & 0xFF))
            self.q.append(((self.a_d & 0xFF) << 8) | (data & 0xFF))
            self.max_q = max(self.max_q, len(self.q))
        elif (not valid) and self.v1d:   # 包间：重置配对相位（孤拍丢弃）
            self.ph = 0
        assert self.max_q <= 4, "lane_deint 队列深度超出 RTL 容量"
        self.v1d = valid
        return out_v, out_d


# ============================================================ 模型：csi2_pkt_rx.v
class Csi2Rx:
    IDLE, HDR, PAY, SKIP = 0, 1, 2, 3

    def __init__(self):
        self.st, self.v1d = self.IDLE, 0
        self.hdr_b0 = self.hdr_b1 = 0
        self.pay_left = 0
        self.pay_first = 0
        self.idle_vcnt = 0
        self.err = 0
        self.events = []          # ('FS'|'FE'|'LS'|'LE')
        self.last_dt = self.last_wc = 0

    def tick(self, valid, data):
        """返回本拍组合输出 dict，并推进状态（对应 RTL 的一拍）"""
        b_hi, b_lo = (data >> 8) & 0xFF, data & 0xFF
        wc_now = ((self.hdr_b1 << 8) | b_hi) & 0xFFFF
        rise = valid and not self.v1d

        out = dict(
            pay_valid=(self.st == self.PAY and valid),
            pay_data=data,
            pay_start=(self.st == self.PAY and valid and self.pay_first),
            pay_end=(self.st == self.PAY and valid and self.pay_left == 1),
        )

        # ---- 状态推进 ----
        if self.st == self.IDLE:
            if rise:
                self.hdr_b0, self.hdr_b1 = b_hi, b_lo
                self.idle_vcnt = 0
                self.st = self.HDR
            elif valid:
                if self.idle_vcnt >= 15:
                    self.err |= 1 << E_HDR
                else:
                    self.idle_vcnt += 1
            else:
                self.idle_vcnt = 0
        elif self.st == self.HDR:
            if valid:
                self.last_dt, self.last_wc = self.hdr_b0 & 0x3F, wc_now
                if self.hdr_b0 == SYNC_B8:
                    self.err |= 1 << E_HDR
                    self.st = self.SKIP
                elif (self.hdr_b0 & 0x3F) == DT_FS:
                    self.events.append('FS'); self.st = self.SKIP
                elif (self.hdr_b0 & 0x3F) == DT_FE:
                    self.events.append('FE'); self.st = self.SKIP
                elif (self.hdr_b0 & 0x3F) == DT_LS:
                    self.events.append('LS'); self.st = self.SKIP
                elif (self.hdr_b0 & 0x3F) == DT_LE:
                    self.events.append('LE'); self.st = self.SKIP
                elif (self.hdr_b0 & 0x3F) == DT_RAW10:
                    if wc_now != WC_720P:
                        self.err |= 1 << E_WC
                    self.pay_left, self.pay_first = wc_now >> 1, 1
                    self.st = self.PAY
                else:
                    if (self.hdr_b0 & 0x3F) != DT_EMB:
                        self.err |= 1 << E_DT
                    self.st = self.SKIP
            else:
                self.err |= 1 << E_HDR
                self.st = self.IDLE
        elif self.st == self.PAY:
            if valid:
                self.pay_first = 0
                if self.pay_left > 1:
                    self.pay_left -= 1
                else:
                    self.st = self.IDLE
            else:
                self.err |= 1 << E_HDR
                self.st = self.IDLE
        else:                      # SKIP
            if not valid:
                self.st = self.IDLE

        self.v1d = valid
        return out


# ============================================================ 模型：raw10_unpack.v
class Raw10Unpack:
    def __init__(self):
        self.pnd, self.np, self.grp = 0, 0, 0
        self.px_valid = 0
        self.px = 0
        self.pkt_done = 0
        self.pkt_grp = 0
        self.grp_pulse = 0          # 本拍出的组（测试用）

    def tick(self, pay_valid, pay_data, pay_start, pay_done):
        self.grp_pulse = 0
        # 行首对齐在推字节之前（对应 RTL 组合块内的 I_pay_start 分支）
        if pay_start:
            q_pnd, q_np, q_grp = 0, 0, 0
        else:
            q_pnd, q_np, q_grp = self.pnd, self.np, self.grp
        q_px, q_pxv = 0, 0

        def push(d):
            nonlocal q_pnd, q_np, q_px, q_pxv, q_grp
            if q_np == 4:
                q_px = ((q_pnd & 0xFF) << 2 | (d >> 0 & 3)) | \
                       (((q_pnd >> 8) & 0xFF) << 2 | (d >> 2 & 3)) << 10 | \
                       (((q_pnd >> 16) & 0xFF) << 2 | (d >> 4 & 3)) << 20 | \
                       (((q_pnd >> 24) & 0xFF) << 2 | (d >> 6 & 3)) << 30
                q_pxv, q_grp, q_np = 1, q_grp + 1, 0
            else:
                q_pnd = (q_pnd & ~(0xFF << (8 * q_np))) | (d << (8 * q_np))
                q_np += 1

        if pay_valid:
            push((pay_data >> 8) & 0xFF)
            push(pay_data & 0xFF)

        self.grp_pulse = q_pxv
        # 寄存器更新
        self.pnd, self.np, self.px, self.px_valid, self.grp = q_pnd, q_np, q_px, q_pxv, q_grp
        self.pkt_done = 0
        if pay_done:
            self.pkt_grp, self.pkt_done, self.grp = q_grp, 1, 0
        return q_pxv, q_px, self.pkt_done, self.pkt_grp


# ============================================================ 模型：mipi_stats.v（字节域）
def bcd_add(v, add, digits):
    out, carry = v, add
    for k in range(digits):
        d = (out >> (4 * k)) & 0xF
        s = d + carry
        out &= ~(0xF << (4 * k))
        if s > 9:
            out |= (s - 10) << (4 * k)
            carry = 1
        else:
            out |= s << (4 * k)
            carry = 0
    return out


class MipiStats:
    def __init__(self):
        self.fs_bcd, self.line_bcd, self.wpx_bcd, self.grp_bcd = 0, 0, 0, 0
        self.err, self.hs_seen, self.dm = 0, 0, 0
        self.snap = None

    def on_fs(self):
        self.fs_bcd = bcd_add(self.fs_bcd, 1, 6)
        self.line_bcd = 0
        self.dm = (self.dm + 1) & 0xF

    def on_line_start(self):
        self.wpx_bcd, self.grp_bcd = 0, 0

    def on_group(self):
        self.wpx_bcd = bcd_add(self.wpx_bcd, 4, 5)
        self.grp_bcd = bcd_add(self.grp_bcd, 1, 4)

    def on_fe(self):
        if self.dm != 1:
            self.err |= 1 << E_PAIR
        if self.line_bcd != 0x0720:
            self.err |= 1 << E_LINES
        if self.wpx_bcd != 0x01280:
            self.err |= 1 << E_WPX
        self.dm = max(self.dm - 1, 0)

    def on_line_done(self):
        self.line_bcd = bcd_add(self.line_bcd, 1, 4)

    def snapshot(self):
        self.snap = dict(fs=self.fs_bcd, line=self.line_bcd,
                         wpx=self.wpx_bcd, grp=self.grp_bcd,
                         err=self.err, hs=self.hs_seen)


# ============================================================ 顶层：跑一段拍流
def run(beats, collect_pixels=True, snap_at_fe=True):
    dei, csi, upd, st = LaneDeint(), Csi2Rx(), Raw10Unpack(), MipiStats()
    pixels = []
    n_fs = n_fe = 0
    for valid, data in beats:
        d_valid, d_data = dei.tick(valid, data)
        out = csi.tick(d_valid, d_data)
        # 事件（csi.events 在 HDR 拍追加；本拍内的脉冲视为本拍）
        for ev in csi.events:
            if ev == 'FS':
                n_fs += 1
                st.on_fs()
            elif ev == 'FE':
                n_fe += 1
                st.on_fe()
                if snap_at_fe:
                    st.snapshot()
        csi.events.clear()
        if out['pay_start']:
            st.on_line_start()
        pxv, px, pkt_done, grp = upd.tick(out['pay_valid'], out['pay_data'],
                                          out['pay_start'], out['pay_end'])
        if out['pay_valid']:
            st.hs_seen = 1
        if pxv and collect_pixels:
            pixels.append((px >> 0) & 0x3FF)
            pixels.append((px >> 10) & 0x3FF)
            pixels.append((px >> 20) & 0x3FF)
            pixels.append((px >> 30) & 0x3FF)
        if pxv:
            st.on_group()
        if pkt_done:
            st.on_line_done()
    st.err |= csi.err
    return dict(pixels=pixels, stats=st, csi=csi, upd=upd, n_fs=n_fs, n_fe=n_fe)


def check(name, cond, fails):
    print("  %-46s %s" % (name, "OK" if cond else "!! 失败"))
    if not cond:
        fails.append(name)


def case_roundtrip(fails):
    print("==== 用例1：一帧 720 行完整往返 ====")
    src, beats = build_frame()
    r = run(beats)
    exp = [p for row in src for p in row]
    print("  拍数 %d，解出像素 %d（期望 %d）" % (len(beats), len(r['pixels']), len(exp)))
    check("像素数一致", len(r['pixels']) == len(exp), fails)
    if len(r['pixels']) == len(exp):
        bad = [i for i, (a, b) in enumerate(zip(r['pixels'], exp)) if a != b]
        check("像素值逐点一致（RAW10 位序/组序）", not bad,
              fails)
        if bad:
            i = bad[0]
            print("     首个不一致: #%d 解出 %d 期望 %d (行 %d 列 %d)"
                  % (i, r['pixels'][i], exp[i], i // COLS, i % COLS))
    s = r['stats']
    check("帧计数 = 000001 (BCD 0x000001)", s.fs_bcd == 0x000001, fails)
    check("行计数 = 0720", s.line_bcd == 0x0720, fails)
    check("行像素 = 01280", s.wpx_bcd == 0x01280, fails)
    check("行组数 = 0320", s.grp_bcd == 0x0320, fails)
    check("FS/FE 各 1 次", r['n_fs'] == 1 and r['n_fe'] == 1, fails)
    check("错误位图 = 00", s.err == 0, fails)
    check("HS_SEEN = 1", s.hs_seen == 1, fails)
    return r


def case_errors(fails):
    print("==== 用例2：错误注入与恢复 ====")
    # 2a WC 不符
    _, beats = build_frame(rows=6, wc_lines=WC_720P + 2)
    r = run(beats)
    check("WC≠1600 → ER bit2", bool(r['stats'].err & (1 << E_WC)), fails)
    check("WC异常后仍能继续解出像素", len(r['pixels']) > 0, fails)

    # 2b 未知 DT（改一行的 DT 为 0x30）
    _, beats = build_frame(rows=6)
    for i, (v, d) in enumerate(beats):
        if (d >> 8) & 0x3F == DT_RAW10:
            beats[i] = (v, (0x30 << 8) | (d & 0xFF))
            break
    r = run(beats)
    check("未知 DT → ER bit1", bool(r['stats'].err & (1 << E_DT)), fails)
    check("未知 DT 行被跳过（少 1280 像素）",
          len(r['pixels']) == (6 - 0) * COLS - COLS, fails)

    # 2c 包体截断（一行中途 valid 拉低 → 包体提前结束）
    _, beats = build_frame(rows=6)
    cut = None
    for i, (v, d) in enumerate(beats):
        if (d >> 8) & 0x3F == DT_RAW10 and cut is None:
            cut = i + 40
            break
    beats[cut:cut + 200] = [(0, 0)] * 200
    r = run(beats)
    check("包体截断 → ER bit3", bool(r['stats'].err & (1 << E_HDR)), fails)

    # 2d 疑似同步码（首字节 0xB8）
    _, beats = build_frame(rows=4)
    beats = beats[:2] + [(1, 0xB8B8)] + pkt_beats(DT_RAW10, WC_720P, [0] * WC_720P)
    r = run(beats)
    check("同步码 → ER bit3（诊断路径生效）", bool(r['stats'].err & (1 << E_HDR)), fails)

    # 2e 嵌入数据行（0x12）不报错
    _, beats = build_frame(rows=4)
    beats = beats[:2] + pkt_beats(DT_EMB, 1600, [0] * 1600) + beats[2:]
    r = run(beats)
    check("嵌入数据行 0x12 → 不算错、不产像素",
          (r['stats'].err & (1 << E_DT)) == 0 and len(r['pixels']) == 4 * COLS, fails)


def case_packer(fails):
    print("==== 用例3：打包/解包参考自检 ====")
    ok = True
    for px in ([0, 0, 0, 0], [1023, 1023, 1023, 1023], [1, 2, 3, 4],
               [0x155, 0x2AA, 0x3FF, 0x000], [0x200, 0x201, 0x202, 0x203]):
        if raw10_unpack_ref(raw10_pack(px)) != px:
            ok = False
            print("     打包往返失败:", px)
    check("RAW10 打包↔解包参考一致（5 组边界值）", ok, fails)


def case_header_contract(fails):
    print("==== 用例4：包头原始字节约定（2026-09-27 上板实测回归） ====")
    b = [DT_RAW10, 0x06, 0x40, 0x3B]          # 标准 CSI-2 包头：DI, WC_hi, WC_lo, ECC（WC=1600）
    raws = [d for _, d in to_raw_beats(b)]
    got = "%02X%02X%02X%02X" % ((raws[0] >> 8) & 0xFF, raws[0] & 0xFF,
                                (raws[1] >> 8) & 0xFF, raws[1] & 0xFF)
    check("WC=1600 的原始拍流 = 2B40063B（与上板实测一致）", got == "2B40063B", fails)
    dei = LaneDeint()
    out = []
    for _, d in to_raw_beats(b):
        v, dd = dei.tick(1, d)
        if v:
            out += [(dd >> 8) & 0xFF, dd & 0xFF]
    for _ in range(3):                        # 冲刷队列（RTL 为 1~2 拍延迟）
        v, dd = dei.tick(0, 0)
        if v:
            out += [(dd >> 8) & 0xFF, dd & 0xFF]
    check("lane_deint 重排后 = DI,WC_hi,WC_lo,ECC", out == b, fails)
    if got != "2B40063B":
        print("     实测不一致: %s" % got)


def main():
    fails = []
    case_packer(fails)
    case_header_contract(fails)
    case_roundtrip(fails)
    case_errors(fails)
    print()
    if fails:
        print("!! 失败项: %s" % fails)
        return 1
    print("全部通过 ✅")
    return 0


if __name__ == "__main__":
    sys.exit(main())
