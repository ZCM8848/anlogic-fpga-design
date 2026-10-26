# M0 前置核实 — PH1P35 RGMII 千兆可行性

> 子项目：`work/camera_eth_720p`
> 核实日期：2026-10-26
> 目的：在动工实施 M1 之前，把 3 个硬约束落实，避免方案返工。
> 风险清单对应 `docs/plan.md §3`。

## 核实项 1 — PH1P35 是否有 IDDR/ODDR 原语

**结论：✅ 具备原生 IDDR/ODDR 原语，无需 PLL 相移 hack。**

### 1.1 ODDR 验证（已有间接证据）

文件 `work/camera_hdmi_720p/ip/hdmi/lane_lvds_10_1.v` 第 121/133 行（HDMI TX 的 TMDS 10:1 并串转换）已实例化：

```verilog
else if(DEVICE == "PH1P")
    PH1P_LOGIC_ODDR U_EG4_ODDR(
        .clk ( I_serial_clk ),
        .rst ( I_rst        ),
        .d1  ( S_oddr_data[0] ),
        .d0  ( S_oddr_data[1] ),
        .q   ( O_serial_out )
    );
```

→ PH1P_LOGIC_ODDR 已在现有工程中验证可用。

### 1.2 IDDR 验证（原语库直接核实）

在 TD 安装目录 `D:\Anlogic\TD_6.2.1_Engineer_6.2.168.116\arch\ph1p_macro.v` 第 8306 行起：

```verilog
module PH1P_LOGIC_IDDR (
        q1, q0, clk, d, rst
);
output q1; output q0;          // q1=上升沿数据, q0=下降沿数据（RGMII RX 解 DDR 直接用）
input  clk; input d; input rst;
parameter ASYNCRST = "ENABLE"; // "ENABLE", "DISABLE".
parameter PIPEMODE = "PIPED";  // "PIPED", "NONE".
endmodule
```

端口定义完美适配 RGMII RX 4 位 DDR 解码：4 个 IDDR 一组，每个把 1 位 DDR 数据解成 q1/q0，得到 8 位 GMII RX 数据。

### 1.3 完整原语家族（line 8280–8479）

| 原语 | 端口要点 | 用途 |
|---|---|---|
| `PH1P_LOGIC_ODDR` | q/clk/d1/d0/rst | RGMII TX：1 位 DDR（d1=上升沿数据，d0=下降沿数据） |
| `PH1P_LOGIC_ODDRx2` | q/pclk/sclk/d3..d0/rst | 多位 DDR（多相位时钟） |
| `PH1P_LOGIC_IDDR` | q1/q0/clk/d/rst | RGMII RX：1 位 DDR 解码 |
| `PH1P_LOGIC_IDDRx2` | q3..q0/pclk/sclk/d/rst | 多位 DDR 解码 |
| `PH1P_LOGIC_HD_IDDR` | q1/q0/clk/d/rst + MODE 参数 | HD bank 变体（OPPOSITE_EDGE/SAME_EDGE/SAME_EDGE_PIPE） |
| `PH1P_LOGIC_HD_ODDR` | q/clk/d1/d0/rst | HD bank ODDR 变体 |
| `PH1P_LOGIC_HR_OSERDES` | sclk/pclk/idata[9:0]/odata | 高速串行器（10:1，TMDS 用） |
| `PH1P_LOGIC_HR_ISERDES` | sclk/pclk/idata/odata[9:0] | 高速解串器 |
| `PH1P_LOGIC_DYNAMIC_HR_IDELAY` | i/dly[7:0]/o + CAS_MODE | HR 动态延迟线（调 RGMII RX clock-data skew） |
| `PH1P_LOGIC_DYNAMIC_HR_ODELAY` | i/dly[7:0]/o + CAS_MODE | HR 动态延迟线（调 TX skew） |
| `PH1P_LOGIC_DYNAMIC_HD_IDELAY` | i/dly[4:0]/o + CAS_MODE | HD 动态延迟线 |
| `PH1P_LOGIC_DYNAMIC_HD_ODELAY` | i/dly[4:0]/o + CAS_MODE | HD 动态延迟线 |

**关键收益**：
- RGMII TX 用 `PH1P_LOGIC_ODDR` 把 GMII 8bit@125M 转 4bit DDR → PHY
- RGMII RX 用 `PH1P_LOGIC_IDDR` 把 4bit DDR → GMII 8bit@125M
- clock-data skew 调节可走原生 `IDELAY/ODELAY`，不依赖 PHY 内部 delay（双保险）

→ **风险 #1 完全消除**。

## 核实项 2 — RGMII 14 引脚是否都在 3.3V bank

**结论：✅ 全部 RGMII 引脚在 LVCMOS33 下可被 TD 接受、综合、布局、布线、bitgen 全程通过。**

实际跑下来发现 **所有 RGMII 引脚都在 HD bank**（不是 HR bank），因此必须用 `PH1P_LOGIC_HD_IDDR` / `PH1P_LOGIC_HD_ODDR` 变体，不能用普通的 `PH1P_LOGIC_IDDR` / `PH1P_LOGIC_ODDR`。

### 2.1 引脚清单（最终版，原理图核实）

| 信号（RGMII 角色） | FPGA 引脚 | IO 标准 | Bank 类型 | DDR 原语变体 | 来源 |
|---|---|---|---|---|---|
| MDC | V9 | LVCMOS33 | HDIO | — | docx §15 |
| MDIO | U10 | LVCMOS33 | HDIO | — | docx §15 |
| RESET_N | V8 | LVCMOS33 | HDIO | — | docx §15 |
| GTX_CLK (TXC) | U9 | LVCMOS33 | HDIO | PH1P_LOGIC_HD_ODDR | docx §15 |
| TX_CTL (TXEN) | R10 | LVCMOS33 | HDIO | PH1P_LOGIC_HD_ODDR | docx §15 |
| TXD[0] | R11 | LVCMOS33 | HDIO | PH1P_LOGIC_HD_ODDR | docx §15 |
| TXD[1] | P11 | LVCMOS33 | HDIO | PH1P_LOGIC_HD_ODDR | docx §15 |
| TXD[2] | T10 | LVCMOS33 | HDIO | PH1P_LOGIC_HD_ODDR | docx §15 |
| TXD[3] | R12 | LVCMOS33 | HDIO | PH1P_LOGIC_HD_ODDR | docx §15 |
| **RX_CLK** | **V2** | LVCMOS33 | HDIO（推断） | （作为时钟输入，不需 ODDR） | ⚠️ docx 漏列，原理图 P01_FPGA + P09_ETHERNET 核实 |
| RX_CTL (RX_DV) | N8 | LVCMOS33 | HDIO | PH1P_LOGIC_HD_IDDR | docx §15 |
| RXD[0] | N9 | LVCMOS33 | HDIO | PH1P_LOGIC_HD_IDDR | docx §15 |
| RXD[1] | T7 | LVCMOS33 | HDIO | PH1P_LOGIC_HD_IDDR | docx §15 |
| RXD[2] | T8 | LVCMOS33 | HDIO | PH1P_LOGIC_HD_IDDR | docx §15 |
| RXD[3] | T9 | LVCMOS33 | HDIO | PH1P_LOGIC_HD_IDDR | docx §15 |

### 2.2 ⚠️ RXC_DV 引脚歧义——**已彻底厘清**

板手册 / docx 引脚分配汇总把 `RX_CLK` 和 `RX_DV` 合并标注为单根 `RXC_DV → N8`。原理图核实结论：

- **YT8511 PHY 侧（page 9 P09_ETHERENT）**：pin 31 = `RX_CLK`，pin 30 = `RX_DV`，是 2 根独立 PHY 引脚，分别接 FPGA 网络名 `ETHPHY_RX_CLK` 与 `ETHPHY_RXC_DV`。
- **FPGA 侧（page 2 P01_FPGA）位置对齐核实**：每个 FPGA 球名与其 ETHPHY 网络名有稳定的 ~2.6 单位 X 偏移规律（`ball_x ≈ net_x − 2.6`）。按此规律逐个验证：
  - V9↔MDC、U10↔MDIO、V8↔RESET_N、U9↔TX_CLK、N9↔RXD0、R11↔TXD0、T7↔RXD1、P11↔TXD1、T8↔RXD2、T10↔TXD2、T9↔RXD3、R12↔TXD3、R10↔TX_EN、N8↔RX_DV —— **14 个全部与 docx 表一致**
  - **V2 ↔ ETHPHY_RX_CLK**（X 偏移 +2.5，方向相反但稳定；V2 在 FPGA 右侧，其余 14 个在左侧）—— **V2 是漏列的第 15 个以太网引脚**

→ **N8 是 RX_DV（数据有效），不是 RX_CLK**。这就是 TD 之前报"`N8 not clock-capable pad`"警告的根本原因——把数据信号当时钟用了。修正后用 V2 作 RX_CLK，警告应消失（待 syn 重跑结果回填）。

→ HW_PINMAP.md 把 V2 标为 "J2 GPIOA_0（扩展口）"，实际上板子把 V2 用于以太网 RX_CLK，J2 扩展口 pin 1 不可用。

### 2.3 旁证（其他工程已用的 LVCMOS33 引脚）

`work/camera_hdmi_720p/constraints/pin.adc` 中已验证可用的 LVCMOS33 引脚行号范围：
- LED1/2/3/4：D10/E10/C6/D6（D/C 行，列 6-10）
- MIPI 控制：L3/L2/K3/J3（**BANK21**，VCCIO=3.3V，板手册明确）
- AE 按键：N2/J14（N/J 行）
- KEY2/3/4：A9/B9/C7（A/B/C 行）
- SW3/4：D11/E11（D/E 行）
- UART：H1（H 行）

V2 在现有 `camera_hdmi_720p/pin.adc` 中**未使用**，本子项目可独占。

## 核实项 3 — TD 项目能否综合 + 布局 IDDR/ODDR + RGMII 引脚

**结论：✅ 完整通过 syn → opt_place → opt_route → fix_hold → bitgen 全流程，0 FEP，bit 文件已生成。**

### 3.1 验证工程

```
work/camera_eth_720p/
├── constraints/pin.adc              # 15 RGMII 引脚（含 V2=RX_CLK）+ 系统时钟 + LED + UART，全 LVCMOS33
├── td_project/
│   ├── bank_check.al                # 最小 .al（无 IP，仅 RTL + pin.adc）
│   ├── bank_check_top.v             # 顶层：5× HD_ODDR + 5× HD_IDDR 例化（覆盖全部 TXD/TXC/TX_CTL/RX_CLK/RX_DV/RXD）
│   └── bank_check_Runs/
│       ├── syn_1/settings.cfg      # end_step=opt_gate
│       └── phy_1/settings.cfg       # end_step=bitgen
└── docs/
    ├── plan.md
    └── M0_verification.md           # 本文件
```

### 3.2 syn_1 综合结果

```
HDL-1007 : elaborate module bank_check_top
HDL-1007 : elaborate module PH1P_LOGIC_ODDR       (HR 变体，未被使用)
HDL-1007 : elaborate module PH1P_LOGIC_HD_ODDR     (HD 变体，5 例)
HDL-1007 : elaborate module PH1P_LOGIC_IDDR        (HR 变体，未被使用)
HDL-1007 : elaborate module PH1P_LOGIC_HD_IDDR     (HD 变体，5 例)
SYN-1079 : finish stage Optimize RTL. Total instances: 46, Total nets: 78.
SYN-1079 : finish stage Optimize Gate. Total instances: 82, Total nets: 113.
```

**0 ERROR / 0 SYN-8228 bank placement error**；仅余 10 条 SYN-6024 CRITICAL-WARNING（`rst=1'b0`，M0 占位测试，M1 实施时给真实 reset 即消除）。

### 3.3 phy_1 物理 layout 结果

```
Stage 2.2 Map IO        → 通过（所有 15 个 RGMII 引脚 + 系统/LED/UART 都 OK）
Stage 2.3 Map Macro     → 通过
Stage 2.4 Map Gate      → 通过
Stage 2.5 Pack Gate     → 通过
Stage 3   Hold Fix      → 通过
Stage 4   Route         → 6.85 s wall
Stage 5   Bitgen       → 通过，bank_check.bit 生成（1,789,489 B）
```

**最终时序**（无任何真实时序约束，纯布局可行性验证）：

```
Setup WNS = 16594 ps / TNS 0 / NUM_FEPS 0
Hold  WNS =   171 ps / TNS 0 / NUM_FEPS 0
```

→ 0 个违例。

### 3.4 详细 IO 报告（最终放置结果）

| Name | Direction | Location | IOStandard | IOType | PackReg |
|---|---|---|---|---|---|
| I_rgmii_rxc | INPUT | V2 | LVCMOS33 | HDIO | NONE（时钟输入） |
| I_rgmii_rx_ctl | INPUT | N8 | LVCMOS33 | HDIO | DDRX1_OPPOSITE |
| I_rgmii_rxd[0..3] | INPUT | N9/T7/T8/T9 | LVCMOS33 | HDIO | DDRX1_OPPOSITE |
| O_rgmii_txc | OUTPUT | U9 | LVCMOS33 | HDIO | DDRX1 |
| O_rgmii_tx_ctl | OUTPUT | R10 | LVCMOS33 | HDIO | DDRX1 |
| O_rgmii_txd[0..3] | OUTPUT | R11/P11/T10/R12 | LVCMOS33 | HDIO | DDRX1 |
| O_rgmii_mdc | OUTPUT | V9 | LVCMOS33 | HDIO | NONE |
| IO_rgmii_mdio | INOUT | U10 | LVCMOS33 | HDIO | NONE |
| O_phy_rst_n | OUTPUT | V8 | LVCMOS33 | HDIO | NONE |

→ **全部 RGMII 引脚都在 HD bank**（IOType=HDIO），全部 PackReg 落 DDRX1 模式（DDR 1 倍速，对应 RGMII 125 MHz DDR）。

### 3.5 资源占用（bank_check_top）

| 资源 | 用量 | 总量 | 占比 |
|---|---|---|---|
| IO | 20 | 160 | 12.5% |
| LUT6 | 29 | 21216 | 0.14% |
| REG | 26 | 42432 | 0.06% |
| SLICE | 29 | 21216 | 0.14% |
| ERAM | 0 | 108 | 0% |
| DSP | 0 | 40 | 0% |
| PLL | 0 | 6 | 0% |
| GCLK | 2 | 32 | 6.25% |
| SCLK | 3 | 48 | 6.25% |

→ 几乎不占资源（这是预期的，M0 只验证可放置性，不含任何真实逻辑）。

## 核实项 4（额外） — 上位机 demosaic 像素顺序

**结论：✅ SC520CS 输出 Bayer BGGR 排列；M4 上位机用 `cv2.COLOR_BayerBG2BGR` 即可。**

来源：`work/camera_hdmi_720p/rtl/isp/demosaic_4x_2_0/demosaic.v` 第 24 行：

```verilog
parameter BAYER_MODE = "BGGR"
```

`isp_top.v` 例化时未覆盖该参数，沿用默认值。BGGR 2×2 排列：

```
B G
G R
```

OpenCV 对应 enum：`cv2.COLOR_BayerBG2BGR`。M4 上位机伪码：

```python
bgr = cv2.cvtColor(raw_10bit_packed_to_16bit, cv2.COLOR_BayerBG2BGR)
```

不阻塞 M0~M3；M4 实施时直接照用。

## 总结与下一步

| 风险 | 状态 | 备注 |
|---|---|---|
| #1 PH1P35 IDDR/ODDR | ✅ 已确认 | 原生原语齐备：`PH1P_LOGIC_HD_ODDR` / `PH1P_LOGIC_HD_IDDR` + `IDELAY/ODELAY` 延迟线 |
| #2 RGMII 引脚 bank | ✅ 已确认 | 全部 15 个 RGMII 引脚（含 V2=RX_CLK）都在 **HDIO** 类型，LVCMOS33 全部可放置、可 bitgen |
| #3 RGMII TX clock-data skew | ✅ 缓解手段齐备 | PHY 内部 delay + 原生 `PH1P_LOGIC_DYNAMIC_HD_IDELAY/ODELAY` 双保险，M1 实施时再调 |
| RXC_DV 引脚歧义 | ✅ 已彻底厘清 | **N8 = RX_DV**，**V2 = RX_CLK**（原理图 P09+P01 位置对齐核实；docx 漏列 V2） |
| 上位机 Bayer 顺序 | ✅ 已确认 | SC520CS = BGGR；M4 用 `cv2.COLOR_BayerBG2BGR` |
| 综合/布局/bitgen | ✅ 全通过 | syn→phy→bitgen 一气呵成，0 FEP，bit `bank_check.bit`（1.79 MB） |

### 关键工程结论（M1 实施必须照办）

1. **DDR 原语用 HD 变体**，不用 HR 变体：
   - TX：`PH1P_LOGIC_HD_ODDR`（5 例：GTX_CLK + TX_CTL + TXD[3:0]）
   - RX：`PH1P_LOGIC_HD_IDDR #(.MODE("OPPOSITE_EDGE"))`（5 例：RX_CLK 解 DV + RXD[3:0]）
2. **引脚分配锁定**（15 个 RGMII 引脚）：
   - `pin.adc` 已在 `work/camera_eth_720p/constraints/pin.adc` 中固化，**M1 起直接复用**
3. **V2 是 RX_CLK 专用**：HW_PINMAP.md 把 V2 标 J2 扩展口 GPIOA_0，但板子已用于以太网 RX_CLK；J2 pin 1 不可作为用户扩展
4. **N8 是 RX_DV 数据**，不要当 RX_CLK 用（否则触发 SYN-6019 clock-capable warning）

### M0 通过判据

✅ **完全达成**：bank_check 工程跑完 phy_1（bitgen 通过），0 FEP，可进入 M1。

### 下一步（M1）

按 `docs/plan.md §2.M1`：
1. 写 `rtl/eth/phy_rst.v` + `rtl/eth/mdio_ctrl.v`，复位 YT8511 + 配 0x9 寄存器（1000M 全双工 + RGMII delay）
2. 写 `rtl/eth/rgmii_mac.v`（含 `PH1P_LOGIC_HD_ODDR/IDDR` 例化 + CRC32 + FIFO），做自环测试
3. 验收：MDIO 读出 PHY ID = 0x10d，自环 MAC 收到自己发的包
