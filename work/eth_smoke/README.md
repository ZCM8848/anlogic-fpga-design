# eth_smoke — 以太网 TX 通断测试（独立工程）

用**最小、可验证**的设计证明 RGMII TX 通路：`FPGA → YT8511 → 网线 → PC`。
每 200ms 发一个 128 字节的 ARP 请求帧。

## 验证状态：✅ TX + RX 均已通过（2026-10-27）

### TX（FPGA → PC）

```
tshark 抓包结果：
  frame 1  0.000000000  124 bytes  0x0806
  frame 2  0.199919500  124 bytes  0x0806
  frame 3  0.399970800  124 bytes  0x0806      ← 严格 200ms = 125MHz
  ...
  Ethernet II, Src: 01:23:45:67:89:ab, Dst: Broadcast
  Type: ARP (0x0806)
  ARP: request, Sender 192.168.1.200, Target 192.168.1.100
  填充 A0 A1 A2 ... F0 F1 逐字节正确

PC 端 arp -a：
  192.168.1.200   01-23-45-67-89-ab   动态
```

### RX（PC → FPGA）

PC 每 200ms 回一个 ARP reply（`a8:2b:dd:29:a4:ce → 01:23:45:67:89:ab`），
FPGA 解析后通过 COM4 每秒打印：

```
N=00C7 A=0032 M=A82BDD29A4CE
N=00D2 A=0037 M=A82BDD29A4CE
N=00D9 A=003C M=A82BDD29A4CE
```

- `N` = 收到的帧总数（含 PC 的 mDNS/LLMNR 广播）
- `A` = ARP reply 命中次数（每 5 秒 +25，即 5 帧/秒，与 200ms 请求严格对应）
- `M` = 学到的对端 MAC = `A8:2B:DD:29:A4:CE` ✅ 与 Wireshark 抓到的一致



## 为什么另建工程

`work/camera_eth_720p` 的 M1 版本发不出帧，后来定位到 3 个**致命** bug（都不是硬件问题）：

| # | Bug | 证据 | 后果 |
|---|-----|------|------|
| 1 | **ODDR 的 d0/d1 用反了** | TD 原语模板 `template/verilog/Device-Primitive/PH1P/I,O/ph1p_i_o.v` 明确写着：`.d0 // 1 bit posedge input data`、`.d1 // 1 bit negedge input data`、`.rst // Reset, high active`。厂商 `rgmii_interface.v` 也把低 nibble 接 `.d0`。旧代码 `.d1(gmii_txd[i])` `.d0(gmii_txd[i+4])` | ① 高低 nibble 发反 → 每个字节变成 `{b[3:0],b[7:4]}`；② **TX_EN 落到下降沿** → PHY 在上升沿看不到有效 TX_EN，整帧不发 |
| 2 | **CRC 查找表没有驱动** | 综合日志 `HDL-5314 WARNING: net 'crc_lut' does not have a driver in arp_tx.v(97)`（`initial` 块里的数组初始化没有被推断成 ROM） | FCS 全错 → 网卡按 CRC 错误丢弃 |
| 3 | **帧太短（runt）** | 42 字节 payload + 4 FCS = 46 字节，小于以太网最小 60 字节（DA..FCS） | PHY/网卡丢弃 |
| 4 | **TX_CTL 下降沿编码错** | RGMII 规定下降沿是 `TX_EN XOR TX_ER`（厂商 `rgmii_tx_ctl_int = gmii_tx_en ^ gmii_tx_er`）。旧/新代码下降沿直接送 `TX_ER`=0 | PHY 解出 `TX_ER = EN xor 0 = 1` → **整帧当 error frame 丢弃** |
| 5 | **PLL 频率一直只有 100MHz** | 该 PLL 的频率关系是 `C0 = (FIN / REFCLK_DIV) × FBCLK_DIV`，`VCO = C0 × CLKC0_DIV`。原配置 `50/1×2 = 100MHz`。把 `CLKC0_DIV` 从 15 改成 12 只把 VCO 从 1500 变成 1200，**C0 仍是 100MHz** | GTX_CLK 只有 100MHz，PHY 按 125MHz 发 → TX FIFO 每 ~90 字节回卷一次 → 帧内出现 20 字节重复，FCS 失效 |
| 6 | RX_CLK 引脚写错（V2 → V3） | 原理图球名↔网络名严格对齐：`V3(561.8) → ETHPHY_RX_CLK(564.4)`，`V2(566.9) → GPIOA0(569.0)` | 收不到 RX_CLK（LED3 不亮） |

**最终 PLL 配置**（关键）：

```
REFCLK_DIV = 2, FBCLK_DIV = 5   →  C0 = 50/2 × 5 = 125MHz
CLKC0_DIV  = 12                 →  VCO = 125 × 12 = 1500MHz
CLKC1_DIV  = 12, CPHASE = 3     →  C1 = 125MHz, 90°
```

另外 YT8511 的 RGMII 时序要求 `TskewR ≥ 1ns`，而 PHY 内部 `Tx_clk_delay_sel` 默认只有 0.75~1.25ns，
所以 GTX_CLK 引脚加了 `OUTDEL = 2`（TD 合法范围 1-4）把采样点推进数据眼中心。

本工程把上面 6 处全部改掉：

- `rgmii_tx_phy.v` 按厂商映射：`d0`（上升沿）= 低 nibble / TX_EN，`d1`（下降沿）= 高 nibble / TX_EN^TX_ER
- FCS 用 PC 端 `zlib.crc32` **预计算写死**（不用 CRC 逻辑，避开 `initial` 数组不被综合的坑）
- 帧 128 字节（124 数据 + 4 FCS），并带自描述填充 `A0 A1 … F1` 便于抓包核对
- PLL 按 `C0=(FIN/REFCLK_DIV)×FBCLK_DIV` 重算，得到真正的 125 MHz
- RX_CLK 引脚改到 V3
- GTX_CLK 加 `OUTDEL=2`

## 关于「官方例程」

本板的官方以太网例程是 `ref/HX1P35A_Contest_202606/2_Example/33_ethernet_udp_led`，
但随包发布的 `uisrc/` 目录里**只剩 NetAssist.exe，源码全部缺失**（只剩 `fpga_prj.al` 和一堆编译日志）。
EG4 版 `32_Ethernet_test` 有完整 RTL，但用的是 EG4S20 器件 + TEMAC 硬核 + 加密 UDP 协议栈，
不能直接搬到 PH1P35。

所以本工程采用「按官方 RGMII 收发结构重写 + 官方引脚表」的方式，
关键映射直接照抄厂商 `rgmii_interface.v`（这是已经量产的代码）。

## 帧内容（128 字节 = 124 数据 + 4 FCS）

```
DA   = FF FF FF FF FF FF          (广播)
SA   = 01 23 45 67 89 AB
Type = 08 06                       (ARP)
ARP  = 0001 0800 06 04 0001
       SHA 01:23:45:67:89:AB  SPA 192.168.1.200
       THA 00:00:00:00:00:00  TPA 192.168.1.100   ← 问 PC 的 MAC
Pad  = A0 A1 A2 ... F0 F1          (82 字节，自描述，便于抓包核对错位)
FCS  = F1 D4 3F 01
```

PC 收到后会回 ARP reply，`arp -a` 里就会出现 `192.168.1.200`。

FCS 自检：

```
crc = zlib.crc32(前 124 字节) = 0x013FD4F1  →  线序 F1 D4 3F 01
zlib.crc32(整帧 128 字节)     = 0x2144DF1C  ← 以太网 CRC 余数魔数，PASS
```


## LED

| LED | 引脚 | 含义 |
|-----|------|------|
| LED1 | D10 | PLL lock（应常亮） |
| LED2 | E10 | frame_sent（TX 发过帧后常亮） |
| LED3 | C6  | **RX alive**：收到过至少一帧就常亮 |
| LED4 | D6  | 50MHz 心跳（约 0.75Hz） |

## RX 通路

```
I_rgmii_rxc (V3,125MHz)
   │
   ├─ rgmii_rx_phy   5× PH1P_LOGIC_HD_IDDR  (q0=上升沿=低 nibble/RX_DV)
   │                 → gmii_rxd[7:0] / gmii_rx_dv / gmii_rx_er
   │
   ├─ eth_rx_mac     SFD 自适应对齐（跳 0x55 / 跳 0xD5 / PHY 已剥 SFD 直接当 DA）
   │                 → frame_start / frame_data / frame_idx / frame_byte_v / frame_end / frame_len
   │
   ├─ arp_rx         校验 EtherType=0x0806、opcode=2、target IP=192.168.1.200
   │                 → peer_mac / peer_ip / arp_cnt / rx_frame_cnt
   │
   └─ CDC            MAC 用 toggle 握手（静态数据），计数器 2FF 同步
                     → 50MHz 域
                          │
                          └─ dbg_uart_report + uart_tx (H1, 115200)
```

### 串口协议

每秒一行，30 字符，`115200 8N1`：

```
N=XXXX A=XXXX M=XXXXXXXXXXXX\r\n
  N = 收帧总数(hex)   A = ARP reply 命中数(hex)   M = 对端 MAC(hex)
```

PC 端：

```powershell
python work\eth_smoke\host\rx_monitor.py COM4
```

### 已知限制

- **不做 FCS 校验**：组合 CRC32 在 125MHz 下单字节更新时序偏紧，联调阶段用
  「EtherType + opcode + target IP」三重自洽代替。后续做 UDP 时需要补
  （可考虑 4 bit/拍 或流水化实现）。
- 未做 DA 过滤（谁的帧都收），也未做 MAC 缓存（每帧都重新解析）。
- 计数器跨时钟域是 2FF 直采，理论上有 ±1 的读数抖动（调试用足够）。


## 构建

```powershell
cd work\eth_smoke\td_project\eth_smoke_Runs\syn_1
& "D:\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin\td_commands_prompt.exe" `
  "D:/Anlogic/TD_6.2.1_Engineer_6.2.168.116/doc/scripts/DefaultFlow.tcl"

cd ..\phy_1
& "D:\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin\td_commands_prompt.exe" `
  "D:/Anlogic/TD_6.2.1_Engineer_6.2.168.116/doc/scripts/DefaultFlow.tcl"
```

产物：`td_project/eth_smoke_Runs/phy_1/eth_smoke.bit`

## 引脚

与 `camera_eth_720p` 完全一致（官方《HX1P35B开发板引脚分配汇总》十五、以太网接口）：

| 信号 | 球 | 信号 | 球 |
|---|---|---|---|
| MDC | V9 | MDIO | U10 |
| RESET_N | V8 | TXCLK | U9 |
| RXD0..3 | N9/T7/T8/T9 | TXD0..3 | R11/P11/T10/R12 |
| TXEN | R10 | RXC_DV (RX_DV) | N8 |
| RX_CLK | **V3**（`IO_BE17P_22,GCLKIOT1`；docx 漏列，原理图 page2 球名↔网络名对齐确认。**旧工程写的 V2 是 GPIOA0，错的**） | UART TX | **H1** |
