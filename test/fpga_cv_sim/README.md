# fpga_cv_sim — M9 当前 RTL/固件的离线视频仿真

把一段 1280×720 视频当作 `cv_top` 看到的摄像头像素流，**逐帧复刻当前仓库里的
`rtl/cv/cv_top.v` + `mcu_fw/main.c`**，输出板子会显示的 CV 画面。

不是"近似算法演示"：阈值、Sobel 窗口、run 提取的边界行为、`MAX_RUNS=1024`
截断、软件 CCL/筛选/跟踪/计数、overlay 打包与叠加优先级，都按源码实现；
`--selftest` 会用逐像素直译版 RTL 对拍 run 提取。

## 用法

```powershell
# 自检（向量化 run 提取 vs 逐像素直译）
python test/fpga_cv_sim/fpga_cv_sim.py --selftest

# 默认：test/video_20261020_183037.mp4 → 机器视角（MASK_VIEW=1）
python test/fpga_cv_sim/fpga_cv_sim.py

# 原画视角（便于看框落在哪）+ 指定阈值
python test/fpga_cv_sim/fpga_cv_sim.py --view image --thr 80

# 只看一段
python test/fpga_cv_sim/fpga_cv_sim.py --start 200 --end 500

# 一键跑自检 + 两种视角
powershell -File test/fpga_cv_sim/run.ps1
```

输出（`test/fpga_cv_sim/out/`，已被本目录 `.gitignore` 忽略）：

| 文件 | 内容 |
|---|---|
| `*_fpga_th80_mask.mp4` | 与板子一致的机器视角：黑白 Sobel mask + 绿框 + 白 ID + 左上 Count |
| `*_fpga_th80_image.mp4` | 同一份叠加，但底图用输入原画 |
| `*_stats.csv` | 每帧 `run_cnt / overflow / n_labels / n_det / n_trk / n_overlay / count / boxes` |

视频默认走 `ffmpeg` + libx264（`--codec auto`，有 ffmpeg 时），`--crf 26`；
没有 ffmpeg 会自动退回 OpenCV `mp4v`。本片段机器视角约 88 MB（画面本身就是
逐像素噪声，压缩率差），原画视角约 3 MB。

## 模型对照表

| 仿真 | 源码 |
|---|---|
| `luma()` | `cv_top.v` `w_y = R[7:2] + G[7:1] + B[7:2]`（不是标准灰度） |
| `sobel_mag()` | `cv_top.v` 3×3 Sobel + 2 级流水（窗口中心 = 扫描点 (x-1,y-1)） |
| `frontend_mask()` | `MASK_SRC=1`：`mag > EDGE_THR`（严格大于） |
| `extract_runs()` | `cv_top.v` run FSM，含 `x=1279` row_last 丢像素、跨行 carry、vsync 以 `y=720` 落盘等边界行为 |
| `Mcu._ccl()` | `ccl_init/ccl_step/ccl_finalize`：union-find、`MAX_LABELS=64`、`MAX_PREV=128` |
| `Mcu._track()` | `track_update()`：贪心 NN、`GATE=240`、`ALPHA=0.5/BETA=0.0625`、exit/death 计数 |
| `render()` | `cv_top.v` 叠加组合逻辑：`FBOX_W=2`、5×7 `f_digit`、Count@(24,56)、优先级 |

关键参数（与源码一致）：`MAX_RUNS=1024`、`MAX_LABELS=64`、`MAX_DET=8`、
`MAX_TRK=8`、`MIN_AREA=8`、`MAX_AREA=20000`、`MIN_FILL=15%`、`MIN_RATIO=25%`、
`EDGE_MG=4`、`MISS_K=20`、`MIN_HITS_EX=4`、`MIN_HITS_DT=5`、`EXIT_MISS=10`。

默认 `--latency 1`：第 k 帧的 run 在 vsync 后由 MCU 处理，overlay/count 从
第 k+1 帧才出现（与板子上 MCU 在消隐期更新寄存器一致）。`--latency 0` 可关闭。

## 本片段（video_20261020_183037.mp4）的预测结果

输入：1280×720@60，19.0 s / 1141 帧，手机 HEVC 录制（含音频）。

跑完整段（`--thr 80`，默认）：

```
frames: 1141   平均 run=1024.0   溢出帧=1141/1141
labels 恒 64（饱和）   det 2~8   overlay 0~8   Count 最终 43
所有绿框的 y 都 ≤ 177（球出现在 y≈200~320）
```

也就是说：**当前参数下这块画面每帧都会把 `run_mem` 写满，MCU 只能看到最上面
约一百多行的碎片，钢珠本体永远进不了 CCL**；左上 Count 会持续上涨，但基本是
噪声轨迹的 exit/death 误计。这与 M9 上板观测（`RUN=1024`、`y1 ≤ ≈330`、
`NC=64`、小碎片被框）是同一失败模式，只是这条手机录像的压缩/摩尔纹更锐利，
截断位置更高。

> 注意：`--thr` 是**最终生效阈值** `eff_thr`。仓库里 `r_user_off` 用 8 位无符号
> 相加、溢出时钳到 255，所以"从 80 往下按 K3"在 RTL 里实际会得到 255，而不是
> 更小值。仿真不做按键序列，直接给最终阈值；`--thr 50` 只用于假设性对照。

## 为什么钢珠没有绿框（M9 当前 RTL 的真实结果）

逐帧查过 run/label 后，原因不是画框逻辑，而是球根本进不了 MCU 的 CCL：

| 环节 | 实测（frame 240，球在 y=184~249 与 y=471~541） |
|---|---|
| `MAX_RUNS=1024` | 第 1024 条 run 落在 **y≈180**；球所在行全被截掉 |
| 放大到全帧 run 后 | 球环其实是一个合法连通域（bbox≈60×65、area≈1620、fill≈41%、ratio≈92%，能过形状筛选） |
| `MAX_LABELS=64` | 一帧有几千个噪声连通域，label 立刻饱和到 63，球环被并进"全屏大团块"（area>20000）后丢弃 |
| `MAX_DET=8` | det 按 label 出现顺序取前 8 个（不是按面积），噪声碎片占满名额 |

也就是说：**当前 M9 的 Sobel + run + 64-label 软件 CCL 在这条画面上物理上框不到球**，
Count=43 是噪声轨迹的 exit/death 误计。这与 M9 上板照片（`work/test/M9_00/`）
是一致的：板上也只框到球面高光的小碎片，Count 已经跑到 `021C`(540)。

## blkdet_sim.py：块域检测管线的识别结果

仓库 `Python/PYTHON2/` 里还有一套更新的**块域暗块检测 + a-b 跟踪**管线
（其 README 称与 `cv_blkdet` RTL 同参；该 RTL **不在本仓库任何分支**）。
`blkdet_sim.py` 就是它的移植版，只把 PC 风格的 `IDn / COUNT=` 换成 M9 的 OSD 风格
（绿框 + 5×7 ID + 左上 4 位 hex Count）。

```powershell
python test/fpga_cv_sim/blkdet_sim.py                    # exit 计数（球滚出画面）
python test/fpga_cv_sim/blkdet_sim.py --count-rule combined
python test/fpga_cv_sim/blkdet_sim.py --dark 100 --gate 240 --miss-k 35
```

同一段 `video_20261020_183037.mp4` 的结果：

| 计数规则 | COUNT | 说明 |
|---|---|---|
| `exit`（默认） | **6** | 球滚出画面即计；事件帧 256/433/447/649/868/929 |
| `combined` | 17 | 出画面 + 消亡补计 |
| `death` | 31 | 只按轨迹消亡，误计最多 |

输出：`out/video_20261020_183037_blkdet_exit.mp4`。
对照图：`out/compare.png`（输入 / M9 当前 RTL / blkdet 三行）。

> 这不是 M9 bit 的逐周期输出，而是"块域算法在 PC 上的识别结果"。
> 若要让板子也这样，需要把 `cv_blkdet` 合并进本仓库 RTL 并重编，
> 或者把 M9 前端改成块域检测。

## 局限（有意不建模）

- 输入视频是手机拍摄的同一场景，不是 SC520CS 的原始 ISP 输出（锐度、噪声、
  视场都不同）。本仿真回答的是"把这段视频喂给当前 RTL 会发生什么"。
- 不模拟 DDR2 帧缓存、HDMI 时序、ISP、跨时钟域、MCU 处理耗时与 run_mem
  读写撕裂；MCU 被假设在下一帧有效区开始前处理完。
- 输入若与 1280×720 不同会先 `INTER_AREA` 缩放。
- 计数从 0 开始、不模拟中途按键复位/切换 CV。

## 想验证改法时

直接改 `Cfg` 里的常量（等价于改 RTL/固件后重编），例如把 `max_runs` 改成
4096 看球是否进入 CCL、把 `edge_thr` 改成 200 看噪声是否下降。建议同时保留
`MAX_RUNS=1024` 的基线输出做对照。
