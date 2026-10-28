# MCU 钢珠检测固件（mcu_fw）

本目录的 `main.c` 是 PH1P35 MCU 上运行的钢珠检测后处理固件。RTL（`rtl/cv/cv_top.v`）
只做像素级前端：4×4 平均 → 320×180 → |G−BG| → run 提取；CCL、形状筛选、碎块合并、
跟踪、门线计数、overlay 全部由本固件完成。

## 1. 参数区（只改这里）

`main.c` 顶部有一段醒目的注释：

```
/* =====================================================================
 *                        调 参 区（只改这里）
 * ===================================================================== */
typedef struct { ... } vision_params_t;
static const vision_params_t VISION_PARAMS = { ... };
/* ============================ 调参区结束 ============================ */
```

**所有业务阈值、几何、跟踪参数都在 `VISION_PARAMS` 里，RTL 不写死任何检测阈值。**
改完只需重新编译 MCU 固件，不需要重新综合 FPGA。

### 1.1 前端 / 背景

| 字段 | 默认 | 说明 |
|---|---:|---|
| `enable` | 1 | 1=启用钢珠前端；0=只保留摄像头直通 |
| `bg_thr` | 30 | 背景差分阈值（0..255，作用在 320×180 的 4×4 平均值上） |
| `min_run` | 2 | run 最短长度（320 尺度；1=不过滤，2=去孤立点噪声） |
| `bg_capture_delay` | 120 | 相机配置/DDR 就绪后再等多少帧采背景（≈2 s @60 fps） |
| `bg_settle_frames` | 10 | 先 enable（关 edge/OSD、切摄像头）后等多少帧再采背景，用于清 DDR/OSD 流水线 |

### 1.2 连通域筛选（320×180）

| 字段 | 默认 | 说明 |
|---|---:|---|
| `min_area` / `max_area` | 100 / 1500 | 面积上下限 |
| `min_w` / `max_w` | 18 / 100 | bbox 宽上下限 |
| `min_h` / `max_h` | 5 / 50 | bbox 高上下限 |
| `min_fill` | 0 | 填充率下限（百分比，0=不检查） |
| `min_ratio` | 0 | 短边/长边下限（百分比，0=不检查） |
| `edge_margin` | 0 | 贴边剔除像素（320 尺度，0=不剔除） |
| `merge_dist` | 34 | 碎块合并半径（320 尺度，约 0.8·D；D/4≈43） |
| `max_run_len` | 200 | 单行 run 最大长度，超过丢弃；用于剔除底部球堆/横向大团块（0=不过滤） |

### 1.3 几何

| 字段 | 默认 | 说明 |
|---|---:|---|
| `box_w_small` | 43 | 固定 2R 框边长（320 尺度；40 mm 标定 D≈171.3 px → 43） |
| `gate_x` | 96 | 门线 x（320 尺度；0.30×320） |
| `gate_y0` / `gate_y1` | 14 / 166 | 门线 y 范围（320 尺度；0.08..0.92×180） |
| `roi_y1` | 166 | CCL 只处理 `y <= roi_y1`；用于跳过底部球堆/反光（<0 或 >=180 表示不过滤） |

只有从右向左穿过 `gate_x` 的可见轨迹才计数；反向滚动不计数。

### 1.4 跟踪 / 运动门控

| 字段 | 默认 | 说明 |
|---|---:|---|
| `track_gate` | 55 | 最近邻关联半径（320 尺度，欧氏距离；220/4） |
| `max_miss` | 5 | 连续丢失多少帧删轨迹 |
| `min_hits` | 2 | 确认所需命中数 |
| `min_move` | 9 | 总位移门限（320 尺度，约 0.2·D） |
| `min_window` | 21 | 最近 5 帧位移门限（320 尺度，约 0.5·D） |
| `vx_max` | -1 | 左向速度门限（320 尺度，负数；对应全分辨率 −4 px/帧） |
| `static_max_age` | 30 | 静态轨迹最多存活帧数 |

可见条件（与 Python 参考实现一致）：

```
hits >= min_hits
&& misses == 0
&& moved >= min_move
&& window_move <= -min_window
&& vx <= vx_max
```

只有可见轨迹才画绿框、才可能计数。

### 1.5 调试

| 字段 | 默认 | 说明 |
|---|---:|---|
| `debug` | 1 | 1=输出 `D ...` 调试行 |
| `debug_div` | 30 | 每多少帧输出一行 `D`（调参时可改 5..10，部署时可改 60 或设 `debug=0`） |

## 2. 背景采集时序（重要）

上电/复位后固件执行：

1. 等 `CAM_REG.CFG=1` 且 `DDR=1`。
2. 等 `bg_capture_delay` 帧，让曝光/补光稳定。
3. 写 `BALL_CTRL=1`：**先 enable**。这样 `S_ball_en=1` 会立即关掉 edge 检测和 OSD，
   并把 `video_mux` 强制切到摄像头；等 `bg_settle_frames` 帧清空 DDR/OSD 流水线。
4. 写 `BALL_CTRL=3`：enable=1 + capture=1，在下一个 vsync 采一帧**干净的空滑道**背景。
5. 等 `BALL_STATUS.bg_ready=1`，写 `BALL_CTRL=1`，开始正常检测。

> **采背景时滑道必须为空。** 如果上电时已有钢珠，背景会把钢珠学进去。
> 需要重采背景时，复位 MCU（或重新上电）并保持滑道空。

固件没有做 Python 版的 IIR 背景更新；RTL 只保存一帧背景。现场光照恒定时这样最简单，
也最省 BRAM。如果长时间运行后相机曝光漂移，重采一次背景即可。

## 3. 串口输出

串口 115200 8N1（UART TX = H1）。

上电时先打印参数（每行以 `VP` 开头），然后：

```
BALL BG ready=1
```

周期状态行（每 30 帧）：

```
CAM ID=EE4B OK=1 E=0 CFG=1 DDR=1 SW4=1 SW3=0 CV=1 TH=1E BG=1 OVF=0 LBL=0 CNT=3
SW1=0 SW2=1 SW3=0 SW4=1 SW5=NA SW6=NA
```

- `BG`：背景已就绪
- `OVF`：本帧 run_mem 溢出（该帧被跳过，只做轨迹老化）
- `LBL`：CCL 标签/行 run 溢出（该帧检测被丢弃）
- `CNT`：门线计数
- `SW1..SW4`：拨码开关原始状态（拨上=1）
- `SW5/SW6`：板级硬件开关，未接 FPGA IO，无法读取，固定显示 `NA`

调试行（`debug=1` 时每 `debug_div` 帧）：

```
D F=1234 RUN=96 NC=5 DET=2 OVF=0 LBL=0 SR=0 SL=0 B=1,2,0 | *640,120,80,140,100 .80,300,20,310,30
```

- `F`：帧号低 24 位
- `RUN`：本帧 run 数
- `NC`：CCL 标签数
- `DET`：经过形状筛选 + 碎块合并后的检测数
- `OVF`：run_mem 溢出
- `LBL`：CCL 标签/行 run 溢出（该帧检测被丢弃）
- `SR`：因 `roi_y1` 跳过的 run 数
- `SL`：因 `max_run_len` 跳过的 run 数
- `B=a,b,c`：面积分桶 `<100 / 100..499 / >=500`
- `|` 后是面积最大的几个连通域；`*` 表示通过形状筛选，`.` 表示被筛掉；
  数字依次为 `area,x0,y0,x1,y1`（320×180 坐标）

## 4. 调参流程

### 4.1 只改 C 参数

```powershell
cd work\camera_hdmi_720p

# 1) 同步 main.c 到 FD 工程并强制重编 main.c.o
powershell -ExecutionPolicy Bypass -File tools\sync_fw.ps1

# 2) 命令行编译（也可以直接用 FD IDE 的 Clean/Build）
$env:Path='D:\Anlogic\FD_Release_2026.2\toolchain\build-tools\bin;D:\Anlogic\FD_Release_2026.2\toolchain\gcc\riscv\ph1p35\bin;'+$env:Path
make -C C:/Users/Z___C/FDWork/ph1p35_status `
  TARGET=ph1p35_status `
  SDK_ROOT=C:/Users/Z___C/FDWork/MCU_startup `
  COMPILE_PREFIX=D:/Anlogic/FD_Release_2026.2/toolchain/gcc/riscv/ph1p35/bin/riscv64-unknown-elf- -j4
```

然后用 FD IDE 的 Debug 配置加载 `build/ph1p35_status.elf`，Resume。

### 4.2 改了 RTL

需要重新跑 `syn_1` 和 `phy_1`：

```powershell
cd td_project\camera_hdmi_720p_Runs\syn_1
cmd /c "run.bat < nul"

cd ..\phy_1
cmd /c "run.bat < nul"
```

> 必须用命令行 `run.bat`，不要用 TD GUI 的 Run：GUI 会重写 `settings.cfg`，
> 丢掉 DDR IP 的 `IpADCList/IpSDCList` 约束（SYN-8534）。

### 4.3 典型调参顺序

1. **先看 `D` 行**：
   - `RUN=0`：背景/阈值问题。检查滑道是否空、`BG=1`、`bg_thr` 是否过高。
   - `RUN` 很大且 `OVF=1`：噪声/阈值过低。提高 `bg_thr` 或加 `min_area`。
   - `DET=0` 但 `|` 后有 `*`：跟踪/运动门控问题，看 `track_gate`、`min_move`、`min_window`、`vx_max`。
   - `DET>0` 但无绿框：轨迹还没满足 `min_hits`/`min_move`/`min_window`，或 `misses>0`。
2. **阈值**：`bg_thr` 从 30 起，漏检降到 20..25，噪声多升到 40..60。
3. **孤立点**：`min_run` 默认 2，RTL 直接丢弃 1 像素 run；噪声多可升到 3..5，
   细小碎块被误丢时降回 1。
4. **形状**：根据 `D` 行的 `area,x0,y0,x1,y1` 调 `min_area/max_area/min_w/max_w/min_h/max_h`。
5. **碎块**：一颗球被阈值切成几块时，增大 `merge_dist`（30..40）；两颗球被误合并时减小。
6. **跟踪**：钢珠快时增大 `track_gate`（55..80）；误关联多时减小。
7. **运动门控**：静态划痕/反光误框时增大 `min_move`/`min_window`；真实球漏框时减小。
8. **框大小**：`box_w_small = round(D/4)`；当前 40 mm 标定 D≈171.3 px → 43。
9. **门线**：`gate_x = round(0.30*320) = 96`；`gate_y0/y1` 默认 14/166。

## 5. RTL / 寄存器边界

MCU 通过 AHB-Lite 访问 `0x8000_0000`：

| 偏移 | 名称 | 方向 | 说明 |
|---:|---|---|---|
| 0x00 | CAM_REG | R | 相机/板级状态 |
| 0x04 | CV_REG | R | `bin_thr`、run_cnt、frame_cnt 低 8 位 |
| 0x08 | FRAME_REG | R | vsync 帧计数 |
| 0x0C | VER_REG | R | `0x4D435602`（MCV2） |
| 0x10 | HEARTBEAT | W | 心跳 |
| 0x18 | RUN_IDX | W | run_mem 读索引（10 bit） |
| 0x1C | RUN_DAT | R | run_mem 数据（3 次读后取新值） |
| 0x20 | OV_IDX | W | overlay 索引 0..7 |
| 0x24 | OV_W0 | W | overlay 高 32 位 |
| 0x28 | OV_W1 | W | overlay 低 32 位，写入提交 |
| 0x2C | META_REG | R | `{run_cnt[10:0], min_y, max_y, ...}` |
| 0x30 | OV_COUNT | W | 计数值（cv_top 显示 4 位 hex） |
| 0x34 | BALL_CTRL | W | `[0]=enable [1]=capture` |
| 0x38 | BALL_THR | W | `[7:0]=bg_thr`，`[15:8]=min_run` |
| 0x3C | BALL_STATUS | R | `[0]=bg_ready [1]=capturing [2]=run_overflow` |

`run_mem` 项格式：`{row_y[9:0], xs[10:0], xe[10:0]}`（32 bit，320×180 坐标）。
`overlay` 项格式：`{valid, id[3:0], x0[11:0], y0[11:0], x1[11:0], y1[11:0]}`（64 bit，1280×720 坐标）。

## 6. 当前实现与 Python 参考的差异

1. **背景**：RTL 是单帧快照；Python 是 IIR（`bg_shift=4`）。现场光照恒定，快照够用；
   曝光漂移时重采背景。
2. **形态学**：RTL 没有 3×3 close/open；C 用形状筛选 + 碎块合并补偿。
   如果现场噪声大，优先提高 `bg_thr`/`min_area`，或后续在 RTL 加 3×3 滤波。
3. **run_mem 单缓冲**：MCU 在 vsync 后立即读上一帧 run；CPU 远快于像素扫描，正常不会撕裂。
   `BALL_STATUS[2]` 会在 run 数超过 1024 时置位，固件跳过该帧。
4. **时序**：当前 bitstream 的 2 个 setup 违例端点均在
   `u_isp_top/u_awb → u_edge_detect_96`（edge 模式，M6 遗留）；
   钢珠模式 `edge_on=0`，该路径被旁路；摄像头/钢珠 overlay/OSD 数据路径均干净。

## 7. 当前构建产物（2026-10-28）

- bit：`td_project/camera_hdmi_720p_Runs/phy_1/camera_hdmi_720p.bit`
  - size 1,789,539 B，MD5 `341B1A2C38D7BEC9FCFD9826E4C027B2`
  - Setup WNS −1.137 ns / Hold +0.020 ns / 2 violated endpoints
    （均为 edge Sobel `awb→edge`；ball mode 旁路）
  - slices 16,078 / 21,216（75.78%），EBR 68/108，DSP 10/40
- ELF：`C:\Users\Z___C\FDWork\ph1p35_status\build\ph1p35_status.elf`
  - size 204,760 B，MD5 `814512928604BB9409AF855CE3297B1E`
  - text 35,912 B / data 600 B / bss 11,596 B

## 8. 上板检查清单

- [ ] 烧录新 bit（`phy_1/camera_hdmi_720p.bit`）
- [ ] 加载新 ELF（`build/ph1p35_status.elf`），Resume
- [ ] 串口 115200 8N1 能看到 `VP ...` 三行
- [ ] 上电时滑道为空，看到 `BALL BG ready=1`
- [ ] 摄像头画面正常（钢珠模式不受 SW4/SW3 影响，会自动切到摄像头并关 edge/OSD）
- [ ] 钢珠从右向左滚过 x=0.30·W，出现绿框且 `CNT` 增加
- [ ] 反向滚动不计数
- [ ] 静态划痕/反光不出现持续绿框
- [ ] 若漏检：抓 `D` 行，按第 4.3 节定位是 RUN、DET 还是跟踪阶段
