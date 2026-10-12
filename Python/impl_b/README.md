# impl_b — 钢珠跟踪与计数（FPGA 黄金参考）

面向「全国大学生嵌入式芯片与系统设计竞赛'2026 · FPGA 赛道 · 选题二」的**算法验证原型**，
与 `Python/impl_a/` 的区别在于：**本实现逐算法对齐 FPGA 侧 `work/camera_hdmi_720p/rtl/cv/cv_top.v`**，
保证「电脑上跑出来的效果 == FPGA 上板效果」。

> 核心原则：算法层 **零 cv2 黑盒**（不用 `findContours` / `HoughCircles` / `MOG2` /
> `morphologyEx`），全部用 numpy 整数运算 + 纯 Python 小表，可逐行映射到 RTL。

---

## 1. 快速开始

```powershell
cd Python\impl_b
python -m pip install -r ..\requirements.txt   # numpy + opencv-python（仅 I/O）

# 1) 生成合成滚珠视频
python simulate.py --out sim_test.mp4 --seconds 20

# 2) 无窗口跑一遍，输出结果并打印最终计数
python main.py --video sim_test.mp4 --no-display --output out.mp4

# 3) 带窗口观察 + 调参
python main.py --video sim_test.mp4
```

按键：`q`/`ESC` 退出 · `空格` 暂停 · `r` 复位 · `m` 机器视角开关 · `d` 掩膜窗口 ·
`-`/`=` 阈值偏置 ∓/±1（等价 FPGA K3/K4）· `s` 保存参数。

---

## 2. 算法流水线（与 cv_top.v 逐行对应）

| 步骤 | 模块 | cv_top.v 行号 | 说明 |
|---|---|---|---|
| 亮度 | `preprocess.luma` | 80 | `Y=(R>>2)+(G>>1)+(B>>2)` |
| Sobel | `preprocess.sobel_magnitude` | 87~103 | 3×3，`mag=|gx|+|gy|` |
| 阈值 | `detect` | 79~85 | 默认 Sobel 幅值 > `EDGE_THR+user_off` |
| run 提取 | `detect.extract_runs` | 243~257 | 行序扫描，run 顺序一致 |
| 简化 CCL | `detect.ccl` | 298~316 | 两行 run-length，**无 union-find** |
| 特征筛选 | `detect.filter_features` | 165~183 | 面积/填充率/长短边比/贴边 |
| 跟踪 | `track.Tracker` | 327~383 | α-β + 贪心最近邻(Manhattan) |
| 计数 | `count.count_crossings` | Phase C | 计数线（叉积符号 + 方向） |
| 叠加 | `osd.render_overlay` | 394~450 | 绿框 + 5×7 ID（左上角） |

---

## 3. FPGA 映射与门资源估算

> 资源池（PH1P35MDG324，见 `docs/hardware/HW_PH1P35.md`）：LUT4 38,189 / DFF 42,432 /
> ERAM20K 108 块 / 分布式 RAM 507 Kbit / DSP 40。

| 模块 | 存储 | LUT/FF | DSP |
|---|---|---|---|
| Luma | — | 组合 ~0 | 0 |
| Sobel 2 行缓存 | 2×1280×8b → 1~2 ERAM | ~50 | 0 |
| Sobel Gx/Gy+幅值 | — | ~150 | 0 |
| 自适应阈值 min/max | 2×8 FF | ~20 | 0 |
| run 提取 | — | ~60 | 0 |
| run_mem | 1024×34b → 2 ERAM | ~40 | 0 |
| feature 表(32×65b) | 2080b dist | ~65 | 0 |
| rca 表(64×30b) | 1920b dist | ~60 | 0 |
| det 表(8×73b) | 584b dist | ~20 | 0 |
| track 表(8×105b) | 840b dist | ~26 | 0 |
| CCL FSM | — | ~300 | 0 |
| α-β 跟踪算术 | — | ~200 + 1~2 乘法器 | 0~2 |
| 叠加(框+字模) | 字模 ~1Kb | ~300 | 0 |
| **计数线(Phase C)** | 每 track 2 FF | **~20 + 1 乘加器** | 0~1 |
| **合计** | **≈5 ERAM + ~5.4Kb dist** | **≈1.5~2K LUT** | **0~2 DSP** |

**结论：全量上板资源占用 <5% LUT / <5% ERAM / ~1% 分布式 RAM，余量 >90%。**
佐证：M7 实际综合总 LUT 9756（含整套 ISP + 视频通路 + DDR2 控制器），钢珠管线只占其中很小一部分。

---

## 4. 计数线 FPGA 设计规格（Phase C，尚未写入 cv_top.v）

- 每个 track 增补 2 位寄存器：`prev_side`、`crossed`；一个计数寄存器 `cnt`。
- 计数线为编译期常量 `a*x + b*y + c = 0` + 期望方向 `(dx,dy)`（来自现场标定）。
- 每帧 vblank、跟踪器更新后，顺序对每个 track：
  - `side = (a*cx + b*cy + c) > 0`（1 次乘加 + 比较，复用 1 个乘法器）
  - `prev_side≠side 且 vx*dx+vy*dy > 0` → `cnt++`、置 `crossed`
- 资源：每 track 2 位 FF + 复用 1 个乘加器，约 20 LUT，几乎免费。
- `cnt` 经 `status_report` 串口输出 `CNT=` 字段（或叠加到 OSD）。

---

## 5. 对齐清单（保证 PC == FPGA 的四个关键点）

1. **简化 CCL**：只查「上一行第一个重叠 run」，无 union-find。对凹/间隙 blob 会过分割，
   但 PC 与 FPGA 过分割得**一模一样**（不用 OpenCV 的 8 连通全并查集）。
2. **Manhattan 距离**：关联代价是 `|dx|+|dy|`，不是欧氏距离。
3. **无 min_hits 确认**：新检测立即成为有效轨迹、立即分配 ID，只有 `MISS_K` 帧未命中才删除。
4. **1 帧延迟**：帧 N 的检测/跟踪结果叠加在帧 N+1 上（等价 FPGA 在 vblank 更新 track 表）。

其它一致性细节：ID 是 4 位、回绕 0~f（叠加用十六进制 5×7 字模）；掩膜边界 `x<2||y<2` 被掩掉。

---

## 6. 已知偏差（算法等价，非逐比特）

- 浮点/整型：本实现用 Python int，α-β 的 Q8 右移结果与 RTL 算术右移一致；
  但坐标不做 12 位回绕（正常运动不会溢出，不影响结果）。
- Sobel 有 1px 流水中断偏移（RTL 注释标注"不可见"），本实现取对齐坐标。
- 机器视角/ID 字模逐位一致；HUD 文本（count/tracks/fps）与计数线是显示层便利，
  用 cv2 绘制，FPGA 侧对应串口上报 + Phase C 字模 ROM。

---

## 7. 目录结构

```
impl_b/
├── config.py       # 参数（映射 cv_top.v parameter 段）
├── preprocess.py   # 亮度 + Sobel
├── detect.py       # 阈值 -> run -> CCL -> 筛选
├── track.py        # α-β 跟踪器
├── count.py        # 计数线（含 FPGA 设计规格）
├── font5x7.py      # 5x7 字模（与 f_digit 逐位一致）
├── osd.py          # 叠加（框+ID）+ HUD
├── main.py         # I/O 主循环
├── simulate.py     # 合成滚珠视频
└── README.md
```
