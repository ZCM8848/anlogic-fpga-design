# HW_HX1P35A_BOARD — HX1P35A 开发板参数与引脚分配

> 核心器件：安路 **PH1P35MDG324**（见 `HW_PH1P35.md`）。
> 来源：《新HX1P35A开发板手册-HDL版2604.pdf》（下称"板手册"）、原理图 `HX1P35B_FT.pdf`、
> 以及本项目已验证的 `work/camera_hdmi_720p/constraints/pin.adc`。
>
> ⚠️ 板手册引脚表存在个别笔误（见各节"注"）；**凡本项目已上板验证过的引脚，以 `pin.adc` 为准。**

## 1. 板级概览

| 项目 | 说明 |
|---|---|
| 核心芯片 | PH1P35MDG324（LUT 38189，DFF 42432，MCU RISC-V×1，MIPI DPHY×2） |
| 供电 | USB 或 12 VDC（1 A）适配器；稳压产生 5V / 3.3V / 1.8V / 1.5V / 0.95V |
| 核心板外设 | 4 按键、6 乒乓开关、8 位数码管、8 组双色 LED、4 个独立 LED、蜂鸣器 |
| 接口 | USB-JTAG(Type-C)、USB转UART、TF 卡、HDMI、千兆网口(YT8511)、MIPI CSI(42P FPC)、2×40芯 GPIO 扩展口 |
| 配置存储器 | QSPI FLASH **N25Q128**（128 Mb，配置用）+ SPI FLASH **GD25Q128**（128 Mb） |
| 时钟源 | 50 MHz 有源晶振（用户逻辑）+ 100 MHz LVDS 差分晶振（DDR 内核，SIT9121） |

## 2. 时钟源

| 时钟 | 频率 | FPGA 引脚 | 说明 |
|---|---|---|---|
| 系统时钟 CLK | **50 MHz** | **C4** | 有源晶振，接 PLL 参考/用户逻辑 |
| DDR 差分时钟 | **100 MHz** | LVDS_P/N：**L5 / K5**（板手册标注两行均为 "LVDS_N"，疑为 P/N 笔误） | SIT9121，LVDS 3.3V |

## 3. 电源

- 12 VDC 适配器（1 A）经稳压得 5 V，与 USB 供电经 MOS 汇流 → 电源开关 → `VCC_5V`。
- 由 `VCC_5V` 产生 **+3.3V、+1.8V、+1.5V、+0.95V** 供给 FPGA 各 BANK / 内核及外设。

## 4. USB / JTAG / UART

| 功能 | 信号 | FPGA 引脚 |
|---|---|---|
| USB-JTAG | FPGA_TCK / FPGA_TMS / FPGA_TDO / FPGA_TDI | R13 / L14 / T13 / R13 ⚠️ |
| USB-UART | RXD（FPGA 侧接收） | **J1** |
| USB-UART | TXD（FPGA 侧发送） | **H1** |

> ⚠️ 板手册 JTAG 表将 TDI 也写成 R13（与 TCK 重复），应以实际原理图/器件为准。

## 5. HDMI 接口（直连 FPGA，19P）

| 信号 | FPGA 引脚 | 信号 | FPGA 引脚 |
|---|---|---|---|
| HDMI1_D0_P | **G16** | HDMI1_D0_N | H16 |
| HDMI1_D1_P | **F17** | HDMI1_D1_N | E18 |
| HDMI1_D2_P | **H14** | HDMI1_D2_N | H13 |
| HDMI1_CLK_P | **C17** | HDMI1_CLK_N | D18 |
| HDMI1_SCL | E15 | HDMI1_SDA | F15 |
| HDMI1_HPD | B17 | — | — |

> 本项目 `pin.adc` 仅用到 4 对 TMDS 的 P 端（G16/F17/H14/C17，IOSTANDARD = TMDS33），已上板验证。

## 6. MIPI_CSI 接口（42 脚 FPC + TXS0104E 电平转换）

| 信号 | FPGA 引脚 | 信号 | FPGA 引脚 |
|---|---|---|---|
| MIPI_CSI_CK_P | **V16** | MIPI_CSI_CK_N | **U16** |
| MIPI_CSI_D0_P | **V14** | MIPI_CSI_D0_N | **U14** |
| MIPI_CSI_D1_P | **V15** | MIPI_CSI_D1_N | **U15** |
| MIPI_CSI_D2_P | V17 | MIPI_CSI_D2_N | U17 |
| MIPI_CSI_D3_P | U18 | MIPI_CSI_D3_N | V18 |
| MIPI_CSI_I2C_FSCL | **K3** | MIPI_CSI_I2C_FSDA | **J3** |
| MIPI_CSI_FCLK | **L3** | MIPI_CSI_FPWDNB | **L2** |

> **MIPI 差分对是 D-PHY 硬核专用 pad，不写入 `pin.adc`**；由顶层直连 IP 硬核 pad。
> FPGA（BANK21，3.3 V）与 FPC 座之间有 **TXS0104E** 双向电平转换；模组板载 I²C 4.7K 上拉。

## 7. 40 芯 GPIO 扩展口

### J1（正方向右下 1 为第 1 脚）

| 脚位(信号) | FPGA | 脚位(信号) | FPGA |
|---|---|---|---|
| 1 (GPIOA_0) | C18 | 2 (GPIOA_1) | D15 |
| 3 (GPIOA_2) | E12 | 4 (GPIOA_3) | E16 |
| 5 (GPIOA_4) | E17 | 6 (GPIOA_5) | F13 |
| 7 (GPIOA_6) | F14 | 8 (GPIOA_7) | F18 |
| 9 (GPIOA_8) | G17 | 10 (GPIOA_9) | H17 |
| 11 VCC5V | — | 12 GND | — |
| 13 (GPIOA_10) | H18 | 14 (GPIOA_11) | J13 |
| 15 (GPIOA_12) | J14 | 16 (GPIOA_13) | J15 |
| 17 (GPIOA_14) | J16 | 18 (GPIOA_15) | J18 |
| 19 (GPIOA_16) | D9 | 20 (GPIOA_17) | K17 |
| 21 (GPIOA_18) | K16 | 22 (GPIOA_19) | K15 |
| 23 (GPIOA_20) | K13 | 24 (GPIOA_21) | L15 |
| 25 (GPIOA_22) | L16 | 26 (GPIOA_23) | P10 |
| 27 (GPIOA_24) | P9 | 28 (GPIOA_25) | P8 |
| 29 3.3V | — | 30 GND | — |
| 31 (GPIOA_26) | R7 | 32 (GPIOA_27) | R6 |
| 33 (GPIOA_28) | T5 | 34 (GPIOA_29) | U7 |
| 35 (GPIOA_30) | U6 | 36 (GPIOA_31) | U5 |
| 37 (GPIOA_32) | U4 | 38 (GPIOA_33) | V7 |
| 39 (GPIOA_34) | V6 | 40 (GPIOA_35) | V4 |

### J2（正方向左上 1 为第 1 脚）

| 脚位(信号) | FPGA | 脚位(信号) | FPGA |
|---|---|---|---|
| 1 (GPIOA_0) | V2 | 2 (GPIOA_1) | V1 |
| 3 (GPIOA_2) | U2 | 4 (GPIOA_3) | U1 |
| 5 (GPIOA_4) | T4 | 6 (GPIOA_5) | T3 |
| 7 (GPIOA_6) | T2 | 8 (GPIOA_7) | R5 |
| 9 (GPIOA_8) | R3 | 10 (GPIOA_9) | R2 |
| 11 VCC5V | — | 12 GND | — |
| 13 (GPIOA_10) | R1 | 14 (GPIOA_11) | P6 |
| 15 (GPIOA_12) | P5 | 16 (GPIOA_13) | P4 |
| 17 (GPIOA_14) | P3 | 18 (GPIOA_15) | P1 |
| 19 (GPIOA_16) | N7 | 20 (GPIOA_17) | N4 |
| 21 (GPIOA_18) | N3 | 22 (GPIOA_19) | N2 |
| 23 (GPIOA_20) | N1 | 24 (GPIOA_21) | M5 |
| 25 (GPIOA_22) | M4 | 26 (GPIOA_23) | M2 |
| 27 (GPIOA_24) | M1 | 28 (GPIOA_25) | L4 |
| 29 3.3V | — | 30 GND | — |
| 31 (GPIOA_26) | K2 | 32 (GPIOA_27) | K1 |
| 33 (GPIOA_28) | H2 | 34 (GPIOA_29) | D4 |
| 35 (GPIOA_30) | C8 | 36 (GPIOA_31) | B5 |
| 37 (GPIOA_32) | A5 | 38 (GPIOA_33) | B14 |
| 39 (GPIOA_34) | B10 | 40 (GPIOA_35) | A10 |

> 注意：J1/J2 均标注 `GPIOA_0..35`（同一组名字），但各自映射到**不同物理引脚**；使用时按物理脚位号对应。
> **本项目用到的 AE 按键 `I_button` 取自 J2 的 N2/J14**（见 `HW_PINMAP.md`）。

## 8. 数码管 / 双色 LED（复用，SW6 选择）

SW6 拨上=数码管工作，拨下=双色 LED 工作。8 个数码管 + 8 组双色 LED 共用 16 个引脚。

| 双色 LED | 数码管 | FPGA 引脚 |
|---|---|---|
| LED6 红 | DIG0 (a) | C9 |
| LED6 绿 | SEL0 | G15 |
| LED7 红 | DIG1 (b) | C11 |
| LED7 绿 | SEL1 | G14 |
| LED8 红 | DIG2 (c) | B11 |
| LED8 绿 | SEL2 | A17 |
| LED9 红 | DIG3 (d) | E7 |
| LED9 绿 | SEL3 | A18 |
| LED10 红 | DIG4 (e) | E6 |
| LED10 绿 | SEL4 | B16 |
| LED11 红 | DIG5 | B6 |
| LED11 绿 | SEL5 | A15 |
| LED12 红 | DIG6 (g) | B7 |
| LED12 绿 | SEL6 | B15 |
| LED13 红 | DIG7 (h/DP) | E5 |
| LED13 绿 | SEL7 | A14 |

- 数码管为**共阳**：段（DIG）低电平点亮；位选（SEL）高电平使能。
- 双色 LED：FPGA 输出 1 点亮、0 熄灭。

## 9. 4 个独立 LED（LED1~LED4）

| 信号 | FPGA 引脚 |
|---|---|
| LED1 | **D10** |
| LED2 | **E10** |
| LED3 | **C6** |
| LED4 | **D6** |

- **高电平点亮**（原理图 LED 阴极接 GND）。本项目用于 PLL/复位/心跳/状态指示。
- 板上另有一红色 **LED14 为电源指示灯**，常亮与本设计无关。

## 10. 按键（KEY1~KEY4）

| 信号 | FPGA 引脚 | 说明 |
|---|---|---|
| KEY1 | **D5** | 按下低电平，松开高电平 |
| KEY2 | **A9** | 本项目：CV 开关 |
| KEY3 | **B9** | 本项目：CV 阈值 − |
| KEY4 | **C7** | 本项目：CV 阈值 + |

## 11. 乒乓开关

| 信号 | FPGA 引脚 | 用途 |
|---|---|---|
| SW1 | A4 | 用户 IO 输入 |
| SW2 | B4 | 用户 IO 输入 |
| SW3 | **E11** | 本项目：模式子选（0=edge, 1=OSD） |
| SW4 | **D11** | 本项目：模式主选（0=彩条, 1=摄像头） |
| SW5 | — | 蜂鸣器开关（拨上断开，拨下接通） |
| SW6 | — | 双色 LED / 数码管选择（拨上=数码管，拨下=双色 LED） |

- SW1–SW4 作 IO 输入：**拨上=1，拨下=0**。

## 12. 蜂鸣器

| 信号 | FPGA 引脚 | 说明 |
|---|---|---|
| BUZZER | C12 | 低电平响（经三极管）；SW5 串在中间 |

## 13. 配置 FLASH 与 SPI FLASH

### 固化 QSPI FLASH — N25Q128（128 Mb，用于 FPGA 配置）

| 信号 | FPGA 引脚 |
|---|---|
| QSPI_CS | D14 |
| QSPI_SDO(D1) | D16 |
| QSPI_WP(D2) | C16 |
| QSPI_HOLD(D3) | A13 |
| QSPI_SCLK | N6 |
| QSPI_SDI(D0) | E13 |

### SPI FLASH — GD25Q128（128 Mb）

| 信号 | FPGA 引脚 |
|---|---|
| FLASH_CSN | R8 |
| FLASH_DQ1(DIN) | U12 |
| FLASH_DQ2 | V11 |
| FLASH_DQ3 | U11 |
| FLASH_DQ0(MOSI) | V12 |
| FLASH_GCLK | R15 |

## 14. TF 卡槽（板背面，SD 模式）

| 信号 | FPGA 引脚 |
|---|---|
| SD_DAT3(CS) | B12 |
| SD_DAT2 | A12 |
| SD_DAT1 | D8 |
| SD_DAT0(MISO) | E8 |
| SD_CLK | A7 |
| SD_CMD(MOSI) | A8 |

## 15. 千兆以太网（YT8511）

| 信号 | FPGA | 信号 | FPGA |
|---|---|---|---|
| MDC0 | V9 | MDIO0 | U10 |
| RESET_N | V8 | TXCLK | U9 |
| RXD0 | N9 | TXD0 | R11 |
| RXD1 | T7 | TXD1 | P11 |
| RXD2 | T8 | TXD2 | T10 |
| RXD3 | T9 | TXD3 | R12 |
| TXEN | R10 | RXC_DV | N8 |

> 本项目把 R10（以太网 TXEN）**不用于以太网**，仅作为可选复位脚位记录；系统复位由 PLL lock 产生。

## 16. DDR2 内存

- 板载 DDR2 挂接 PH1P 的**集成存储接口（DDR BANK，BANK11）**，引脚由 D-PHY/DDR PHY 硬核专用 pad 承载，
  **不写入用户 `pin.adc`**，而由 DDR2 IP 自带 `ddr2.adc` / `ddr2.sdc` 约束（经 TD run 的 `settings.cfg` 的
  `IpADCList/IpSDCList` 加载）。详见 `HW_CLOCKS_RESET.md` 与 `work/camera_hdmi_720p/ip/README.md`。
