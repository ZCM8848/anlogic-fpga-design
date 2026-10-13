# M7_blkdet — 块域暗块检测版（cv_blkdet）全流程构建

> 把检测从"像素级 Sobel 边缘 / CCL"换成**块域暗块检测**后的可上板版本。
> 动机：钢珠是**深色实心圆盘**，边缘检测不合适；且 `cv_top` 的简化像素级 CCL
> （无并查集、标签/run 受限）在这种掩膜上过分割/溢出。改用块域后掩膜干净、标记确定。

## 检测链路（`rtl/cv/cv_blkdet.v`，`MASK_SRC=3`）

```
1280x720 --16x16 块均值--> 80x45 暗块掩膜(均值<DARK_THR)
         --块级光栅标记(左/上邻居标签继承)--> 连通块
         --面积/填充/长短比/贴边筛选--> 像素坐标检测框 --> cv_top 跟踪器(建轨迹) --> 叠加
```
- 规避了 `findContours`/union-find（此前导致 TD coredump）；无嵌套异步读。
- 掩膜按块展开回像素流喂 CCL 的思路已弃用（过分割），改为块域直接标记。

## 关键工程点（踩坑记录）

1. **TD 不推断 RAM 会面积爆炸**：`feat`/`rbuf` 若多端口（多读/多写），TD 会把
   大表实现成**寄存器 + 大 mux** —— `u_blkdet` 一度 **6941 LUT / 6432 reg**，
   slice 24297 **超器件上限**(21216) build 失败。
   → `feat` 改**单写口 + 单读口（组合写控制）**，TD 正确推断分布式 RAM：
   `u_blkdet` 降到 **393 LUT**，总量 17555。
2. **TD 不支持数组端口 / 端口直访数组**：`o_box[]` → 改 `i_sel + o_det_box`（内部选通读出）。
3. **BOM/编码**：PowerShell `Set-Content -Encoding UTF8` 会加 BOM → TD/iverilog 解析失败；
   文本往返还会破坏中文注释。**一律用编辑器改文件**。
4. **`EDGE_THR` 8bit 截断**：`cv_top` 原本 `base_thr=EDGE_THR[7:0]` 把 300 截成 44（掩膜爆量）；
   已把阈值链路加宽到 11bit。
5. **`track[]` 复位**：原来不复位，仿真为 x 导致不建轨迹；已在 reset 清零。

## 构建

```
cd work/camera_hdmi_720p/td_project
D:\Tangdynasty\bin\td_commands_prompt.exe ../tools/td_run/build_full.tcl
```
TD v6.2.168116；PH1P35MDG324 -3；顶层 `design_top_wrapper`。

## 结果（route 级 final）

| 资源 | 占用 | 总量 | 占比 |
|---|---|---|---|
| slice | 18223 | 21216 | **85.89%** |
| LUT6 | 16816 | 21216 | 79.26% |
| slice reg | 15728 | 42432 | 37.07% |
| dram lut | 1312 | | |
| f7mux / f8mux | 290 / 4 | 10608 / 5304 | 2.73% / 0.08% |

| 时序 | WNS | TNS | FEP |
|---|---|---|---|
| Setup | **−1328 ps** | −5.5 ns | **20** |
| Hold | **+20 ps** | 0 | 0 |

> 时序比之前的 Sobel 版（−2664ps / 1140 FEP）**好很多** —— 去掉 CCL/Sobel 后逻辑大减。

### 比特流

| 文件 | 大小 | MD5 |
|---|---|---|
| `camera_hdmi_720p.bit` | 1,789,539 B | `07894E320C5D2B57637532A4F900DF56` |

## RTL 级验证（iverilog，钢珠5 真实帧）

`cv_blkdet`（`DARK_THR=100`）+ 集成 `cv_top`（MASK_SRC=3）：
frame 200 → **3 个球框**（112×64/96×48），frame 210/220 → 各 2 个，每个球建立轨迹 `track[]`。

## 上板验证要点

烧 `td_project\camera_hdmi_720p.bit`；`SW4=1` + `KEY2` 开 CV：
- 看机器视角是否框出钢珠、串口 `CV/NB`；
- 颜色正常（vendor 除法器，此前品红问题已修）；
- 若漏检/过检：调 `DARK_THR`（板载 K3/K4 微调偏置，当前范围 0..2047）。
