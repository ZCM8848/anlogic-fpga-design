# HW_PINMAP — 引脚总表

> 交叉核对来源：本项目 `work/camera_hdmi_720p/constraints/pin.adc`（**已上板验证，最高优先**）、
> 板手册《新HX1P35A开发板手册》、DS1300 数据手册。
> `IO 标准 / 上下拉 / 驱动` 一列仅对写入 `pin.adc` 的信号给出（本项目实际值）。

## 1. 本项目实际使用的引脚（`pin.adc`）

| FPGA 引脚 | 本项目信号 | 板网络 / 外设 | IO 标准 | 属性 |
|---|---|---|---|---|
| **C4** | `I_sys_clk` | 板载 50 MHz 有源晶振 | LVCMOS33 | PULLUP |
| **G16** | `O_tmds_ch0_p` | HDMI D0_P | TMDS33 | NONE |
| **F17** | `O_tmds_ch1_p` | HDMI D1_P | TMDS33 | NONE |
| **H14** | `O_tmds_ch2_p` | HDMI D2_P | TMDS33 | NONE |
| **C17** | `O_tmds_clk_p` | HDMI CLK_P | TMDS33 | NONE |
| **D10** | `O_led[0]` | LED1 | LVCMOS33 | DS=8 |
| **E10** | `O_led[1]` | LED2 | LVCMOS33 | DS=8 |
| **C6** | `O_led[2]` | LED3 | LVCMOS33 | DS=8 |
| **D6** | `O_led[3]` | LED4 | LVCMOS33 | DS=8 |
| **L3** | `O_cam_24m` | MIPI_CSI_FCLK（摄像头 EXTCLK/XCLK） | LVCMOS33 | DS=8, PULLUP |
| **L2** | `O_cam_rst` | MIPI_CSI_FPWDNB（PWDNB，低有效） | LVCMOS33 | DS=8, PULLUP |
| **K3** | `O_cam_scl` | MIPI_CSI_I2C_FSCL | LVCMOS33 | DS=8, PULLUP |
| **J3** | `IO_cam_sda` | MIPI_CSI_I2C_FSDA（inout） | LVCMOS33 | DS=8, PULLUP |
| **N2** | `I_button[0]` | AE 按键 1（J2 扩展口，当前未使用） | LVCMOS33 | PULLUP |
| **J14** | `I_button[1]` | AE 按键 2（J2 扩展口，当前未使用） | LVCMOS33 | PULLUP |
| **D5** | `I_key1` | KEY1（短按切显示源/测试曲，长按清零） | LVCMOS33 | PULLUP |
| **A9** | `I_key2` | KEY2（长按重采背景，仅识别态） | LVCMOS33 | PULLUP |
| **B9** | `I_key3` | KEY3（遗留阈值脉冲，未使用） | LVCMOS33 | PULLUP |
| **C7** | `I_key4` | KEY4（遗留阈值脉冲，未使用） | LVCMOS33 | PULLUP |
| **H1** | `O_uart_tx` | USB-UART TXD（115200 8N1） | LVCMOS33 | DS=8 |
| **A4** | `I_sw1` | SW1（0=识别态，1=测试/调试态） | LVCMOS33 | PULLUP |
| **B4** | `I_sw2` | SW2（测试态子模式：0=静态图案，1=动态调试） | LVCMOS33 | PULLUP |
| **D11** | `I_sw4` | SW4（仅上报 `SW_STAT[3]`） | LVCMOS33 | PULLUP |
| **E11** | `I_sw3` | SW3（仅上报 `SW_STAT[2]`） | LVCMOS33 | PULLUP |
| **C12** | `O_buzzer` | 蜂鸣器 BUZZER（低电平响，SW5 硬件开关） | LVCMOS33 | DS=8 |

> UART 方向已定案：**FPGA 的 `O_uart_tx` → H1**；J1 为 FPGA 侧 RXD（本设计未用）。
> 原理图 sheet3 里 `FPGA_TXD/RXD` 是桥侧视角命名，勿按字面判方向。

## 2. MIPI 差分对（D-PHY 硬核 pad，**不写入 `pin.adc`**）

| 信号 | FPGA 引脚 | 说明 |
|---|---|---|
| MIPI_CSI_CK_P / CK_N | **V16 / U16** | 时钟差分对 |
| MIPI_CSI_D0_P / D0_N | **V14 / U14** | 数据 lane0 |
| MIPI_CSI_D1_P / D1_N | **V15 / U15** | 数据 lane1 |
| MIPI_CSI_D2_P / D2_N | V17 / U17 | 本项目未用（顶层仍声明 pad 数组） |
| MIPI_CSI_D3_P / D3_N | U18 / V18 | 本项目未用 |

- 由顶层直连 D-PHY IP 硬核 pad；IP 参数取 SC520 lab 原值（DPHY0、3dB、8dB、LANE_NUM=2、BYTE_NUM=1）。

## 3. DDR2（集成存储接口，硬核 pad，**不写入 `pin.adc`**）

- 走 **BANK11**，由 DDR2 IP 自带 `ddr2.adc`（SSTL15/DIFF_SSTL15 + PHY 硬核/IOCLK/BANKREF 位置）约束，
  经 TD run 的 `settings.cfg`（`IpADCList`）加载。详见 `HW_CLOCKS_RESET.md`。

## 4. 板级外设完整引脚表（板手册，供扩展使用）

> 以下未用于本项目，但记录以便未来扩展。分组顺序同板手册。

### 时钟 / 复位 / 调试 / 串口

| 功能 | FPGA 引脚 |
|---|---|
| 系统时钟 CLK（50 MHz） | C4 |
| DDR 差分时钟 | L5 / K5（P/N，板手册标注疑有笔误） |
| FPGA_TCK / TMS / TDO / TDI | R13 / L14 / T13 / R13 ⚠️ |
| UART RXD / TXD | J1 / H1 |

### HDMI

| 信号 | FPGA | 信号 | FPGA |
|---|---|---|---|
| D0_P / D0_N | G16 / H16 | D1_P / D1_N | F17 / E18 |
| D2_P / D2_N | H14 / H13 | CLK_P / CLK_N | C17 / D18 |
| SCL / SDA | E15 / F15 | HPD | B17 |

### MIPI CSI

| 信号 | FPGA | 信号 | FPGA |
|---|---|---|---|
| CK_P / CK_N | V16 / U16 | D0_P / D0_N | V14 / U14 |
| D1_P / D1_N | V15 / U15 | D2_P / D2_N | V17 / U17 |
| D3_P / D3_N | U18 / V18 | I2C_FSCL / FSDA | K3 / J3 |
| FCLK | L3 | FPWDNB | L2 |

### LED / 按键 / 开关 / 蜂鸣器

| 功能 | FPGA 引脚 |
|---|---|
| LED1~LED4 | D10 / E10 / C6 / D6（高电平点亮） |
| 电源指示 LED14 | （板上电源灯，非用户 IO） |
| KEY1 / KEY2 / KEY3 / KEY4 | D5 / A9 / B9 / C7（按下低电平） |
| SW1 / SW2 / SW3 / SW4 | A4 / B4 / E11 / D11（拨上=1；SW1/SW2 选择工作模式，SW3/SW4 只上报 `SW_STAT`） |
| 蜂鸣器 BUZZER | C12（低电平响，SW5 硬件开关） |

### 数码管 / 双色 LED（复用，SW6 选择）

| 双色 LED | 数码管 | FPGA | 双色 LED | 数码管 | FPGA |
|---|---|---|---|---|---|
| LED6 红/绿 | DIG0 / SEL0 | C9 / G15 | LED7 红/绿 | DIG1 / SEL1 | C11 / G14 |
| LED8 红/绿 | DIG2 / SEL2 | B11 / A17 | LED9 红/绿 | DIG3 / SEL3 | E7 / A18 |
| LED10 红/绿 | DIG4 / SEL4 | E6 / B16 | LED11 红/绿 | DIG5 / SEL5 | B6 / A15 |
| LED12 红/绿 | DIG6 / SEL6 | B7 / B15 | LED13 红/绿 | DIG7 / SEL7 | E5 / A14 |

### 配置 FLASH / SPI FLASH / TF 卡 / 以太网

| 功能 | FPGA 引脚 |
|---|---|
| QSPI(N25Q128) CS/SDO/WP/HOLD/SCLK/SDI | D14 / D16 / C16 / A13 / N6 / E13 |
| SPI(GD25Q128) CSN/DQ1/DQ2/DQ3/DQ0/GCLK | R8 / U12 / V11 / U11 / V12 / R15 |
| TF: DAT3/DAT2/DAT1/DAT0/CLK/CMD | B12 / A12 / D8 / E8 / A7 / A8 |
### 以太网（YT8511，RGMII）✅ 已上板验证（2026-10-27，见 `HW_ETH_RGMII.md`）

| 功能 | 信号名 | FPGA 引脚 |
|---|---|---|
| MDC（管理时钟） | `ETHPHY_MDC` | **V9** |
| MDIO（管理数据，双向） | `ETHPHY_MDIO` | **U10** |
| PHY 复位（低有效） | `ETHPHY_RESET_N` | **V8** |
| GTX_CLK（125 MHz，FPGA→PHY） | `ETHPHY_TX_CLK` | **U9** |
| TX_EN | `ETHPHY_TX_EN` | **R10** |
| TXD0 / TXD1 / TXD2 / TXD3 | `ETHPHY_TXD0..3` | **R11 / P11 / T10 / R12** |
| RX_CLK（125 MHz，PHY→FPGA） | `ETHPHY_RX_CLK` | **V3**（`IO_BE17P_22,GCLKIOT1`） |
| RX_DV | `ETHPHY_RX_DV` | **N8** |
| RXD0 / RXD1 / RXD2 / RXD3 | `ETHPHY_RXD0..3` | **N9 / T7 / T8 / T9** |

> ⚠️ **板手册《HX1P35B开发板引脚分配汇总》有误**：它把 RX 侧写成单根 `RXC_DV = N8`，
> 且**完全漏掉 RX_CLK**。实测 RX_CLK 在 **V3**（不是 V2！V2 是 `GPIOA0`）。
> 核对方法：原理图 page2 的球名与网络名在图中是逐行对齐的，文字坐标必须按
> 「网络名 x = 球名 x + ~2.1」的固定偏移配对，不能靠直觉或纯文本排序。

### 40 芯扩展口

见 `HW_HX1P35A_BOARD.md` §7（J1 / J2 完整 40 脚表）。
