# MCU 钢珠检测固件

`main.c` 运行在 PH1P35 内嵌 RISC-V MCU 上。FPGA 只完成像素级前端：4×4 平均、背景差分、run 提取、门线绘制和 overlay 叠加；CCL、筛选、碎块合并、跟踪、门线计数、背景重采和相机曝光/增益全部由本固件完成。

## 1. 参数区

所有业务参数集中在 `VISION_PARAMS`：

```c
typedef struct { ... } vision_params_t;
static const vision_params_t VISION_PARAMS = { ... };
```

修改参数后重新编译 ELF，不需要重新综合 FPGA。

### 1.1 前端与相机

| 字段 | 当前值 | 说明 |
|---|---:|---|
| `enable` | 1 | 1=启用钢珠前端；0=只保留摄像头直通 |
| `exposure` | 768 | 曝光目标，半行单位，约 6.4 ms |
| `gain` | 64 | 增益目标，16..176；小于 16 按 16 处理 |
| `bg_thr` | 80 | 背景差分阈值，作用在 320×180 的 4×4 平均值 |
| `min_run` | 2 | run 最短长度，去掉单像素噪声 |
| `bg_capture_delay` | 120 | 上电后等待多少帧再采背景 |
| `bg_settle_frames` | 10 | 上电采背景前的流水线稳定帧数 |
| `bg_recalc_settle_frames` | 30 | K2 重采背景前的稳定帧数，同时保持数码管横线 |

### 1.2 连通域筛选

| 字段 | 当前值 | 说明 |
|---|---:|---|
| `min_area` / `max_area` | 100 / 2000 | 面积上下限 |
| `min_w` / `max_w` | 18 / 100 | bbox 宽度上下限 |
| `min_h` / `max_h` | 5 / 50 | bbox 高度上下限 |
| `min_fill` | 0 | 填充率下限，0=不检查 |
| `min_ratio` | 0 | 短边/长边下限，0=不检查 |
| `edge_margin` | 0 | 贴边剔除像素，0=不剔除 |
| `merge_dist` | 20 | 碎块合并半径，320 尺度 |
| `max_run_len` | 200 | 单行 run 最大长度，超过丢弃 |

### 1.3 几何

| 字段 | 当前值 | 说明 |
|---|---:|---|
| `box_w_small` | 43 | 固定绿框边长，320 尺度 |
| `gate_x` | 100 | 门线 x，320 尺度；全分辨率 x=400 |
| `gate_y0` / `gate_y1` | 0 / 180 | 门线 y 范围，覆盖全高 |
| `roi_y1` | 180 | CCL 只处理 `y <= roi_y1`，180=不过滤 |

只有可见轨迹从右向左穿过 `gate_x` 才计数，反向滚动不计数。

### 1.4 跟踪与运动判定

| 字段 | 当前值 | 说明 |
|---|---:|---|
| `track_gate` | 55 | 最近邻关联半径，320 尺度 |
| `max_miss` | 5 | 连续丢失多少帧删除轨迹 |
| `min_hits` | 2 | 确认轨迹所需命中次数 |
| `min_move` | 5 | 总位移门限，320 尺度 |
| `min_window` | 21 | 最近 5 帧位移门限 |
| `vx_max` | -1 | 左向速度门限，负数 |
| `static_max_age` | 30 | 静态轨迹最多存活帧数 |

可见条件：

```text
hits >= min_hits
&& missed == 0
&& moved >= min_move
&& window_move <= -min_window
&& vx <= vx_max
```

只有可见轨迹才画绿框、才可能计数。

### 1.5 调试

| 字段 | 当前值 | 说明 |
|---|---:|---|
| `debug` | 1 | 1=输出 `D` 调试行 |
| `debug_div` | 30 | 每 30 帧输出一次 |

## 2. 背景采集

上电流程：

1. 等待 `CAM_REG.CFG=1` 和 `DDR=1`
2. 等待 `bg_capture_delay` 帧，让曝光和补光稳定
3. 写 `BALL_CTRL=1`，启用前端
4. 等待 `bg_settle_frames` 帧
5. 写 `BALL_CTRL=3`，下一帧采集背景
6. 等待 `BALL_STATUS.bg_ready=1`
7. 写 `BALL_CTRL=1`，开始检测

K2 长按重采背景：

1. `SEG_CTRL=1`，数码管显示 `--------`
2. 清轨迹、绿框、`BALL_NOW`
3. 停止检测，等待 `bg_recalc_settle_frames` 帧
4. `BALL_CTRL=3` 采集背景
5. 等待 `capturing` 上升，再等待 `bg_ready` 重新上升
6. `BALL_CTRL=1`，恢复检测
7. `SEG_CTRL=0`，恢复数码管

重采背景时滑道必须为空。Count、BCD、HDMI Count 保持原值。

## 3. 串口输出

串口 115200 8N1，TX=H1。

上电参数行：

```text
VP en=1 thr=80 minrun=2 capd=120 settle=10
VP camera ae=768 ag=64
VP area=100..2000 wh=18..100,5..50 fill=0 ratio=0 edge=0 merge=20 roi=180 runmax=200
VP box=43 gate=100,0..180 trk=55 miss=5 hit=2 mv=5 win=21 vx=-1 age=30
BALL BG ready=1
```

周期状态行：

```text
CAM ID=EE4B OK=1 E=0 CFG=1 DDR=1 SW4=1 SW3=0 CV=1 TH=1E BG=1 OVF=0 LBL=0 CNT=3
SW1=0 SW2=1 SW3=0 SW4=1 SW5=NA SW6=NA
```

调试行：

```text
D F=1234 RUN=96 NC=5 DET=2 OVF=0 LBL=0 SR=0 SL=0 BN=3 B=1,2,0 | *640,120,80,140,100 .80,300,20,310,30
```

字段：

- `F`：帧号低 24 位
- `RUN`：本帧 run 数
- `NC`：CCL 标签数
- `DET`：筛选和合并后的检测数
- `OVF`：run_mem 溢出
- `LBL`：CCL 标签溢出
- `SR`：ROI 丢弃的 run 数
- `SL`：超长 run 丢弃数
- `BN`：当前绿框数
- `B=a,b,c`：面积分桶 `<100 / 100..499 / >=500`
- `|` 后为面积最大的几个连通域，`*` 表示通过筛选，`.` 表示被拒绝

## 4. 调参流程

### 4.1 只改 C 参数

```powershell
cd work\camera_hdmi_720p

powershell -ExecutionPolicy Bypass -File tools\sync_fw.ps1

$env:Path='D:\Anlogic\FD_Release_2026.2\toolchain\build-tools\bin;D:\Anlogic\FD_Release_2026.2\toolchain\gcc\riscv\ph1p35\bin;'+$env:Path
make -C C:/Users/Z___C/FDWork/ph1p35_status `
  TARGET=ph1p35_status `
  SDK_ROOT=C:/Users/Z___C/FDWork/MCU_startup `
  COMPILE_PREFIX=D:/Anlogic/FD_Release_2026.2/toolchain/gcc/riscv/ph1p35/bin/riscv64-unknown-elf- -j4
```

### 4.2 改了 RTL

```powershell
cd td_project\camera_hdmi_720p_Runs\syn_1
cmd /c "run.bat < nul"

cd ..\phy_1
cmd /c "run.bat < nul"
```

必须使用命令行。TD GUI 会重写 `settings.cfg`，导致 DDR IP 约束丢失。

### 4.3 典型排查

- `RUN=0`：检查背景、`bg_thr`、滑道是否为空
- `RUN` 很大或 `OVF=1`：提高 `bg_thr`、`min_area`，降低噪声
- `DET=0` 且调试行有 `*`：检查跟踪门限 `track_gate`、`min_move`、`min_window`
- `DET>0` 但没有绿框：检查 `min_hits`、`min_move`、`min_window`、`missed`
- 一颗球被拆成多块：增大 `merge_dist`
- 两颗球被合并：减小 `merge_dist` 或增加连通域拆分
- 靠近镜头的球尺寸偏大：适当增大 `max_area`、`max_w`、`max_h`
- 门线位置：修改 `gate_x`，`BALL_GATE` 会自动写入

## 5. AHB 寄存器

MCU 通过 `0x8000_0000 + offset` 访问。

| 偏移 | 名称 | 方向 | 说明 |
|---:|---|---|---|
| `0x00` | `CAM_REG` | R | 摄像头和板级状态 |
| `0x04` | `CV_REG` | R | bin_thr、run_cnt、帧计数 |
| `0x08` | `FRAME_REG` | R | vsync 帧计数 |
| `0x0C` | `VER_REG` | R | `0x4D435602` |
| `0x10` | `HEARTBEAT` | W | 心跳 |
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
| `0x60` | `CAM_AE` | W | 曝光目标 |
| `0x64` | `CAM_AG` | W | 增益目标 |

`run_mem` 项格式：`{2'b0, y[7:0], 2'b0, xs[8:0], 2'b0, xe[8:0]}`。

`overlay` 项格式：`{valid, id[3:0], x0[11:0], y0[11:0], x1[11:0], y1[11:0]}`。

## 6. 容量与限制

```text
MAX_RUNS   = 1024
MAX_PREV   = 160
MAX_LABELS = 96
MAX_DET    = 8
MAX_TRK    = 8
```

这些是综合期常量，修改后需要重新综合 FPGA。

背景为单帧快照，没有 IIR 更新。光照变化或场景变化后使用 K2 重采。当前没有形态学滤波，高光分裂依靠 `merge_dist` 和形状筛选。

## 7. 当前发布产物

```text
bit: camera_hdmi_720p_ae_mcu_E93577E7.bit
MD5: E93577E71A445D475698BA80A714343B

elf: ph1p35_status_tune_gate100_E6DFDDC8.elf
MD5: E6DFDDC8E784C607C1192C3459FC97DF
```

烧录顺序：bit → ELF → Resume。串口应出现 `VP` 参数行和 `BALL BG ready=1`。
