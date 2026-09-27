# camera_hdmi_720p — 摄像头 → HDMI 720p60 显示工程

PH1P35MDG324（HX1P35A 开发板 / TD 6.2.1）上，从零搭建的 **SC500CS / SC520CS MIPI 摄像头 → HDMI 1280×720@60fps** 显示工程。

本工程为**半净室**实现：厂商 IP 核（加密交付物）及其官方匹配件直接复用；应用逻辑、约束、验证全部自研，
不复制参考工程的胶水代码。复用清单见下与 `ip/README.md`。

## 工程状态

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M1 | 工程骨架 + HDMI 测试图案（不接摄像头） | ✅ **上板验收通过**（时序 0 违例，图案/LED 全部正确） |
| M2 | 摄像头上电时序 + I²C 配置（读 Sensor ID 验证） | ✅ **上板验收通过**（2026-09-26 23:10；串口 `ID=EE4B ADR=36 W=A5 P=9E4B OK=1 E=0`） |
| M3 | MIPI 接收 + CSI-2/RAW10 解包 + 帧统计 | ✅ **上板验收通过**（2026-09-27；串口 `MIPI HS=1 F=… L=0720 W=01280 G=0320 ER=00 HW=2B06403B PL=0000 HC=0`） |
| M4 | 灰度直通出图（行缓存版，暂不接 DDR） | ✅ **上板验收通过**（2026-09-27 11:35）：实时灰度画面、感光正常；串口 `HS=1 … RX=1`（MIPI 链路完好，帧率 **≈59.6fps**）。画面证据 `work/test/M4_00/`。已知（预期）现象：纵向细条纹 = Bayer 网格（M6 去马赛克消）、缓慢自上而下滚动 = 相机帧率 59.6fps 与显示 60Hz 未锁相（相差约 0.4Hz）而行缓存「跟随最新行」的固有现象（M5 帧缓存消）。**注意：串口 F/L/W/G 是 BCD 码（RTL 字段名 `D_fs_bcd` 等），解析勿按 hex。** |
| M5 | DDR2 帧缓存（自研读写控制器） | 🟡 计划已定，待实施（DDR2 IP 已入库 `ip/ddr2/`，54 文件逐字节保真） |
| M6 | 彩色 ISP（去马赛克 + 简易 AWB/gamma） | 未开始 |
| M7 | 收尾（按键模式接口、参数化、文档、CI） | 未开始 |

详细计划与调研结论见 `docs/plan.md`。

## 半净室边界

**直接复用（不改动，见 `ip/`）**

| 类别 | 文件 | 来源 |
|---|---|---|
| 通用 PLL IP | `ip/pll/`（`PLL.xml/.v` + `RTL/ph1p_phy_pll_wrapper_25a56e5ce2f9.v`） | 厂商工程 `ip_source/PLL/` |
| HDMI 1.4b TX IP | `ip/hdmi/hdmi_1_4b_transmitter_core_wrapper.enc.v` | 厂商加密 IP |
| HDMI 配套件 | `hdmi_tx.v`、`hdmi_phy_warpper.v`、`lane_lvds_10_1.v`、`I2S_receiver.v`、`audio_arc_calculate.v`、`key_remove_shakes.v` | 厂商工程 `hdl_source/`（HDMI 参考设计的配套模块） |
| MIPI D-PHY RX IP（M3） | `ip/mipi_dphy_rx/`（`mipi_dphy_rx_ph1p_mipiio_wrapper.sv`、`ph1p_mipiio_rx_wrapper.v`、`hs_detect.enc.v`、`byte_aligner(.enc).v`、`channel_aligner(.enc).v`） | 厂商加密 IP 及其官方配套件 |
| DDR2 控制器 IP（M5 起） | `ph1p35_324_ddr_wrapper` + `ddr2/` | 厂商加密 IP |
| 传感器寄存器表（M2 起） | SC520CS 720p60 初始化表（数据） | 原厂参数表，数据手册不含完整序列 |

**自研（本工程 `rtl/`）**：顶层与时钟/复位、HDMI 时序发生器、测试图案、摄像头控制（I²C 主机 + 上电时序 + 寄存器表加载）、
CSI-2 解包、RAW10 解包、帧统计/调试状态机、DDR2 帧缓存读写控制、去马赛克/AWB/gamma、按键/模式控制、全部约束文件。

## 目录结构

```
camera_hdmi_720p/
├─ README.md          # 本文档
├─ docs/plan.md       # 实施计划、调研结论、风险
├─ rtl/               # 自研 RTL
│  ├─ top/            # design_top_wrapper.v  板级顶层
│  ├─ common/         # reset_ctrl.v、i2c_master.v、uart_tx.v
│  ├─ video/          # hdmi_timing.v、test_pattern.v
│  └─ camera/         # cam_ctrl.v（上电+I²C 初始化）、cam_report.v（串口报告）
├─ constraints/       # 自研约束：pin.adc（引脚）、timing.sdc（时序）
├─ ip/                # 复用件（不自研、不修改），来源见 ip/README.md
│  ├─ pll/            # 通用 PLL IP（IP 生成件）
│  ├─ hdmi/           # HDMI 1.4b TX IP + 官方配套件
│  └─ sc520reg/       # SC520CS 720p60 原厂寄存器表（数据件）
├─ tools/             # 自研验证工具（无 iverilog 环境下的替代手段）
│  ├─ check_rtl.py    # 静态自检：.al 清单 / 端口-网络-位宽交叉校验
│  └─ sim/            # 行为级仿真：i2c_sim.py（I²C 主机协议）、cam_sim.py（上电流程）
└─ td_project/        # TD 工程目录（camera_hdmi_720p.al + 自动生成的 *_Runs/）
```

## 时钟方案（复用厂商 PLL 配置，单 PLL）

| PLL 输出 | 频率 | 用途 |
|---|---|---|
| C0 | 100.000 MHz | 系统逻辑（M2 起：I²C、控制） |
| C1 | 23.809524 MHz | 摄像头 XCLK（M2 起；手册标注"24MHz"，见风险） |
| C4 | 75.000 MHz | HDMI 像素时钟（720p60 标准为 74.25MHz，见下） |
| C5 | 375.000 MHz | HDMI 串行（TMDS）时钟 |

- 板上 50MHz 有源晶振 → C4（`I_sys_clk`）。PLL 由 `u_pll` 例化，参数在 `ip/pll/PLL.v`（厂商已验证配置，本工程未改动）。
- **75MHz 说明**：720p60 标准像素时钟 74.25MHz，由 50MHz 整数分频 PLL 无法精确产生（74.25 = 50×297/200）。
  厂商用 75.000MHz（偏 +1.01%）跑通，本工程沿用，作为第一个上板验证点；若不兼容显示器，
  可改为调整行/场总数或更换显示器，见 `docs/plan.md`。
- **23.809524MHz**：模组原理图注明"主机须提供 27M"，而厂商寄存器表/RTL 按 24MHz 设计，M2 上板时验证（见风险）。

## TD 工程

- 工程文件：`td_project/camera_hdmi_720p.al`（按厂商 `.al` 格式生成，器件 PH1P35MDG324 / -3）。
- 若 TD 无法打开该文件，则在 TD 中手动新建工程后按下面清单添加：
  - 设计文件：`rtl/**/*.v` + `ip/hdmi/*.v`；IP：`ip/pll/PLL.xml`（自动引入 RTL 包装器）。
  - 约束：`constraints/pin.adc`、`constraints/timing.sdc`；顶层模块：`design_top_wrapper`。
- 编译流程：Synthesis → Physical Design（含 Bitgen）→ `*_Runs/` 生成 bit/fcs 文件 → BitWriter 下载到 SRAM。

## M1 验证记录

**编译（2026-09-26 22:04，首次）**
- syn_1 + phy_1 全部完成（bitgen complete，资源：LUT 836 / REG 1390 / SLICE 1071 / ERAM 5 / PLL 1 / GCLK 3 / IO 13）。
- 时序：HDMI_PIXEL_CLK 自域 SWNS +7.331ns、HDMI_SERIAL_CLK 自域 +1.218ns、pixel→serial 数据跨域 52 条端点全通过；
  **总 SWNS -0.365ns 全部来自 4 条"像素域同步复位 → TMDS 输出寄存器复位脚"的分发路径**（非数据通路）。
- 修正：HDMI IP 的复位改用 `~S_pll_lock`（异步、无发起时钟，与厂商参考一致），自研逻辑仍用 `reset_ctrl`。
  修正后待重编确认 SWNS 转正。

**上板（2026-09-26 22:13，验收通过）**
- [x] 重编后时序 0 违例（SWNS +0.943ns / HWNS +0.033ns）
- [x] BitWriter 下载成功（首次 PRG-8000 为偶发，重试即好）
- [x] 显示器 **Dell**：8 彩条（白/黄/青/绿/品红/红/蓝/深灰，顺序正确）+ 四面白边框 + 灰度渐变带
      （位于 41.7%~58.2% 屏高处、内部 5 次锯齿循环，与 x[7:0] 设计一致）+ 橙/蓝两个方块均可见且在动
      → **75MHz 像素时钟被该显示器正常接受**（风险①解除）
- [x] 无花屏/噪声/错位（照片：`tests/01/`）
- [x] 方块运动方向目视确认：天蓝方块在白色|黄色交界处（x=64~192）**向下**移动、橙色方块在灰度带下方（y=540~668）**向右**移动 —— 与设计完全一致
- [x] 白边框：设计 4px；1080p 面板把 720p 放大 1.5× → 实测约 6px（4×1.5），符合预期
- [x] **LED 极性修正后复验通过**（22:21 重编，SWNS +0.944ns / 0 违例）：LED1/LED3/LED4 绿色常亮（PLL 锁定 / 复位已释放 / 已输出数据）、LED2 绿色闪烁（像素域心跳）。
      注：原代码误按低电平点亮（手册 p20 实为高电平点亮），已修正为 `assign O_led = S_led_status`。红色 LED14 为板上电源指示灯，常亮与设计无关。


## M2 实现（摄像头上电 + I²C 初始化，已上板验收 2026-09-26）

**验收判据**：上板后 LED4 常亮（复读 ID = `9E4B`）；串口（115200 8N1）循环输出
`CAM ID=EE4B ADR=36 W=A5 P=9E4B OK=1 E=0`。

**新增自研模块**

| 文件 | 说明 |
|---|---|
| `rtl/common/i2c_master.v` | 单主机 I²C（开漏）：单字节写 / 16 位子地址读（重复起始 + NACK + STOP），100kHz |
| `rtl/camera/cam_ctrl.v` | 上电时序 + ID 读取（地址自适应）+ 165 条寄存器表写入 + 复读校验，输出错误码 |
| `rtl/camera/status_report.v` | 结果格式化 + 115200 串口输出（每 500ms 连发 CAM 与 MIPI 两行，取代 M2 的 `cam_report.v`） |
| `rtl/common/uart_tx.v` | 简单 UART 发送器（8N1） |
| `tools/check_rtl.py`、`tools/sim/*` | 静态自检 + 行为级仿真（本机无 iverilog，作为上板前的验证手段） |

**引脚事实（原理图 sheet3 BANK21 / 开发板引脚表，BANK21 VCCIO=VCC_3V3 → LVCMOS33）**

| 信号 | FPGA 引脚 | 说明 |
|---|---|---|
| O_cam_clk (FCLK/XCLK) | L3 | 23.81MHz，手册 EXTCLK 范围 6~40MHz |
| O_cam_pwdnb（原厂 PWDNB） | L2 | 低=关断，高=工作 |
| IO_cam_scl / IO_cam_sda | K3 / J3 | 模组板载 4.7K 上拉；经 TXS0104E 电平转换到 42P FPC 座 |
| O_uart_tx | H1 | 经 USB-JTAG Cable（Type-C）的通道B 到 PC；FPGA 侧 `uart_rx`=J1 本阶段未用 |
| MIPI 数据（M3 用） | CK_P=V16 / CK_N=U16，D0=V14 / U14，D1=V15 / U15 | 2-lane RAW10 |

**上电与初始化流程（`cam_ctrl.v`）**

1. 复位释放后 PWDNB 拉低 2ms（手册 T4≥1ms），再拉高并等 8ms（T5≥5ms）；
2. 100kHz I²C 读 `0x3107/0x3108`：先用 7'h36，整笔 NAK 则切 7'h10 重试 → `D_id_pre`（应为 `EE4B`）；
3. 逐条写入原厂寄存器表 165 条（`ip/sc520reg/uics520reg_720p60.v`，24MHz MCLK / 2-lane RAW10 / 828Mbps）；
4. 等 20ms 后复读 `0x3107/0x3108` → `D_id_post`（原厂表生效后应为 `9E4B`）；
5. 错误码 `E`：0 正常 / 1 无 I²C 应答 / 2 写表 NAK（`W` 停在出错条数）/ 4 ID 不符（收到 `EE4B` 说明表未生效）。

**M2 LED 定义**：LED1=PLL 锁定、LED2=100MHz 域心跳、LED3=初始化流程结束、LED4=ID 校验通过。
HDMI 测试图案在 M2 仍然输出（屏幕可继续作为参考画面）。

**验证记录（上板前）**

- `tools/check_rtl.py`：0 错误 0 警告（18 个模块；`.al` 清单与实际文件一致；顶层所有例化的端口名/位宽/连接全部匹配）。
- `tools/sim/i2c_sim.py`：写寄存器 ✓、读 ID（`EE4B`/`4B`）✓、错误地址 `ack_err` ✓、事件序列
  `START→ADDR_W_ACK→Sr→ADDR_R_ACK→master_NACK→STOP` ✓（QUART=4 与 250 两组时基）。
- `tools/sim/cam_sim.py`（含真实 ROM 表 + SC520 从机模型）：正常流程 `EE4B→9E4B`、地址回退（0x10）、写表 NAK、无器件 四种场景均符合预期。
- 仿真过程中据此修掉 3 处 RTL 缺陷：① START 的 SDA 下降沿与 SCL 同时变化（从机看不到起始条件）；
  ② ACK 通过后未跳回 TX 状态（状态机空转）；③ 重复起始前未先释放 SCL（SDA 上升沿会被从机误判为 STOP）。



## M3 实现（MIPI 接收 + CSI-2/RAW10 解包 + 帧统计，2026-09-27）

**链路**：MIPI 差分对 → `ip/mipi_dphy_rx/`（D-PHY 硬核 IP，1:8 模式，2 lane）→ 字节流（`O_hs_rx_clk`
= 串行时钟/4 ≈ 103.5MHz，每拍 2 字节：lane0 在高字节、lane1 在低字节）→ `lane_deint.v`（拍对重排成
标准 CSI-2 字节序）→ `csi2_pkt_rx.v`（包解析）→ `raw10_unpack.v`（5 字节 → 4 像素）→
`mipi_stats.v`（字节域计数 + 跨域快照握手）→ `status_report.v`（串口）。

| 文件 | 说明 |
|---|---|
| `rtl/mipi/lane_deint.v` | **拍对重排**：硬件每拍给出 lane0/lane1 各 1 字节，原始配对为 `(b0,b2),(b1,b3),…`；本模块按「拍对 (A,B) → A高,B高,A低,B低」还原成标准 CSI-2 字节流（包首重置配对相位） |
| `rtl/mipi/csi2_pkt_rx.v` | CSI-2 包解析：包起始 = HS valid 上升沿；解析 4 字节包头（DI/WC/ECC）；FS/FE/LS/LE 短包脉冲；RAW10 长包负载直通；粘滞错误位（非预期 DT / WC≠1600 / 包头包体异常） |
| `rtl/mipi/raw10_unpack.v` | RAW10 解包：每拍 2 字节 → 每 5 字节出 4 个 10bit 像素（`O_px={P3,P2,P1,P0}`），行首对齐 |
| `rtl/mipi/mipi_stats.v` | 字节域统计（帧/行/行像素/行组数，BCD）+ 错误位图 + req/ack 双相握手快照到 100MHz 域 |
| `rtl/camera/status_report.v` | 每 500ms 连发两行（CAM 行与 M2 完全一致 + MIPI 行），取代 M2 的 `cam_report.v` |
| `constraints/timing.sdc` | 新增 `mipi_rx_ck_pad`（2.415ns = 828Mbps/lane）、`MIPI_RX_BYTE_CLK`（重命名 IP 内部字节时钟）、两域 `set_clock_groups -asynchronous` |
| `tools/sim/mipi_sim.py` | 逐拍行为级仿真（本机无 iverilog，作为上板前验证手段） |

**串口上报格式（115200 8N1，每 500ms 两行）**

```
CAM ID=EE4B ADR=36 W=A5 P=9E4B OK=1 E=0
MIPI HS=1 F=000012 L=0720 W=01280 G=0320 ER=00 HW=2B0640xx PW=xxxx PL=0000 HC=0 SW4=1
```

- `F` 累计帧数（BCD 十进制）、`L` 上一帧行数（应 0720）、`W` 上一行像素数（应 01280）、
  `G` 上一行组数（应 0320）、`HS` 是否见过 HS 流量（无流量时整行显示 0，可据此判断链路是否通）。
- `ER` 错误位图：bit0 通道错误 / bit1 非预期 DT / bit2 WC≠1600 / bit3 包头或包体异常 /
  bit4 行数≠720 / bit5 行像素≠1280 / bit6 FS/FE 不配对 / bit7 保留。
- 联调诊断字段（M3 上板调试用）：`HW` 最近一个 RAW10 包收到的 4 个包头字节（应 `2B0640xx`
  = DI, WC_hi, WC_lo, ECC）、`PW` 该包负载首拍 2 字节、`PL` 包体提前结束那一拍还剩多少拍
  （0 表示未发生）、`HC` err_hdr 成因位图（bit0 包头中断 / bit1 包体中断 / bit2 IDLE 超时 / bit3 疑似同步码）。

**首轮上板联调记录（2026-09-27）**

- 首轮实测：`HS=1 F=…(60fps) L=0000 W=01300 G=0325 ER=3C HW=2B40063B PL=1CD5 HC=2`。
  物理层完全正常（有 HS 流量、帧起始识别正确、60fps 稳定、无 lane 错、DI 解析为 RAW10）；
  问题在**行长字段解析**：按「每拍 2 字节即 CSI-2 顺序」读得 `WC=0x4006=16390`（荒谬），
  导致负载永远消费不完（`L=0000`）、统计计数被 CRC 等字节污染（`G=0325` 而非 0320）。
- 根因：D-PHY 硬核每拍同时给出 **lane0 与 lane1 各 1 字节**，原始流配对为 `(b0,b2),(b1,b3),…`；
  真正 CSI-2 字节序要把拍对还原为 `A高,B高,A低,B低`。按此还原 `HW=2B40063B` → `WC=0x0640=1600`
  = 1280 像素 × 10bit / 8，与 720p 行宽完全吻合；并与原厂 `csi_unpacket_2lane.v` 读法
  `{I_hs_data[15:8], S_hs_data_1d[7:0]}` 一致（只读接口语义核对）。
- 修复：新增 `rtl/mipi/lane_deint.v` 做拍对重排，接在 D-PHY 与 `csi2_pkt_rx` 之间；下游逻辑无需改动。
  仿真激励同步改为「按硬件行为构造原始拍流」，并新增契约回归用例（`WC=1600` → 原始流必为 `2B40063B`）。
- **二次上板（2026-09-27 09:59）：验收通过** —— 连续 14 秒读数全部为
  `MIPI HS=1 F=… L=0720 W=01280 G=0320 ER=00 HW=2B06403B PW=… PL=0000 HC=0`：
  `L/W/G` 精确达标、`ER=00`（零错误）、`F` 稳定 60 帧/秒递增、`HW` 还原为 `2B 06 40 3B`
  （WC=0x0640=1600 ✓ 与推断一致）、`PL=0`/`HC=0`（无包体中断）。`PW` 在 `1111/1212` 间变化，
  说明是真实像素数据在流动。
  说明：TD 首次编译时报 `lane_deint is a black box` —— 因为 TD 只认它**打开工程那一刻**的清单，
  新增文件条目必须在 TD 关闭状态下写入 `.al` 后重开工程。

**上板前验证记录**

- `tools/check_rtl.py`：**0 错误 0 警告**（27 个模块；`.al` 清单、顶层例化端口/位宽/连接全部一致；
  输出端口悬空按警告处理）。
- `tools/sim/mipi_sim.py`：**一帧 720 行 921600 像素逐点往返一致**（RAW10 打包↔解包），统计计数
  （`F/L/W/G`）与错误位图全部符合预期；错误注入 5 场景（WC 不符 / 未知 DT / 包体截断 / 疑似同步码 /
  嵌入数据行 0x12）均按设计给出对应错误位并可恢复；**新增包头契约回归**：`WC=1600` 的原始拍流必须
  等于上板实测值 `2B40063B`，且经 `lane_deint` 重排后还原为 `DI,WC_hi,WC_lo,ECC`。
- 仿真抓到并修掉 2 处缺陷：①`raw10_unpack.v` 的行首对齐原本在"推字节之后"执行，会清掉每行头 2 字节、
  并让上一行残留的 3 字节跨行拼组（现象：每行少 4 像素且像素错位）；改为在组合块中"先对齐、再推字节"。
  ②缺少 `lane_deint` 拍对重排（上板才发现，仿真激励已同步改为硬件真实格式）。
- 关键位序显式核对：RAW10 前 4 字节是像素高 8 位、第 5 字节 bit1:0 = P0 低 2 位（MIPI CSI-2 / V4L2 Y10P）。

**M3 待上板确认的假设（均已确认，2026-09-27）**

1. HS valid 在包与包之间有拉低（本设计以"上升沿"识别包起始）。✅ 确认（`F` 以 60fps 递增、`HC` 位 0 未出现）。
2. 传感器按 2-lane RAW10、**WC=1600**（1600 字节/行）输出。✅ 确认：`HW=2B06403B` → `WC=0x0640=1600`
   （重排字节序后），与 1280 像素 × 10bit ÷ 8 完全吻合。
3. 帧行数 720 / 行像素 1280。✅ 确认：`L=0720`、`W=01280`、`G=0320`。

### M4 实施（灰度直通 + SW4 画面切换）

- **切换开关**：SW4 = 引脚 D11（板手册 2-22 乒乓开关，拨上=1、拨下=0）。**拨上 = 摄像头画面**、
  拨下 = 彩条测试图案（已知正确基准）。串口 MIPI 行末尾新增 `SW4=n`，开关读数一目了然。
- **新增自研模块**：
  - `rtl/video/cam_linebuf.v`：双 bank（ping-pong）行缓存。
    写侧在 MIPI 字节时钟域（`S_rx_byte_clk`）按「组」写入 —— 每地址存 40bit = 4 个 10bit 像素，
    一拍一组（raw10_unpack 每 2.5 拍给一组，一拍写一组刚好跟得上）；行首 `S_pay_start` 翻 bank
    并清写地址，行尾 `S_pay_end` 发「本行完成」。
    读侧在 HDMI 像素域由 `de/x/vs` 驱动：地址 `x[11:2]`、字段 `x[1:0]`，输出 `{gray,gray,gray}`。
    跨域用 2 级同步链 + 翻转标志，**读侧永远读「已完成的行」**，不会读到正在写的行。
  - `rtl/video/video_mux.v`：摄像头画面 / 测试图案二选一（内部对 SW4 做 2 级同步），
    接口与 `test_pattern` 一致（data/de_o/vs_o 同拍）。
- **灰度映射**：`(RAW10 − 黑电平 64) >> 2` 送 R=G=B（黑电平是 `BLACK_LEVEL` 参数，可按画面调）。
- **仿真**（`tools/sim/linebuf_sim.py`，逐拍行为级）：5 用例 10 项**全部通过**。
  其中**仿真抓出并修复 2 个 RTL 真 bug**（这类问题不做仿真会直接烧到板子上）：
  ① 读侧 bank 锁存取了同步链的**旧**值（`sync_bank[2]` 应为与边沿同级的 `sync_bank[1]`）
     → 否则读侧永远晚一行切 bank，画面会卡在上一行；
  ② `O_rd_de/O_rd_vs` 延迟 2 拍而 data 只延迟 1 拍 → de 与 data 差一拍，画面整体错位。
- **验收**：见 docs/plan.md「M4 实施要点与预期效果」（实时灰度画面 + 串口 M3 不退化；
  允许轻微撕裂/偏暗/Bayer 网格）。

## 已知事项

1. `I_rst_n`（厂商用 R10 = 以太网 TXEN 引脚做复位）本工程**不使用**，系统复位由 PLL lock 同步产生（`reset_ctrl.v`）。
2. **HDMI IP 的复位用异步 `~S_pll_lock`**（见 `design_top_wrapper.v` 注释）：IP 内部跨 75MHz/375MHz 两域，
   若用单域同步复位驱动，TD 会把复位分发路径当定时路径分析并违例（实测 -0.365ns）；无发起时钟的 lock 不参与分析。
3. LED 为**高电平点亮**（手册 p20 明确 + 原理图 LED 阴极接 GND）；板上红色 **LED14 是电源指示灯**，常亮正常、与本设计无关。
4. 摄像头控制引脚（I²C/XCLK/PWDNB）与 UART TX 已在 M2 接入 `constraints/pin.adc`。
   **MIPI 差分对（CK/D0/D1）是器件专用脚，不写进 `pin.adc`**（厂商 SC520 lab 的 `pin.adc` 里同样没有任何 MIPI 条目）——
   它们由顶层 `IO_rx_clk_pad_*` / `IO_rx_data_pad_*` 直连 D-PHY IP 的硬核 pad；
   引脚：CK_P=V16 / CK_N=U16、D0=V14,U14、D1=V15,U15，D2/D3 本设计不用（但顶层端口仍需声明全部 4 lane 的 pad 数组）。
5. 本机无 iverilog；语法/时序验证靠 TD 编译（`td_command_prompt` 可做命令行构建，待验证），
   上板前用 `tools/check_rtl.py`（静态自检）与 `tools/sim/*.py`（行为级仿真）替代。
6. **目录命名坑**：约束目录必须用 `constraints/`，不能用 `con/`——`CON` 是 Windows 保留设备名，git 无法索引其下文件（TD 能正常用，但提交会报 "No such file or directory"）。
7. `.al` 的 `Path` 属性是绝对路径（厂商同样如此），换机器/换路径后建议同步更新；TD 对不匹配的路径一般能自行重定位。
8. **`.al` 不是严格 XML**：`<Attr Name="UsedInP&R" .../>` 里的 `&` 未转义，用标准 XML 解析器会报错；
   工具脚本（如 `tools/check_rtl.py`）按文本正则解析（TD 自身宽松解析，不受影响）。
9. **UART 引脚与方向（已定案，踩过坑）**：官方例程 `ref/HX1P35A_Contest_202606/2_Example/16_uart_rs232/uart_test.adc`
   （同板：clk=C4、rst=D5）给出 `uart_rx=J1`（PULLUP）/ `uart_tx=H1`（DRIVESTRENGTH=8），与手册表格一致。
   原理图 sheet3 BANK21 里的 net 名 `FPGA_TXD/FPGA_RXD` 是**桥侧视角**命名，按名字判方向会把 FPGA 的 TX 接到
   实际作输入的 J1（既发不出数据，又与桥的 TXD 输出顶牛）。本设计取 **O_uart_tx → H1**。
10. 摄像头控制信号在 FPGA（BANK21，3.3V）与 42P FPC 座之间有 **TXS0104E 电平转换**；I²C 为开漏，
    RTL 只在"拉低/释放"之间切换，上拉由模组板载 4.7K 与 TXS 内部上拉提供。
11. **D-PHY IP 例化硬约束（M3）**：参数必须取 SC520 720P lab 原值
    （`DPHY_RX_LOCATION="DPHY0"`、`HS_EQUALIZER="3dB"`、`HS_VGA_GAIN="8dB"`、`LANE_NUM=2`、`BYTE_NUM=1`；
    SC500 lab 的 `"0dB"` 是更低链路速率的取值，勿混用）；顶层实例名必须是 `u_mipi_dphy_rx_ph1p_mipiio_wrapper`，
    否则 SDC 的 `rename_clock MIPI_RX_BYTE_CLK` 找不到时钟。IP 文件按普通源码进 `.al`
    （`.v` → `<Verilog>`，`.sv` → `<System_Verilog>`），**不是** `IP_FILE`。
12. **字节时钟域复位**：`S_rst_n_rx` 由 100MHz 域复位异步置位、在 `O_hs_rx_clk` 上同步释放。
    HS 流量停止时该域逻辑冻结（统计保持不变，串口显示 `HS=0 F=000000`），便于区分"链路没通"与"解析错"。
13. `status_report.v` 的 CAM 行字符序列与 M2 的 `cam_report.v` **逐字符一致**（方便与 M2 验收输出对照），
    MIPI 行紧随其后（两行共 89 字符，每 500ms 重发）。
