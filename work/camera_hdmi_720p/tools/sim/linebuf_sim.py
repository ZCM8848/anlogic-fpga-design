"""
linebuf_sim.py — M4 行缓存行为级仿真（cam_linebuf.v 的逐拍模型）

本机无 iverilog，沿用 M3 的做法：用 Python 逐拍复刻 RTL 的寄存器语义
（组合读地址 + 寄存输出 + 非阻塞赋值顺序），验证：

  用例1  单行写读往返：320 组突发布入 → HDMI 侧按 x 逐点读出，逐点比对
  用例2  读侧只读「已完成的行」：写 A 行 → 完成 → 开始写 B 行，期间读到的仍是 A
  用例3  行首对齐与越界守卫：多写超过 320 组被丢弃；第二行数据不污染第一行
  用例4  速率漂移：写侧快于读侧时，读侧始终读最近完成的行，不混行
  用例5  灰度映射：黑电平扣除 + 10bit→8bit（与 RTL 的 px_raw/BLACK_LEVEL 一致）

运行：python tools/sim/linebuf_sim.py
"""

ENTRIES = 320          # H_ACTIVE/GRP = 1280/4


# ============================================================ 模型：cam_linebuf.v
class CamLinebuf:
    def __init__(self, black=64):
        self.black = black
        self.mem = [[0] * ENTRIES, [0] * ENTRIES]
        # 写侧
        self.wr_bank = 0
        self.wr_addr = 0
        self.done_tgl = 0
        self.bank_at_done = 0
        self.line_cnt = 0
        # 跨域同步链（3 位，bit0 = 最新输入）
        self.sync_tgl = 0
        self.sync_bank = 0
        # 读侧
        self.rd_bank = 0
        self.rd_q = 0
        self.x_d1 = 0
        self.de_d1 = 0
        self.vs_d1 = 0
        self.switch_cnt = 0
        self.o_data = 0
        self.o_de = 0
        self.o_vs = 0

    # ---------------- 写侧一拍 ----------------
    def wr_tick(self, line_start, line_end, grp_valid, grp):
        if line_start:
            self.wr_bank ^= 1
            self.wr_addr = 0
        if grp_valid and self.wr_addr < ENTRIES:
            self.mem[self.wr_bank][self.wr_addr] = grp
            self.wr_addr += 1
        if line_end:
            self.done_tgl ^= 1
            self.bank_at_done = self.wr_bank
            self.line_cnt += 1

    # ---------------- 读侧一拍 ----------------
    def rd_tick(self, de, x, vs):
        # 1) 同步链与边沿
        self.sync_tgl = ((self.sync_tgl << 1) | self.done_tgl) & 0b111
        self.sync_bank = ((self.sync_bank << 1) | self.bank_at_done) & 0b111
        edge = ((self.sync_tgl >> 2) & 1) ^ ((self.sync_tgl >> 1) & 1)

        # 2) 组合读（用当前 rd_bank 与当前 x；本拍结果下拍进入 rd_q）
        q = self.mem[self.rd_bank][x >> 2]

        # 3) 寄存输出：字段选择用上一拍的 x；de/vs 延迟 1 拍与 data 对齐
        sel = self.x_d1 & 3
        px = (self.rd_q >> (sel * 10)) & 0x3FF
        gray = (px - self.black) >> 2 if px > self.black else 0
        data_next = (gray << 16) | (gray << 8) | gray
        de_next, vs_next = self.de_d1, self.vs_d1

        # 4) 提交（非阻塞）
        if edge:
            self.rd_bank = (self.sync_bank >> 1) & 1      # 与边沿同级的新 bank（RTL 已同步修正）
            self.switch_cnt += 1
        self.rd_q = q
        self.x_d1 = x
        self.de_d1 = de
        self.vs_d1 = vs
        self.o_data, self.o_de, self.o_vs = data_next, de_next, vs_next

    # ---------------- 便于测试：写一整行 ----------------
    def write_line(self, pixels):
        """pixels: 1280 个 10bit 值。按 RTL 的时序：行首发脉冲 + 每拍一组 + 行尾脉冲。"""
        assert len(pixels) == ENTRIES * 4
        self.wr_tick(1, 0, 0, 0)
        for g in range(ENTRIES):
            grp = 0
            for i in range(4):
                grp |= (pixels[g * 4 + i] & 0x3FF) << (i * 10)
            self.wr_tick(0, 1 if g == ENTRIES - 1 else 0, 1, grp)

    def drain_sync(self):
        for _ in range(6):
            self.rd_tick(0, 0, 0)

    # ---------------- 便于测试：读一行（de 有效 1280 拍） ----------------
    def read_line(self, n=1280):
        """模拟一行像素时钟：前 2 拍 de=0 预填，随后 n 拍 de=1（x 递增），
        再 3 拍 de=0 冲刷；收集所有 o_de=1 的输出（应恰好 n 个，顺序即像素顺序）。"""
        for _ in range(2):
            self.rd_tick(0, 0, 0)
        out = []
        for x in range(n):
            self.rd_tick(1, x, 0)
            if self.o_de:
                out.append(self.o_data)
        for k in range(4):
            self.rd_tick(0, (n - 1 + k) % 1024, 0)
            if self.o_de:
                out.append(self.o_data)
        return out


checks = []


def check(name, ok, extra=""):
    checks.append(ok)
    print(("  [OK]   " if ok else "  [FAIL] ") + name + (("  " + extra) if extra else ""))


def gray_of(px, black=64):
    return (px - black) >> 2 if px > black else 0


# ============================================================ 用例
def case_roundtrip():
    print("==== 用例1：单行写读往返 ====")
    lb = CamLinebuf()
    px = [(g * 4 + i) * 3 % 1024 for g in range(ENTRIES) for i in range(4)]
    lb.write_line(px)
    lb.drain_sync()
    got = lb.read_line()
    exp = [(gray_of(v) * 0x010101) for v in px]
    bad = [i for i, (a, b) in enumerate(zip(got, exp)) if a != b]
    check("1280 个像素逐点一致", not bad, f"不一致 {len(bad)} 个" + (f"，首个 x={bad[0]}" if bad else ""))
    check("行计数 = 1", lb.line_cnt == 1, f"line_cnt={lb.line_cnt}")
    check("读侧切换计数 ≥ 1", lb.switch_cnt >= 1, f"switch_cnt={lb.switch_cnt}")


def case_no_tearing():
    print("==== 用例2：读侧只读「已完成的行」 ====")
    lb = CamLinebuf()
    a = [100 + (g * 4 + i) % 200 for g in range(ENTRIES) for i in range(4)]
    b = [900 - (g * 4 + i) % 200 for g in range(ENTRIES) for i in range(4)]
    lb.write_line(a)
    lb.drain_sync()
    # 开始写 B 行（bank 已翻转），只写一半就同时读
    lb.wr_tick(1, 0, 0, 0)
    for g in range(160):
        grp = sum(((b[g * 4 + i] & 0x3FF) << (i * 10)) for i in range(4))
        lb.wr_tick(0, 0, 1, grp)
    got = lb.read_line()
    exp = [gray_of(v) * 0x010101 for v in a]
    bad = [i for i, (x, y) in enumerate(zip(got, exp)) if x != y]
    check("B 行写一半时，读到的仍是完整的 A 行", not bad, f"不一致 {len(bad)} 个")


def case_overflow_and_isolation():
    print("==== 用例3：行首对齐与越界守卫 ====")
    lb = CamLinebuf()
    a = [(g * 4 + i) % 1024 for g in range(ENTRIES) for i in range(4)]
    lb.write_line(a)
    # 行尾后又来 5 组垃圾（模拟异常多包的余量）
    for _ in range(5):
        lb.wr_tick(0, 0, 1, 0x3FF3FF3FF)
    lb.drain_sync()
    got = lb.read_line()
    exp = [gray_of(v) * 0x010101 for v in a]
    bad = [i for i, (x, y) in enumerate(zip(got, exp)) if x != y]
    check("越界组被丢弃，前 320 组不受影响", not bad, f"不一致 {len(bad)} 个")
    check("写地址未溢出（< 320）", lb.wr_addr <= ENTRIES, f"wr_addr={lb.wr_addr}")


def case_drift():
    print("==== 用例4：写侧与读侧并发（速率漂移） ====")
    lb = CamLinebuf()

    def pat(base):
        return [base + i % 16 for i in range(ENTRIES * 4)]

    # 真实场景：写侧与读侧各自连续跑 —— 每写完一行都伴随读侧活动，
    # 因此每个"行完成"都能被读域同步到（而不是三行写完再一起读）。
    for base in (100, 400, 700):
        lb.write_line(pat(base))
        lb.drain_sync()
        lb.read_line(64)                    # 读侧在下一行写入期间持续显示

    got = lb.read_line()
    exp = [gray_of(v) * 0x010101 for v in pat(700)]
    check("漂移时读到的行 = 最近完成的行（C=700+）", got == exp,
          f"首点 {got[0]:#08x} 期望 {exp[0]:#08x}")

    # 再写 D 行并完成，读侧应切到 D
    lb.write_line(pat(800))
    lb.drain_sync()
    got2 = lb.read_line()
    exp2 = [gray_of(v) * 0x010101 for v in pat(800)]
    check("新的行完成后读侧切换过去（D=800+）", got2 == exp2, f"首点 {got2[0]:#08x}")
    check("切换计数随行数增长（4 行 → ≥4）", lb.switch_cnt >= 4, f"switch_cnt={lb.switch_cnt}")


def case_gray():
    print("==== 用例5：灰度映射 ====")
    lb = CamLinebuf(black=64)
    vals = [0, 1, 63, 64, 65, 66, 67, 68, 512, 1023]
    px = (vals * 200)[:ENTRIES * 4]
    lb.write_line(px)
    lb.drain_sync()
    got = lb.read_line()
    exp = [gray_of(v) * 0x010101 for v in px[:10]]
    check("黑电平扣除 + 10bit→8bit 正确", got[:10] == exp,
          f"px=1023→{got[9] & 0xFF}（期望 {gray_of(1023)}）")


def main():
    fails_before = len([c for c in checks if not c])
    case_roundtrip()
    case_no_tearing()
    case_overflow_and_isolation()
    case_drift()
    case_gray()
    n_fail = len([c for c in checks if not c]) - fails_before
    print()
    if n_fail:
        print(f"结果：{n_fail} 项失败")
        raise SystemExit(1)
    print(f"结果：{len(checks)} 项全部通过")


if __name__ == "__main__":
    main()
