# HW_PH1P35 — 安路 PH1P35 FPGA 芯片参数

> 平台：上海安路信息科技 **SALPHOENIX® 1P（PH1P）** 系列。
> 本板所用具体型号：**PH1P35MDG324-3**（速度等级 3，工业级）。
> 来源：DS1300（数据手册 V1.2）、DS1301（器件概览 V1.1）、板手册、MCU 指南（详见 `README.md`）。

## 1. 型号与封装

| 项目 | 值 | 来源 |
|---|---|---|
| 系列 | Anlogic SALPHOENIX PH1P | DS1301 |
| 本板器件 | PH1P35MDG324，速度等级 **-3**（中速），工业级 I（TJ −40~100 ℃） | 板手册 / MCU 指南 |
| 封装 | MDG324：**15 × 15 mm，0.8 mm pitch，324 球**（BGA） | DS1301 / DS1300 |
| 命名规则 | `PH1 P <LUT容量> <封装> <温度> <速度>`，例：`PH1P35MDG324-3` | DS1301 §5 |
| MSL | MSL3 | DS1301 |

> 板上丝印/文档口径不一：板手册正文有"HX1P35C"字样，标题为"HX1P35A"，原理图文件为"HX1P35B_FT"。
> 属同系列不同丝印/修订，**芯片均为 PH1P35MDG324**。

## 2. 逻辑与存储资源（PH1P35 列）

| 资源 | 数量 | 说明 |
|---|---|---|
| LUT4s | **38,189** | 双 LUT5 / 双 LUT4 结构 |
| DFFs | **42,432** | 触发器（板手册误写为 42,434，以 DS1301 为准） |
| 分布式 RAM | **507 Kbit** | 64×8 与 32×16 两种模式 |
| ERAM20K 块数 | **108** | 每块 20 Kbit |
| ERAM 总容量 | **2,160 Kbit** | 108 × 20 Kbit |
| DSP | **40** | 预加器 + 三输入加法器 + 乘法器 + ALU |
| PLL | **6** | 每 PLL 7 路输出（可相位/占空比调整、小数分频、SSC）。**频率公式见 [`HW_CLOCKS_RESET.md`](HW_CLOCKS_RESET.md) §2 与 [`HW_ETH_RGMII.md`](HW_ETH_RGMII.md) §2**：`C0=(FIN/REFCLK_DIV)×FBCLK_DIV`、`VCO=C0×CLKC0_DIV`，只改 `CLKCn_DIV` 不会改变输出频率 |
| GCLK | **32 路全局时钟网络** | 另有 MLCLK / LCLK / IOCLK |
| MIPI DPHY | **2 组** | 每组最大 1 clk lane + 4 data lane |
| 内嵌 MCU | **1**（RISC-V） | 见 §5 |
| TVS（电压温度检测） | 1 | 支持实时电压/温度监测 |
| ADC | 无（PH1P35 无 ADC） | DS1301 表 3-1 |

> PH1P 全系列对比：PH1P100 / PH1P35 / PH1P50。PH1P35 无 ADC、无 HXT 收发器、无 PCIe。
> （来源：DS1301 表 3-1）

## 3. 外部存储接口（MDG324）

- 支持 **DDR2 / DDR3 / DDR4**，最大 DQ 位宽 **x16**。
- 数据率（DS1301 表 3-2，PH1P35MDG324）：DDR2 **800 Mbps**、DDR3 800 Mbps、DDR4 800 Mbps。
- **集成存储接口（Integrated Memory Interface）**：速率 **1066 Mbps**，DQ **x16**。
  → 本工程 DDR2 即走此集成接口（见 `HW_CLOCKS_RESET.md` 与 `HW_SC520CS.md` 无关，属板级内存）。

## 4. 电源与电气特性（关键值）

来源：DS1300 §3.1。所有值对地。

### 4.1 最大绝对额定值（不得超限）

| 符号 | 参数 | 最小 | 最大 | 单位 |
|---|---|---|---|---|
| VCCAUX | 辅助电源 | −0.5 | 1.98 | V |
| VCCIO（HR/HD） | I/O 驱动供电 | −0.5 | 3.63 | V |
| VCCIO（DDR） | I/O 驱动供电（DDR bank） | −0.5 | 1.98 | V |
| VCCINT | 内核电源 | −0.5 | 1.05 | V |
| VCCDPHY | MIPI DPHY 电源（PH1P35） | −0.5 | 1.98 | V |
| VCCIO_DDR | 集成存储 I/O 供电（PH1P35MDG324） | −0.5 | 1.98 | V |
| VI（HR/HD/DDR） | 直流输入电压 | −0.3 | VCCIO+0.4 / +0.5 / +0.2 | V |
| VI（MIPI） | MIPI 输入电压 | −0.15 | 1.45 | V |
| TSTG | 存储温度 | −40 | 125 | ℃ |
| TJ | 结点温度（工业级） | −40 | 125 | ℃ |
| VESD | HBM / CDM | — | ±2000 / ±350 | V |

### 4.2 推荐工作条件

| 符号 | 参数 | 最小 | 典型 | 最大 | 单位 |
|---|---|---|---|---|---|
| **VCCINT** | 内核电源 | 0.92 | **0.95** | 0.98 | V |
| VCCAUX | 辅助电源 | 1.71 | 1.8 | 1.89 | V |
| VCCIO | I/O 供电 | 见下（按 bank 标准） | | | V |
| VCCDPHY | MIPI DPHY 电源（PH1P35） | 1.71 | 1.8 | 1.89 | V |
| **VCCIO_DDR** | 集成存储 I/O（PH1P35MDG324） | 1.425 | **1.5** | 1.575 | V |
| VDDR_VREF | 集成存储参考电压 | 0.49 | 0.5 | 0.51 | ×VCCIO_DDR |
| TVCCxx | 各电源上电时间（GND→90%） | 0.1 | — | 100 | ms |

I/O 供电可选标称（VCCIO）：
- HR：3.3 / 2.5 / 1.8 / 1.5 / 1.35 / 1.2 V
- HD：3.3 / 2.5 / 1.8 / 1.5 V
- DDR：1.8 / 1.5 / 1.35 / 1.2 V

> 本项目 MIPI 摄像头控制引脚（I²C/XCLK/PWDNB）属 **BANK21，VCCIO = 3.3 V**，故 `pin.adc` 用 LVCMOS33。

## 5. 内嵌 RISC-V MCU 硬核

来源：DS1301 §2、MCU 指南。

- 指令集：**RV32 I/M/A/F/C/P/B**，三级流水。
- 存储：**32 KB ICache + 32 KB DCache + 16 KB DLM**。
- 调试：JTAG。
- 外设：QSPI0/1、UART0/1、GPIO×8、I²C，支持 DMA。
- 总线：AHB / APB 与 FPGA Fabric 互联（经 PIB）。
- 使用 MCU 时 **CCLK 不能复用为普通 I/O**（DS1301 表 3-2 注）。
- 生成关系（MCU 指南）：TD 生成 bit（硬件环境）与导出的 HPF（硬件平台描述）；FD 依 HPF 生成 BSP/平台；
  MCU 程序编译为 ELF；运行时 = bit（硬件）+ ELF（软件）。

> **实操细节**（时钟要求/JTAG 模式/fabric AHB·APB 窗口地址/IP 配置/内部地址映射/FD 工具链/OpenOCD 排错/printf 坑）见 [`HW_MCU.md`](HW_MCU.md)。

## 6. MIPI D-PHY（PH1P35 集成 2 组）

- 符合 MIPI D-PHY v2.0；每组可配为输入或输出，最大 4 lane。
- 高速模式（HS）+ 低功耗模式（LP）动态切换；内部串并转换支持 **1:8 与 1:16**。
- LP 支持双向；支持动态 skew 调节与自动 skew 校准。
- 输入输出电气参数可编程。
- 不用时可复用为 **LVCMOS / LVDS**。
- 本工程用 **DPHY0**，2-lane RX，HS 1:8（详见 `HW_CLOCKS_RESET.md`、`ip/README.md`）。

## 7. 配置（Configuration）

- 配置模式：从动串行 / 主动串行 / 主动 SPI x1/x2/x4 / 主动并行 x8/x16 / 从动并行 x8/x16/x32 / JTAG。
- 本板经 USB-JTAG（Type-C）下载 `.bit`，或写入掉电不丢的 FLASH（`.bin`）自动加载。
- 配置引脚 CCLK 进入用户模式后可复用为普通 I/O，**仅支持 LVCMOS，且不支持 ISERDES/OSERDES/IDDR/ODDR**；
  使用 MCU 模块时不可复用（DS1301 表 3-2 注）。

## 8. 其它特性

- ERAM20K：单/真双口、专用 FIFO 控制逻辑、支持 ECC、支持配置期初始化。
- PLL：7 路输出、输入 6~40 MHz（此处指传感器无关，芯片 PLL 另有范围），支持 SSC、CLOCK ALIGNER 相位对齐。
- SEU：单 bit 检错纠错 + 双 bit 检错 + 错误注入。
- 每芯片唯一 **64 位 DNA**；兼容 IEEE-1149.1 BSCAN。
