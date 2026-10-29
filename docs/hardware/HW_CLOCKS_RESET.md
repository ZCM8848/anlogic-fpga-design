# HW_CLOCKS_RESET — 时钟方案与复位策略

> 主要来源：`work/camera_hdmi_720p/ip/pll/PLL.v`、`ip/pll/PLL.xml`、`rtl/top/design_top_wrapper.v`、
> `constraints/timing.sdc`、`ip/README.md`、`docs/TECHNICAL_DETAILS.md`，以及 DS1300 数据手册。

## 1. 板级时钟源

| 源 | 频率 | FPGA 引脚 | 用途 |
|---|---|---|---|
| 有源晶振 | **50 MHz** | **C4**（`I_sys_clk`） | PLL 参考；直接接 PLL `refclk`，也直接接 DDR2 IP 的 `ref_clk` |
| LVDS 差分晶振 | **100 MHz**（SIT9121，LVDS 3.3 V） | L5 / K5（P/N） | DDR 备用参考（本项目未用） |

> DDR2 IP 参数文件里 `PLL0_REFCLK_FREQ = 100.0` 与"板上 50 MHz 直接接 ref_clk"的接法不一致，
> 属历史遗留；**按厂商三份 lab 的接法（50 MHz 直连）**即可（见 `ip/README.md`）。

## 2. PLL 配置（`ip/pll/`，厂商已验证配置，本项目未改）

### ⚠️ 频率公式（2026-10-27 上板实测确认，非常重要）

```
C0  = (FIN / REFCLK_DIV) × FBCLK_DIV          ← 输出频率由这两个参数决定
VCO = C0 × CLKC0_DIV                          ← CLKC0_DIV 只改 VCO，不改 C0！
Cn  = VCO / CLKCn_DIV  （相位 = CLKCn_CPHASE / CLKCn_DIV × 360°）
```

**踩过的坑**：想把 100 MHz 改成 125 MHz 时只把 `CLKC0_DIV` 15→12，
结果 VCO 从 1500 变成 1200，`C0 = 1200/12` 仍然是 **100 MHz** —— 频率纹丝不动。
正确做法是改 `REFCLK_DIV` / `FBCLK_DIV`：

| 目标 C0 | REFCLK_DIV | FBCLK_DIV | CLKC0_DIV（定 VCO） |
|---|---|---|---|
| 100 MHz | 1 | 2 | 15（VCO=1500） |
| **125 MHz** | **2** | **5** | **12（VCO=1500）** |

> 本板 50 MHz 参考下，`REFCLK_DIV=2, FBCLK_DIV=5` 才得到 125 MHz；
> VCO 保持 1500 MHz 时，`LPF_RES/LPF_CAP/ICP_CUR`（0/13/29）无需改动。

- 输入 `FIN = 50 MHz`，环路反馈 `FBCLK_DIV = 2` → 参考 100 MHz；
- **VCO = 1,500 MHz**。
- 顶层实例名必须是 **`u_pll`**（`timing.sdc` 的 `rename_clock` 依赖完整层次
  `u_pll/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[n]`）。

| 输出 | 频率 | 分频 | 用途 |
|---|---|---|---|
| C0 | **100.000 MHz** | DIV=15 | 系统逻辑（I²C、AE、UART、LED、SW 同步） |
| C1 | **23.809524 MHz** | DIV=63 | 摄像头 XCLK / I²C 配置域 |
| C4 | **75.000 MHz** | DIV=20 | HDMI 像素时钟 |
| C5 | **375.000 MHz** | DIV=4 | HDMI TMDS 串行（= 5 × 像素） |

> **75 MHz 说明**：720p60 标准像素时钟为 74.25 MHz，50 MHz 整数分频无法精确产生（74.25 = 50×297/200）；
> 厂商用 75.000 MHz（偏 **+1.01%**）并已验证可用。
> **23.809524 MHz 说明**：模组原理图标注"主机须提供 27 M"，而厂商寄存器表/RTL 按 24 MHz 设计；
> 实测 23.81 MHz 上板可用（在传感器 EXTCLK 6~40 MHz 范围内）。

## 3. 时钟域划分

| 时钟域 | 频率 | 来源 | 用途 |
|---|---|---|---|
| MIPI byte | **≈ 103.5 MHz** | D-PHY 恢复（`O_hs_rx_clk`，828 Mbps ÷ 8） | CSI 解包 / ISP / video_in 写侧 |
| 系统 | 100 MHz | PLL C0 | I²C 配置 / UART / LED / SW 同步 |
| 像素 | 75 MHz | PLL C4 | hdmi_timing / test_pattern / video_mux / hdmi_mixer / hdmi_tx |
| 串行 | 375 MHz | PLL C5 | HDMI TMDS 串行 |
| 摄像头 XCLK | 23.809524 MHz | PLL C1 | SC520CS 外部时钟（L3） |
| DDR 用户 | **≈ 66.67 MHz** | DDR2 IP 输出 `dhi_clk`（`O_ddr_clk`） | video_in 读 / video_out 写 / mc 桥 |

MIPI 与 DDR 均为 D-PHY/DDR 硬核专用时钟，经 IP 内部 PLL 生成。

## 4. DDR2 内存时钟（集成存储接口）

来源：`ip/ddr2/ddr2/.params_ddr2.txt`、`ip/README.md`。

| 参数 | 值 |
|---|---|
| 类型 | **DDR2**（集成存储接口） |
| 速率 | **DDR2-1066**（`PH1P_DDR_SPEED = 1066`，`tCK = 1876 ps`） |
| 存储时钟 | **≈ 533.3 MHz**（`PH1P_ACTUAL_FREQ = 533.3`，对应 1066 MT/s） |
| 位宽 | DRAM 侧 **×16**（`DX_NUM=2`，`DQ_WIDTH=16`） |
| 控制器用户口 | **128-bit**（`MC_DATA_WIDTH=128`），地址宽 25（MC）/26（AXI） |
| 容量 | 512 Mb ×16 → **64 MB** |
| IO 电压 | **1.5 V**（`PH1P_IO_VOL=1.5`） |
| 主 BANK | **BANK11** |
| CL / CWL | 7 / 6 |
| 参考时钟 | 板上 50 MHz（C4）直连 `ref_clk` |
| 板级延时档 | `PH1P_DELAY_B0/B1_AC/DQ = 110`（`ph1p_ddrphy_board_delay.vh`） |

- 用户侧逻辑一律用 IP 输出的 **`dhi_clk`** 作时钟、`sys_rst_n` 作复位。
- IP 自带 `.adc/.sdc` 经 XML fileSet 自动引入，**不手写进 `.al` 的 ADC/SDC 段**；DDR 引脚不进 `pin.adc`。

## 5. 复位策略

来源：`rtl/common/reset_ctrl.v`、`docs/TECHNICAL_DETAILS.md`。

| 域 | 复位模块 | 触发/来源 | 说明 |
|---|---|---|---|
| 100M 系统 | `reset_ctrl u_rst_100m` | PLL lock | 系统逻辑 / UART / LED |
| 像素 75M | `reset_ctrl u_rst_pix` | PLL lock | hdmi_timing / test_pattern / video_mux / hdmi_mixer |
| 24M | `reset_ctrl u_rst_24m` | PLL lock | uicfgcs520 / ae_set |
| DDR | `reset_ctrl u_rst_ddr` | PLL lock **& DDR 校准完成** | video_in / video_out / mc 桥 |
| MIPI 字节域 | 2FF 同步链 | 100M 域复位 → `O_hs_rx_clk` | CSI 解包 / ISP；HS 停止时该域冻结 |
| HDMI IP | 异步 `~pll_lock` | PLL lock | 跨 75/375 MHz 两域，避免复位分发定时违例 |
| video_in / video_out | `S_rst_n`（= PLL lock，异步） | PLL lock | 跨多域最稳，对齐厂商参考工程 |

- **`reset_ctrl`（自研）**：以 PLL lock 为触发，**异步拉低、同步释放**（本域 16 拍计数），
  保证各域在稳定时钟下才开始工作。
- **HDMI IP 复位用异步 `~S_pll_lock`**：IP 内部跨 75/375 MHz 两域，若用单域同步复位驱动，
  TD 会把复位分发路径当定时路径分析并违例（实测 −0.365 ns）；无发起时钟的 lock 不参与分析。
- **字节域 `S_rst_n_rx`**：100 MHz 域复位经 2FF 同步到 `O_hs_rx_clk` 再释放；
  HS 流量停止时该域逻辑冻结（统计保持，串口显示 `HS=0`），便于区分"链路没通"与"解析错"。
- 系统复位**不使用**厂商示例里的 `I_rst_n`（R10 = 以太网 TXEN），由 PLL lock 同步产生。

## 6. 时序约束（`constraints/timing.sdc`）

- `create_clock`：
  - `sys_clk_50m`：**20 ns**（50 MHz，C4）
  - `mipi_rx_ck_pad`：**2.415 ns**（828 Mbps/lane）
- `derive_clocks` + PLL 输出 `rename_clock`：`pll_clk_100m` / `pll_clk_24m` /
  `HDMI_PIXEL_CLK` / `HDMI_SERIAL_CLK` / `MIPI_RX_BYTE_CLK`。
- **3 组异步时钟组**（`set_clock_groups -asynchronous`）：MIPI / 系统+HDMI / DDR。
- MIPI / DDR 的 pad 不进 `pin.adc`（硬核 pad）。

## 7. 已知时序状况（供参考）

- 当前实现（M7 bit）**phy final Setup WNS −1.83 ns / Hold +20 ps**，违例集中在
  `MIPI_RX_BYTE_CLK`（≈103.5 MHz）域的 ISP/`cv_top` 组合路径；
  彩条与 OSD 模式数据路径干净，仅 edge 模式 / CV 叠加路径有潜在画面瑕疵。
- 详见 `work/camera_hdmi_720p/docs/TECHNICAL_DETAILS.md` §十。
