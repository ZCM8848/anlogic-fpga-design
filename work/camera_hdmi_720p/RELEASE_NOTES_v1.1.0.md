# camera_hdmi_720p v1.1.0

PH1P35MDG324 / HX1P35A 开发板上的 SC520CS 摄像头钢珠检测工程。在 v1.0.0 基础上新增 USART 串口在线热调参与上位机工具，运行期间修改全部检测参数无需重新综合 FPGA。

FPGA 完成 MIPI 接收、ISP、DDR2 帧缓存、HDMI 输出、4×4 平均、背景差分、run 提取、门线绘制和 OSD；MCU 完成 CCL、筛选、跟踪、门线计数、背景重采、曝光/增益控制、蜂鸣器调度与串口热调参。

## 相比 v1.0.0 的新增内容

- **USART 串口在线热调参**：USART0 RX 接 J1、TX 接 H1，115200 8N1，主循环轮询 RX FIFO（不开中断），支持 `GET` / `SET <name> <value>` / `APPLY` / `DEFAULT` / `RECAPTURE` / `VER` 命令。
- **运行时参数区**：默认参数保存在 Flash 的 `VISION_PARAMS_DEFAULT`，上电复制到 DLM 中的运行副本 `vp`；`SET` 修改 `vp`，`APPLY` 写入 `BALL_THR` / `BALL_RUN_CFG` / `BALL_GATE` / `CAM_AE` / `CAM_AG` / `BUZZ_CFG` 并清空轨迹。掉电恢复默认值。
- **曝光/增益运行时可调**：`CAM_AE` / `CAM_AG` 由 `APPLY` 在线写入，修改后建议执行一次 `RECAPTURE` 重采背景。
- **`gate_y1` 上限放宽到 180**：覆盖门线全高，与 `roi_y1=180` 一致。
- **上位机工具**：`tools/param_tuner/param_tuner.py` 提供图形化调参界面，可打包为 `camera_param_tuner.exe`。
- **`MAX_LABELS` 由 96 调整为 80**：释放 DLM 空间存放运行时参数副本。

## 适用硬件

- PH1P35MDG324 / HX1P35A 开发板
- SC520CS 摄像头，1280×720@60，2-lane MIPI RAW10，828 Mbps/lane
- HDMI 1280×720@60 输出
- Tang Dynasty 6.2.168116

## 产物

| 文件 | MD5 | SHA256 |
|---|---|---|
| `camera_hdmi_720p_v1.1.0.bit` | `51B960EBD6592266102ACA03E70672E7` | `71CF589C58510C4716F33D8182A9DD8D115D1A559204C50F6AAB088166E71560` |
| `ph1p35_status_v1.1.0.elf` | `3BA844A1E22DA8D74C9A80DF40ACDCC5` | `F98E1DFE6E9E0F8519E683842DE57E64090A53078B71DBE33B8807EDCE222374` |
| `ph1p35_status_v1.1.0.bin` | `9C531A4A24C10F95EBE8926538C26F23` | `D19604787655A9D9FF93282D8438B06BC185A10C16CD0AFCAB311304201C0C39` |

`bin` 用于烧录到 Flash（MCU XIP 偏移 `0x00E00000`，运行地址 `0x20E00000`），掉电不丢失。

烧录顺序：bit → ELF → Resume。bit 与 ELF 必须成对使用。只更换 ELF 可以调整检测参数，不需要重新综合 FPGA；运行期间通过串口热调参修改参数则连 ELF 都不需要重新烧录。

## 功能

- 1280×720@60 摄像头采集、DDR2 4 帧乒乓缓存、HDMI 1.4b 输出
- FPGA 4×4 G 通道平均到 320×180，背景差分、逐行 run 提取
- MCU union-find CCL、面积/宽高/填充率/长短比筛选、碎块合并、a-b 跟踪
- 只有可见轨迹从右向左穿过门线才计数，反方向不计，最多 7 个同时可见钢珠
- 识别态 UI：Logo、`STEEL BALL`、Count、`DETECTED N`、`Anlogic HX1P35A`、`FRAME 000123` 和门线
- 门线 `#FF3366`，2 像素宽，位置由 MCU `gate_x` / `gate_y0` / `gate_y1` 控制
- 所有可见文字使用 MiSans Medium 1-bit ROM
- 5 位 BCD 数码管与 HDMI Count，同一计数源
- K1 长按 ≥1 s 清零 Count、BCD、绿框和轨迹，仅识别态生效
- K2 长按 ≥1 s 重采背景，数码管显示 `--------`，仅识别态生效
- 静态测试图案：K1 短按播放/暂停蜂鸣器测试曲，默认暂停，离开该模式自动暂停
- 动态调试：K1 短按循环 RGB / score / mask
- 过门短鸣 1 kHz、50 ms，按球数排队，相邻两声间隔约 `beep_ms`
- 静态测试态 `buzzer_beep` 强制静音，过门事件不入短鸣队列
- 测试图案显示 `HDMI TEST 1280X720` 与 `MiSans by Xiaomi` 来源标注
- 曝光和增益由 MCU 控制，不再使用 N2/J14 按键
- **串口热调参**：运行期间通过 USART0 修改全部检测参数，`APPLY` 写入 FPGA 寄存器并清空轨迹，无需重新综合或烧录

## 工作模式

| SW1 | SW2 | 模式 |
|---|---|---|
| 0 | × | 识别画面 |
| 1 | 0 | 静态测试图案 |
| 1 | 1 | 动态调试 |

测试态只切换显示源和按键行为，检测、计数与背景保持运行。

## 关键参数

```text
exposure=768        gain=64
bg_thr=80           min_run=2
min_area=100        max_area=2000
min_w=18            max_w=100
min_h=5             max_h=50
merge_dist=20       max_run_len=200
gate_x=100          gate_y0=0       gate_y1=180
roi_y1=180
track_gate=55       max_miss=5
min_hits=2          min_move=5
min_window=21       vx_max=-1
beep_ms=50          beep_freq_hz=1000
```

门线全分辨率位置：`x=400`，`y=0..720`。

## 串口协议

```text
波特率  115200 8N1
TX      H1
RX      J1
命令    GET / SET <name> <value> / APPLY / DEFAULT / RECAPTURE / VER
```

`SET` 修改 MCU 侧运行参数副本；`APPLY` 校验跨字段范围后写入 `BALL_THR`、`BALL_RUN_CFG`、`BALL_GATE`、`CAM_AE`、`CAM_AG`、`BUZZ_CFG`、`BALL_CTRL` 并清空轨迹；`DEFAULT` 恢复 `VISION_PARAMS_DEFAULT`；`RECAPTURE` 调用与 K2 长按相同的背景重采流程。参数只保存在 RAM，掉电恢复默认值。完整命令字段与上位机说明见 `work/camera_hdmi_720p/mcu_fw/README.md` 与 `work/camera_hdmi_720p/tools/param_tuner/README.md`。

## 时序与资源

```text
Setup WNS +0.671 ns
Hold  WNS +0.020 ns
0 violations
Slices 17,389 / 21,216 (81.96%)
RAM    71 / 108
DSP    10 / 40
```

## 已知限制

- 背景为单帧快照，光照或场景变化后需要 K2 重采或发送 `RECAPTURE`
- 未实现形态学滤波和粘连球拆分，高光分裂依靠 `merge_dist` 和形状筛选
- `MAX_TRK=8`、`MAX_DET=8`、`MAX_LABELS=80`、`MAX_RUNS=1024` 为综合期常量
- Count 和数码管为 5 位，超过 99999 后显示回绕
- 相机固定 1280×720@60，120 fps 检测通路未实现
- K3/K4 为遗留阈值脉冲，当前 RTL 不消费
- 串口热调参参数只保存在 RAM，掉电恢复默认值

## 源码

tag `camera_hdmi_720p-v1.1.0`。
