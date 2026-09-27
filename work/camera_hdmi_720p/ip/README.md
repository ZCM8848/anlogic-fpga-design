# ip/ — 复用件说明（不自研、不修改）

本目录文件均来自厂商交付（安路 TD / 康芯 SC520 2026 竞赛资料包），作为**IP 与 IP 配套件**直接复用。
修改这些文件会破坏与厂商 IP 的兼容性；升级请从厂商资料包整份重新拷贝。

## pll/ — 通用 PLL IP

| 文件 | 说明 |
|---|---|
| `PLL.xml` | IP-XACT 描述（TD 通过它加载 IP；fileSet 引用 `PLL.v` 与 `RTL/*.v`，相对路径） |
| `PLL.v` | PLL 例化封装：C0=100MHz、C1=23.809524MHz、C4=75MHz、C5=375MHz（VCO 1500MHz，FIN=50MHz） |
| `RTL/ph1p_phy_pll_wrapper_25a56e5ce2f9.v` | PH1P 物理 PLL 包装器（加密交付） |
| `.params_PLL.txt` / `.ports_PLL.txt` / `.m_params_PLL.txt` | TD 生成参数记录（备查） |

来源：厂商工程 `user_source/ip_source/PLL/`。
注意：`constraints/timing.sdc` 中的 `rename_clock` 依赖实例名 `u_pll/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[n]`，
即顶层 PLL 实例必须命名为 `u_pll`（见 `rtl/top/design_top_wrapper.v`）。

## hdmi/ — HDMI 1.4b 发送 IP 及配套件

| 文件 | 说明 |
|---|---|
| `hdmi_1_4b_transmitter_core_wrapper.enc.v` | HDMI 1.4b TX 核（加密交付）；720p60 参数在 `hdmi_tx.v` 内例化 |
| `hdmi_tx.v` | IP 配套封装：RGB/stream 视频输入、音频、EDID/DDC、TMDS 输出（本工程只用视频通路） |
| `hdmi_phy_warpper.v` | TMDS 物理输出包装（DEVICE="PH1P"） |
| `lane_lvds_10_1.v` | TMDS 10:1 并串转换 |
| `I2S_receiver.v` / `audio_arc_calculate.v` / `key_remove_shakes.v` | `hdmi_tx.v` 的配套子模块（音频/按键，本工程音视频输入置 0） |

来源：厂商工程 `user_source/hdl_source/`（与官方 IP 文档 APUG092《HDMI1.4b Transmitter》配套设计一致）。

## mipi_dphy_rx/ — MIPI D-PHY 接收 IP 及配套件（M3 起）

| 文件 | 说明 |
|---|---|
| `mipi_dphy_rx_ph1p_mipiio_wrapper.sv` | 顶层包装（SystemVerilog）：参数 `DPHY_RX_LOCATION` / `HS_EQUALIZER` / `HS_VGA_GAIN` / `LANE_NUM` / `BYTE_NUM`；对外接硬核 pad 与 fabric |
| `ph1p_mipiio_rx_wrapper.v` | PH1P MIPI IO 接收包装（1:8 模式；输出 `o_fabric_div4_8_clk` 字节时钟与 `hs_rx_valid/hs_rx_data`） |
| `byte_aligner.enc.v` / `byte_aligner_wrapper.enc.sv` | 字节对齐（加密交付） |
| `channel_aligner.enc.v` / `channel_aligner_wrapper.enc.sv` | 通道对齐（加密交付） |
| `hs_detect.enc.v` | HS 检测（加密交付） |

来源：厂商 SC520 720P lab（`ref/HX1P35A_Contest_202606/3_原理图/摄像头SC520CS.zip` 内
`lab_ex1_mipi_hdmi_SC520/lab_ex1_mipi_hdmi/user_source/hdl_source/mipi_dphy_rx/`），7 个文件与原件**逐字节一致**（md5 已核对）。

使用约定：

- 硬原语 `PH1P_LOGIC_DPHY_MIPI_RX` 由 TD 器件库提供，**不需要 `IP_FILE` 条目**；
  这些文件按普通源码列进 `.al`——`.v` 进 `<Verilog>` 段，`.sv` 进 `<System_Verilog>` 段。
- **实例名硬约束**：顶层必须例化为 `u_mipi_dphy_rx_ph1p_mipiio_wrapper`，
  `constraints/timing.sdc` 的 `rename_clock MIPI_RX_BYTE_CLK` 依赖完整层级
  `u_mipi_dphy_rx_ph1p_mipiio_wrapper/u_ph1p_mipiio_rx_wrapper/u_PH1P_LOGIC_DPHY_MIPI_RX.o_fabric_div4_8_clk`。
- 例化参数取 **SC520 720P lab 原值**：`DPHY_RX_LOCATION="DPHY0"`、`HS_EQUALIZER="3dB"`（该 lab 注明对应 828Mbps/lane）、
  `HS_VGA_GAIN="8dB"`、`LANE_NUM=2`、`BYTE_NUM=1`。SC500 lab 用的是 `HS_EQUALIZER="0dB"`（其链路速率更低），勿混用。

## sc520reg/ — SC520CS 原厂寄存器表（**数据件**）

| 文件 | 说明 |
|---|---|
| `uics520reg_720p60.v` | 165 条 `{16 位子地址, 8 位数据}` ROM（`REG_INDEX`→`REG_DATA`，`REG_SIZE=165`），表头注明 24MHz MCLK / 2-Lane RAW10 / Lane 828Mbps |

来源：厂商 SC520 版 lab 工程（`ref/HX1P35A_Contest_202606/3_原理图/摄像头SC520CS.zip` 内 `lab_ex1_mipi_hdmi_SC520/.../uics520_cfg/uics520reg_720p60.v`）。
本工程只把它当**数据表**使用（初始化寄存器序列属于传感器厂商给定的配置数据，非应用逻辑）；
按**半净室**约定整份拷贝、不改内容，加载时序由自研 `rtl/camera/cam_ctrl.v` 控制。

## 约定

- 本目录文件**不提交任何修改**；如需改行为，在 `rtl/` 中包一层或改顶层连接。
- 相关 IP 使用文档：`参考IP设计资料文档/APUG092_HDMI1.4b_Transmitter_V1.0.zip` 等（TD 安装目录 / 资料包内）。
