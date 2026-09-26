# camera_hdmi_720p 实施计划

目标：在 `work/camera_hdmi_720p/` 下（半净室）实现 SC500CS/SC520CS MIPI 摄像头 → HDMI 1280×720@60fps 的完整显示链路，
结构清晰、可继续演进（算法/按键/OSD），不复制参考工程胶水代码。

## 一、调研结论（据厂商资料）

### 链路与器件

- 芯片：PH1P35MDG324（安路 PH1P 系列）；板卡：HX1P35A；工具：TD 6.2.1。
- 摄像头：SC500CS / SC520CS，MIPI CSI-2 2-lane RAW10，HD 模式 1280×720@60（内部 2×2 binning + crop）。
- 板级：50MHz 有源晶振（C4）→ PLL；HDMI-A 直连 FPGA（TMDS33）；MIPI 42P FPC 经 TXS0104E 电平转换；
  DDR2（IP 参数：tCK=1876ps→533MHz、16bit、Row13/Col10/BA2）。

### 传感器（SC520CS）

- I²C：上电默认 7 位地址 **0x36**（SID 低）；备用 0x10。
- Sensor ID 寄存器 0x3107/0x3108：上电未加载 setting = `ee4b`，初始化完成后 = `9e4b`（用于 M2 验证）。
- 上电时序：T4 ≥ 1ms（XSHUTDN 释放后）、T5 ≥ 5ms（再发 I²C/XCLK 数据）。
- 关键寄存器：软复位 0x0103[0]、睡眠 0x0100[0]、lane 数 0x3018、RAW10 0x3031、
  输出窗口 {0x3208,09}/{0x320a,0b}/{0x3210–13}、VTS {0x320e,0x320f}、曝光/增益 0x3e00~0x3e09、Group hold 0x3812。
- 传感器自带测试图案 0x4501 可辅助验证"传感器→MIPI→ISP"链路。

### 厂商 SC520 720P 参考（仅作配置事实参考）

- MIPI RX：`DPHY0`、2-lane、EQ=3dB、VGA=8dB、delay=0、invert=0；寄存器表注释"828Mbps/lane"。
- MIPI 时钟约束：`create_clock` 于 `IO_rx_clk_pad_p`，周期 2.415ns（=414MHz 时钟 → 828Mbps DDR）。
- 约束要点：`sys_clk_50m` 20ns + `derive_clocks` + PLL 时钟重命名 +（MIPI/DDR/系统）异步时钟组。
- DPHY 输出字节时钟：`o_fabric_div4_8_clk`。

## 二、架构

```
S_50m 域:  I_sys_clk → PLL(复用) → 100M / 23.809524M / 75M / 375M
─────────────── 像素域 (75MHz) ───────────────
hdmi_timing(自研) → test_pattern(自研) ─┬→ hdmi_tx(复用) → hdmi_phy(复用) → TMDS 4 对
                                        └→ (M4 起) 帧缓存读出 → ISP(自研)
─────────────── M3 起 ───────────────
SC520CS → MIPI RX(IP) → csi2_unpack/MIPI 统计(自研) → raw10_unpack(自研)
        → (M4)行缓存/(M5)DDR2 帧缓存(自研控制) → isp(自研) → 像素域
camera 控制(自研 M2): 上电时序 + I²C 主机 + 寄存器表加载 + 状态机
```

## 三、里程碑与验收

| # | 内容 | 上板验收 |
|---|---|---|
| M1 | 工程骨架 + HDMI 测试图案 | 彩条+移动方块稳定显示；LED 心跳；时序 0 违例 |
| M2 | 摄像头控制（上电/I²C/寄存器表） | 读回 Sensor ID（ee4b→9e4b）；I²C 错误可观测 |
| M3 | MIPI 接收 + CSI/RAW10 解包 + 帧统计 | 状态码显示（HS/帧长/行数/lane 错误定位到级） |
| M4 | 灰度直通（行缓存） | 屏幕出现实时灰度画面 |
| M5 | DDR2 帧缓存 | 无撕裂、稳定 60fps |
| M6 | 彩色 ISP | 全彩实时画面 |
| M7 | 收尾 | 按键/模式、README/验证记录、CI lint 接入 |

## 四、风险与对策

1. **HDMI 75MHz off-spec（+1.01%）**：厂商验证可用；若显示器不兼容，备选调整 H/V 总数（如 1666×750 → 60.0Hz）或换屏。
2. **XCLK 24 vs 27MHz 矛盾**（模组图 27M / 厂商表 24M）：M2 先按厂商 23.809524MHz；M3 收不稳再试 24.000（VCO 1200，需改 PLL 配置）或 27M 方案。
3. **MIPI delay/invert**：厂商全填 0；若 M3 数据不稳，按 UG921/UG1316 做 per-lane delay 扫描（自研可控参数，加寄存器可调更佳）。
4. **DDR2 IP 参考时钟疑点**：IP 参数 `PLL0_REFCLK_FREQ=100.0` 但厂商接 50MHz `I_sys_clk`；厂商板上已验证可行，M5 实现时读全 wrapper 核对。
5. **时序收敛**：MIPI 828Mbps RX + DDR2 533MHz + TMDS 375MHz；沿用厂商约束与 IP 布局顺序。

## 五、参考资料（已读）

- `SC520CS-03_数据手册_V1.6.pdf`（全文）、`SC520CS_设计应用指南_V1.4_for-CSP.pdf`（15 页）、`SC520CS_V1.0.pdf`（模组原理图）
- `新HX1P35A开发板手册-HDL版2604.pdf`（关键章节）、`HX1P35B开发板引脚分配汇总.docx`（引脚表）、开发板原理图 10 页
- `DS1300_PH1P_Datasheet.pdf`（结构/外设）、参考 IP 文档：UG1316(PH1P MIPI)、UG921(DPHY-RX)、IPUG035(DDR)、
  APUG092(HDMI1.4b TX)、IPUG012(SoftFIFO)、APUG010/011(SDRAM)
- 厂商 SC520_720P 工程（仅取配置事实：时钟/约束/各 IP 例化参数）
