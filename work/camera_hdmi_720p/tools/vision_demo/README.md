# Vision Parameter Lab

交互式演示：用现有钢珠算法的 **320×180 binned 域**，把 `VISION_PARAMS` 里每个参数的作用直接可视化。用于在决定“CCL 下移 FPGA”之前，先亲手感受每个阈值/几何/跟踪参数。

## 打开

直接双击：

```text
work/camera_hdmi_720p/tools/vision_demo/index.html
```

纯静态页面，无依赖，Edge/Chrome 离线可用。

## 演示的算法链

```text
合成相机 320×180 G
  → |G - bg| ≥ bg_thr
  → 逐行 run 提取
  → min_run / roi_y1 / max_run_len 过滤
  → run-based CCL（union-find，最多 96 labels / 单行 160 runs）
  → 面积/宽高/填充率/长短比/边缘筛选
  → 碎块合并 merge_dist
  → 最多 8 个 det
  → 跟踪 / 门线计数
```

和 `mcu_fw/main.c` 的 CCL、筛选、merge、tracking、gate 逻辑保持一致；`roi_y1` / `max_run_len` / `min_run` 按新 RTL 的行为在 run 提取阶段过滤。

## 界面

- **左栏参数**：按“前端 / Blob 筛选 / 合并 / 几何 / 跟踪 / 启动 / 场景”分组。
- **中间画面**：
  - 绿色横线 = 保留的 run
  - 红色横线 = 被 ROI / 长度 / min_run 丢弃的 run
  - 蓝框 = 通过筛选的 Blob；红虚线框 = 被拒绝
  - 黄框 = 可见轨迹；灰框 = 未确认/丢失轨迹
  - 粉色虚线 = 门线；青色虚线 = ROI 底边
  - 顶部 HUD：帧号、Count、run 数、skip 数、Blob、轨迹
- **右栏**：
  - 当前参数说明、当前值、“试试”建议
  - 所有连通域的 bbox/area/fill/ratio/拒绝原因
  - 轨迹的 ID、cx/cy、vx、hits/miss、moved/window/age
- **顶部**：播放/暂停、单步、重置、换场景、速度、场景预设。
- **画面工具栏**：相机 / Mask / Diff / Runs / Blobs / 拒绝项 / Tracks / Gate-ROI 开关。

## 场景预设

| 预设 | 用途 |
|---|---|
| 标准 7 球 + 底堆 | 综合演示：运动球、静止球、被高光切开的球、底部球堆、长条、噪声 |
| 干净 3 球 | 先理解 CCL/跟踪，不被噪声干扰 |
| 噪声/碎片 | 观察 `min_run`、面积/宽高/填充率/长短比筛选 |
| 反向滚动 | 验证 `vx_max` 和门线方向：右→左才计数 |
| 静止球 | 观察 `static_max_age` / `min_move` / `min_window` |
| 长条干扰 | 观察 `max_run_len` 和 `max_w` |

## 参数分组

- **前端 / run 提取**：`enable`、`bg_thr`、`min_run`、`roi_y1`、`max_run_len`
- **Blob 筛选**：`min_area`、`max_area`、`min_w`、`max_w`、`min_h`、`max_h`、`min_fill`、`min_ratio`、`edge_margin`
- **碎块合并**：`merge_dist`
- **几何 / 门线**：`box_w_small`、`gate_x`、`gate_y0`、`gate_y1`
- **跟踪 / 计数**：`track_gate`、`max_miss`、`min_hits`、`min_move`、`min_window`、`vx_max`、`static_max_age`
- **启动时序**：`bg_capture_delay`、`bg_settle_frames`（只说明固件流程，逐帧演示不模拟）
- **场景**：`sensorNoise`、`ballG`（非 VISION_PARAMS，用于制造更难/更易的画面）

## 怎么用它判断 CCL 是否下移

1. 用“标准 7 球 + 底堆”跑一段时间，看 `RUN`、`BLOB`、`COUNT`。
2. 逐步调 `bg_thr` / `min_run` / `max_run_len` / `roi_y1`：
   - 看 run 数和 skip 数如何变化；
   - 看哪些 Blob 被面积/宽高/填充率拒绝。
3. 调 `merge_dist`：观察被高光切开的球如何从两个 Blob 合并成一个 det。
4. 调跟踪参数：
   - `track_gate` 太小会断轨，太大可能串球；
   - `min_hits` / `min_move` / `min_window` / `vx_max` 决定“何时算可见、何时计数”；
   - `max_miss` / `static_max_age` 决定轨迹寿命。
5. 观察 `RUN` 峰值和单行 run 数：
   - 如果 `RUN` 离 1024 很远、单行 run 数远小于 160，CCL 硬件容量压力不大；
   - 如果经常接近上限，迁 FPGA 前要保留/加大 `MAX_RUNS`/`MAX_PREV`。

## 结构参数（只读）

| 参数 | 值 | 含义 |
|---|---:|---|
| `MAX_RUNS` | 1024 | 整帧 `run_mem` 深度；超过则 `run_overflow` |
| `MAX_PREV` | 160 | 单行 CCL 工作区；320 宽理论最大 160 |
| `MAX_LABELS` | 96 | 连通域标号上限 |
| `MAX_DET` | 8 | 每帧参与跟踪的检测数 |
| `MAX_TRK` | 8 | 同时存在的轨迹数 |
| `BALL_W × BALL_H` | 320×180 | 4×4 灰度平均后的小图 |

这些是综合期常量，改它们需要重新综合 FPGA；不是日常调参。

## 说明 / 限制

- 演示在 **320×180 binned G** 上直接算，不逐像素模拟 4×4 平均、MIPI/ISP/DDR/HDMI。
- 场景是合成的，不是真实相机；噪声/球亮度是演示控制，不是 `VISION_PARAMS`。
- 跟踪参数按“每帧”语义；改顶部 FPS 会改变运动速度，但参数定义仍是每帧。
- 参数即时预览在暂停时重算 run/CCL/筛选；跟踪状态要单步或播放才更新。
- 演示中的 `bg_capture_delay` / `bg_settle_frames` 只显示在参数表里，不参与逐帧画面。
- 演示不是 RTL 仿真器；最终以板上 bit/ELF 为准。

## 文件

```text
tools/vision_demo/
├─ index.html
├─ style.css
├─ app.js
├─ preview.png        # 运行截图
└─ README.md
```
