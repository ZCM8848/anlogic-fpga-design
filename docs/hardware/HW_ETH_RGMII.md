# HW_ETH_RGMII — 千兆以太网（YT8511 + PH1P35 RGMII）实测笔记

> 来源：2026-10-27 `work/eth_smoke` 从"完全发不出帧"到"PC 端 `arp -a` 正确解析"的完整调试过程。
> 所有结论均为**上板实测**，不是猜测。配套代码：`work/eth_smoke/`（已通过验证）。

---

## 1. 硬件事实

| 项 | 值 |
|---|---|
| PHY | **Motorcomm YT8511C/H**（U34，QFN40 5×5 mm，0.4 mm 脚距） |
| 接口 | RGMII（YT8511 只有 RGMII，无 MII/RMII 模式选择 strap） |
| RGMII IO 电压 | **3.3 V**（实测 PHY 侧 RX_CLK 摆幅 3.3 V；FPGA 侧 BANK22 的 VCCIO = VCC_3V3） |
| 晶振 | 25 MHz（Y1） |
| 网口 | HR911130A（含变压器），绿色 LED = 1000M link，橙色 LED = ACT |
| PHY 复位 | RESET_N（V8），低有效，≥150 µs；建议上电后拉低 ≥100 ms 再释放 |

### 1.1 YT8511 上电 strap（本板实测配置）

| PHY 引脚 | strap 功能 | 本板 | 结果 |
|---|---|---|---|
| LED_1000 (22) | TEST mode | 10K 上拉 | 1 = Normal ✅ |
| LED_10_100 (24) | RXC delay enable | 10K 上拉 | 1 = RX_CLK 内部延迟使能 ✅ |
| LED_ACT (21) | PHYAD[2] | 10K 上拉 | PHYAD 高位=1 |
| RXD0/RXD1 | PHYAD[1:0] | 4.7K | — |
| RX_DV (30) | RGMII IO power | — | 0 = 3.3 V（实测摆幅确认） |
| RXD2 (26) | PLLON in hibernation | — | — |
| RXD3 (25) | Low power mode | — | — |

> **本板 PHY 不需要 MDIO 配置**：上电 strap + 自协商即可工作（厂商例程同样不用 MDIO）。
> 实测 MDIO 读不到 ACK（PHYAD 0..31、MDC 1 MHz / 2.5 MHz、两种极性全试过），
> 但链路 1 Gbps 正常、收发正常 —— **MDIO 不通不代表 PHY 有问题，不要在这里耗时间**。

### 1.2 引脚（已实测确认，与板手册不同！）

| 信号 | FPGA 球 | 方向 | 备注 |
|---|---|---|---|
| GTX_CLK | **U9** | out | 125 MHz |
| TX_EN | **R10** | out | |
| TXD0..3 | **R11 / P11 / T10 / R12** | out | |
| RX_CLK | **V3** | in | `IO_BE17P_22,GCLKIOT1`（专用时钟脚） |
| RX_DV | **N8** | in | |
| RXD0..3 | **N9 / T7 / T8 / T9** | in | |
| MDC | V9 | out | 不用时保持 0 |
| MDIO | U10 | inout | 不用时高阻 |
| RESET_N | V8 | out | 低有效 |

**⚠️ 板手册《HX1P35B开发板引脚分配汇总》第十五节错误**：
- 把 RX 侧写成单根 `RXC_DV = N8`（RGMII 实际是 RX_CLK + RX_DV 两根）；
- **完全漏掉 RX_CLK**；
- 早期文档按"V2"设计（V2 实际是 `GPIOA0`）→ FPGA 完全收不到 RX_CLK。

**核对原理图的方法**（重要）：Altium 导出的 PDF `rotation=90`，
`get_text("words")` 的坐标不是直观的 (x,y) 行列关系。可靠做法是**利用固定偏移**：
同一行里 `网络名 x ≈ 球名 x + 2.1`。

```
U4 (556.8) → GPIOB32     (558.9)
V3 (561.8) → ETHPHY_RX_CLK (564.4)     ← RX_CLK
V2 (566.9) → GPIOA0      (569.0)       ← 不是 RX_CLK
U9 (461.0) → ETHPHY_TX_CLK (463.6)
R10(456.0) → ETHPHY_TX_EN  (458.6)
```
再用 **功能名 x ≈ 球名 x + 3.1** 交叉验证：`V3 → IO_BE17P_22,GCLKIOT1`（时钟专用脚）、
`V2 → IO_BE17N_22,GCLKIOT3`（虽也是时钟脚，但网络是 GPIOA0）。两条规则互相印证即可定案。

### 1.3 与 FPGA 相连的上下拉

- TXD0/TXD1/GTX_CLK：4.7K 上拉到 VDDH（R153/R154/R155）。
- **调试价值**：如果 FPGA 不驱动，GTX_CLK 应停在高电平。
  实测到 **0 V** 说明 FPGA 在**主动拉低**（该脚 datasheet 标 `I, PD`），
  即"ODDR 有输出但一直是 0"，直接指向 PLL/ODDR 问题，而不是断路。

---

## 2. 时钟：最大的坑

### 2.1 Anlogic PH1P PLL 的频率公式（实测）

```
C0  = (FIN / REFCLK_DIV) × FBCLK_DIV
VCO = C0 × CLKC0_DIV
Cn  = VCO / CLKCn_DIV
相位 = CLKCn_CPHASE / CLKCn_DIV × 360°
```

**教训**：只改 `CLKC0_DIV` 不会改变 C0！它改的是 VCO，输出频率保持不变。

| 目标 C0 | REFCLK_DIV | FBCLK_DIV | CLKC0_DIV |
|---|---|---|---|
| 100 MHz | 1 | 2 | 15（VCO=1500） |
| **125 MHz** | **2** | **5** | **12（VCO=1500）** |

本板 50 MHz 参考。VCO 保持 1500 MHz 时环路滤波器 `LPF_RES/LPF_CAP/ICP_CUR = 0/13/29` 不用改。

**如何确认实际频率（不靠猜）**：
- 用固定周期数发帧，数网口 ACT 灯的闪烁频率：`CLK = N_cycles / 间隔`。
  我们就是靠"154 次 / 41.3 s → 中位间隔 250 ms → 100 MHz"抓出这个 bug 的。
- TD 的 timing report 里的 `clk_125 8.000 ns` **只是 SDC 约束值，不是实测值**，不能当证据。

### 2.2 PLL C1（90° 输出）在本板不可用

- `ip/pll/PLL.v` 里 C1 = 125 MHz、`CPHASE=3`（90°）、`DUTY_INT=6`，
  TD 时钟报告也显示 `{2.000 6.000}` 波形、驱动 1 个 HD_PAD……
- **但实测 C1 完全没有波形**（用它驱动 GTX_CLK 时该脚恒 0 V）。
- 加显式 `PH1P_LOGIC_BUFG`、修 `DUTY_INT` 都无效。
- **结论：本项目不要依赖 C1**，90° 相移改用 `OUTDEL` 实现（见 §2.3）。
- 若将来必须用 C1，建议用 TD 的 IP 生成器**重新生成 PLL IP**（换个 wrapper 名），
  而不是手改 `PLL.v`（`.m_params_PLL.txt` 里还留着旧参数，容易混）。

### 2.3 GTX_CLK 与数据的相位

YT8511 datasheet（RGMII TIMING W/O DELAY）：

| 符号 | 含义 | Min | Typ | Max |
|---|---|---|---|---|
| `TskewT` | 发送端 data→clock skew | −500 ps | 0 | +500 ps |
| `TskewR` | **接收端 data→clock skew** | **1 ns** | — | — |
| `Tcyc` | 时钟周期 | 7.2 | 8.0 | 8.8 ns |

MAC 端 0° 输出（数据与时钟同沿）时，PHY 必须自己补 ≥1 ns；
而 PHY 内部 `Tx_clk_delay_sel`（EXT 0x0C bit[7:4]）默认值 5 只有 **0.75~1.25 ns**，
处于临界 → **PHY 采样踩在数据跳变沿 → 帧内字节重复/回卷**。

**解决**：在 `pin.adc` 给 GTX_CLK 加输出延迟：

```
set_pin_assignment { O_rgmii_txc } { LOCATION = U9; IOSTANDARD = LVCMOS33;
    DRIVESTRENGTH = 8; PULLTYPE = NONE; OUTDEL = 2; }
```

> TD 的 `OUTDEL` **合法范围是 1-4**（从 `td.exe` 里的报错字符串确认：
> "Value range for INDEL/OUTDEL/DRIVESTRENGTH is 1-32, 1-4, 4/8/12/16/20"）。
> 厂商例程里也出现过 `OUTDEL = 3`。

---

## 3. RGMII 协议 / 原语映射（最容易写错的地方）

### 3.1 Anlogic ODDR/IDDR 的 d0/d1 语义

TD 原语模板 `template/verilog/Device-Primitive/PH1P/I,O/ph1p_i_o.v` 原文：

```
PH1P_LOGIC_HD_ODDR:
  .d0  // 1-Bit input. 1 bit posedge input data.     ← 上升沿
  .d1  // 1-Bit input. 1 bit negedge input data.     ← 下降沿
  .rst // Reset, high active.
PH1P_LOGIC_HD_IDDR:
  .q0  // 1 bit posedge data output                  ← 上升沿采样
  .q1  // 1 bit negedge data output
```

厂商 `32_Ethernet_test/src/rgmii_interface.v` 的用法与此一致（低 nibble 接 `d0`/`q0`）。

### 3.2 RGMII 映射表

| 信号 | 上升沿（d0 / q0） | 下降沿（d1 / q1） |
|---|---|---|
| TXD[3:0] | `gmii_txd[3:0]`（低 nibble） | `gmii_txd[7:4]`（高 nibble） |
| TX_CTL | `TX_EN` | **`TX_EN XOR TX_ER`** |
| RX_CTL | `RX_DV` | `RX_DV XOR RX_ER` |

**两个致命易错点**：
1. nibble 接反 → 每个字节变成 `{b[3:0], b[7:4]}`；
2. `TX_CTL` 下降沿直接送 `TX_ER`（恒 0）→ PHY 解出 `TX_ER = TX_EN xor 0 = 1`，
   **整帧被判为 error frame 丢弃**（本项目的 bug #4）。

### 3.3 前导码

- 必须正好 **7 × `0x55` + 1 × `0xD5`**（8 字节）。
- 用寄存器输出时有一段"输出滞后一拍"的陷阱：
  `S_PRE` 状态里循环 7 次会把第 7 个 `0x55` 带到下一状态再出一拍，
  结果多发一个 `0x55`。正确写法：`S_PRE` 只数到 5，第 7 个 `0x55` 由 `S_SFD` 那拍输出，
  进入 `S_DATA` 的第 1 拍输出 `0xD5`。
- `TX_EN` 必须与前导码第一个字节同拍拉高。

### 3.4 帧长与 FCS

- 以太网最小帧：**DA..FCS ≥ 64 字节**（即 payload ≥ 46）。短了会被当 runt 丢弃。
- FCS = CRC-32（poly `0xEDB88320`，初值 `0xFFFFFFFF`，结果取反，**低字节先发**）。
- **不要在 Verilog 里用 `initial` 初始化 CRC 查找表**：TD 综合会忽略，
  报 `HDL-5314 WARNING: net 'crc_lut' does not have a driver`，FCS 全错。
  固定帧直接预计算写死；动态帧用组合逻辑实现（逐位 8 次循环的函数即可综合）。
- 自检方法：`zlib.crc32(整帧含FCS) == 0x2144DF1C`（以太网 CRC 余数魔数）。

```
帧长度检查（本项目最终版）：128 字节 = 124 数据 + 4 FCS
zlib.crc32(前124字节) = 0x013FD4F1  → 线序 F1 D4 3F 01
zlib.crc32(全128字节) = 0x2144DF1C  ✅
```

---

## 4. TD / 工具链注意事项

| 项 | 说明 |
|---|---|
| HDIO 原语 | RGMII 15 根脚都在 HDIO bank，必须 `PH1P_LOGIC_HD_ODDR` / `PH1P_LOGIC_HD_IDDR`，否则 `SYN-8228 can't be mapped into HDIO` |
| ODDR 复位 | `SYN-6024` 警告 "not have rst or rst is const" 不致命；但 `rst` 是**高有效** |
| `settings.cfg` | **不能带 UTF-8 BOM**！PowerShell `Set-Content -Encoding utf8` 会加 BOM，Tcl `source` 会报 `invalid command name "锘?"` 且流程静默失败（退出码仍是 0） |
| `OUTDEL` / `INDEL` | 输出延迟 1-4 档，输入延迟 1-32 档 |
| 上传/构建 | `td_commands_prompt.exe D:/Anlogic/.../DefaultFlow.tcl`，先 `syn_1` 后 `phy_1`；`phy_1` 需要 `parent ../syn_1` 和同一份 `*.prj` |
| SDC | 不加 SDC 时 TD 只会派生一个 50 MHz 时钟，125 MHz 逻辑不会被真正约束；加 `create_generated_clock` 后才可信 |
| 时钟报告 | `report_clock_utilization` 的 waveform（如 `{2.000 6.000}`）只反映**约束/推导**，不代表 PLL 真的在振 |

---

## 5. 调试方法论（下次遇到类似问题照这个顺序走）

1. **先证明"有没有发"**：PHY 的 ACT 灯 / PC 抓包。只有抓到**任何**来自 FPGA MAC 的帧，才说明 TX 通了。
2. **用"灯语"确认时钟**：把待测时钟分频后接 LED，用**手机录像 + 数闪烁次数**测频率。
   这比示波器容易得多，也是这次抓出 100 MHz 的关键。
   - 固定周期计数器 + LED = 一个廉价频率计。
3. **抓包看字节**：`tshark -x` 看原始 hex。填充区用**自描述序列**（`A0 A1 A2 ...`），
   一眼就能看出错位、重复、截断。
4. **区分"FPGA 没发"和"PHY 没发"**：PHY 的 ACT 灯规律闪 = PHY 在发；再区分"帧内容错"和"没帧"。
5. **不要相信"看起来对"的日志**：TD 的 8 ns 时钟周期只是约束；`MDIO 不通`也不代表 PHY 坏。
6. **引脚一定要回到原理图核对**：板手册/例程 `pin.adc` 都可能有误（本项目 RX_CLK、R10 都踩过）。

### 本次踩过的 6 个 bug（按发现顺序）

| # | Bug | 现象 | 根因 |
|---|---|---|---|
| 1 | ODDR `d0/d1` 接反 | 完全收不到 | `d1` 才是下降沿；TX_EN 落到下降沿 |
| 2 | CRC 查找表没综合 | 帧内容对但被丢 | `initial` 数组初始化不支持 |
| 3 | 帧 46 字节 | 被丢 | 小于最小 60（DA..FCS） |
| 4 | `TX_CTL` 下降沿送 `TX_ER` | 整帧被当 error frame | 应为 `TX_EN XOR TX_ER` |
| 5 | **PLL 实际只有 100 MHz** | 帧内 20 字节重复 | 只改 `CLKC0_DIV`，C0 频率不变 |
| 6 | RX_CLK 用了 V2 | LED 不亮、收不到 | 实际是 V3 |

---

## 6. 已验证的最小实现

`work/eth_smoke/`：
- `rtl/eth_top.v`：PLL（125 MHz）+ PHY 复位 + ARP 帧发生器 + RGMII TX + LED 诊断
- `rtl/rgmii_tx_phy.v`：HD_ODDR 映射（d0=上升沿）+ GTX_CLK（0° + OUTDEL）
- `rtl/arp_frame_tx.v`：128 字节固定帧（自描述填充 + 预计算 FCS）
- `constraints/pin.adc` + `constraints/timing.sdc`

**实测结果**：200 ms 一帧、124 字节、`0x0806`、PC `arp -a` 正确出现
`192.168.1.200 → 01-23-45-67-89-ab`。

### 后续要做的事

1. **RX 通路**：`PH1P_LOGIC_HD_IDDR`，`q0`=上升沿（低 nibble / RX_DV）、`q1`=下降沿（高 nibble / RX_DV^RX_ER）。
2. **真正的 CRC-32 生成器**（组合逻辑，不用查找表）。
3. **MAC 地址**：现在用的 `01:23:45:67:89:AB` 的 bit0 = 1，是**组播地址**（Wireshark 会警告）。
   正式设计建议 `02:00:00:00:00:01` 这类本地管理单播地址。
4. **UDP 打包**：视频每包 ~1400 字节，需要序号/帧号用于 PC 端丢帧检测。
