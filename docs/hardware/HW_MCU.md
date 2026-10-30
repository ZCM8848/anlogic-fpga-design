# HW_MCU — PH1P35 内嵌 RISC-V MCU 硬核（开发实操细节）

> 来源：`ref/MCU_ref/00_使用指南/PH1P35内MCU核使用指南.pdf`（MCU 指南，27p）、
> `ref/MCU_ref/01_安路PH1P35官方资料/DS1300_PH1P_Datasheet (1).pdf`（DS1300）、
> `ref/MCU_ref/03_FutureDynasty资料/SWUG500_FD_User_Guide.pdf`（FD 用户指南）、
> TD IP Catalog 重生后的 `ip/mcu/.params_mcu.txt` / `.ports_mcu.txt`、
> FD 自带 `data/addrmap/ph1p35/index.html`、`data/embeddedsw/.../ahb_demo.c`、
> 以及本项目 Phase A→B8 上板验证的实测结论。
>
> 本文把 MCU 迁移过程中**从 ref/MCU_ref 查到、但 HW_PH1P35.md §5 没写清楚**的实操细节集中成一份。
> 芯片级概览（ISA/缓存/外设清单）见 [`HW_PH1P35.md §5`](HW_PH1P35.md)；本文专注**怎么用**。

## 1. 时钟（必须由 fabric PLL 提供，不能直接喂板钟）

| 信号 | 频率 | 来源 | 备注 |
|---|---|---|---|
| `core_clk` | **300 MHz** | fabric PLL（本项目用 `pll_mcu`：50MHz 板钟 → 300MHz） | MCU **不自己倍频**；须 fabric 直接给 300MHz |
| `timer_clk` | **100 MHz** | `u_pll` C0 | |
| `apb_clk` | **50 MHz**（数据手册规格） | `I_sys_clk` 板钟直供（50MHz） | 用 MCU→Fabric APB 时按规格给 50MHz；本项目状态从口改走 AHB 后 APB 悬空 |
| `ahb_clk` | ~150 MHz（core/2） | MCU 输出（IP `ahb_clk` 端口） | AHB master 总线时钟，喂回外部 AHB 从口 |

> **易踩坑**：早期假设"core_clk 喂 50MHz 板钟、靠 MCU 内部 DPLL 升到 300MHz"是错的。MCU 指南 §4 明确要 fabric PLL 出 300MHz。本项目用独立 `pll_mcu`（不碰已上板验证的相机/HDMI `u_pll`）。

## 2. 复位

| 信号 | 有效级 | 触发 |
|---|---|---|
| `core_reset` / `por_reset` | **高有效** | 两 PLL 都锁定后释放（`~(pll_lock & pll_mcu_lock)`） |
| `nmi` / `clic_irq[22:0]` | — | 不用接 0 |

- **复位向量 `0x20E00000`** = QSPI flash boot 地址（IP 参数 `MCU_RESET_VECTOR`）。
  量产：固件 ELF → raw bin → TD BitWriter 写 flash 对应偏移，MCPU 上电从 flash 取指。
  调试：JTAG 直接 load ELF 到 RAM 跑（不必烧 flash）。
- **bit 下载会触发 MCU 重启**（MCU 指南 §15.1）：bit 重建 MCU 的时钟/复位/硬件环境，复位向量指向 flash → 之前调试加载的程序映像仍可被启动（"只下 bit 也看到之前的 Hello World"现象的来源）。

## 3. JTAG（关键：MCU_JTAG_SEL=0，走专用 pad，不进 fabric）

| `MCU_JTAG_SEL` | JTAG 路径 | 适用 |
|---|---|---|
| **0**（指南推荐 / 本项目） | 板载 USB-JTAG → **专用 PAD JTAG** → MCU Debug Module | FD/OpenOCD 直接访问，**顶层不用接 JTAG 信号** |
| 1 | JTAG 端口导出到 fabric（`jtag_tck/tms/tdi/tdo` 进端口表） | 需要 fabric/PIB 侧 JTAG 时才启用（本项目不用） |

> **本项目重生 MCU IP 时 JTAG 不勾**（`MCU_JTAG_SEL=0`）→ `jtag_tck/tms/tdi/tdo` 端口**不存在**于 `mcu.v`，顶层无需也无需在 `pin.adc` 加 JTAG 条目（专用 pad 由芯片硬连到板载 USB-JTAG）。这是与"JTAG_SEL=1 的 ref 副本"最大的端口表差异。

## 4. Fabric 面向端口（MCU→fabric）

MCU IP 有 **AHB master** 和 **APB master** 两个面向 fabric 的主端口（经 PIB）。固件访问 fabric 寄存器经这两个口。

### 4.1 AHB master 窗口 = `0x80000000`（已验证）

- 来源：FD 自带 `data/embeddedsw/master_sdk/solutions/demo/baremetal/ahb_demo_n/ahb_demo.c` 里 `#define AHB_BaseAddr 0x80000000`，演示 MCU→fabric AHB 读写。
- 固件 `*(volatile uint32_t*)0x80000000` → MCU AHB master → 外部 AHB 从口。
- 本项目 `ahb_status_slave` 挂在 AHB master 上，地址 `0x80000000 + 偏移`，版本寄存器 `VER=0x4D435602`。

| 偏移 | 名称 | 方向 | 用途 |
|---:|---|---|---|
| `0x00` | `CAM_REG` | R | 摄像头与板级状态 |
| `0x04` | `CV_REG` | R | `bin_thr`、run_cnt、帧计数 |
| `0x08` | `FRAME_REG` | R | vsync 帧计数 |
| `0x0C` | `VER_REG` | R | `0x4D435602` |
| `0x10` | `HEARTBEAT` | W | MCU 心跳 |
| `0x14` | `SCRATCH` | R/W | 调试暂存 |
| `0x18` | `RUN_IDX` | W | run_mem 读索引 |
| `0x1C` | `RUN_DAT` | R | run_mem 数据 |
| `0x20` | `OV_IDX` | W | overlay 索引 |
| `0x24` | `OV_W0` | W | overlay 高 32 位 |
| `0x28` | `OV_W1` | W | overlay 低 32 位，写入提交 |
| `0x2C` | `META_REG` | R | run_cnt、min_y、max_y |
| `0x30` | `OV_COUNT` | W | 计数值 |
| `0x34` | `BALL_CTRL` | W | `[0]=enable [1]=capture` |
| `0x38` | `BALL_THR` | W | `[7:0]=bg_thr [15:8]=min_run` |
| `0x3C` | `BALL_STATUS` | R | bg_ready / capturing / run_overflow |
| `0x40` | `SW_STAT` | R | SW1..SW4 |
| `0x44` | `BCD_COUNT` | W | 5 位 BCD |
| `0x48` | `BALL_RUN_CFG` | W | roi_y1 / max_run_len |
| `0x4C` | `SKIP_CNT` | R | ROI 与超长 run 丢弃计数 |
| `0x50` | `KEY_EVT` | R/W | `[0]=K1 长按 [1]=K2 长按`，写 1 清零 |
| `0x54` | `BALL_NOW` | W | 当前绿框数 |
| `0x58` | `SEG_CTRL` | W | `[0]=1` 数码管全部显示 `-` |
| `0x5C` | `BALL_GATE` | W | gate_x / gate_y0 / gate_y1 |
| `0x60` | `CAM_AE` | W | 曝光目标，2..1991 半行 |
| `0x64` | `CAM_AG` | W | 增益目标，16..176 |
| `0x68` | `BUZZ_CTRL` | W | 翻转 `[0]` 触发一次短鸣 |
| `0x6C` | `BUZZ_CFG` | W | `[15:0]=beep_ms`，`[31:16]=半周期时钟数` |

- 相机曝光和增益由 MCU 写入 `CAM_AE` / `CAM_AG`，`ae_set` 在 24 MHz 域同步后写 SC520CS。当前默认 `exposure=768`、`gain=64`。
- 门线位置由 `BALL_GATE` 下发，`cv_top` 按 `gate_x × 4` 绘制到 1280×720 画面。
- 蜂鸣器由 `BUZZ_CTRL` / `BUZZ_CFG` 控制：识别态与动态调试态过门短鸣，静态测试图案输出 RTL 测试曲，C12 低电平响，SW5 为硬件供电开关。

### 4.2 APB master 窗口 = **文档无记载**（实测结论）

- FD 自带 `data/addrmap/ph1p35/index.html`（地址映射）只列**内部外设**（USART/GPIO/I2C/QSPI/DMA/Misc_ctrl），**没有 fabric AHB/APB 窗口**。
- BSP `al_hwcfg.h` / `al_chip.h` 同样只有内部外设基址。
- MCU 指南、DS1300 均无 APB 窗口基址。
- **结论**：fabric APB 窗口基址在所有可访问文档里都找不到。本项目状态从口原用 APB，因地址未知改走 AHB（`0x80000000` 已知）。

### 4.3 端口清单（重生后的 `mcu` IP，JTAG off/GPIO off）

来自 `ip/mcu/.ports_mcu.txt`：

| 端口 | 方向 | 备注 |
|---|---|---|
| `core_clk`, `timer_clk`, `core_reset`, `por_reset`, `nmi`, `clic_irq[22:0]` | in | 时钟/复位/中断 |
| `core_sysrst` | **out** | MCU 主动复位输出（重生 IP 新增；ref TD6.1 副本无） |
| `ahb_clk`, `htrans[1:0]`, `hwrite`, `haddr[30:0]`, `hsize[2:0]`, `hburst[2:0]`, `hprot[3:0]`, `hmastlock`, `hwdata[31:0]` | out | AHB master |
| `hrdata[31:0]`, `hresp[1:0]`, `hready` | in | AHB 从口返回 |
| `apb_clk`, `apb_rst`, `paddr[19:0]`, `psel`, `penable`, `pwrite`, `pwdata[31:0]`, `pstrobe[3:0]`, `pprot[2:0]` | out/in | APB master（本项目悬空） |
| `prdata[31:0]`, `pready`, `pslverr` | in | APB 从口返回 |
| `uart0_tx/rx` | out/in | UART0（本项目接 H1/J1） |
| `jtag_*`, `gpio0-7_*`, `uart1_*`, `i2c_*`, `qspi1_*` | — | **重生后端口不存在**（IP 配置关掉） |

## 5. MCU 内部地址映射（固件访问内部外设用）

来自 FD `data/addrmap/ph1p35/index.html`（地址映射网页）：

| 外设 | 基址 |
|---|---|
| Misc_ctrl | `0x18000000` |
| IDU | `0x10010000` |
| DMA | `0x10020000` |
| USART0 | `0x11010000` |
| USART1 | `0x11012000` |
| I2C | `0x11020000` |
| QSPI0 | `0x11040000` |
| QSPI1 | `0x11050000` |
| GPIO | `0x11090000` |

> 注：fabric AHB/APB 窗口（§4）**不在**这个内部映射里。

## 6. MCU IP 配置（TD IP Catalog 重生，按指南）

本项目重生时按下表（`ip/mcu/.params_mcu.txt` 的值）：

| 选项 | 值 | 说明 |
|---|---|---|
| UART0 | ✅ on | 串口输出（必开） |
| AHB | ✅ on | 导出 AHB master（接 fabric 从口） |
| APB | ✅ on | 导出 APB master（留扩展；本项目悬空） |
| **JTAG** | ❌ off | `MCU_JTAG_SEL=0`，走板载 USB-JTAG 专用 pad |
| GPIO0-7 | ❌ off | 不用 |
| I2C / UART1 / QSPI1 | ❌ off | 不用（摄像头 I²C 仍由 fabric 的 `uicfgcs520` 负责） |
| Reset Vector | `0x20E00000` | QSPI flash boot |
| Core Clock FREQ | `300 MHz` | |
| Timer Clock FREQ | `100 MHz` | |
| AHB Div | `2` | AHB = core/2 = 150MHz |
| UART0 Baud | `115200` | |
| MCU_DPLL_POST_DIV | `4` | |
| MCU_DPLL_BYPASS | `DISABLE` | |

## 7. FD 工具链（FutureDynasty IDE）

- 安装：`ref/HX1P35A_Contest_202606/1_安路工具和软件/FD_Release_2026.2.exe` → 默认装 `D:\Anlogic\FD_Release_2026.2`。
- 主程序：`D:\Anlogic\FD_Release_2026.2\fd.exe`。
- **自带**（不需另装 xPack GCC）：
  - RISC-V GCC：`toolchain/gcc/riscv/ph1p35/bin/`
  - OpenOCD：`toolchain/openocd/fpsoc/bin/openocd.exe`
  - GDB：`toolchain/gcc/riscv/ph1p35/bin/riscv64-unknown-elf-gdb.exe`
- OpenOCD target cfg：`toolchain/openocd/fpsoc/share/openocd/scripts/target/anlogic/ph1p35.cfg`

### 7.1 HPF（Hardware Platform File）流程

1. TD 配 MCU IP + 综合 + 生成 bit → **Export HPF**（菜单导出，`.hpf` 文件）。
2. FD：New Platform Project → 选 HPF → standalone → processor `rpu` → 生成 BSP（`soc_plat.h/c` 等）。
3. FD：New Application Project → 模板（HELLO_WORLD / EMPTY / AHBDemo / QSPI_XIP_FLASH / CoreMark 等）。
4. Build → `.elf`；Debug As → GDB OpenOCD Debugging → Load elf → F8 Resume。

HPF 是个 zip（`PK` 头），含 `HPFs/Design.xml`、`HPFs/soc_plat.h`、`HPFs/soc_plat.c`、`HPFs/hpf.info` 等。

> **只改 main.c 不用重导 HPF**；改 MCU IP 参数/硬件/总线/外设才重导，并在 FD 里 Platform → Change Referenced HPF → Re-generate BSP Sources。

### 7.2 平台 bit（`${bsp_loc}/platform/PH1P35.bit`）会过期

FD Platform 的 `platform/PH1P35.bit` 是**导 HPF 那一刻**的 bit。若后续硬件改了（如本项目 B6 改了 AHB 从口、B7 切了 H1），这个 bit 就**过期**。FD 启动配置默认 `Program FPGA=勾` 会烧这个旧 bit → 固件行为异常。

- **指南 §11.5 推荐**：`Program FPGA` **不勾**，先在 TD 手工下载最新 bit，再 FD Debug。
- 或：硬件改完后**重导 HPF** + Platform Change Referenced HPF，刷新 `platform/PH1P35.bit`。

## 8. OpenOCD / JTAG 排错（实测）

### 8.1 `OpenOCD failed with code (1)` —— 先确认 bit 已下载

OpenOCD 连的是**已配置好 bit 的 FPGA**。没烧 bit → FPGA 没配置 → JTAG 链上没 MCU TAP → 扫描全 1 → 失败。

指南 §13.3 推荐顺序：**① 上电 → ② TD 下载最新 bit → ③ 开串口 → ④ FD Debug**。第 2 步不可省。

### 8.2 `libusb_open() failed with LIBUSB_ERROR_ACCESS` —— 驱动问题

OpenOCD 用 libusb（要 WinUSB 驱动）。板载 USB-JTAG 默认是 D2xx（FTDI 私有）→ libusb 访问被拒，OpenOCD 回退 D2xx（能连但 "(null)" 设备名）。当下 D2xx 回退能扫描，驱动问题仍然存在；要彻底解决，用 Zadig 把下载线驱动换成 WinUSB（libusbK）。

### 8.3 典型报错对照（指南 §14）

| 现象 | 含义 | 处理 |
|---|---|---|
| `OpenOCD failed with code (1)` | 启动/目标检查失败 | 看 OpenOCD Console；确认 JTAG Cable、bit、ph1p35.cfg |
| `JTAG scan chain ... all ones` / `IR capture error; saw 0x1f` | 链上没 TAP | 没烧 bit / 烧了 JTAG_SEL=1 的旧 bit；烧最新 bit |
| `riscv0.cfg = 0xffffffff` | JTAG 链不匹配 | 不要强制 INIT_PARM；恢复默认；确认 IP JTAG 未误勾 |
| `clock speed 100/1000 kHz 都失败` | 频率非根因 | 恢复 1000 kHz，别降频浪费时间 |

## 9. 固件 printf 坑（BSP 极简 printf）

- AL_LOG 宏（`al_utils_def.h`）：`SIMPLE_PRINTF` 定义时 → `al_simp_printf`；否则 → newlib `printf`。PH1P35 小内存走 **al_simp_printf**。
- `al_simp_printf`（`lib/log/src/al_simp_printf.c`）：支持 `%c/%s/%d/%u/%x/%llu/%lld/%f`，**`%x` 输出大写 hex**（LUT 含 A-F），**不支持 `%X`（大写 specifier）/`%0Nx` 宽度限定符**。
  - `%04X` 会被解析器吞掉 "04X" 直到下一个 specifier → 字段错位、丢字段。
  - 解决：hex 字段用自写 `putx(val, width)`（经 `al_simp_putchar`，extern 声明——它不在公开头里），`%d` 留给 flag 字段。
- `anl_printf`（`StdPeriphLib`）是**另一套**极简 printf，**不在链接 lib 里**（直接 extern 会 undefined reference）。AL_LOG 走的是 `al_simp_printf`，不是 `anl_printf`。

## 10. 单一真相源（冲突时）

1. **本项目已上板验证的源码**（`work/camera_hdmi_720p/`）：
   - `ip/mcu/`（重生后的 mcu IP + `.params/.ports`）
   - `rtl/mcu/ps_wrapper.v`（MCU 例化：core_clk=300M、timer_clk=C0、AHB master→ahb_status_slave）
   - `rtl/mcu/ahb_status_slave.v`（fabric AHB 从口，地址 0x80000000+偏移）
   - `constraints/timing.sdc`（pll_clk_300m、MCU core_clk 异步组）
   - `mcu_fw/main.c`（固件：读 AHB 状态、UART0 上报）
2. MCU 指南 PDF（`ref/MCU_ref/00_使用指南/`）。
3. DS1300 / DS1301。
4. FD 自带 addrmap / demos / BSP。

> 凡与本项目源码不一致处，以源码为准（已在文中标注）。
