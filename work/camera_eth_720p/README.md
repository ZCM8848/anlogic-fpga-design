# camera_eth_720p — SC520CS 720P@60 RAW10 千兆网口实时上行

> 独立子项目，与 `work/camera_hdmi_720p` 平级。目标：把 SC520CS MIPI 摄像头 720P@60 RAW10 Bayer
> 帧通过板载 YT8511 千兆 PHY（RGMII）实时 UDP 上传到上位机，PC 端解 demosaic → 显示 + 落盘，
> 用于加速视觉算法开发（CV 检测部分腾出来专门做视频通路）。

## 与 `camera_hdmi_720p` 的关系

- **复用**：MIPI D-PHY RX IP、CSI-2 解包、DDR2 IP、通用 PLL、SC520 寄存器表（仅作数据件）、camera 控制时序。
- **不复用**：HDMI TX 链路（如资源紧张则砍掉）、`cv_top`/`run_mem`/`overlay`/MCU CCL+跟踪代码。
- **新增**：RGMII MAC、MDIO 控制器、ARP/ICMP/UDP 协议栈、视频打包器、DDR2→网络 egress 桥。

详见 [`docs/plan.md`](docs/plan.md) 与 [`docs/M0_verification.md`](docs/M0_verification.md)。

## 关键约束（一句话）

- PHY：**YT8511 千兆，RGMII 接口，FPGA 侧理论上限 1 Gbps 全双工**。
- 像素：摄像头 RAW10 Bayer @ 720P@60 = **553 Mbps**，占 RGMII 线速 55%、UDP 净荷（≈940 Mbps）59%，余量充足。
- **RGB888（1327 Mbps）超线速，不可行**；本项目只送 RAW10 Bayer，上位机做 demosaic。
- UDP 丢包 → 直接丢帧，视觉算法迭代不在乎丢几帧。

## 目录结构

```
work/camera_eth_720p/
├── README.md                  # 本文件
├── docs/
│   ├── plan.md                # 详细拆解计划（M0~M5）
│   └── M0_verification.md     # M0 前置核实结果（IDDR/ODDR、bank、引脚占位）
├── constraints/
│   ├── pin.adc                # RGMII + 摄像头控制脚
│   └── timing.sdc             # 4 个异步时钟域（50M / 125M / RGMII_RXC / MIPI 字节时钟）
├── rtl/
│   ├── cam/                   # cam_raw10_rx.v（D-PHY→CSI→RAW10→FIFO→字节流）+ async_fifo.v
│   ├── camera/                # SC520CS I2C 初始化（uicfgcs520 / uics520reg_720p60 / uii2c …）
│   ├── isp/                   # csi_unpacket_2lane.v / raw10_unpacket_2lane.v
│   ├── eth/                   # eth_udp_tx / vid_udp_src / eth_rx_mac / arp_rx / dbg_uart_report
│   └── top/                   # eth_top.v
├── ip/
│   ├── pll/                   # C0=125MHz（以太网）/ C1=23.81MHz（摄像头 XCLK）
│   └── mipi_dphy_rx/          # D-PHY RX 硬核 IP（.sv 必须放 prj 的 <System_Verilog> 段）
└── host/
    ├── cam_monitor.py         # 串口状态行解析（N/T/C/S/V）
    ├── cam_stream_check.py    # 抓包统计：帧完整性 / 帧率 / 带宽
    └── raw10_pcap_decode.py   # 抓包 → RAW10 解包 → demosaic → PNG
```

## 数据通路

```
SC520CS (MIPI 2lane 828Mbps, RAW10 720p60)
  → D-PHY 硬核 (DPHY0)
  → csi_unpacket_2lane      (16bit 双 lane → 32bit CSI 字)
  → raw10_unpacket_2lane    (40bit = 4 × 10bit 像素)
  → async_fifo 41bit×1024   (写 = MIPI 字节时钟 ~103.5MHz，读 = 125MHz)
  → 展开器 40bit → 5 字节   (1 字节/周期，MIPI RAW10 打包)
  → vid_udp_src             (够 1460 字节就发，800 包 × 1440B = 1,152,000B = 一帧)
  → eth_udp_tx              (Ethernet + IPv4 + UDP + CRC32)
  → rgmii_tx_phy (HD_ODDR)
```

- 帧大小：1280×720×10bit = **1,152,000 B**，正好 **800 × 1440 B**，帧号天然对齐包边界。
- 不需要 DDR2 帧缓存：TX 能力 125 MB/s，摄像头平均 69 MB/s（1.8× 余量），
  8KB 级 FIFO 只用来吸收「每行 1600B / 7.7µs」的 MIPI 突发。
- 包边界会跨行，FIFO 按**连续字节流**处理，不做行对齐。

## 上位机用法（速查）

```powershell
python host/cam_monitor.py COM4            # 串口状态
python host/cam_view.py                    # 实时显示（推荐）
python host/cam_view.py --record out.mp4   # 实时 + 录像
& "D:\Program Files\Wireshark\dumpcap.exe" -i "\Device\NPF_{...}" -w cap.pcapng -a duration:10
python host/cam_stream_check.py cap.pcapng
python host/raw10_pcap_decode.py cap.pcapng frame.png
```

## 图像参数（实测，2026-10-27）

| 项 | 值 | 说明 |
|---|---|---|
| 曝光 | `1991`（= 995 行 ≈ 16.6ms） | 原厂表就是最大值，改动见 `cam_raw10_rx.v` 的 `CAM_AE_INIT` |
| 模拟增益 | `ag=48` → `0x3e09=0x08`（2x） | 补光灯下均值 ≈ 290/1023，高光不削顶 |
| 帧率 / 带宽 | 59.6 fps / 551.6 Mbps | 800 包 × 1440B，抓包 0 丢包 |
| 传感器 ID | `0xEE4B` | `V` 的 bit1 = 1 表示 ID 校验通过 |
| Bayer | BGGR | PC 端 `cv2.COLOR_BayerBG2BGR` |
| 列固定图案噪声 | ≈ 8.7 LSB @2x | 暗场高增益下会看到竖条纹，属传感器 FPN |

增益档位（`SC520GainTbl`：(16,48,80,112,144,176) → (1x,2x,4x,8x,16x,32x)），
补光灯下实测全帧均值：**179 / 292 / 503 / 834 / 993 / 1020**（8x 起饱和）。

> 如果换成别的光照条件，只改 `cam_raw10_rx.v` 里的 `CAM_AG_INIT` 一个常数即可。
> PC 端 `host/raw10_pcap_decode.py` 已内置灰世界 AWB + 自动拉伸，RAW 直出不会偏紫。

## 每帧元数据包（M3）

每帧先发 1 个 `pkt_idx = 0xFFFF` 的 UDP 包（与数据包同端口 4660、同 1440B 长度），
前 32 字节有效：

| 偏移 | 内容 |
|---|---|
| 0-1 | `A5 5A` 魔数（数据包是 `AA 55`） |
| 2-3 | frame_id |
| 4-5 | 曝光（半行，当前 1991） |
| 6-7 | 模拟增益档位（当前 48 = 2x） |
| 8-9 | 传感器 ID（0xEE4B） |
| 10 | 状态 [0]=cfg_done [1]=sensor_ok [2]=fifo_ovf [3]=lane_err |
| 11 | 版本 = 1 |
| 12-23 | 上一完整传感器帧的 B/G/R 累加和（各 32bit，含黑电平） |
| 24-27 | 总像素数 0x000E1000 |
| 28-31 | `5A 5A A5 A5` |

FPGA 在 125MHz 域按 sensor 帧统计 B/G/R（偶行 P0/P2=B、P1/P3=G；奇行 P0/P2=G、P1/P3=R），
PC 端 `awb_gains_from_meta()` 扣黑电平后算灰世界增益 —— 这样每帧 AWB 用的是
**与传感器帧对齐的统计**，比单帧现算更稳。

## 上位机工具

| 脚本 | 用途 |
|---|---|
| `cam_monitor.py COM4` | 串口状态（N/T/C/S/V），带帧率增量 |
| `cam_stream_check.py cap.pcapng` | 帧完整性 / 帧率 / 带宽 |
| `raw10_pcap_decode.py cap.pcapng out.png` | 解一帧 → AWB（优先用元数据）→ PNG |
| `cam_view.py` | **实时显示**：UDP 4660 → AWB → 列噪声校正 → 双边降噪 → 窗口；`s` 存图，`r` 录像 |
| `make_video.py cap.pcapng out.mp4` | 抓包 → mp4（AWB/列校正/拉伸全片固定，不闪烁） |
| `cam_gain_scan.py` / `cam_frame_grab.py` / `cam_phase_analysis.py` | 调试：按帧统计亮度 / 按帧号抓图 / 分档对比 |

## 当前状态

- **M0 ✅ 完成**（2026-10-26）：核实 PH1P35 有 `PH1P_LOGIC_HD_IDDR/HD_ODDR` 原语 + 15 个 RGMII 引脚全部能在 LVCMOS33 下综合/布局/bitgen（0 FEP）+ 厘清 RXC_DV 歧义（**N8=RX_DV，V2=RX_CLK**，docx 漏列 V2）。详见 [`docs/M0_verification.md`](docs/M0_verification.md)。
- **M1 ✅ 完成**（2026-10-27）：RGMII TX/RX + IPv4/UDP 全部打通。eth_smoke 实测 146,536 包 0 错、60.3fps、581 Mbps；端口到本项目后复测 99,777 包 0 错。ARP 学习到 PC MAC。
- **M2 ✅ 完成**（2026-10-27，上板验证）：SC520CS → D-PHY → CSI-2 → RAW10 → 异步 FIFO → UDP 全链路打通。
  实测 **59.5 fps / 551.5 Mbps / 8.08s 抓包 482 帧（480 完整，2 帧是抓包首尾边界）帧号 0 断点**；
  串口 `N/T/C/S/V` 正常（`C≈T≈60/s`、`S=EE4B`、`V=B` 无 FIFO 溢出）。
  构建：LUT 1122 / REG 1222 / ERAM 2 / PLL 1，Setup WNS +1.463ns（0 违例）。
  RAW10 打包顺序已用 4 像素全排列验证（`(0,1,2,3)` 最优）；图像参数见上表。
- **M3 ⏳ 待开工**：每帧一个元数据包（AWB 增益 + 曝光），PC 端复现 FPGA 色彩；
  以及 UDP 控制通道（在线调增益/曝光，免重新烧录）。

