#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
apb_sim.py — apb_status_slave 行为级仿真
============================================================
本机无 iverilog；按项目既定方法用 Python 建一个 cycle-accurate 的
APB 主机模型 + 从口行为模型，验证：
  1) 各只读寄存器打包位域正确（CAM_REG / CV_REG / FRAME_REG / VER_REG）
  2) 写 HEARTBEAT / SCRATCH + 字节使能（pstrobe）按字节合并
  3) 帧计数在 vsync 上升沿累加（像素域→APB 域 2FF 同步）
  4) 读寄存器在 access 相给出有效数据（1 拍寄存）
  5) 恒就绪 pready=1 / pslverr=0

用法：  python apb_sim.py
"""
import sys


# --------------------------------------------------------------------
# APB 从口行为模型（与 rtl/mcu/apb_status_slave.v 逐字段对应）
# --------------------------------------------------------------------
class APBStatusSlave:
    VER = 0x4D435601  # "MCV1"

    def __init__(self):
        self.heartbeat = 0
        self.scratch = 0
        self.frame_cnt = 0
        self.vs_sync = 0b00
        self.vs_d = 0
        # 当前 APB 事务的 setup 相捕获的地址（读用）
        self._rd_addr = None
        # 输出（每拍更新）
        self.prdata = 0
        self.pready = 1
        self.pslverr = 0

    # 状态输入（顶层已同步到 APB 域；仿真里直接给值）
    def status_word(self, inputs):
        cam_id = inputs["cam_id"] & 0xFFFF
        blob = inputs["blob_cnt"] & 0x3F
        cam_reg = (cam_id << 16) | (inputs["cam_id_ok"] << 15) | \
                  (inputs["cam_i2c_err"] << 14) | (inputs["cam_cfg_done"] << 13) | \
                  (inputs["ddr_rdy"] << 12) | (inputs["sw4"] << 11) | \
                  (inputs["sw3"] << 10) | (inputs["cv_on"] << 9) | blob
        run_cnt = inputs["run_cnt"] & 0x7FF
        cv_reg = ((inputs["bin_thr"] & 0xFF) << 24) | (run_cnt << 11) | \
                 (inputs["ccl_busy"] << 10) | (inputs["run_overflow"] << 9) | \
                 (self.frame_cnt & 0xFF)
        return cam_reg, cv_reg

    def rdata_mux(self, idx, inputs):
        cam_reg, cv_reg = self.status_word(inputs)
        if idx == 0x00: return cam_reg
        if idx == 0x01: return cv_reg
        if idx == 0x02: return self.frame_cnt & 0xFFFFFFFF
        if idx == 0x03: return self.VER
        if idx == 0x04: return self.heartbeat
        if idx == 0x05: return self.scratch
        return 0

    def clock(self, psel, penable, pwrite, paddr, pwdata, pstrobe, vsync, inputs):
        """一拍时钟：先算组合，再更新寄存器（对应 always @(posedge)）。"""
        # ---- vsync 2FF + 上升沿 + 帧计数（vs_sync 为 2bit 移位寄存器）----
        bit0 = self.vs_sync & 1            # vs_sync[0]
        bit1 = (self.vs_sync >> 1) & 1      # vs_sync[1]
        vs_sync_next = ((bit0 << 1) | (1 if vsync else 0)) & 0b11
        vs_d_next = bit1
        vs_rise = bit1 & (1 ^ self.vs_d)    # 当前态的上升沿
        frame_cnt_next = (self.frame_cnt + 1) & 0xFFFFFFFF if vs_rise else self.frame_cnt

        # ---- 读寄存器（psel & !pwrite 时锁存 mux 结果）----
        widx = (paddr >> 2) & 0x1F
        prdata_next = self.rdata_mux(widx, inputs) if (psel and not pwrite) else self.prdata

        # ---- 写寄存器（access 相：psel & penable & pwrite）----
        wr = psel and penable and pwrite
        hb_next, sc_next = self.heartbeat, self.scratch
        if wr:
            if widx == 0x04:
                hb_next = self._merge(self.heartbeat, pwdata, pstrobe)
            elif widx == 0x05:
                sc_next = self._merge(self.scratch, pwdata, pstrobe)

        # ---- 提交 ----
        self.vs_sync = vs_sync_next
        self.vs_d = vs_d_next
        self.frame_cnt = frame_cnt_next
        self.prdata = prdata_next & 0xFFFFFFFF
        self.heartbeat = hb_next & 0xFFFFFFFF
        self.scratch = sc_next & 0xFFFFFFFF
        self.pready = 1
        self.pslverr = 0

    @staticmethod
    def _merge(oldv, newv, strb):
        r = oldv
        for k in range(4):
            if strb & (1 << k):
                m = 0xFF << (k * 8)
                r = (r & ~m) | (newv & m)
        return r & 0xFFFFFFFF


# --------------------------------------------------------------------
# APB 主机模型：把一次读/写拆成 setup 拍 + access 拍驱动从口
# --------------------------------------------------------------------
class APBMaster:
    def __init__(self, slave):
        self.s = slave
        self.inputs = {
            "cam_id": 0x9E4B, "cam_id_ok": 1, "cam_i2c_err": 0, "cam_cfg_done": 1,
            "ddr_rdy": 1, "sw4": 1, "sw3": 0, "cv_on": 0,
            "blob_cnt": 0, "bin_thr": 91, "run_cnt": 320, "ccl_busy": 0,
            "run_overflow": 0,
        }

    def set_status(self, **kw):
        self.inputs.update(kw)

    def _idle_clock(self, vsync=0):
        self.s.clock(0, 0, 0, 0, 0, 0, vsync, self.inputs)

    def read(self, addr):
        widx = (addr >> 2) & 0x1F
        # setup 拍：psel=1, penable=0, pwrite=0
        self.s.clock(1, 0, 0, addr, 0, 0, 0, self.inputs)
        # access 拍：penable=1，从口此时给出 prdata
        self.s.clock(1, 1, 0, addr, 0, 0, 0, self.inputs)
        v = self.s.prdata
        self._idle_clock()
        return v

    def write(self, addr, data, strobe=0xF):
        # setup 拍
        self.s.clock(1, 0, 1, addr, data, strobe, 0, self.inputs)
        # access 拍：写落寄存器
        self.s.clock(1, 1, 1, addr, data, strobe, 0, self.inputs)
        self._idle_clock()


# --------------------------------------------------------------------
# 用例
# --------------------------------------------------------------------
def check(name, got, exp):
    ok = (got & 0xFFFFFFFF) == (exp & 0xFFFFFFFF)
    print(("  [PASS] " if ok else "  [FAIL] ") + name +
          ("  got=0x%08X exp=0x%08X" % (got & 0xFFFFFFFF, exp & 0xFFFFFFFF)))
    return ok


def main():
    print("== apb_status_slave behavior sim ==")
    m = APBMaster(APBStatusSlave())
    npass = 0
    nfail = 0

    def C(name, got, exp):
        nonlocal npass, nfail
        if check(name, got, exp):
            npass += 1
        else:
            nfail += 1

    # --- 复位后初始态 ---
    # 给几个 idle 拍让复位释放
    for _ in range(4):
        m._idle_clock()

    # --- 用例1：读 VER_REG ---
    C("read VER_REG", m.read(0x0C), 0x4D435601)

    # --- 用例2：读 CAM_REG 打包 ---
    m.set_status(cam_id=0x9E4B, cam_id_ok=1, cam_i2c_err=0, cam_cfg_done=1,
                 ddr_rdy=1, sw4=1, sw3=0, cv_on=0, blob_cnt=3)
    cam_reg = ((0x9E4B << 16) | (1 << 15) | (1 << 13) | (1 << 12) |
               (1 << 11) | 3)
    C("read CAM_REG", m.read(0x00), cam_reg)

    # --- 用例3：读 CV_REG 打包 ---
    m.set_status(bin_thr=0x5B, run_cnt=0x140, ccl_busy=1, run_overflow=0)
    cv_reg = ((0x5B << 24) | (0x140 << 11) | (1 << 10) | (0 << 9) |
              (m.s.frame_cnt & 0xFF))
    C("read CV_REG (frame_cnt lo)", m.read(0x04), cv_reg)

    # --- 用例4：帧计数——给 vsync 上升沿，frame_cnt 应 +1 ---
    f0 = m.s.frame_cnt
    # vsync 高一拍、再低：2FF 同步后第三拍出上升沿 → frame_cnt+1
    for v in (1, 0, 0):
        m._idle_clock(vsync=v)
    C("frame_cnt after one vsync rise", m.s.frame_cnt, (f0 + 1) & 0xFFFFFFFF)
    # 再来三次 vsync
    for _ in range(3):
        for v in (1, 0, 0):
            m._idle_clock(vsync=v)
    C("frame_cnt after 4 vsyncs total", m.s.frame_cnt, (f0 + 4) & 0xFFFFFFFF)

    # --- 用例5：写 HEARTBEAT 全字 + 回读 ---
    m.write(0x10, 0xDEADBEEF, 0xF)
    C("read HEARTBEAT (full write)", m.read(0x10), 0xDEADBEEF)

    # --- 用例6：写 SCRATCH 字节使能（只写 byte1）---
    m.write(0x14, 0x0000AA00, 0x2)   # 只 byte1
    C("read SCRATCH (byte1 only)", m.read(0x14), 0x0000AA00)
    m.write(0x14, 0xFF000000, 0x8)   # 只 byte3
    C("read SCRATCH (byte3 merge)", m.read(0x14), 0xFF00AA00)

    # --- 用例7：未映射地址读返回 0 ---
    C("read unmapped addr", m.read(0x3C), 0)

    # --- 用例8：恒就绪 / 无错 ---
    C("pready always 1", m.s.pready, 1)
    C("pslverr always 0", m.s.pslverr, 0)

    print("\n== %d pass, %d fail ==" % (npass, nfail))
    sys.exit(0 if nfail == 0 else 1)


if __name__ == "__main__":
    main()
