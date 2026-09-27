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
| M1 | 工程骨架 + HDMI 测试图案 | ✅ 彩条+移动方块稳定显示；LED 心跳；时序 0 违例 |
| M2 | 摄像头控制（上电/I²C/寄存器表） | ✅ 串口 `ID=EE4B ADR=36 W=A5 P=9E4B OK=1 E=0`（500ms 循环）；LED4=ID 校验通过 |
| M3 | MIPI 接收 + CSI/RAW10 解包 + 帧统计 | ✅ **上板验收通过**（2026-09-27 09:59）：串口 `MIPI HS=1 F=…(60fps) L=0720 W=01280 G=0320 ER=00 HW=2B06403B PL=0000 HC=0`；首轮发现 D-PHY 字节配对问题（原始流配对为 `(b0,b2),(b1,b3)…`），加 `lane_deint.v` 重排后通过 |
| M4 | 灰度直通（行缓存） | 🟡 实现 + 仿真完成，待上板：摄像头实时灰度画面（SW4=D11 拨上切换）；仿真 5 用例 10 项全过并抓出 2 个 RTL bug |
| M5 | DDR2 帧缓存 | 无撕裂、稳定 60fps |
| M6 | 彩色 ISP | 全彩实时画面 |
| M7 | 收尾 | 按键/模式、README/验证记录、CI lint 接入 |

### M2 实施要点（已完成编码 + 仿真验证）

- I²C 主机自研（开漏、100kHz、16 位子地址、读用 Sr+NACK+STOP）；从机地址先试 7'h36，整笔 NAK 再试 7'h10 ⇒ 不依赖模组 SID 跳线。
- 寄存器表用原厂 165 条（`ip/sc520reg/`，数据件），逐条写入后复读 ID 校验：`EE4B`(未加载) → `9E4B`(已加载)。
- 调试通道：板上 UART（USB-JTAG Cable 的 Type-C 双通道之一，115200 8N1；**H1=TXD / J1=RXD**）输出 `CAM ID=.. ADR=.. W=.. P=.. OK=.. E=..`，错误码 E 区分"无应答/写表 NAK/ID 不符"。
- 上板前验证：`tools/check_rtl.py`（静态）+ `tools/sim/i2c_sim.py`（协议）+ `tools/sim/cam_sim.py`（流程，含真实 ROM 与 SC520 模型）。

### M3 实施要点（2026-09-27）

- **复用**：`ip/mipi_dphy_rx/`（D-PHY 硬核 IP + 官方配套件，与厂商原件逐字节一致）；参数取 SC520 720P lab 原值
  （`HS_EQUALIZER="3dB"` 对应 828Mbps/lane）。硬核 pad 是器件专用脚，**不进 `pin.adc`**。
- **自研**：`rtl/mipi/lane_deint.v`（拍对重排）、`csi2_pkt_rx.v`（包解析）、`raw10_unpack.v`（解包）、
  `mipi_stats.v`（统计 + 跨域握手）、`rtl/camera/status_report.v`（两行串口上报）。
- **字节序（首轮上板踩到的坑）**：硬核每拍给出 lane0/lane1 各 1 字节，原始流配对为 `(b0,b2),(b1,b3),…`
  （实测 `HW=2B40063B`）；必须还原为 `A高,B高,A低,B低` 才是标准 CSI-2 次序，否则 WC 会被读成 0x4006
  这种荒谬值、负载永远消费不完。`lane_deint.v` 就是干这个的（包首重置配对相位）。
- **时钟**：`timing.sdc` 增加 `mipi_rx_ck_pad`(2.415ns) → `MIPI_RX_BYTE_CLK`（IP 内部 ÷4 字节时钟）+
  两域 `set_clock_groups -asynchronous`；跨域只有统计快照，用 req/ack 双相握手。
- **验证**：`tools/check_rtl.py` 0 错 0 警；`tools/sim/mipi_sim.py` 一帧 921600 像素逐点一致 + 错误注入 5 场景
  + 包头契约回归（`WC=1600` 原始流必须 = `2B40063B`）通过；仿真激励按硬件真实拍流格式构造。
- **风险**：见 README「M3 待上板确认的假设」（包间 valid 拉低 / 2-lane WC=1600 / 720 行 1280 列），
  失败均有对应 `ER` 错误位可定位。

### M4 实施要点与预期效果（灰度直通，行缓存版）

**预期效果（上板后屏幕上应该看到什么）**

1. **屏上出现摄像头实时画面，替换掉 M1 以来的彩条测试图案**：镜头对着什么，屏幕显示什么，
   移动镜头时画面跟手（实时 60fps，无卡顿）。
2. **是灰度（黑白）画面**：亮度 = RAW10 高 8 位（`>>2`）送 R=G=B。**彩色要等到 M6。**
3. **画面会看到细密的棋盘格纹理**（Bayer 阵列的 RGGB 相位）—— 这是**预期现象不是故障**，
   去马赛克在 M6。近看有轻微"网格感"属正常。
4. **亮度偏暗、对比度偏低**（黑电平未扣、无 gamma）—— 加一级常数黑电平扣除 + 简单拉伸后
   画面应当"正常可看"，但不追求好看（ISP 在 M6）。
5. **允许轻微撕裂/横向抖动**（画面里偶尔一条水平错位）：因为行缓存版没有帧缓存，
   摄像头与 HDMI 各自自由跑，行相位会缓慢漂移 → **无撕裂是 M5（DDR 帧缓存）的验收项**，M4 不要求。
6. **串口两行保持 M3 的达标状态不变**（`CAM OK=1`、`MIPI L=0720 W=01280 G=0320 ER=00`），
   屏幕内容不影响 MIPI 链路；LED 行为保持 M2。
7. **按键/开关（若做）：可在"摄像头画面 ↔ 彩条测试图案"之间切换** —— 测试图案是已知正确的基准，
   便于 A/B 判断问题出在采集侧还是显示侧。

**验收标准（可判定）**

- 屏幕出现实时灰度画面，镜头遮挡/移动有明显反应；
- 串口 MIPI 行仍为 `L=0720 W=01280 G=0320 ER=00`（M3 不退化）；
- 允许撕裂与偏暗；不允许全黑/全白/纯噪声/行错位整体错行。

**实现要点（自研）**

- 新增 `rtl/video/cam_linebuf.v`：**双行缓存 ping-pong**
  - 写侧（字节时钟域，103.5MHz 突发写入）：把 `raw10_unpack` 输出的像素按行内序号写入 BRAM，
    行首清零写地址；行突发约 7.8µs，远小于 23.1µs 行周期，ping-pong 有足够余量。
  - 读侧（HDMI 像素域 75MHz）：由 `hdmi_timing` 的 `de/x/y` 驱动，按 `x` 取当前行像素，
    输出 `{gray,gray,gray}` + `de_o`。跨时钟用双口 BRAM（TD 可推断）＋ 2 级同步器。
  - 行缓冲切换：写侧行首翻转 bank，经 2 级同步 + 握手指针交给读侧；读侧读取"上一行"，
    避免读到正在写的行（漂移时宁可丢一行，不撕裂整幅）。
- 新增 `rtl/video/video_mux.v`：把 `test_pattern` 与 `cam_linebuf` 的输出按开关二选一，
  接口与 `test_pattern` 完全一致（`data/de_o/vs_o`），顶层例化位置不变。
- 保留 M1/M2/M3 的一切调试通道（串口、LED、HDMI 测试图案），M4 失败时可直接切回图案定位。
- 仿真：新增 `tools/sim/linebuf_sim.py`（写侧突发 vs 读侧 75MHz 取数、bank 切换、行首对齐、
  漂移丢行）——本机无 iverilog，仍用逐拍 Python 行为级模型。

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
