#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cam_sim.py — cam_ctrl.v（M2 上电/初始化流程）行为级仿真
复用 i2c_sim 的 Master/Slave 模型，并直接解析真实 ROM 文件 ip/sc520reg/uics520reg_720p60.v。
计时器状态按事件跳过（只关心时序逻辑，不关心 100MHz 级计数）。
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from i2c_sim import Master, Slave, run_txn          # noqa: E402

ROOT = r"C:\Users\Z___C\Documents\FPGA_is_good\work\camera_hdmi_720p"


def load_table():
    p = os.path.join(ROOT, "ip", "sc520reg", "uics520reg_720p60.v")
    t = open(p, encoding="utf-8", errors="replace").read()
    pairs = []
    for m in re.finditer(r"9'd(\d+)\s*:\s*REG_DATA\s*=\s*\{\s*16'h([0-9A-Fa-f]+)\s*,\s*8'h([0-9A-Fa-f]+)\s*\}", t):
        pairs.append((int(m.group(1)), int(m.group(2), 16), int(m.group(3), 16)))
    pairs.sort()
    idxs = [p[0] for p in pairs]
    assert idxs == list(range(len(pairs))), "ROM 索引不连续: %s" % idxs[:5]
    return pairs


class SC520(Slave):
    """SC520CS 模型：0x3107/0x3108 = EE4B → 寄存器表全部写完后变 9E4B；可注入 NAK"""
    def __init__(self, addr=0x36, nak_from=None, **kw):
        super().__init__(addr=addr, regs={0x3107: 0x00EE, 0x3108: 0x004B}, **kw)
        self.nak_from = nak_from
        self.writes = 0

    def handle_byte(self, b):
        n0 = len(self.events)
        super().handle_byte(b)
        if len(self.events) > n0 and self.events[-1].startswith("WR["):
            self.writes += 1
            if self.writes == 165:                       # 表加载完成 → ID 变为 9E4B
                self.regs[0x3107] = 0x009E
                self.regs[0x3108] = 0x004B
            if self.nak_from is not None and self.writes >= self.nak_from:
                self.ack = False


def boot(quart, slave, verbose=False):
    """cam_ctrl.v 状态机（生成器形式，与 RTL 同构）"""
    log = []

    def i2c(rd, dev, sub, wdata=0):
        m = Master(quart)
        ok, ev, n = run_txn(m, slave, rd=rd, dev=dev, sub=sub, wdata=wdata)
        if verbose:
            log.append(("i2c", rd, dev, sub, wdata, ok, m.O_rdata, ev))
        return ok, m.O_rdata, m.O_ack_err

    asel = [0]
    dev = lambda: 0x36 if asel[0] == 0 else 0x10
    res = dict(id_pre=0, id_post=0, wr_cnt=0, err=0, n_txn=0)
    res["xshutdn"] = 0
    yield ("wait_ms", 2)                                  # S_PWR_LOW
    res["xshutdn"] = 1
    yield ("wait_ms", 8)                                  # S_PWR_WAIT

    while True:                                           # S_IDR_H
        ok, d, ae = i2c(True, dev(), 0x3107)
        res["n_txn"] += 1
        if ok:
            res["id_pre"] = (d << 8) & 0xFF00
            break
        if asel[0] == 0:
            asel[0] = 1
            continue
        res["err"] = 1
        return res

    ok, d, ae = i2c(True, dev(), 0x3108)                   # S_IDR_L
    res["n_txn"] += 1
    if not ok:
        res["err"] = 1
        return res
    res["id_pre"] |= d

    for idx, sub, dat in TABLE:                            # S_TBL_ISSUE/S_TBL_WR
        ok, d, ae = i2c(False, dev(), sub, dat)
        res["n_txn"] += 1
        if not ok:
            res["err"] = 2
            return res
        res["wr_cnt"] += 1

    yield ("wait_ms", 20)                                  # S_TBL_WAIT

    ok, d, ae = i2c(True, dev(), 0x3107)                   # S_IDP_H
    res["n_txn"] += 1
    if not ok:
        res["err"] = 1
        return res
    res["id_post"] = (d << 8) & 0xFF00
    ok, d, ae = i2c(True, dev(), 0x3108)                   # S_IDP_L
    res["n_txn"] += 1
    if not ok:
        res["err"] = 1
        return res
    res["id_post"] |= d
    res["err"] = 0 if res["id_post"] == 0x9E4B else 4
    return res


def run_case(name, slave, quart=4, exp=None, verbose=False):
    gen = boot(quart, slave, verbose=verbose)
    ev = None
    try:
        op = next(gen)
        while op is not None:
            op = gen.send(None)
    except StopIteration as e:
        ev = e.value
    print("  %-22s err=%d id_pre=%04X id_post=%04X wr=%d txn=%d"
          % (name, ev["err"], ev["id_pre"], ev["id_post"], ev["wr_cnt"], ev["n_txn"]))
    if exp:
        bad = []
        for k, v in exp.items():
            if ev.get(k) != v:
                bad.append("%s=%s(期望 %s)" % (k, ev.get(k), v))
        if bad:
            print("     FAIL:", bad)
            return False
    return True


TABLE = load_table()


def main():
    print("ROM 表：%d 条，首条 %04X=%02X，末条 %04X=%02X"
          % (len(TABLE), TABLE[0][1], TABLE[0][2], TABLE[-1][1], TABLE[-1][2]))

    fails = []
    for Q in (4, 40):
        print("==== QUART=%d ====" % Q)
        s = SC520(addr=0x36)
        if not run_case("正常(0x36)", s, Q, dict(err=0, id_pre=0xEE4B, id_post=0x9E4B, wr_cnt=165)):
            fails.append("normal @Q%d" % Q)
        s = SC520(addr=0x10)
        if not run_case("地址回退(0x10)", s, Q, dict(err=0, id_pre=0xEE4B, id_post=0x9E4B, wr_cnt=165)):
            fails.append("fallback @Q%d" % Q)
        s = SC520(addr=0x36, nak_from=100)
        if not run_case("写表 NAK@100", s, Q, dict(err=2)):
            fails.append("nak @Q%d" % Q)
        s = SC520(addr=0x36, ack=False)
        if not run_case("无器件", s, Q, dict(err=1)):
            fails.append("noack @Q%d" % Q)

    print()
    print("!! 失败: %s" % fails if fails else "全部通过 ✅")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
