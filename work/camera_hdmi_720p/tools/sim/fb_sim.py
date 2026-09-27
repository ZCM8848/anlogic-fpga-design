"""
fb_sim.py — M5-② DDR 帧缓存链路行为级仿真（fb_wr/fb_rd/ddr_arb/fb_ctrl 逐拍模型）

本机无 iverilog，沿用 M3/M4 的做法：用 Python 逐拍复刻 RTL 的寄存器语义
（组合读当前态 + 非阻塞提交），验证四个新模块的联合行为：

  用例1 正常帧流：3 帧摄像头 → 每一显示行逐点比对（字/字节序、三缓冲换帧、
        计数器 WR/RD/OV/UN/ER），并对照 DDR 内存模型抽查写入地址
  用例2 压力：DDR 读延迟拉长 + 应用口间歇忙 → 无欠载、无丢帧、像素全对
  用例3 读看门狗：一段窗口内读永不返回 → 4096 拍超时冲刷 → 恢复（在写的帧判坏
        牺牲、ER+1，冲刷后继续出帧、画面恢复正常）
  用例4 坏帧：某帧大量丢组 → 该帧不上屏（WR 不增）、ER 增加、后续帧恢复正常

模型约定（与 RTL 一一对应；时间单位 = 用户域 1 拍；空闲期自动跳跃加速）：
  · 显示帧周期 750 行 × 1500 拍；vs 在帧首，24 行消隐后依次 720 行有效。
  · 摄像头帧周期 754 行 × 1500 拍（≈59.68fps，比显示 60fps 慢 —— 与真板一致，
    覆盖「重复旧帧」路径）。每行：st + 320 组（1 组/拍，压缩 1.55×，只验证逻辑）。
  · 像素值：gray(fid,y,x) = (fid*31+y+x)%200+11；RAW10 = gray*4+64，
    灰度还原恰为 gray —— 任何错位/错帧/撕裂都会逐点暴露。
  · 跨域（字节→用户、像素→用户）各延迟 2 拍；FIFO 深度 8（满则丢）。

运行：python tools/sim/fb_sim.py
"""

LINE_TICKS = 1500
LINES = 720
V_TOTAL = 750
V_BLANK_LINES = 24              # vs 之后的消隐行数
FIFO_DEPTH = 8
XD = 2                          # 跨域延迟（拍）
ST_OFS = 10                     # 行内 st 出现位置
DV_OFS = 12                     # 行内首个像素组位置
BLACK = 64

FT_DISP = V_TOTAL * LINE_TICKS          # 显示帧周期
FT_CAM = 754 * LINE_TICKS               # 摄像头帧周期


def gray8(p):
    return ((p - BLACK) >> 2) if p > BLACK else 0


def cam_gray(fid, y, x):
    return ((fid * 31 + y + x) % 200) + 11


def cam_raw(fid, y, x):
    return cam_gray(fid, y, x) * 4 + BLACK


def exp_word(fid, y, k):
    w = 0
    for n in range(16):
        w |= cam_gray(fid, y, k * 16 + n) << (8 * n)
    return w


# ============================================================ DDR 模型
class Ddr:
    def __init__(self, latency=40, stall_period=0, stall_len=0, dead=()):
        self.mem = {}
        self.latency = latency
        self.pending = []            # [(due, addr)]
        self.out = []                # 本拍响应 [(addr, data)]
        self.stall_period = stall_period
        self.stall_len = stall_len
        self.dead = list(dead)
        self.reads = 0
        self.writes = 0
        self.t = 0

    def rdy(self, t):
        if self.stall_period and (t % self.stall_period) < self.stall_len:
            return False
        return True

    def do_read(self, t, addr):
        self.reads += 1
        if not any(a <= t < b for a, b in self.dead):
            self.pending.append((t + self.latency, addr))

    def do_write(self, addr, data):
        self.writes += 1
        self.mem[addr] = data

    def tick(self, t):
        self.t = t
        self.out = []
        due = [p for p in self.pending if p[0] <= t]
        for p in due:
            self.pending.remove(p)
            self.out.append((p[1], self.mem.get(p[1], 0)))


# ============================================================ fb_wr（用户域）
class FbWr:
    def __init__(self):
        self.item = 0
        self.item_v = False
        self.line_cnt = 0
        self.cur_slot = 0
        self.pack_ptr = 0
        self.grp_cnt = 0
        self.wcnt = 0
        self.word = 0
        self.bad = False
        self.done_p = False
        self.bad_p = False
        self.start_p = False
        self.line_addr = [0, 0]
        self.ptgl = [0, 0]
        self.dtgl = [0, 0]
        self.rb = [[0] * 128, [0] * 128]
        self.dr_st = 0
        self.dr_slot = 0
        self.dr_ptr = 0
        self.dr_data = 0

    def req(self):
        return self.dr_st == 2

    def wr_addr(self):
        return (self.line_addr[self.dr_slot] + self.dr_ptr * 8) & 0x1FFFFFF

    def start_now(self):
        """组合：fs 条目本拍将被消费（fb_ctrl 需同拍取基址）"""
        if not (self.item_v and ((self.item >> 43) & 1)):
            return False
        return (self.ptgl[self.line_cnt & 1] == self.dtgl[self.line_cnt & 1])

    def tick(self, fifo, wr_base, gnt_wr):
        item = self.item
        ev_fs = bool(self.item_v and (item >> 43) & 1)
        ev_fe = bool(self.item_v and (item >> 42) & 1)
        ev_st = bool(self.item_v and (item >> 41) & 1)
        ev_dv = bool(self.item_v and (item >> 40) & 1)
        grp = item & ((1 << 40) - 1)

        slot_free = (self.ptgl[self.line_cnt & 1] == self.dtgl[self.line_cnt & 1])
        frz = ev_st and not slot_free
        pop = self.item_v and not frz
        self.start_p = bool(ev_fs and not frz)

        line_base = (wr_base + self.line_cnt * 640) & 0x1FFFFFF
        frame_ok = (self.line_cnt == LINES and self.pack_ptr >= 80
                    and self.grp_cnt >= 320 and not self.bad)

        if ev_dv:
            g = [gray8((grp >> (10 * i)) & 0x3FF) for i in range(4)]
            top = (g[3] << 120) | (g[2] << 112) | (g[1] << 104) | (g[0] << 96)
            w_next = top if ev_st else (top | ((self.word >> 32) & ((1 << 96) - 1)))
        else:
            w_next = 0
        wdone = bool(ev_dv and not ev_st and self.wcnt == 3)
        pack_waddr = 0 if ev_st else self.pack_ptr

        if not frz:
            if fifo:
                self.item = fifo.pop(0)
                self.item_v = True
            else:
                self.item_v = False

        if pop:
            if ev_fs:
                if self.line_cnt != 0:
                    if frame_ok:
                        self.done_p = True
                    else:
                        self.bad_p = True
                self.line_cnt = 0
                self.pack_ptr = 0
                self.grp_cnt = 0
                self.wcnt = 0
                self.bad = False
            if ev_st:
                if self.line_cnt != 0 and (self.pack_ptr < 80 or self.grp_cnt < 320):
                    self.bad = True
                self.cur_slot = self.line_cnt & 1
                self.line_addr[self.line_cnt & 1] = line_base
                self.line_cnt += 1
                self.pack_ptr = 0
            elif wdone:
                self.pack_ptr = min(self.pack_ptr + 1, 127)
            if ev_dv:
                self.word = w_next
                self.wcnt = 1 if ev_st else ((self.wcnt + 1) & 3)
            if wdone and pack_waddr < 80:
                self.rb[self.cur_slot][pack_waddr] = w_next
                if pack_waddr == 79:
                    self.ptgl[self.cur_slot] ^= 1
            if ev_st:
                self.grp_cnt = 1 if ev_dv else 0
            elif ev_dv:
                self.grp_cnt = min(self.grp_cnt + 1, 511)
            if ev_fe:
                if frame_ok:
                    self.done_p = True
                else:
                    self.bad_p = True
                self.line_cnt = 0
                self.pack_ptr = 0
                self.grp_cnt = 0
                self.wcnt = 0
                self.bad = False

        pend = [self.ptgl[i] != self.dtgl[i] for i in range(2)]
        if self.dr_st == 0:
            if pend[0]:
                self.dr_slot, self.dr_ptr, self.dr_st = 0, 0, 1
            elif pend[1]:
                self.dr_slot, self.dr_ptr, self.dr_st = 1, 0, 1
        elif self.dr_st == 1:
            self.dr_data = self.rb[self.dr_slot][self.dr_ptr]
            self.dr_st = 2
        else:
            if gnt_wr:
                if self.dr_ptr == 79:
                    self.dtgl[self.dr_slot] ^= 1
                    self.dr_st = 0
                else:
                    self.dr_ptr += 1
                    self.dr_st = 1


# ============================================================ fb_rd
class FbRd:
    def __init__(self):
        self.evt_cnt = 0
        self.done_line = 0x3FF
        self.want_line = 0
        self.want_v = False
        self.fill_act = False
        self.fill_slot = 0
        self.fill_line = 0
        self.fill_la = 0
        self.fill_cnt = 0
        self.fill_got = 0
        self.rb = [[0] * 128, [0] * 128]
        self.vsync_p = False
        self.undf_p = False
        self.flush = False
        self.events = []             # [(due, 'vs'|'ln')]

    def req(self):
        return bool(self.fill_act and not self.flush and self.fill_cnt < 80
                    and (self.fill_cnt - self.fill_got) < 16)

    def rd_addr(self):
        return (self.fill_la + self.fill_cnt * 8) & 0x1FFFFFF

    def tick(self, now, rd_base, gnt_rd, dvalid, flush):
        self.flush = flush
        # 拍首寄存器快照：启动判定与锁存值都用旧值（与 RTL 逐拍语义一致——
        # RTL 在 t 拍由事件置 want_v，t+1 拍才启动填充并清零 want_v）
        want_before = self.want_v
        want_line_before = self.want_line
        start_now = (not self.fill_act) and want_before and not flush

        vs_p = ln_p = False
        if self.events:
            evs = [e for e in self.events if e[0] <= now]
            if evs:
                self.events = [e for e in self.events if e[0] > now]
                vs_p = any(e[1] == 'vs' for e in evs)
                ln_p = any(e[1] == 'ln' for e in evs)
        self.vsync_p = False
        self.undf_p = False

        if vs_p:
            self.evt_cnt = 0
            self.done_line = 0x3FF
            self.want_line = 0
            self.want_v = True
            self.vsync_p = True
        if ln_p:
            if self.done_line != self.evt_cnt:
                self.undf_p = True
            if self.evt_cnt < LINES - 1:
                self.want_line = self.evt_cnt + 1
                self.want_v = True
            else:
                self.want_v = False
            self.evt_cnt += 1

        if start_now:
            self.fill_act = True
            self.fill_slot = want_line_before & 1
            self.fill_line = want_line_before
            self.fill_la = (rd_base + want_line_before * 640) & 0x1FFFFFF
            self.fill_cnt = 0
            self.fill_got = 0
            self.want_v = vs_p or ln_p

        if self.req() and gnt_rd:
            self.fill_cnt += 1

        if dvalid is not None:
            if self.fill_act and not flush:
                self.rb[self.fill_slot][self.fill_got & 127] = dvalid
                if self.fill_got == 79:
                    self.fill_act = False
                    self.done_line = self.fill_line
                self.fill_got += 1

        if flush:
            self.fill_cnt = 0
            self.fill_got = 0


# ============================================================ ddr_arb
class DdrArb:
    def __init__(self):
        self.st = 0                  # 0 IDLE 1 RD 2 WR 3 FL
        self.cd = False              # 接受后 1 拍冷却（RTL S_cd：防重复采样）
        self.out_cnt = 0
        self.wd = 0
        self.fl_cnt = 0
        self.gnt_wr = False
        self.gnt_rd = False
        self.flush = False
        self.err = 0
        self.err_p = False
        self.mc = {'addr': 0, 'cmd': 0, 'en': 0, 'wdf_data': 0, 'wdf_wren': 0}

    def tick(self, t, rdy, dvalid, rd_req, rd_addr, wr_req, wr_addr, wr_data, ddr):
        g_wr, g_rd = self.gnt_wr, self.gnt_rd      # 上一拍发出，本拍被主机看到
        self.gnt_wr = False
        self.gnt_rd = False
        self.err_p = False

        rd_acc = (self.st == 1) and rdy
        if self.st != 3 and (rd_acc or dvalid is not None):
            self.wd = 0
        elif self.st != 3:
            self.wd = min(self.wd + 1, 0xFFFF)

        if self.st == 0:
            if self.cd:
                self.cd = False        # 冷却拍：主机此刻才看到 gnt 并更新计数
            elif rd_req:
                self.mc = {'en': 1, 'cmd': 1, 'addr': rd_addr, 'wdf_data': 0, 'wdf_wren': 0}
                self.st = 1
            elif wr_req:
                self.mc = {'en': 1, 'cmd': 0, 'addr': wr_addr, 'wdf_data': wr_data, 'wdf_wren': 1}
                self.st = 2
        elif self.st == 1:
            if rdy:
                ddr.do_read(t, self.mc['addr'])
                self.gnt_rd = True
                self.cd = True
                self.st = 0
        elif self.st == 2:
            if rdy:
                ddr.do_write(self.mc['addr'], self.mc['wdf_data'])
                self.gnt_wr = True
                self.cd = True
                self.st = 0
        else:  # FL
            if dvalid is not None:
                self.fl_cnt = 0
            elif self.fl_cnt >= 4095:
                self.fl_cnt = 0
                self.out_cnt = 0
                self.flush = False
                self.st = 0
            else:
                self.fl_cnt += 1

        dec = bool(dvalid is not None and self.out_cnt != 0)
        if rd_acc and not dec:
            self.out_cnt += 1
        elif (not rd_acc) and dec:
            self.out_cnt -= 1

        if self.out_cnt != 0 and self.wd == 4095 and self.st != 3:
            self.err += 1
            self.err_p = True
            self.flush = True
            self.fl_cnt = 0
            self.st = 3
        return g_wr, g_rd


# ============================================================ fb_ctrl
class FbCtrl:
    FREE, WR, RDY, DSP = 0, 1, 2, 3
    BASE = [0, 0x80000, 0x100000]

    def __init__(self):
        self.st = [0, 0, 0]
        self.wr_idx = 0
        self.rd_idx = 0
        self.base = 0
        self.rd_base = 0
        self.rd_valid = False
        self.wr_bcd = 0
        self.rd_bcd = 0
        self.ov = 0
        self.un = 0
        self.er = 0

    def pick_idx(self):
        for i in range(3):
            if self.st[i] == self.FREE:
                return i
        for i in range(3):
            if self.st[i] == self.RDY:
                return i
        return 0

    def wr_base(self, frame_start):
        if frame_start:
            return self.BASE[self.pick_idx()]
        return self.base

    def rd_base_mux(self, vsync_p, frame_start):
        """O_rd_base 的组合预览（与 RTL assign 同拍语义：vs 当拍新槽基址）"""
        if vsync_p and not frame_start:
            for i in range(3):
                if self.st[i] == self.RDY:
                    return self.BASE[i]
        return self.rd_base

    def tick(self, frame_start, frame_done, frame_bad, vsync_p, undf_p, arb_err_p):
        if frame_start:
            if self.WR in self.st:
                self.st[self.st.index(self.WR)] = self.FREE
            if self.FREE in self.st or self.RDY in self.st:
                p = self.pick_idx()
                if self.st[p] == self.RDY:
                    self.ov += 1
                self.st[p] = self.WR
                self.wr_idx = p
                self.base = self.BASE[p]
            else:
                self.er += 1
        if frame_done and self.WR in self.st:
            w = self.st.index(self.WR)
            if self.RDY in self.st and not vsync_p:
                r = self.st.index(self.RDY)
                self.st[r] = self.FREE
                self.ov += 1
            self.st[w] = self.RDY
            self.wr_bcd = (self.wr_bcd + 1) % 10000
        if frame_bad:
            self.er += 1
        if vsync_p and not frame_start:
            if self.RDY in self.st:
                r = self.st.index(self.RDY)
                if self.DSP in self.st:
                    self.st[self.st.index(self.DSP)] = self.FREE
                self.st[r] = self.DSP
                self.rd_idx = r
                self.rd_base = self.BASE[r]
                self.rd_valid = True
                self.rd_bcd = (self.rd_bcd + 1) % 10000
        if undf_p:
            self.un += 1
        if arb_err_p:
            self.er += 1


# ============================================================ 测试台
class Bench:
    def __init__(self, frames, ddr, drop_lines=()):
        self.n_frames = frames
        self.ddr = ddr
        self.wr = FbWr()
        self.rd = FbRd()
        self.arb = DdrArb()
        self.ctrl = FbCtrl()
        self.fifo = []
        self.enq = []
        self.drop_lines = set(drop_lines)      # {(fid, li)} 丢组
        self.cam_ev = []
        self.disp_ev = []
        self.fs_q = []
        self.started_fid = 0
        self.slot_fid = [None, None, None]
        self.gnt_wr_d = self.gnt_rd_d = False
        self.done_d = self.bad_d = self.vsync_d = self.undf_d = self.err_d = False
        self.mism = []
        self.checked = 0
        self.dropped = 0
        self._build_events()

    def _build_events(self):
        for f in range(self.n_frames):
            t0 = f * FT_CAM
            self.cam_ev.append((t0, 1, (1 << 43), f))          # fs
            for li in range(LINES):
                lt = t0 + (li + 1) * LINE_TICKS
                self.cam_ev.append((lt + ST_OFS, 1, (1 << 41), None))
                for g in range(320):
                    if (f, li) in self.drop_lines and g % 13 == 0:
                        continue                                # 丢组注入
                    grp = 0
                    for i in range(4):
                        grp |= (cam_raw(f, li, g * 4 + i) & 0x3FF) << (10 * i)
                    self.cam_ev.append((lt + DV_OFS + g, 1, (1 << 40) | grp, None))
            self.cam_ev.append((t0 + 722 * LINE_TICKS, 1, (1 << 42), None))  # fe
        self.cam_ev.sort(key=lambda x: x[0])
        n_disp = int((self.n_frames * FT_CAM) // FT_DISP) + 3
        for f in range(n_disp):
            t0 = f * FT_DISP
            self.disp_ev.append((t0, 'vs', None))
            for y in range(LINES):
                self.disp_ev.append((t0 + (V_BLANK_LINES + y) * LINE_TICKS, 'ln', y))
        self.disp_ev.sort(key=lambda x: x[0])

    def run(self, t_end):
        cam_i = disp_i = 0
        t = 0
        while t < t_end:
            while cam_i < len(self.cam_ev) and self.cam_ev[cam_i][0] <= t:
                _, _, entry, f = self.cam_ev[cam_i]
                self.enq.append((t + XD, entry))
                if f is not None:
                    self.fs_q.append(f)
                cam_i += 1
            while disp_i < len(self.disp_ev) and self.disp_ev[disp_i][0] <= t:
                _, kind, y = self.disp_ev[disp_i]
                if kind == 'vs':
                    self.rd.events.append((t + XD, 'vs'))
                else:
                    self.rd.events.append((t + XD, 'ln'))
                    self._check_line(y, t)
                disp_i += 1
            if self.enq:
                for d, e in [x for x in self.enq if x[0] <= t]:
                    self.enq.remove((d, e))
                    if len(self.fifo) < FIFO_DEPTH:
                        self.fifo.append(e)
                    else:
                        self.dropped += 1

            # 快速跳跃：全静默则跳到下一个事件（挂起的事件/条目/排空未完成时不跳）
            if (self.arb.st == 0 and self.arb.out_cnt == 0 and not self.ddr.pending
                    and not self.fifo and not self.enq and not self.rd.events
                    and self.wr.dr_st == 0
                    and self.wr.ptgl == self.wr.dtgl
                    and not self.rd.want_v
                    and not self.wr.req() and not self.rd.req()):
                nxt = []
                if cam_i < len(self.cam_ev):
                    nxt.append(self.cam_ev[cam_i][0])
                if disp_i < len(self.disp_ev):
                    nxt.append(self.disp_ev[disp_i][0])
                nxt = [x for x in nxt if x > t]
                if nxt:
                    t = min(nxt)
                    continue

            self._tick(t)
            t += 1

    def _tick(self, t):
        ddr_rdy = self.ddr.rdy(t)
        self.ddr.tick(t)
        dvalid = self.ddr.out[0][1] if self.ddr.out else None

        wr_req = self.wr.req()
        rd_req = self.rd.req()
        fs_now = self.wr.start_now()
        base_now = self.ctrl.wr_base(fs_now)

        gnt_wr, gnt_rd = self.arb.tick(
            t, ddr_rdy, dvalid, rd_req, self.rd.rd_addr(),
            wr_req, self.wr.wr_addr(), self.wr.dr_data, self.ddr)

        self.wr.tick(self.fifo, base_now, gnt_wr)
        self.rd.tick(t, self.ctrl.rd_base_mux(self.vsync_d, fs_now), gnt_rd, dvalid, self.arb.flush)

        if self.done_d and FbCtrl.WR in self.ctrl.st:
            self.slot_fid[self.ctrl.st.index(FbCtrl.WR)] = self.started_fid
        if fs_now and self.fs_q:
            self.started_fid = self.fs_q.pop(0)

        self.ctrl.tick(fs_now, self.done_d, self.bad_d,
                       self.vsync_d, self.undf_d, self.err_d)

        self.done_d, self.bad_d = self.wr.done_p, self.wr.bad_p
        self.vsync_d, self.undf_d = self.rd.vsync_p, self.rd.undf_p
        self.err_d = self.arb.err_p
        self.wr.done_p = False
        self.wr.bad_p = False

    def _check_line(self, y, t):
        if FbCtrl.DSP not in self.ctrl.st:
            return
        slot = self.ctrl.st.index(FbCtrl.DSP)
        fid = self.slot_fid[slot]
        if fid is None:
            return
        buf = self.rd.rb[y & 1]
        for k in range(80):
            w = buf[k]
            for o in (0, 5, 15):
                x = k * 16 + o
                b = (w >> (8 * o)) & 0xFF
                exp = cam_gray(fid, y, x)
                self.checked += 1
                if b != exp:
                    self.mism.append((t, y, x, b, exp, fid))


# ============================================================ 用例
def summary(tag, b, ddr, expect_wr, allow_mm_before=None):
    ok = True
    print(f"==== {tag} ====")
    print(f"  检查点数 {b.checked}；不一致 {len(b.mism)}；"
          f"WR={b.ctrl.wr_bcd} RD={b.ctrl.rd_bcd} OV={b.ctrl.ov} UN={b.ctrl.un} ER={b.ctrl.er}；"
          f"丢条目 {b.dropped}；DDR 读 {ddr.reads} 写 {ddr.writes}")
    late = [m for m in b.mism if allow_mm_before is None or m[0] > allow_mm_before]
    checks = [
        ("写入帧数 = %d" % expect_wr, b.ctrl.wr_bcd == expect_wr),
        ("显示帧数 ≥ %d" % max(1, expect_wr - 1), b.ctrl.rd_bcd >= max(1, expect_wr - 1)),
        ("检查点足够（>100000）", b.checked > 100000),
    ]
    if allow_mm_before is None:
        checks.append(("像素零不一致", len(b.mism) == 0))
    else:
        checks.append((f"恢复后（t>{allow_mm_before}）零不一致", len(late) == 0))
    for name, cond in checks:
        print(("  [OK]   " if cond else "  [FAIL] ") + name)
        ok &= cond
    if b.mism:
        print("  首条不一致样例：", b.mism[:3])
    return ok


def case1():
    ddr = Ddr(latency=40)
    b = Bench(3, ddr)
    b.run(3 * FT_CAM + 3 * FT_DISP)
    ok = summary("用例1：正常帧流（3 帧，逐点比对）", b, ddr, expect_wr=3)
    addr_ok = True
    for s in range(3):
        for (y, k) in ((0, 0), (360, 40), (719, 79)):
            addr = FbCtrl.BASE[s] + y * 640 + k * 8
            got = ddr.mem.get(addr)
            if got is None:
                if any(FbCtrl.BASE[s] <= a < FbCtrl.BASE[s] + 0x80000 for a in ddr.mem):
                    print(f"  [FAIL] DDR 地址抽查 槽{s} 行{y} 字{k} addr={addr:#x} 缺失")
                    addr_ok = False
                continue                       # 整槽未用：正常（三缓冲按需分配）
            if not any(got == exp_word(f, y, k) for f in range(3)):
                print(f"  [FAIL] DDR 地址抽查 槽{s} 行{y} 字{k} addr={addr:#x} 内容不匹配")
                addr_ok = False
    print(("  [OK]   " if addr_ok else "") + "DDR 地址/字序抽查（3 槽 × 3 行）")
    return ok and addr_ok


def case2():
    ddr = Ddr(latency=120, stall_period=700, stall_len=40)
    b = Bench(3, ddr)
    b.run(3 * FT_CAM + 3 * FT_DISP)
    return summary("用例2：读延迟 120 拍 + 应用口间歇忙", b, ddr, expect_wr=3)


def case3():
    dead = (300000, 306000)
    ddr = Ddr(latency=40, dead=(dead,))
    b = Bench(4, ddr)
    b.run(4 * FT_CAM + 3 * FT_DISP)
    # 读挂起窗口落在帧 0 中段：仲裁器被挂起读占住 → 排空饿死 → FIFO 溢出丢组
    # → 帧 0 残缺判坏（不上屏）；看门狗冲刷后恢复，帧 1..3 全部完好。
    # 故 expect_wr=3：一次挂起 = 牺牲一个在写的帧，代价有界。
    ok = summary("用例3：读看门狗（6000 拍内读永不返回）", b, ddr, expect_wr=3,
                 allow_mm_before=dead[1] + 12000)
    for name, cond in (("看门狗触发（ER≥1）", b.ctrl.er >= 1),
                       ("欠载被记录（UN≥1）", b.ctrl.un >= 1)):
        print(("  [OK]   " if cond else "  [FAIL] ") + name)
        ok &= cond
    return ok


def case4():
    ddr = Ddr(latency=40)
    drop = {(1, li) for li in range(0, LINES, 2)}      # 帧1 半数行各丢一批组
    b = Bench(4, ddr, drop_lines=drop)
    b.run(4 * FT_CAM + 3 * FT_DISP)
    ok = summary("用例4：坏帧（帧1 大量丢组）", b, ddr, expect_wr=3)
    for name, cond in (("坏帧不计入 WR（帧1 被弃）", b.ctrl.wr_bcd == 3),
                       ("坏帧被记 ER（ER≥1）", b.ctrl.er >= 1)):
        print(("  [OK]   " if cond else "  [FAIL] ") + name)
        ok &= cond
    return ok


def main():
    ok = True
    ok &= case1()
    ok &= case2()
    ok &= case3()
    ok &= case4()
    print()
    print("结果：全部通过" if ok else "结果：存在失败项")
    raise SystemExit(0 if ok else 1)


if __name__ == "__main__":
    main()
