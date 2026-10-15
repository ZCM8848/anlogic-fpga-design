# Python/impl_hw — 钢珠跟踪与计数 · 硬件可实现版

> 本目录是 [`../impl_a/`](../impl_a/) 算法原型的**硬件可实现（FPGA-mappable）重写版**：
> 只保留可综合/可流水线化的算子（定点整数、局部窗口、逐行流式、倒数 LUT、min/max、比较器、并查集），
> **去掉了浮点、MOG2、大核 GaussianBlur、CLAHE、HoughCircles**。可与 `impl_a` 逐帧对拍，
> 也是后续写 Verilog 的"黄金参考（golden model）"。

## 1. 与 impl_a 的差异（按"硬件可实现"要求改了什么）

| 项 | impl_a（原型） | impl_hw（本版） | 硬件是否可综合 |
|---|---|---|---|
| 数值 | float64 大量 | **全整数 / 定点 Q8.8、Q8、Q10** | ✅ |
| 灰度 | `cv2.cvtColor` | `(77R+150G+29B)>>8` | ✅ 3 乘 + 加法树 |
| 下采样 | `cv2.resize(INTER_AREA)` | 2×2 盒平均（加法 + 移位） | ✅ |
| 光照归一化 | `GaussianBlur(σ=25)` 大核 + `cv2.divide` | **块均值(1/16)降采样 + 整数双线性 + 倒数 LUT** | ✅ |
| 背景建模 | `MOG2`（每像素多高斯、浮点） | **IIR 一阶**：`bg += ((cur-bg)*α)>>8` | ✅ 1 乘 1 加 1 移位 |
| 形态学 | `cv2.morphologyEx` | 窗口 min/max（椭圆/矩形结构元，移位+比较） | ✅ |
| 连通域 | `cv2.findContours`（边界跟踪） | **run-length + 并查集**（同 `cv_top.v` 思路） | ✅ |
| 特征 | 浮点 `contourArea/moments` | 累加器 `Σ1/Σx/Σy`、4 邻域边界像素计数 | ✅ |
| 圆周率/开方 | `np.sqrt/np.pi` | 常数 `12566/10000`、整数 `isqrt`（CORDIC） | ✅ |
| 跟踪 | float 向量 + `np.linalg.norm/dot` | Q8.8 定点 + 距离平方比较 + 贪心 NN | ✅ |
| 分位数 | `np.percentile` | （自动直径默认关）改用直方图分位 | ✅/可关 |
| 颜色门 | `cv2.cvtColor(BGR2HSV)` | 整数 `S=(max-min)*255/max`（倒数 LUT） | ✅ |
| Hough 圆 | `cv2.HoughCircles` | **未实现**（累加器代价过大，建议不上 fabric） | ➖ |

> 计数、跟踪的生命周期/方向约束/出生侧判据等**语义与原版一致**，只是换成整数实现。

## 2. 文件清单与硬件映射

| 文件 | 内容 | 对应硬件 |
|---|---|---|
| `hw_config.py` | 全部参数（整数/定点常量） | 寄存器 / 比较器常量 |
| `hw_fixed.py` | 倒数 LUT、IIR、饱和、整数开方、Q 格式 | ROM(LUT) + 乘法器 + 算术逻辑 |
| `hw_ops.py` | 下采样/灰度/光照归一化/IIR 背景/阈值/形态学/ROI/饱和度 | 逐行流水级（行缓存 + 窗口 + 加法树） |
| `hw_cc.py` | run-length 连通域 + 逐块特征 | 行扫描 + 标签 RAM + 累加器 |
| `hw_track.py` | 定点多目标跟踪（预测/贪心匹配/补位/方向） | track 表寄存器组 + 距离平方比较 |
| `hw_count.py` | 计数（line/exit） | 直线方程符号 + 1 位触发器 + 点积 |
| `hw_osd.py` | 方框/ID/计数/计数线叠加 | 波门矩形 + 字模 ROM（仅显示层） |
| `hw_pipeline.py` | 端到端流水线编排 | 顶层数据通路 |
| `run_hw.py` | 入口（视频/摄像头/自测） | — |

`hw_config.py` 的常量刻意与 `work/camera_hdmi_720p/rtl/cv/cv_top.v` 对齐
（Q 格式增益、门限比较、`MAX_TRACKS`、Q8.8 坐标），便于直接搬到 RTL。

## 3. 运行

```powershell
cd Python\impl_hw
# 内置合成视频自测（无需摄像头/素材），打印最终计数：
python run_hw.py --selftest --no-display
# 离线视频 + 保存结果：
python run_hw.py --video ..\..\钢珠视频\ball_real5.mp4 --output ..\..\钢珠视频\out_hw.mp4 --no-display
# 摄像头：
python run_hw.py --camera 1
# 另一种计数模式：
python run_hw.py --selftest --no-display --count-mode exit
```
> 依赖与 `impl_a` 相同（`numpy` + `opencv-python`）；`cv2` 只用于**视频/摄像头 I/O 与 OSD 绘制**，算法核心不依赖它。

## 4. 资源估算（引自本仓库的 FPGA 评估，详见 `docs/hardware/`）

处理 640×360@60、≤16 目标、motion 主线（相对现有 MIPI→HDMI 链的**增量**）：

| 模块 | LUT4 | DFF | ERAM20K | DSP |
|---|---|---|---|---|
| 下采样 + 灰度 | 1,200 | 600 | 2 | 3 |
| 光照归一化 | 3,000 | 1,200 | 4 | 2 |
| IIR 背景 + 阈值 | 1,000 | 700 | 2 | 1 |
| ROI + 形态学 | 2,500 | 1,500 | 6 | 0 |
| 连通域 + 特征 | 5,000 | 3,500 | 4 | 4 |
| 颜色门 | 600 | 300 | 0 | 2 |
| 跟踪器(≤16) | 3,500 | 6,000 | 0 | 3 |
| 计数 | 300 | 150 | 0 | 2 |
| OSD | 1,500 | 700 | 6 | 0 |
| **小计** | **≈19,100** | **≈15,050** | **≈24** | **≈17** |

对照 PH1P35（`docs/hardware/HW_PH1P35.md`）：LUT4 38,189 / DFF 42,432 / ERAM 108 / DSP 40。
**瓶颈是 LUT**；建议帧级缓存走 **DDR2（64MB，1066MB/s）**、时间复用、并把跟踪/计数交给
**内嵌 RISC-V MCU 硬核**，可显著压 LUT/DFF。

## 5. 上板建议（映射到现有工程）

本版流水线与现有 `rtl/cv/cv_top.v` 已实现的部分**重叠**（阈值 + run-length CCL + 贪心 NN + 框叠加）。
要"补齐"本版算法，需在 `cv_top.v` 基础上增加：
1. 光照归一化（块均值背景 + 双线性 + 倒数 LUT）；
2. IIR 背景（替代当前的上帧 Otsu 阈值）；
3. 形态学开/闭/竖开（窗口 min/max）；
4. 面积/圆度/填充/长宽比 + 颜色门（当前已有部分面积/填充/比例）。
跟踪与计数沿用现有 a-b + NN 结构即可。
