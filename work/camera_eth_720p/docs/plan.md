# 详细拆解计划：720P@60 RAW10 Bayer 千兆网口实时上行

> 子项目：`work/camera_eth_720p`
> 决策定稿：RAW10 Bayer 透传 + UDP 丢帧模型
> 来源：硬件能力评估（见同仓 docs/hardware/HW_HX1P35A_BOARD.md §15、HW_SC520CS.md、HW_PH1P35.md）

## 1. 数据流总览

```
SC520CS ─MIPI 2-lane 828Mbps─→ D-PHY RX(IP) ─→ lane_deint ─→ csi2_pkt_rx
                                                                  │
                                                                  │ RAW10 长包载荷 1600B/line
                                                                  ▼
                                                          [新增] tap_raw10
                                                                  │  ~553 Mbps 突发(行有效期)
                                                                  ▼
                                                          [新增] video_in_net (写)
                                                                  │
                                                                  ▼
                                              ┌─────── DDR2 帧缓冲 (ping-pong) ──────┐
                                              │       (现有 IP，新增第2个写口/读口)     │
                                              └────────────────────────────────────────┘
                                                                  │  ~553 Mbps 平滑
                                                                  ▼
                                                          [新增] video_out_net (读)
                                                                  │  66.67M DDR 域
                                                                  ▼
                                                          [新增] net_packetizer
                                                                  │  帧号+块号+TS+载荷
                                                                  ▼
                                                          [新增] udp_tx_lite
                                                                  │
                                                                  ▼
                                                          [新增] rgmii_mac (TX主, RX收ARP)
                                                                  │  125M 8bit GMII → 4bit DDR RGMII
                                                                  ▼
                                              [新增] mdio_ctrl ──→ YT8511 PHY ── 1G UTP ── PC
                                                                                          │
                                                                                          ▼
                                                                                  Python: recv→reorder→
                                                                                  cv2.demosaic→imshow+落盘
```

### 速率对账

- 摄像头 RAW10 净荷：1280×720×60×10/8 = **69.12 MB/s = 553 Mbps**
- RGMII 线速：1000 Mbps；UDP 净荷 ≈ 940 Mbps
- 占用率：553/940 ≈ **59%**，余量充足
- DDR2 带宽：533 Mbps×128bit = 6.4 GB/s ≫ 写 553 + 读 553 Mbps，无瓶颈

## 2. FPGA 侧模块拆解（按工作量+依赖序）

### M1 — PHY 起来 + RGMII MAC 自环（基础砖）

> ## ✅ M1 已完成（2026-10-27），但验收标准要改
>
> **MDIO 是死路，不要做**：本板 YT8511 靠上电 strap + 自协商工作，
> 实测 MDIO 读不到 ACK（PHYAD 0..31、MDC 1/2.5 MHz、两种极性全试过）。
> 厂商例程同样不用 MDIO。**M1 验收改为「PC 端能抓到正确的 ARP 请求」**。
>
> 已跑通的实现见 **`work/eth_smoke/`**（独立工程，PC `arp -a` 已能正确解析）。
> 关键结论全部记录在 **`docs/hardware/HW_ETH_RGMII.md`**，要点：
>
> | 项 | 结论 |
> |---|---|
> | PLL 125 MHz | `REFCLK_DIV=2, FBCLK_DIV=5, CLKC0_DIV=12`（**只改 CLKC0_DIV 无效**） |
> | ODDR 语义 | `d0`=上升沿、`d1`=下降沿；`rst` 高有效 |
> | TX_CTL | 下降沿发 `TX_EN XOR TX_ER` |
> | GTX_CLK | 0° + `OUTDEL=2`（PHY 内部延迟只有 0.75~1.25ns，`TskewR` 要求 ≥1ns） |
> | 前导码 | 正好 `7×0x55 + 0xD5`（注意寄存器一拍延迟） |
> | RX_CLK | **V3**（不是 V2） |
> | FCS | 固定帧预计算写死；动态帧用组合逻辑，**不要用 `initial` 初始化查找表** |

| 模块 | 文件 | 资源估算 | 关键技术点 |
|---|---|---|---|
| ~~`mdio_ctrl.v`~~ | ~~`rtl/eth/mdio_ctrl.v`~~ | — | ❌ **不需要**（PHY 靠 strap，MDIO 实测无 ACK） |
| `rgmii_mac.v`（TX+RX） | `rtl/eth/rgmii_mac.v` | ~2000 LUT, 4 BRAM | TX：GMII 8bit@125M → 4bit DDR；插 preamble/SFD/IFG；CRC32。RX：4bit DDR → GMII 8bit，仅 ARP/ICMP 路径要，可简化 |
| `rgmii_iddr_oddrr.v`（或 PLL 相移方案） | `rtl/eth/rgmii_ddr.v` | — | ✅ 已确认 PH1P35 有 HD_ODDR/HD_IDDR；**必须用 HD 变体**（普通变体会 SYN-8228） |
| `phy_rst.v` | `rtl/eth/phy_rst.v` | ~50 LUT | RESET_N 上电序列，≥1ms 低 + 等自协商 |

**M1 验收（修正后）**：PC 端 `arp -a` 出现 FPGA 的 IP/MAC，Wireshark 帧逐字节正确。✅ 已达成。

### M2 — ARP + ICMP + 最小 UDP TX（能让 ping 通 + 发测试包）

| 模块 | 文件 | 资源 | 说明 |
|---|---|---|---|
| `arp_responder.v` | `rtl/eth/arp.v` | ~300 LUT | 缓存最近 8 个 requester MAC；收到 ARP 请求回填自己 MAC |
| `icmp_echo.v` | `rtl/eth/icmp.v` | ~200 LUT | 仅 echo reply，回 data 原样 |
| `udp_tx_lite.v` | `rtl/eth/udp_tx.v` | ~600 LUT | 给定 dst_ip/dst_port + data stream → 输出完整 UDP/IP/Eth 帧；IP checksum 预算或在线 1's comp |
| `ip_config` | 寄存器/拨码开关 | — | 本机 MAC = 固定；本机 IP = `192.168.1.100`（可经 SW1/SW2 调末字节）；目标 IP/Port = 上位机，固化或经 MCU 配置 |

**M2 验收**：上位机 `ping 192.168.1.100` 通；`tcpdump` 能看到固定的测试 UDP 包（如每秒一个 100B 包）。

### M3 — CSI-2 RAW10 tap + DDR2 弹性缓冲 + 打包器（数据真正上来）

| 模块 | 文件 | 资源 | 说明 |
|---|---|---|---|
| `tap_raw10.v` | `rtl/net/tap_raw10.v` | ~300 LUT | 接 `csi2_pkt_rx` 长包有效信号，把每行 1600B 载荷+行号+帧号送进 video_in_net；行间 HBLANK 期不发 |
| `video_in_net.v` | `rtl/net/video_in_net.v` | ~800 LUT, 2 BRAM | 复用现有 `video_in` 模式：跨域 103.5M→66.67M；按行写 DDR2 ping-pong（帧 N/帧 N-1） |
| `video_out_net.v` | `rtl/net/video_out_net.v` | ~800 LUT, 2 BRAM | 从 DDR2 读帧 N-1，跨域到 125M RGMII 域，按 UDP MTU 分块（载荷 1400B，对齐到完整行边界） |
| `net_packetizer.v` | `rtl/net/pkt.v` | ~1500 LUT, 2 BRAM | 每包：`magic(4B) + frame_id(4B) + chunk_id(2B) + total_chunks(2B) + ts(4B) + line_offset(2B) + payload(≤1400B)` |

**每帧包数**：1280×10/8×720 = 1.152 MB / 1400B ≈ **838 包/帧 × 60fps ≈ 50280 包/秒**。

**M3 验收**：上位机能看到持续的 UDP 流；按 chunk_id 重组能凑出完整 720P 帧（虽然此时还没解 demosaic）。

### M4 — 上位机 Python 接收 + demosaic + 显示 + 落盘

伪码：

```python
sock = socket.socket(AF_INET, SOCK_DGRAM)
sock.setsockopt(SOL_SOCKET, SO_RCVBUF, 64MB)
sock.bind(("0.0.0.0", 5000))
frame_buf = {}    # frame_id -> {expected: total, got: 0, chunks: {}}
while True:
    pkt, _ = sock.recvfrom(2048)
    parse magic/frame_id/chunk_id/total/line_off
    if frame_id not in frame_buf:
       frame_buf[frame_id] = {expected: total, got: 0, chunks: {}}
    buf[frame_id].chunks[chunk_id] = payload
    buf[frame_id].got += 1
    if got == total:
       assemble 1600×720 RAW10 packed
       raw = unpack_to_16bit_array()       # 4px/5B → 4×16bit
       bgr = cv2.cvtColor(raw, cv2.COLOR_BayerBG2BGR)
       cv2.imshow("cam", bgr); cv2.VideoWriter.write(bgr)
       del frame_buf[frame_id]
       # 丢帧检测：如果 frame_buf 拖留 N>2 帧未完成 → 丢弃旧帧
```

**M4 验收**：实时 720P 画面、`output.avi` 落盘正常；丢帧率 < 5% 时人眼无感。

### M5 — 集成 + 时序收敛 + 吞吐验证

| 工作 | 说明 |
|---|---|
| 删除 `cv_top`、`run_mem`、`overlay`、MCU CCL/跟踪代码 | 释放约 2000~3000 LUT |
| 是否保留 HDMI | 推荐**先砍掉 HDMI**（既然视频走网口给上位机了，HDMI 是冗余）；保留的话 video_out 要双输出，资源更紧 |
| 跨域 reset_ctrl 加 125M_rgmii 域 | 沿用现有 PLL lock 同步框架 |
| 时序收敛 | RGMII 125M + DDR2 533M + MIPI 103.5M 三域 |
| 吞吐验证 | 上位机统计：实际收到的帧率（目标 ≥ 55fps）、丢帧率（目标 < 5%）、单帧完整性 |

## 3. 关键风险与未决项（M0 必须先答清的）

| # | 风险 | 影响 | 缓解 |
|---|---|---|---|
| 1 | **PH1P35 是否有 IDDR/ODDR 原语** | 决定 RGMII DDR 实现方式 | M0 开工前先用 TD primitive library 查；无则用 PLL 0°/90°/180°/270° 四相时钟采样 |
| 2 | **RGMII 14 引脚是否都在 3.3V bank** | 不能混合 VCCIO | V9/U10/V8/U9/N9/T7/T8/T9/R11/P11/T10/R12/R10/N8 在 `pin.adc` 加进去后查 bank 报告 |
| 3 | **RGMII TX clock-data skew** | 链路不通 / 误码高 | 启用 PHY 内部 TX delay（写 0x9 bit[0]=1）；或 FPGA PLL 相位偏移 1.5~2ns |
| 4 | **DDR2 第二读口对 video_in(写) 的公平性** | 帧率掉 / 行断裂 | 现有 DDR2 是单 AXI 口，需要 round-robin 仲裁 |
| 5 | **丢帧率 vs UDP 包速率** | 50k 包/秒对嵌入式自研 MAC 不轻 | M5 用 FPGA 内置帧计数器 + 上位机丢包率双向对账 |
| 6 | **本机/目标 IP 配置** | 不配好就完全不通 | SW1/SW2 拨码切本机 IP 末字节；目标 IP/Port 编进 bit |
| 7 | **MCU 角色定位** | 复用还是砍 | 推荐：保留 MCU 做 MDIO init + ARP/ICMP 慢路径 + 状态 UART；视频快路径纯 fabric |

## 4. 资源预算（CV 移除后）

| 资源 | 总量 | 现有占用（含 CV） | 移除 CV 后 | 新增 ETH 链路占用 | 净占用 | 富余 |
|---|---|---|---|---|---|---|
| LUT4 | 38189 | ~32400（85%） | ~29400 | ~6000 | ~35400 | ~2800 (7%) |
| DFF | 42432 | ~同比例 | — | ~4000 | — | 紧 |
| ERAM | 108 块 | 5 块（早期）/更多 | — | ~12 块（FIFO+线缓冲） | — | OK |
| DSP | 40 | ISP+CV 占用 | 移除 CV 省 ~8 | 0 | — | 富 |
| PLL | 6 | 2（系统+MCU） | — | **+1（125M RGMII 域）** | 3/6 | OK |
| IO | — | 13 | — | +13（RGMII 14 根，含 RESET_N） | — | 需查 bank |

→ **LUT 净占用约 92%，比 CV 时代略紧但可行**；若时序不收敛，**优先砍 HDMI**（节省 ~1500 LUT + 1 PLL + 4 IO）。

## 5. 推荐实施顺序与里程碑

| 里程碑 | 工作内容 | 验收信号 | 预估工期 |
|---|---|---|---|
| **M0** 前置核实 | ① 查 TD 是否有 IDDR/ODDR；② 查 RGMII 14 引脚 bank；③ 在 `pin.adc` 占位添加 RGMII 引脚（不实现） | TD 报告无 bank 冲突 | 0.5 天 |
| **M1** PHY 起来 | mdio_ctrl + rgmii_mac 自环 | ping 不通但 PHY 链路灯亮、MDIO 读出 ID | 1 周 |
| **M2** ARP+ICMP+UDP TX | 协议栈慢路径走 MCU，UDP TX 走 fabric | `ping` 通 + tcpdump 见测试 UDP 包 | 1 周 |
| **M3** 视频通路 | tap_raw10 + video_in/out_net + packetizer | 上位机能收到完整 720P 帧（无 demosaic） | 1.5 周 |
| **M4** 上位机 | Python recv + demosaic + imshow + 落盘 | 实时画面 + AVI 落盘正常 | 3 天 |
| **M5** 集成 + 优化 | 砍 CV、砍 HDMI（如需）、时序收敛、吞吐调优 | 稳定 60fps、丢帧<5% | 1 周 |

**总工期估**：5.5~6 周（全职单人）。
