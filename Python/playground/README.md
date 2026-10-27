# 钢珠视觉 Playground（P1）

针对 3D 打印滑道中的 10 mm 钢珠，做**可上 FPGA 的定点检测/跟踪/计数**算法原型，
以及一个只跑算法的 Web 预览 + 人工标注工具。**不连接 FPGA，不生成 RTL。**

> 滑道实际尺寸：**宽度 40 mm（完全入镜）**，长度 160 mm（摄像头只能看到一部分）。
> 标定请用 40 mm 宽度线；不要用 160 mm 长度。

## 当前状态（P1）

- 输入：`../sample/*.mp4`，1280×720@60，FPGA HDMI RGB888 直出。
- 检测：4×4 降到 320×180 → 静态背景差分 → 3×3 形态学 → 游程 CCL → 合并碎片。
- 跟踪：≤16 条轨迹，最近邻 + 速度预测，2 帧确认；**运动门控**：轨迹必须在最近
  5 帧内持续左移 ≥0.5D 才显示/计数，静态划痕与反光被隐藏（clip1 f399–480 已验证 0 框）。
- 计数：门线固定在图像 `x = 0.30·W`，球心从右到左过线计 1；倒滚不计。
- Web：原始 / 处理帧 50% 叠加 / **处理帧 100%（score 或 mask）** / OSD 四视图；
  标注；标定；密集帧跳转；“放大”查看 1280×720 处理帧。
- 基线计数（`--mode bright`，使用预计算背景，40 mm 标定后 D=171 px）：clip1 = **13**，clip3 = **3**；
  **clip2 不参与计数**（背景 29–33% 像素为 255，已确认排除）。
  这些是当前参数下的结果，不是真值；请用隐藏真值对照后再调参。

## 快速开始

```powershell
cd Python\playground
pip install -r requirements.txt
python run_web.py
# 浏览器打开 http://127.0.0.1:8000
```

依赖已在本机验证：Python 3.13、numpy、opencv-python、fastapi、uvicorn。

### 预计算背景

背景差分需要一张“无球”的静态背景。仓库里已为 clip1/clip3 生成：

```powershell
python tools\make_background.py --video 2026-10-27_22-19-44.mp4
python tools\make_background.py --video 2026-10-27_22-23-09.mp4
```

输出在 `data/backgrounds/<clip>_bg.png`（320×180）。部署到 FPGA 时，开机采集
一帧无球背景存入 ERAM 即可，语义相同。

### 整段计数 / 密集帧扫描

```powershell
python tools\count_clip.py --video 2026-10-27_22-19-44.mp4 --mode bright
python tools\scan_clip.py  --video 2026-10-27_22-19-44.mp4 --top 30
```

- `count_clip.py`：从第 0 帧顺序跑完整段，输出总计数和过线事件，写入
  `data/analysis/<clip>_count.json`。
- `scan_clip.py`：逐帧只做检测，按检测数/前景面积排序，写入
  `data/analysis/<clip>_scan.json`；Web 的“密集帧”按钮读这个文件。
- 单帧调试：`python tools\preview_frame.py --video ... --time 4.0`，输出三张图到
  `data/debug/`。

## 标注约定

1. 打开“标注当前帧”，算法框以绿色虚线显示；你只需增/删/拖黄框。
2. **框整条拖影**，不要只框球心；工具取框中心为球心、长边方向为运动方向。
3. **一帧可标多个框**；框重叠时用“新建框”或 Shift+拖动强制新框。
4. 一条拖影里有多颗球时：选中该框 → “加点” → 在框内点球心；
   计数按球心数，而不是框数。
5. 选中框后可直接拖动移动；Delete/Backspace 删除。
6. 算法 OSD 框始终是**固定 2R 的球轮廓框**；评估用球心与计数，不用拖影框 IoU。
7. 标注自动保存到 `data/annotations/<clip>.json`。

## 标定

“标定”页里：

1. 选择已知尺寸：**滑道宽度 40 mm（完全入镜，推荐）** / 钢球 10 mm。
   滑道长度 160 mm **未完全入镜，不建议**用来标定。
2. 点击“画已知长度”，在图像上点两个端点。
3. 计算 `px/mm` 与 `球径 = 10 mm × px/mm`；“保存标定”会把球径写回参数。
4. 若使用静止球轮廓，可用“画球轮廓”直接量球径（取框的短边）。

## 目录

```
ballvision/          定点核心（无浮点；OpenCV 仅解码/编码与矩形 min/max）
web/                 FastAPI + 三视图/标注/标定
tools/               背景、扫描、整段计数、单帧预览
configs/default.json 默认参数
data/backgrounds/    预计算背景
data/analysis/       扫描/计数结果
data/annotations/    人工标注（JSON）
data/calibration/    标定结果
docs/                算法、Web、评估、FPGA 映射
```

## 逐位一致

- 核心只有整数运算：4×4 均值 `(sum+8)>>4`；背景 IIR 右移；CCL 面积/质心整除；
  跟踪速度 `(v+delta)//2`。
- `ballvision/ccl.py` 是游程 + 并查集，和 RTL 的结构一致；没有用
  `cv2.connectedComponents` 的浮点质心。
- OpenCV 只用于视频解码/JPEG 编码和矩形 min/max（整数语义精确）。
- H.264 解码不属于模型；给定同一帧 RGB 像素，Python 与未来 RTL 的输出应一致。
- 轨迹信息不导出；`count_clip.py` 的 JSON 只含计数事件，便于对照真值。

## 已知限制（P1）

- 密集接触球的合并/拆分尚未用人工真值验证；`merge_distance_ratio=0.8` 是保守值。
- 全局跟踪在密集簇中可能交换 ID；计数靠门线事件，仍需密集帧标注校验。
- 背景差分依赖“静止相机 + 恒定补光”；部署时补光是恒定的，符合条件。
- clip2 过曝，明确不计数。
