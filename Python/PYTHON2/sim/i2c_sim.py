#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
i2c_sim3.py — rtl/common/i2c_master.v 行为级仿真（主机 FSM 逐 clk 忠实移植）
从机：SC520CS 简化模型，按真实 I2C 器件行为建模（SCL 上升沿采样、下降沿驱动）。
本机无 iverilog，这是上板前的协议级验证手段。
"""
import os
import sys

ST_IDLE, ST_START, ST_TX, ST_ACK, ST_RX, ST_NACK, ST_STOP, ST_RSTAR = range(8)


class Master:
    """与 i2c_master.v 逐行对应（含 qi/qlast/RSTART 5 相位）"""
    def __init__(self, quart):
        self.QUART = quart
        self.st = ST_IDLE; self.qi = 0; self.q = 0; self.bit = 0; self.seq = 0
        self.sh = 0; self.dev = 0; self.sub = 0; self.wdata = 0; self.rd = 0
        self.O_rdata = 0; self.O_busy = 0; self.O_done = 0; self.O_ack_err = 0
        self.I_go = 0; self.I_rd = 0; self.I_dev = 0; self.I_sub = 0; self.I_wdata = 0
        self.I_sda_in = 1

    def outs(self):
        scl_low = 0; sda_low = 0
        st = self.st; qi = self.qi
        if st == ST_START:
            sda_low = 1
            scl_low = 1 if qi >= 1 else 0
        elif st == ST_RSTAR:
            scl_low = 1 if (qi <= 1 or qi == 4) else 0
            sda_low = 1 if qi == 3 else 0
        elif st == ST_TX:
            scl_low = 1 if qi < 2 else 0
            sda_low = 0 if ((self.sh >> 7) & 1) else 1
        elif st in (ST_ACK, ST_RX, ST_NACK):
            scl_low = 1 if qi < 2 else 0
            sda_low = 0
        elif st == ST_STOP:
            scl_low = 1 if qi < 2 else 0
            sda_low = 1 if (1 <= qi < 3) else 0
        return scl_low, sda_low

    def step(self):
        qend = (self.q == self.QUART - 1)
        qlast = 4 if self.st == ST_RSTAR else 3
        self.O_done = 0
        if self.st == ST_IDLE:
            if self.I_go:
                self.dev = self.I_dev; self.sub = self.I_sub; self.wdata = self.I_wdata
                self.rd = self.I_rd
                self.seq = 0; self.bit = 0; self.qi = 0; self.q = 0
                self.O_busy = 1; self.O_ack_err = 0; self.st = ST_START
            return
        if not qend:
            self.q += 1
            return
        self.q = 0
        if self.st == ST_RX and self.qi == 2:
            self.sh = ((self.sh << 1) & 0xFF) | self.I_sda_in
        if self.qi == qlast:
            self.qi = 0
            st = self.st
            if st == ST_START:
                self.st = ST_TX; self.seq = 1; self.sh = (self.dev << 1) & 0xFF; self.bit = 0
            elif st == ST_RSTAR:
                self.st = ST_TX; self.sh = (self.dev << 1) | 1; self.bit = 0
            elif st == ST_TX:
                if self.bit == 7:
                    self.st = ST_ACK
                else:
                    self.bit += 1; self.sh = (self.sh << 1) & 0xFF
            elif st == ST_ACK:
                if self.I_sda_in:
                    self.O_ack_err = 1; self.st = ST_STOP
                else:
                    if self.seq == 1:
                        self.seq = 2; self.sh = (self.sub >> 8) & 0xFF; self.bit = 0; self.st = ST_TX
                    elif self.seq == 2:
                        self.seq = 3; self.sh = self.sub & 0xFF; self.bit = 0; self.st = ST_TX
                    elif self.seq == 3:
                        if self.rd:
                            self.seq = 5; self.st = ST_RSTAR
                        else:
                            self.seq = 4; self.sh = self.wdata; self.bit = 0; self.st = ST_TX
                    elif self.seq == 4:
                        self.seq = 6; self.st = ST_STOP
                    elif self.seq == 5:
                        self.seq = 6; self.st = ST_RX; self.bit = 0; self.sh = 0
                    else:
                        self.st = ST_STOP
            elif st == ST_RX:
                if self.bit == 7:
                    self.O_rdata = self.sh; self.st = ST_NACK
                else:
                    self.bit += 1
            elif st == ST_NACK:
                self.seq = 8; self.st = ST_STOP
            elif st == ST_STOP:
                self.O_busy = 0; self.O_done = 1; self.st = ST_IDLE
        else:
            self.qi += 1


class Slave:
    """SC520CS 简化从机：SCL 上升沿采样（收），下降沿驱动（发/ACK）"""
    def __init__(self, addr=0x36, regs=None, ack=True, verbose=False, trace=None):
        self.addr = addr
        self.regs = dict(regs or {})
        self.ack = ack
        self.sda_low = 0
        self.mode = 'idle'      # idle/addr/sub/wait/data_r
        self.k = 0              # 当前字节内已过的上升沿数：0..7 数据位，8 = ACK 位
        self.rx = 0
        self.subcnt = 0
        self.sub = 0
        self.txbyte = 0
        self.events = []
        self.prev_scl = 1; self.prev_sda = 1
        self.verbose = verbose
        self.trace = trace

    # --- SCL 上升沿：采样
    def on_rising(self, sda):
        if self.mode == 'idle':
            return
        if self.mode == 'data_r':
            if self.k == 8:
                ackd = (sda == 0)
                self.events.append('master_ACK' if ackd else 'master_NACK')
                self.k = 0
                if ackd:
                    self.txbyte = self.regs.get(self.sub, 0x00)
                else:
                    # 主机 NACK：本字节束，等 STOP；不要再驱动总线（否则会吞掉 STOP 的 SDA 上升沿）
                    self.mode = 'idle'
                return
            self.k += 1
            return
        # 接收方向
        if self.k < 8:
            self.rx = ((self.rx << 1) & 0xFF) | sda
            self.k += 1
        else:
            self.k = 0
            b = self.rx & 0xFF
            self.rx = 0
            self.handle_byte(b)

    # --- SCL 下降沿：驱动下一位
    def on_falling(self):
        if self.mode == 'idle':
            self.sda_low = 0
            return
        if self.mode == 'data_r':
            if self.k < 8:
                self.sda_low = 0 if ((self.txbyte >> (7 - self.k)) & 1) else 1
            else:
                self.sda_low = 0        # ACK 位由主机驱动
            return
        # 接收：k==8 时输出 ACK
        if self.k == 8:
            if self.mode == 'addr':
                self.sda_low = 1 if (self.ack and ((self.rx >> 1) == self.addr)) else 0
            else:
                self.sda_low = 1 if self.ack else 0
        else:
            self.sda_low = 0

    def handle_byte(self, b):
        if self.mode == 'addr':
            if (b >> 1) == self.addr:
                if b & 1:
                    self.mode = 'data_r'
                    self.txbyte = self.regs.get(self.sub, 0x00)
                    self.events.append('ADDR_R_ACK')
                else:
                    self.mode = 'sub'; self.subcnt = 0
                    self.events.append('ADDR_W_ACK')
            else:
                self.mode = 'idle'
                self.events.append('ADDR_NAK')
        elif self.mode == 'sub':
            if self.subcnt == 0:
                self.sub = (b << 8) & 0xFF00; self.subcnt = 1
            else:
                self.sub |= b; self.subcnt = 0; self.mode = 'wait'
        elif self.mode == 'wait':
            self.regs[self.sub] = b
            self.events.append('WR[%04X]=%02X' % (self.sub, b))

    def on_edge(self, scl, sda):
        if self.prev_scl == 1 and scl == 1:      # SDA 在 SCL 高电平期间的沿
            if self.prev_sda == 1 and sda == 0:
                self.events.append('START' if self.mode == 'idle' else 'Sr')
                self.k = 0; self.rx = 0; self.subcnt = 0; self.sda_low = 0
                self.mode = 'addr'               # 起始条件一律回到"等地址"状态
            elif self.prev_sda == 0 and sda == 1:
                self.events.append('STOP')
                self.mode = 'idle'; self.k = 0; self.sda_low = 0
        if self.prev_scl == 0 and scl == 1:
            self.on_rising(sda)
        if self.prev_scl == 1 and scl == 0:
            self.on_falling()
        self.prev_scl = scl; self.prev_sda = sda


def run_txn(master, slave, rd, dev, sub, wdata, max_clk=2000000, trace=None):
    master.I_rd = 1 if rd else 0
    master.I_dev = dev
    master.I_sub = sub
    master.I_wdata = wdata
    master.I_go = 1
    master.step()
    master.I_go = 0
    n = 0
    prev_scl = 1
    while master.O_busy and n < max_clk:
        ml_scl, ml_sda = master.outs()
        sda_low = ml_sda or slave.sda_low
        scl = 0 if ml_scl else 1
        sda = 0 if sda_low else 1
        slave.on_edge(scl, sda)
        master.I_sda_in = sda
        if trace is not None:
            trace.append((n, master.st, master.qi, master.q, scl, sda,
                          slave.mode, slave.k, slave.sda_low))
        master.step()
        prev_scl = scl
        n += 1
    return (not master.O_ack_err), list(slave.events), n


def main():
    fails = []
    for QUART in (4, 250):
        tag = '加速' if QUART == 4 else '真实(100kHz@100MHz)'
        print('==== QUART=%d %s ====' % (QUART, tag))
        # 1) 写寄存器
        slave = Slave(addr=0x36, regs={0x3107: 0xEE, 0x3108: 0x4B})
        m = Master(QUART)
        ok, ev, n = run_txn(m, slave, rd=False, dev=0x36, sub=0x0103, wdata=0x01)
        print('  写[0103]=01 :', 'ok' if (ok and slave.regs.get(0x0103) == 0x01) else 'FAIL', ev)
        if not ok or slave.regs.get(0x0103) != 0x01:
            fails.append('write @Q%d' % QUART)
        # 2) 读 ID 高/低位
        m = Master(QUART)
        slave = Slave(addr=0x36, regs={0x3107: 0xEE, 0x3108: 0x4B})
        ok, ev, n = run_txn(m, slave, rd=True, dev=0x36, sub=0x3107, wdata=0)
        print('  读[3107]    : rdata=%02X %s (%d clk)' % (m.O_rdata, ev, n))
        if not ok or m.O_rdata != 0xEE:
            fails.append('read 0x3107 @Q%d -> %02X' % (QUART, m.O_rdata))
        m = Master(QUART)
        slave = Slave(addr=0x36, regs={0x3107: 0xEE, 0x3108: 0x4B})
        ok, ev, n = run_txn(m, slave, rd=True, dev=0x36, sub=0x3108, wdata=0)
        print('  读[3108]    : rdata=%02X %s' % (m.O_rdata, ev))
        if m.O_rdata != 0x4B:
            fails.append('read 0x3108 @Q%d -> %02X' % (QUART, m.O_rdata))
        # 3) 地址不匹配
        m = Master(QUART)
        slave = Slave(addr=0x36, regs={}, ack=False)
        ok, ev, n = run_txn(m, slave, rd=True, dev=0x10, sub=0x3107, wdata=0)
        print('  错误地址    : ack_err=%d(期望1) ok=%d(期望0) %s' % (m.O_ack_err, ok, ev))
        if m.O_ack_err != 1 or ok:
            fails.append('nak @Q%d' % QUART)
        # 4) 读事件序列
        m = Master(QUART)
        slave = Slave(addr=0x36, regs={0x3107: 0x9E, 0x3108: 0x4B})
        ok, ev, n = run_txn(m, slave, rd=True, dev=0x36, sub=0x3107, wdata=0)
        exp = ['START', 'ADDR_W_ACK', 'Sr', 'ADDR_R_ACK', 'master_NACK', 'STOP']
        print('  读事件序列  :', ev)
        print('               ', 'ok' if ev == exp else 'FAIL（期望 %s）' % exp)
        if ev != exp:
            fails.append('seq @Q%d: %s' % (QUART, ev))
        if m.O_rdata != 0x9E:
            fails.append('read 9E @Q%d' % QUART)
    print()
    if fails:
        print('!! 失败:', fails)
        # 失败时导出波形供分析
        tr = []
        m = Master(4); slave = Slave(addr=0x36, regs={0x3107: 0xEE}, verbose=True)
        run_txn(m, slave, rd=True, dev=0x36, sub=0x3107, wdata=0, trace=tr)
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'i2c_wave.txt'), 'w') as f:
            f.write('clk st qi q scl sda mode k sda_low\n')
            for t in tr:
                f.write('%5d %2d %2d %4d %d %d %-6s %d %d\n' % t)
        print('波形已导出: i2c_wave.txt')
        sys.exit(1)
    print('全部通过 ✅')


if __name__ == '__main__':
    main()
