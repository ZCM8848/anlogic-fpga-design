# Web 预览与标注（P1）

## 启动

```powershell
cd Python\playground
python run_web.py
# http://127.0.0.1:8000
```

纯本地，无 CDN；只读取 `../sample/*.mp4`，所有产物写在 `Python/playground` 内。

## 页面

- **原始输入**：H.264 解码后的 RGB 帧。
- **处理帧 · 50% 叠加**：背景差分 `|G−BG|` 的伪彩色，按 50% 叠加在原图上。
- **处理帧 · 100%**：同一 score 图的原始 100% 视图；下拉可切 `score` / `mask`，
  “放大”在新标签页打开 1280×720。用于判断漏检发生在哪一级：
  - score 里没有球 → 背景/对比度问题，阈值或特征不够；
  - score 有、mask 没有 → `bg_thr` 太高；
  - mask 有、OSD 没有 → CCL/面积/形状过滤或运动门控。
- **OSD**：固定 2R 框、轨迹 ID、累计计数、门线（x=0.30W）。
  只画通过运动门控的轨迹；静态划痕/反光不显示。
- 右侧：当前帧统计（含 mask 像素数、score 均值/最大值）、参数、标注/标定入口、计数事件。
- 跳帧时后端会用前 12 帧做跟踪预热，真实球在目标帧即可显示；静态轨迹在预热中就被拒绝。

播放/单步/拖动都会请求 `/api/frame`。**跳帧会重置背景 IIR、跟踪和计数**，
页面会显示“跳帧：跟踪与计数已重置”。整段计数请用 `tools/count_clip.py`。

## 参数

| UI | 参数 | 说明 |
|---|---|---|
| mode | bright/dark/auto | 仅 `use_bg=false` 时生效 |
| 球径 px | ball_diameter_px | 标定后自动更新 |
| 背景差分 | use_bg | 默认开 |
| bg thr | bg_thr | 前景差分阈值 |
| bright thr | bright_thr | 备用亮阈值 |
| dark win / thr | dark_win/dark_thr | 备用黑帽 |
| track gate px | track_gate_px | 关联半径 |
| offset x/y | offset_x_px/offset_y_px | 高光→球心修正 |

“应用参数”会清空缓存与管线，重新从当前帧开始。

## 标注

- “标注当前帧”打开大图；绿色虚线是算法 proposal；拖动黄框标注。
- 框代表**整条拖影**；JSON 同时存 `box`、`cx/cy`（框中心）、`kind:"trail"`。
- **一帧可多个框**；框重叠时用“新建框”或 Shift+拖动强制新框。
- 一条拖影多颗球：选中框 → “加点” → 框内点球心；计数按 `centers` 数量。
- 选中框变红；Delete/Backspace 删除；“保存标注”写入
  `data/annotations/<clip>.json`。
- 自动保存有 350 ms 防抖；关闭弹窗时再保存一次。
- “下一未标注”找当前片段中还没有 `balls` 的帧。
- “密集帧”读取 `data/analysis/<clip>_scan.json` 的 top 列表，循环跳转；
  没有 scan 文件时提示先跑 `tools/scan_clip.py`。

### 标注 JSON

```json
{
  "clip": "2026-10-27_22-19-44",
  "width": 1280,
  "height": 720,
  "frames": {
    "240": {
      "balls": [
        {"id": 1, "box": [470, 240, 650, 330], "cx": 560, "cy": 285, "kind": "trail"}
      ]
    }
  }
}
```

## 标定

- 已知尺寸下拉：**滑道宽度 40 mm（完全入镜，推荐）** / 钢球 10 mm；
  长度 160 mm 未完全入镜，不建议用于标定。
- “画已知长度”：点两个端点；`px_per_mm = 像素长度 / known_mm`。
- 球径默认按 `10 mm × px_per_mm`；也可“画球轮廓”，取框短边。
- “保存标定”写入 `data/calibration/calibration.json`，并把
  `ball_diameter_px` POST 到参数。
- 标定在当前帧上完成；建议选滑道边缘清晰、球完整的一帧。

## API

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/clips` | 片段列表 + 当前参数 |
| GET/POST | `/api/params` | 读写参数；POST 会 reset |
| GET | `/api/frame?clip=&index=` | 处理一帧，返回元数据 + 三张图 URL |
| GET | `/api/image?clip=&index=&view=orig\|proc\|score\|mask\|osd` | JPEG |
| GET/POST | `/api/annotations?clip=` | 标注读写 |
| GET/POST | `/api/calibration` | 标定读写 |
| GET | `/api/scan?clip=` | 密集帧候选（读 scan JSON） |

## 性能

- 720p 解码 + 320×180 处理 + 三张 JPEG，本机约 15–30 fps（取决于 CPU）。
- 前端播放按 30 fps 调度；处理跟不上时自动降速。
- 图片缓存 12 帧，三视图共享同一次处理结果，严格同帧。
