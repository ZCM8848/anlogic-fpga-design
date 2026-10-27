# 算法规范（P1，定点/逐位一致）

输入：1280×720 RGB888（full range 0–255），只用 G 通道。
输出：每帧球框/ID、累计过线计数。

## 1. 数据流

```
G(1280×720)
  → 4×4 均值降采样 (320×180)
  → 背景差分 |G − BG|
  → 阈值 + 3×3 close/open
  → 游程 CCL（面积/bbox/整数质心）
  → 碎片合并（同一球的高光/暗体/拖影）
  → 固定直径框（2R）
  → 最近邻跟踪（≤16）
  → 门线计数（x=0.30W，右→左）
  → OSD
```

## 2. 定点细节

### 2.1 降采样

对每个 4×4 块：

```
s = Σ g[i][j]            (16 个 8-bit 无符号数，16-bit 累加)
d = (s + 8) >> 4         (四舍五入)
```

RTL：两级加法树 + 移位，1 pixel/clk 流水。

### 2.2 背景模型

预计算背景 `BG`（320×180，8-bit）来自无球帧/多帧中值；部署时开机采集。

```
diff = |g − BG|                    (8-bit 绝对差)
if diff < 10:                      (只更新“像背景”的像素)
    BG += (g − BG) >> 4            (算术右移，向 −∞ 取整)
    BG = clamp(BG, 0, 255)
```

- 时间常数约 16 帧；运动球不污染背景。
- 预计算背景在 seek/复位时恢复为初始值（`Background.initial`）。
- 若没有预计算背景，首帧作为背景，首帧 diff=0（正常现象）。

### 2.3 前景

```
score = diff
mask  = score >= 30
mask  = close(mask, 3×3)
mask  = open(mask,  3×3)
```

开运算去掉孤立噪声点；闭运算把高光/暗体连成一块。

### 2.4 连通域

`ballvision/ccl.py`：

- 每行求连续 1 的 runs `[start, end)`。
- 与上一行 runs 有交集则 union（并查集，路径压缩）。
- 第二遍累计：
  - `area += end − start`
  - `sum_x += (start + end − 1) × len / 2`（整数；乘积必为偶数）
  - `sum_y += y × len`
  - bbox 取 min/max
- 质心：`cx = sum_x // area`，`cy = sum_y // area`（向下取整）。
- 过滤：`100 ≤ area ≤ 1500`，`18 ≤ w ≤ 100`，`5 ≤ h ≤ 50`（320×180 尺度）。

RTL：run FIFO + 并查集表（≤1024 标签），逐行流水；帧尾串行输出 blob。

### 2.5 碎片合并

同一个球的亮条、暗体、拖影边缘可能被阈值切成多块。按面积从大到小：

- 若新块质心与已保留块质心距离 `< 0.80 × D`（D=190 px），合并：
  - `area = a1 + a2`
  - `cx = (cx1·a1 + cx2·a2) // area`（y 同理）
  - 框重新按固定 D 生成。
- 球心距至少约一个直径（D），0.8D 留出透视/标定误差余量。

### 2.6 固定框

```
x0 = clamp(cx − D/2, 0, W − D)
y0 = clamp(cy − D/2, 0, H − D)
box = [x0, y0, x0+D, y0+D]
```

D 由标定得到；当前 40 mm 宽度标定得到 **D≈171 px**（`data/calibration/calibration.json`）。
框是球轮廓，不是拖影框。

> 滑道实际宽度 **40 mm**（完全入镜），长度 **160 mm**（摄像头只能看到一部分）。
> 标定请画“宽度 40 mm”这条线；不要用 160 mm 长度做标定。

### 2.7 跟踪

状态：`id, cx, cy, vx, vy, prev_cx, prev_cy, hits, misses, counted, box, start_cx/cy, age, moved, hist_x, window_move`。

每帧：

1. 预测：`cx += vx; cy += vy`。
2. 关联：所有轨迹-检测对的距离平方 `< gate²`（gate=220 px），按距离贪心匹配。
3. 匹配成功：
   - `vx = (vx + (det.cx − prev_cx)) // 2`（vy 同理）
   - `cx,cy = det.cx,det.cy`，`hits++`，`misses=0`
   - `moved = max(|cx−start_cx|, |cy−start_cy|)`
   - `hist_x` 保留最近 5 帧，`window_move = hist_x[-1] − hist_x[0]`
4. 未匹配检测：新建轨迹，`hits=1`，`hist_x=[cx]`。
5. 未匹配轨迹：`misses++`，更新 `moved/window_move`；`misses>5` 删除。
6. **运动门控**（新增）：
   - `visible = hits≥2 且 moved≥0.2D 且 window_move≤−0.5D 且 vx≤−4`
   - 只有 `visible` 的轨迹才画 OSD、才允许过线计数。
   - `age>30` 且 `moved<0.2D` 且 `|window_move|<0.5D` 的轨迹删除。
7. 确认：`hits ≥ 2` 只表示“存在”，真正显示/计数还要通过运动门控。

> 静态划痕/反光可能连续命中几十帧，但没有持续左移；`window_move` 在 ±20 px 内抖动，
> 永远达不到 −0.5D（D=190 时 −95 px），因此不会显示/计数。
> 真实球在 60 fps 下每帧约 20–100 px，5 帧窗口 −100…−500 px，正常通过。

RTL：轨迹表 ≤16 条，距离平方用 18-bit；每轨迹 5×11 bit 的 `hist_x` 移位寄存器；
帧尾串行匹配（16×16），无需排序网络。

### 2.8 门线计数

- 门线：`xg = round(0.30 × W)`；y 范围 `[0.08H, 0.92H]`。
- 对每条确认轨迹：
  - `prev_cx > xg` 且 `cx ≤ xg`；且 y 在范围内；且未计数。
  - `count++`，`track.counted = true`。
- 倒滚不计；同一轨迹只计一次；无反向逻辑。
- 事件记录 `(frame, track_id, cx, cy, count_after)`。

RTL：每轨迹一个 `counted` 位；比较器阵列在帧尾执行。

## 3. 参数（configs/default.json）

| 参数 | 值 | 说明 |
|---|---|---|
| scale | 4 | 320×180 |
| use_bg | true | 背景差分 |
| bg_shift | 4 | IIR 时间常数 |
| bg_update_thr | 10 | 只更新近背景像素 |
| bg_thr | 30 | 前景阈值 |
| min_area / max_area | 100 / 1500 | 320×180 面积 |
| min_width / max_width | 18 / 100 | |
| min_height / max_height | 5 / 50 | |
| ball_diameter_px | 190 | 标定后修改 |
| merge_distance_ratio | 0.80 | 碎片合并 |
| track_gate_px | 220 | 全分辨率 |
| track_max_miss | 5 | |
| track_confirm_hits | 2 | |
| min_move_ratio | 0.20 | 总位移门限 |
| min_window_ratio | 0.50 | 最近 5 帧位移门限 |
| static_max_age | 30 | 静态轨迹删除 |
| gate_x_ratio | 0.30 | 固定物理位置 |

## 4. 为什么选背景差分

- clip1（暗）：只有高光可测；但静态纹理/反光点也很亮。
- clip3（亮）：背景大面积亮，亮阈值会带入大量静态亮斑。
- 三段相机静止、补光恒定；**运动目标 + 静态背景**是最稳的判据。
- 背景差分对亮度极性不敏感：高光、暗体、拖影都能产生差分。
- 代价是一张 320×180 背景图（57.6 KB），ERAM 足够。

## 5. 已知风险

1. **密集接触**：两个球心距若小于 0.8D（152 px），会被合并；实际球心距约 190 px，
   但透视/标定误差可能压到 150 px，需要用标注确认。
2. **ID 交换**：贪心最近邻在密集簇中可能交换；计数依赖过线事件，不依赖 ID 稳定。
3. **拖影长度**：拖影使高光/暗体分离，合并逻辑可能把同一球的两块合并，也可能把
   两球合并；标注数据是最终裁决。
4. **背景不干净**：若预计算背景包含球，会产生幽灵；部署时必须在无球时采背景。
5. **clip2**：过曝不可用，明确不计数。
