# camera_hdmi_720p — 摄像头 → HDMI 720p60 显示工程

PH1P35MDG324（HX1P35A 开发板 / TD 6.2.1）上，从零搭建的 **SC500CS / SC520CS MIPI 摄像头 → HDMI 1280×720@60fps** 显示工程。

本工程为**半净室**实现：厂商 IP 核（加密交付物）及其官方匹配件直接复用；应用逻辑、约束、验证全部自研，
不复制参考工程的胶水代码。复用清单见下与 `ip/README.md`。

## 工程状态

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M1 | 工程骨架 + HDMI 测试图案（不接摄像头） | ✅ **上板验收通过**（时序 0 违例，图案/LED 全部正确） |
| M2 | 摄像头上电时序 + I²C 配置（读 Sensor ID 验证） | 代码完成 + 仿真验证通过，**待上板** |
| M3 | MIPI 接收 + CSI-2/RAW10 解包 + 帧统计 | 未开始 |
| M4 | 灰度直通出图（行缓存版，暂不接 DDR） | 未开始 |
| M5 | DDR2 帧缓存（自研读写控制器） | 未开始 |
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
| MIPI D-PHY RX IP（M3 起） | `mipi_dphy_rx_ph1p_mipiio_wrapper` 等 | 厂商加密 IP |
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


## M2 实现（摄像头上电 + I²C 初始化，代码完成待上板）

**验收判据**：上板后 LED4 常亮（复读 ID = `9E4B`）；串口（115200 8N1）循环输出
`CAM ID=EE4B ADR=36 W=A5 P=9E4B OK=1 E=0`。

**新增自研模块**

| 文件 | 说明 |
|---|---|
| `rtl/common/i2c_master.v` | 单主机 I²C（开漏）：单字节写 / 16 位子地址读（重复起始 + NACK + STOP），100kHz |
| `rtl/camera/cam_ctrl.v` | 上电时序 + ID 读取（地址自适应）+ 165 条寄存器表写入 + 复读校验，输出错误码 |
| `rtl/camera/cam_report.v` | 结果格式化 + 115200 串口输出（每 500ms 重发一次） |
| `rtl/common/uart_tx.v` | 简单 UART 发送器（8N1） |
| `tools/check_rtl.py`、`tools/sim/*` | 静态自检 + 行为级仿真（本机无 iverilog，作为上板前的验证手段） |

**引脚事实（原理图 sheet3 BANK21 / 开发板引脚表，BANK21 VCCIO=VCC_3V3 → LVCMOS33）**

| 信号 | FPGA 引脚 | 说明 |
|---|---|---|
| O_cam_clk (FCLK/XCLK) | L3 | 23.81MHz，手册 EXTCLK 范围 6~40MHz |
| O_cam_pwdnb（原厂 PWDNB） | L2 | 低=关断，高=工作 |
| IO_cam_scl / IO_cam_sda | K3 / J3 | 模组板载 4.7K 上拉；经 TXS0104E 电平转换到 42P FPC 座 |
| O_uart_tx (FPGA_TXD) | J1 | 板载 CH340 → Type-C；`FPGA_RXD`=K1 本阶段未用 |
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



## 已知事项

1. `I_rst_n`（厂商用 R10 = 以太网 TXEN 引脚做复位）本工程**不使用**，系统复位由 PLL lock 同步产生（`reset_ctrl.v`）。
2. **HDMI IP 的复位用异步 `~S_pll_lock`**（见 `design_top_wrapper.v` 注释）：IP 内部跨 75MHz/375MHz 两域，
   若用单域同步复位驱动，TD 会把复位分发路径当定时路径分析并违例（实测 -0.365ns）；无发起时钟的 lock 不参与分析。
3. LED 为**高电平点亮**（手册 p20 明确 + 原理图 LED 阴极接 GND）；板上红色 **LED14 是电源指示灯**，常亮正常、与本设计无关。
4. 摄像头控制引脚（I²C/XCLK/PWDNB）与 UART TX 已在 M2 接入 `constraints/pin.adc`；MIPI 差分对（CK/D0/D1）留待 M3 接入
   （引脚：CK_P=V16 / CK_N=U16 / D0=V14,U14 / D1=V15,U15，D2/D3 本设计不用）。
5. 本机无 iverilog；语法/时序验证靠 TD 编译（`td_command_prompt` 可做命令行构建，待验证），
   上板前用 `tools/check_rtl.py`（静态自检）与 `tools/sim/*.py`（行为级仿真）替代。
6. **目录命名坑**：约束目录必须用 `constraints/`，不能用 `con/`——`CON` 是 Windows 保留设备名，git 无法索引其下文件（TD 能正常用，但提交会报 "No such file or directory"）。
7. `.al` 的 `Path` 属性是绝对路径（厂商同样如此），换机器/换路径后建议同步更新；TD 对不匹配的路径一般能自行重定位。
8. **`.al` 不是严格 XML**：`<Attr Name="UsedInP&R" .../>` 里的 `&` 未转义，用标准 XML 解析器会报错；
   工具脚本（如 `tools/check_rtl.py`）按文本正则解析（TD 自身宽松解析，不受影响）。
9. **UART 方向**：原理图（sheet3 BANK21）`IO_BE2P_21(J1)=FPGA_TXD`、`IO_BE2N_21(K1)=FPGA_RXD`，
   本设计把 J1 作为 FPGA 输出（TX）。若串口助手收不到内容，可先怀疑这一处方向，把两脚对调试一次。
10. 摄像头控制信号在 FPGA（BANK21，3.3V）与 42P FPC 座之间有 **TXS0104E 电平转换**；I²C 为开漏，
    RTL 只在"拉低/释放"之间切换，上拉由模组板载 4.7K 与 TXS 内部上拉提供。
