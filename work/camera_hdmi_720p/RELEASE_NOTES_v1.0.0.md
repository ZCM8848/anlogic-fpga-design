# camera_hdmi_720p v1.0.0

PH1P35MDG324 / HX1P35A 开发板上的 SC520CS 摄像头钢珠检测工程。FPGA 完成 MIPI 接收、ISP、DDR2 帧缓存、HDMI 输出、4×4 平均、背景差分、run 提取、门线绘制和 OSD；MCU 完成 CCL、筛选、跟踪、门线计数、背景重采、曝光/增益控制和蜂鸣器调度。

## 适用硬件

- PH1P35MDG324 / HX1P35A 开发板
- SC520CS 摄像头，1280×720@60，2-lane MIPI RAW10，828 Mbps/lane
- HDMI 1280×720@60 输出
- Tang Dynasty 6.2.168116

## 产物

| 文件 | MD5 | SHA256 |
|---|---|---|
| `camera_hdmi_720p_v1.0.0.bit` | `AD9BB56382EF350F0CD714EF752EFCC1` | `449342681F8B96AC1739B30672416E04915E62A50B74764CF87AC8AF354572DC` |
| `ph1p35_status_v1.0.0.elf` | `C2226280E474EF5B847EB2673F95D91C` | `936E4B4CA3972D00B3BB6EA6483D1A4F4FE9D48C2EB95D7FCECD0AB8C7A4E377` |

烧录顺序：bit → ELF → Resume。bit 与 ELF 必须成对使用。只更换 ELF 可以调整检测参数，不需要重新综合 FPGA。

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

## 时序与资源

```text
Setup WNS +0.158 ns
Hold  WNS +0.020 ns
0 violations
Slices 17,359 / 21,216 (81.82%)
RAM    71 / 108
DSP    10 / 40
```

## 已知限制

- 背景为单帧快照，光照或场景变化后需要 K2 重采
- 未实现形态学滤波和粘连球拆分，高光分裂依靠 `merge_dist` 和形状筛选
- `MAX_TRK=8`、`MAX_DET=8`、`MAX_LABELS=96`、`MAX_RUNS=1024` 为综合期常量
- Count 和数码管为 5 位，超过 99999 后显示回绕
- 相机固定 1280×720@60，120 fps 检测通路未实现
- K3/K4 为遗留阈值脉冲，当前 RTL 不消费

## 源码

tag `camera_hdmi_720p-v1.0.0`。
