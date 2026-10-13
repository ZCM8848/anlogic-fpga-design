# M7_sob_restore — 恢复 M7 圆环(Sobel)检测 + 颜色修正 + 阈值整定版

> 上板实测发现 RGB 崩溃(品红)/识别异常后，经两条回退 + 一处整定得到的**可上板版本**。
> 全流程命令行构建（syn→place→route→bitgen）。

## 本版相对"上一次"的变化（按时间）

| 步骤 | commit | 说明 |
|---|---|---|
| ① 回退 AWB 除法器 | `e79cfce` | 自研窄版除法器上板品红（连续 start 下操作数被覆盖）→ 回到 vendor `divider_gate.v` |
| ② 回退 CV 前端 | `6da1c0f` | 前端"背景差分/运动"在钢珠5过检(22/真值10) → 检测回到 M7 Sobel 圆环（`MASK_SRC=1`）；`.al` 移除 5 个 CV 前端模块 |
| ③ 整定阈值 | `35000a4` | `EDGE_THR` 80 → **300**（钢珠5 实测：80 平均 260 框/帧，300 平均 3.6）|

最终 RTL：`cv_top.v`/`design_top_wrapper.v` = M7(`6b7da30`) + `cv_top` 例化新增 `.EDGE_THR(11'd300)`。
`rtl/cv/cv_*.v`、`Python/impl_hw/` 保留在仓库但**不入 `.al`**（不影响构建）。

## 构建

```
cd work/camera_hdmi_720p/td_project
D:\Tangdynasty\bin\td_commands_prompt.exe ../tools/td_run/build_full.tcl
```
TD v6.2.168116；PH1P35MDG324 -3；顶层 `design_top_wrapper`。总耗时 ~24min（route 10m12s）。

## 结果（route 级 final）

| 资源 | 占用 | 总量 | 占比 |
|---|---|---|---|
| slice | 20490 | 21216 | **96.58%** |
| LUT6 | 19324 | 21216 | 91.08% |
| slice reg | 18139 | 42432 | 42.75% |
| ERAM20K | 39 | 108 | 36.11% |

| 时序 | WNS | TNS | FEP |
|---|---|---|---|
| Setup | **−2664 ps** | −2452.9 ns | 1140 |
| Hold | **+20 ps** | 0 | 0 |

### 比特流

| 文件 | 大小 | MD5 |
|---|---|---|
| `camera_hdmi_720p.bit` | 1,789,539 B | `50FF3B610E54D2E4D550C30D6386671F` |

## 钢珠5 视频验证（Sobel 代理，`EDGE_THR=300`）

`impl_a`（OpenCV 原型）在钢珠5：motion **10/10**、hough **10/10**。
本设计的 Sobel 圆环代理：`EDGE_THR=80` → 平均 260 框/帧（木纹过检）；**`EDGE_THR=300` → 平均 3.6、max 14**（≈画面可见球数）。
结果视频：`C:\Users\gg060\Desktop\钢珠5_M7sobel_THR300.mp4`。

## 上板验证要点（待做）

SW4=1 + KEY2 开 CV：看是否显示机器视角掩膜、钢珠是否被框、串口 `CV/NB` 是否正常。
若仍过检/漏检，用板载 K3/K4 调阈值偏置（±127），或再改 `EDGE_THR` 重建。

## 备注

- 设计仍很拥挤（slice 96.58%），route 较慢且偶发极慢/外部中断。
- `opt/`、`baseline/`（在 `M7_cv_phy/`）为失败实验留档；本目录是**当前可上板候选**。
