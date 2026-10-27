# CV 算法 → Verilog 迁移记录（impl_hw → RTL）

> 把 `Python/impl_hw/`（硬件可实现版定点算法）迁移为可综合 RTL，落在
> `work/camera_hdmi_720p/rtl/cv/`。现有 `rtl/cv/cv_top.v` 已实现
> 「阈值/Sobel → run-length CCL → 贪心 NN 跟踪 → 红框/ID 叠加」，本迁移补齐其**前端**：
> **灰度 → 光照归一化 → IIR 背景 → 形态学 → (计数线)**。

## 1. 新增文件与映射

| RTL 文件 | 对应 Python（`impl_hw/`） | 说明 |
|---|---|---|
| `cv_gray.v` | `hw_ops.to_gray` | `Y=(77R+150G+29B)>>8`，1 级流水 |
| `cv_norm_bg.v` | `hw_ops.illum_norm / iir_update / fg_mask` | 块域(1/16)照度图 + 倒数 LUT 归一化 + IIR 背景 + 阈值；含预热 |
| `cv_morph3x3.v` | `hw_ops.erode / dilate` | 3×3 窗口 min/max；开=腐蚀→膨胀，闭=膨胀→腐蚀，级联≈5×5 |
| `cv_count_line.v` | `hw_count.HWLineCounter` | 直线方程符号 + 方向点积；逐轨迹状态 3bit |
| `cv_front_top.v` | `hw_pipeline` 检测前半段 | 顶层：gray → norm_bg → 形态学开 → 1bit 掩膜 |

行为级校验：`tools/sim/cv_front_sim.py`（逐拍 Python 模型，对拍 `impl_hw`）。

## 2. 停机时间 → 定点约定与 RTL 一致

- 坐标/半径：整帧像素用整数（12 bit），**不引入 Q8.8**（`cv_top` 现用整数坐标 + 整数 vx/vy，
  沿用它一致性更好；`impl_hw` 的 Q8.8 只是 Python 侧便于 EMA）。
- 增益/系数：Q 格式常量（`ALPHA_SH`、`NORM_TGT`、`THRESH`、`GATE` 等）。
- 倒数：256×16 ROM（`rec_rom[d]=65536/d`），`norm = (y*128*rec)>>16`。

## 3. 关键设计决策（与 `impl_hw` 的差异）

| 项 | `impl_hw` | RTL | 原因 |
|---|---|---|---|
| 照度/背景取值 | 双线性插值 | **最近邻**（块域） | 省去插值乘加与块行缓存；对阈值判定影响小 |
| 背景存储 | 整帧数组 | **1/16 块域 BRAM**（80×45≈4 ERAM） | 避免整帧 BRAM（640×360×8bit≈92 ERAM） |
| 冷启动 | `bg=首帧` | **预热 2 帧**（预热期 mask=0、背景载入块均值） | 无首帧初始化，硬件需预热 |
| 形态学核 | 5×5 / 9×9 / 竖开 14 | **3×3 级联** | 省行缓存；两次 3×3 ≈ 5×5 |
| 计数线 | 处理分辨率坐标整数 | 同 | 直接照搬 |

## 4. 验证状态

- **语法**：`iverilog -g2012 -tnull`（与 CI `.github/workflows/verilog-lint.yml` 等价）
  全量 `work/**/*.v`（46 个，排除 `ip/`、`retired/`、`*.enc.*`）→ **0 error**。
- **行为级**：`tools/sim/cv_front_sim.py`
  - 灰度 `cv_gray` 与 `impl_hw.to_gray` **逐点一致**；
  - 块均值与 `impl_hw._block_mean` **逐点一致**；
  - IIR 步进 `>>5`（=8/256）与 `impl_hw` 一致；
  - 整链跨帧：预热 2 帧后背景被抑制、只剩运动目标（第 2 帧起前景像素 ~1.1 万）。
- **未做**：上板（TD 综合/布局布线）、与 `cv_top` 的时序联调、真实视频回归。
  本机无 TD、无摄像头。

## 5. 下一步（接入工程）

1. 把 5 个 `.v` 加入工程清单 `td_project/camera_hdmi_720p.al`（`<File Path="../rtl/cv/xxx.v">`）。
2. 顶层 `design_top_wrapper.v`：在 `cv_top` 之前插入 `cv_front_top`，把它输出的 `O_mask`
   作为 `cv_top` 的检测掩膜（`cv_top` 现内部自算阈值/Sobel，接入时旁路该级）。
3. `cv_count_line`：在 `cv_top` 的 `S_DONE` 后加一段扫描，把 track 表逐条喂进本模块。
4. 命令行重建（`tools/td_run/*.bat`）→ 上板验收（先 `SW4=0` 基准不退化，再开 CV）。

## 6. 资源（增量估算，详见 `docs/hardware/` 与本仓库 FPGA 评估）

新增约 LUT4 5k~8k / DFF 3k~4k / ERAM 约 8~10 块 / DSP 约 3~5；
瓶颈仍是 LUT，建议帧级缓存走 DDR2。
