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

## 目录结构（规划）

```
work/camera_eth_720p/
├── README.md                  # 本文件
├── docs/
│   ├── plan.md                 # 详细拆解计划（M0~M5）
│   └── M0_verification.md      # M0 前置核实结果（IDDR/ODDR、bank、引脚占位）
├── constraints/
│   └── pin.adc                 # 待 M0 通过后写入 RGMII 引脚占位
├── rtl/
│   ├── eth/                    # rgmii_mac / mdio / arp / icmp / udp_tx
│   ├── net/                    # tap_raw10 / video_in_net / video_out_net / net_packetizer
│   └── top/                    # design_top_wrapper（新顶层，不含 HDMI/CV）
└── host/
    └── host_recv.py            # 上位机 UDP 接收 + demosaic + imshow + 落盘
```

## 当前状态

- **M0 ✅ 完成**（2026-10-26）：核实 PH1P35 有 `PH1P_LOGIC_HD_IDDR/HD_ODDR` 原语 + 15 个 RGMII 引脚全部能在 LVCMOS33 下综合/布局/bitgen（0 FEP）+ 厘清 RXC_DV 歧义（**N8=RX_DV，V2=RX_CLK**，docx 漏列 V2）。详见 [`docs/M0_verification.md`](docs/M0_verification.md)。
- **M1 ⏳ 待开工**：MDIO + RGMII MAC 自环。
