# PYTHON2 — 本项目 Python 代码汇总

> 从 `D:\anlogic-fpga-design` 复制出来的**全部有用 Python**（2026-10-15）。
> 原仓库最新提交 `9b38f1e`（`minor` 分支，领先 `origin/minor` 35 个提交，未推上去）。

## 目录

| 目录 | 来源 | 说明 |
|---|---|---|
| **`sim\`** | `work/camera_hdmi_720p/tools/sim/` | RTL 各模块的离线仿真；**`cv_pipeline_sim.py` 是当前主仿真** |
| `tools\` | `work/camera_hdmi_720p/tools/`(+`td_run/`) | 辅助脚本（RTL 检查、串口时序、工程同步）|
| `impl_a\` | `Python/impl_a/` | **算法原型**（浮点 + OpenCV：检测/跟踪/计数/OSD）|
| `impl_hw\` | `Python/impl_hw/` | 原型的**"硬件可实现"定点重写**（曾作 RTL 黄金参考）|

## 哪个是"当前有效"的

### ✅ `sim\cv_pipeline_sim.py` —— 唯一与当前 RTL 对齐的

与 RTL（`cv_blkdet` + `cv_top`）**同参的定点流程**：块域局部对比检测 → 跟踪 → 计数。
本轮全部验证都用它跑，**六段实拍录像结果全部与真值一致**：

| 片 | 帧率/帧数 | 结果 | 真值 |
|---|---|---|---|
| 钢珠1 | 30 / 331 | 6 | 6 |
| 钢珠2 | 30 / 261 | 9 | 9 |
| 钢珠3 | 30 / 407 | 10 | 10 |
| 钢珠4 | 60 / 814 | 10 | 10 |
| 钢珠5 | 60 / 431 | 10 | 10 |
| 钢珠8 | 60 / 631 | 10 | 10 |

**用法**：
```bash
python cv_pipeline_sim.py <输入视频> <输出视频> [gate] [miss_k] [dark] [min_hits] [--amin N] [--count-rule combined|exit|death]
# 例（当前定稿参数）：
python cv_pipeline_sim.py 钢珠4.mp4 out4.mp4 240 35 120 5
```

**当前定稿参数**（与 RTL 一致）：
| 项 | 值 |
|---|---|
| 块网格 | 80×45（16×16 像素/块，仅 720p）|
| 局部对比 | 10×6 大格背景（上一帧），`CB_DELTA=20` |
| `MIN_BLKN` | **14**（滤桌沿 8~13 块假块）|
| 贴球拆分 | 长短边比 ≥150% 且面积 ≥24 块 → 拆双框 |
| 跟踪增益 | `ALPHA=0.5`、`BETA=0.0625` |
| 丢失删除 | `MISS_K=35`（字段 6 位）|
| 出画面即时计数 | `EXIT_MISS=10`、命中 ≥4 |
| 消亡补计 | 命中 ≥5 |

### ⚠️ `impl_hw\` —— **已过期，不再是黄金参考**

它在 2026-10-11（提交 `3af672c`）加入，**早于本轮所有改动**：仍用"光照归一化 + IIR 背景 + 形态学"
的旧方案（`hw_config.py` 里还是 `min_hits=3`），**没有**局部对比、贴球拆分、增益下调、
`MISS_K`/`MIN_BLKN`/计数门限分离。**要与当前 RTL 对拍需先按新算法重写。**

### `impl_a\` —— 算法原型（参考思路用）

浮点 + OpenCV 的原始算法（`detector.py` / `tracker.py` / `counter.py` / `preprocess.py` / `osd.py`）。
历史真值：钢珠3/4/5 = 10/10/4。

## 未包含

- **RTL（Verilog）**：仍在 `work/camera_hdmi_720p/rtl/`（`cv/cv_blkdet.v`、`cv/cv_top.v`、`top/design_top_wrapper.v` 等）——本文件夹按要求只放 Python。
- 测试录像（桌面 `钢珠N.mp4` 及 `*_计数结果.mp4`）。
