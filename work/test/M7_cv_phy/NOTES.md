# M7_cv_phy — CV 前端集成版 全流程构建 + AWB 除法器资源优化（A/B 对照）

> 在 `minor` 分支，对**含 CV 前端**的工程跑命令行全流程（syn→place→route→bitgen）。
> 本目录做一组 A/B：`baseline/`（vendor 除法器）vs `opt/`（窄版除法器）。

## 构建方式

命令行直接对 `.al` 跑（无 `_Runs/`、无 `.prj`）：

```
cd work/camera_hdmi_720p/td_project
D:\Tangdynasty\bin\td_commands_prompt.exe ../tools/td_run/build_full.tcl   ; 全流程出 bit
D:\Tangdynasty\bin\td_commands_prompt.exe ../tools/td_run/syn_only.tcl     ; 仅到 optimize_gate（快测）
```

- TD：`D:\Tangdynasty` v6.2.168116；器件 PH1P35MDG324 -3；顶层 `design_top_wrapper`。
- `.al` 的 `divider` 源：baseline = `ip/divider/divider_gate.v`（vendor 生成网表）；opt = `rtl/isp/divider.v`（自研窄版）。

---

## 优化项：AWB 除法器替换（`rtl/isp/divider.v`）

**动机**：分层面积里 ISP 的 AWB 两个 `divider` IP 合计 ≈ 2148 LUT + 5498 reg，是最大可优化块。
vendor IP 是 **48 位被除数 / 32 位余数**的全流水（`PIPLE=50`），而 AWB 实际只需
`gain = (sum_g<<16)/sum_r|sum_b`，范围仅 **34 位被除数 / 20 位余数**，且调用方只用到商低 20 位 + 溢出。

**做法**：自研 `divider.v`——接口/延迟(50 拍)/数学(无符号 floor)与 IP **完全一致**的窄版全流水除法器。
- 正确性：iverilog 自检 **ALL PASS**（定向 12 + 随机 400，含 `gain=2^20` 溢出边界）；延迟实测 50 拍。
- 语义一致：无溢出 → `quotient={28'b0,q[19:0]}`；溢出 → 高位全 1（沿用 awb 的钳位 `|quotient[47:20]`）。
- `iverilog` 全量 lint 无新错误；TD 综合无 error（`TMR-2509` 组合环为基线已存在，与本改动无关）。

### 门级面积（optimize_gate，布线前）

| 指标 | baseline (vendor) | opt (窄版) | 变化 |
|---|---|---|---|
| `#lut` | 25707 | **24201** | −1506 (−5.9%) |
| `#reg` | 18474 | **14078** | **−4396 (−23.8%)** |
| `#slice*` | 20334 / 21216 = 95.84% | **18413 / 21216 = 86.79%** | **−9.4 个百分点** |
| `#with adder` | 3575 | 2263 | −1312 |

### route 级（final，全流程实建）

| 指标 | baseline (vendor) | opt (窄版) | 变化 |
|---|---|---|---|
| `#slice` | 20576 / 21216 = **96.98%** | 17727 / 21216 = **83.55%** | **−13.4 个百分点** |
| `#lut6` | 19193 (90.46%) | 17551 (82.73%) | −1642 |
| `#reg` | 18165 (42.81%) | 13766 (32.44%) | −4399 |
| ERAM20K / DSP | 41 / 19 | 41 / 19 | 0 |
| **Setup WNS** | **−2527 ps** | **−1916 ps** | **改善 0.61 ns** |
| Setup TNS / FEP | −1968.4 ns / 1119 | −1626.9 ns / 1093 | 改善 |
| Hold WNS | +20 ps | +21 ps | — |
| bit 大小 | 1,789,539 B | 1,789,539 B | — |
| bit MD5 | `8C7ABC19E7A229FC1BC6FED987533B09` | `CA32F9BDFFF47D131D9D7D570F9F822D` | — |

## 结论

1. **资源大降**：route 后 slice **96.98% → 83.55%（−13.4 个百分点）**，寄存器 −4400（−23.8%），
   LUT6 −1642。**腾出约 13 个百分点的布线余量**——为后续 CV 前端/跟踪/CLL 的功能扩展留空间。
2. **时序反而变好**：Setup WNS −2527 → −1916 ps（连最差路径都改善，因逻辑变少布线更松），FEP 1119→1093。
   残留违例仍在既有 ISP/edge 域（工程已知）。
3. **行为等价**：数学/延迟与 vendor IP 一致，仿真全过；AWB 颜色逻辑不变（无需改动 `awb.v`）。
4. 优化版**已完成完整流程并可生成比特流**：`opt/camera_hdmi_720p.bit`（md5 `CA32F9BD…`）。

## 目录

- `baseline/` — 优化前（vendor `divider_gate.v`）全流程报告 + bit
- `opt/` — 优化后（`rtl/isp/divider.v`）全流程报告 + bit
- 报告文件（`*.area/*.ts/*.timing/*_flow.status/*.bit`）按仓库约定由 `.gitignore` 排除
