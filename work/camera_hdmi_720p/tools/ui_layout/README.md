# FPGA UI Layout Studio

面向 `work/camera_hdmi_720p` 的 1280×720 OSD 布局编辑器。纯静态网页，无外部依赖，双击 `index.html` 即可使用。

## 功能

- 放置元素：安路 Logo、钢珠计数、当前球数、OSD 文本、帧计数、标签、调试统计、球框样例、门线、检测 ROI、十字准线、彩条
- 拖动位置，或输入精确 X/Y/W/H
- 网格吸附、边缘贴合、中心贴合
- 图层顺序、显隐、锁定、复制、删除、撤销/重做
- 导入和导出 JSON、Verilog `.vh`、C `.h`、PNG
- 自动保存到浏览器本地存储

## 当前识别 UI

| 元素 | 位置 | 尺寸 | 内容 |
|---|---|---|---|
| Logo | `(24,24)` | 160×160 | 安路 Logo |
| 赛事文本 | `(24,172)` | 160×24 | `Anlogic HX1P35A` |
| 当前球数 | `(184,652)` | 112×20 | `DETECTED N` |
| 计数标题 | `(24,612)` | 160×18 | `STEEL BALL` |
| Count | `(24,638)` | 150×34 | `00000` |
| 帧计数 | `(24,680)` | 240×20 | `FRAME 000123` |
| 门线 | `x=400` | 2×720 | `#FF3366` |

## 导出格式

### JSON

```json
{
  "app": "fpga-ui-layout-studio",
  "version": 1,
  "canvas": { "width": 1280, "height": 720 },
  "elements": [
    {
      "id": "el_detected",
      "type": "detected",
      "name": "当前球数",
      "x": 184, "y": 652, "w": 112, "h": 20,
      "color": "#8be9fd",
      "text": "DETECTED 3",
      "visible": true,
      "locked": false
    }
  ]
}
```

### Verilog

```verilog
`define UI_LOGO_X 12'd24
`define UI_LOGO_Y 12'd24
`define UI_COUNT_X 12'd24
`define UI_COUNT_Y 12'd638
`define UI_COUNT_W 12'd150
`define UI_COUNT_H 12'd34
`define UI_DETECTED_X 12'd184
`define UI_DETECTED_Y 12'd652
```

### C

```c
#define UI_COUNT_X 24
#define UI_COUNT_Y 638
#define UI_COUNT_W 150
#define UI_COUNT_H 34
#define UI_DETECTED_X 184
#define UI_DETECTED_Y 652
```

## 与 RTL 的对应关系

| 工具元素 | RTL 参数 | 当前行为 |
|---|---|---|
| 安路 Logo | `hdmi_mixer.v` 的 `LOGO_X / LOGO_Y` | X/Y 写回；Logo ROM 固定 160×160 |
| 钢珠计数 | `cv_top.v` 的 `CNT_X / CNT_Y / CNT_W / CNT_H` | MiSans 30×34 数字，标准 150×34 |
| 当前球数 | `hdmi_mixer.v` 的 `DETECTED_X / DETECTED_Y` | 固定 112×20，数值来自 `BALL_NOW` |
| OSD 文本 | `hdmi_mixer.v` 的 `DYN_OSD_X / DYN_OSD_Y` | 识别态静态文本由 MiSans ROM 渲染 |
| 门线 | `cv_top.v` 读取 `BALL_GATE@0x5C` | 识别态和动态调试态实时显示，位置来自 MCU |
| 帧计数 / 标签 | `hdmi_mixer.v` | 识别态 MiSans ROM 渲染 |
| 球框 | 运行时 overlay | 编辑器位置仅作预览 |
| 检测 ROI | MCU `roi_y1` | 仅作预览 |

## 写回 RTL

```powershell
python tools/ui_layout/apply_layout.py path/to/ui_layout.json --dry-run
python tools/ui_layout/apply_layout.py path/to/ui_layout.json
```

写回内容：

- Logo → `hdmi_mixer.v` 的 `LOGO_X / LOGO_Y`
- Count → `cv_top.v` 的 `CNT_X / CNT_Y / CNT_W / CNT_H`
- 当前球数 → `hdmi_mixer.v` 的 `DETECTED_X / DETECTED_Y`
- OSD 文本 → `hdmi_mixer.v` 的 `DYN_OSD_X / DYN_OSD_Y`

门线位置由 MCU 的 `gate_x / gate_y0 / gate_y1` 控制，编辑器中的门线元素仅作预览。

## MiSans 字库

生成脚本：

- `gen_ui_text_rom.py`：`STEEL BALL`、`Anlogic HX1P35A`、`FRAME` 前缀、帧数字
- `gen_mi_fonts.py`：Count 30×34、球框 ID 8×12、`DETECTED ` 前缀、`DETECTED` 数字、测试图案文字、测试图案来源标注

RTL ROM：

- `rtl/video/ui_text_rom.v`
- `rtl/video/mi_digit_rom.v`
- `rtl/video/detected_text_rom.v`
- `rtl/video/tp_text_rom.v`
- `rtl/video/tp_attr_text_rom.v`

预览图：

- `misans_text_preview.png`
- `misans_more_preview.png`

## 文件

- `index.html`：页面结构
- `style.css`：深色界面
- `app.js`：编辑、渲染、导出
- `apply_layout.py`：JSON 写回 RTL
- `gen_ui_text_rom.py`：静态文字 ROM 生成
- `gen_mi_fonts.py`：Count、ID、DETECTED、测试图案、来源标注 ROM 生成
- `examples/ball_counter.json`：当前实机布局
- `examples/competition.json`：比赛布局
- `examples/debug.json`：调试布局

## 快捷键

| 操作 | 快捷键 |
|---|---|
| 移动 1 像素 / 10 像素 | 方向键 / Shift + 方向键 |
| 复制 | Ctrl/Cmd + D |
| 删除 | Delete / Backspace |
| 撤销 / 重做 | Ctrl/Cmd + Z / Ctrl/Cmd + Y |
| 导出 JSON | Ctrl/Cmd + S |
| 取消选择 | Esc |
| 缩放 | Ctrl + 滚轮 |
| 临时关闭吸附 | 拖动时按住 Alt |

## 控制台 API

```js
FPGAUILayout.preset('competition');
FPGAUILayout.design;
FPGAUILayout.json();
FPGAUILayout.verilog();
FPGAUILayout.cHeader();
FPGAUILayout.select(id);
FPGAUILayout.exportPng();
```
