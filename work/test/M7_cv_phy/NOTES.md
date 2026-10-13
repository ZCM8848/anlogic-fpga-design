# M7_cv_phy — CV 前端集成版 全流程构建 + AWB 除法器优化（**已回退**）

> 在 `minor` 分支，对**含 CV 前端**的工程跑命令行全流程（syn→place→route→bitgen）。
> 本目录记录一次 A/B 尝试：`baseline/`（vendor 除法器）vs `opt/`（自研窄版除法器）。
> **结论：优化版上板出现 RGB 崩溃（品红），已回退**——详见「失败与根因」。

## 构建方式

```
cd work/camera_hdmi_720p/td_project
D:\Tangdynasty\bin\td_commands_prompt.exe ../tools/td_run/build_full.tcl   ; 全流程出 bit
D:\Tangdynasty\bin\td_commands_prompt.exe ../tools/td_run/syn_only.tcl     ; 仅到 optimize_gate（快测）
```

- TD：`D:\Tangdynasty` v6.2.168116；器件 PH1P35MDG324 -3；顶层 `design_top_wrapper`。

## 基线（vendor `divider_gate.v`，route 级 final）

| 指标 | 值 |
|---|---|
| slice | 20576 / 21216 = **96.98%** |
| LUT6 / reg | 19193 (90.46%) / 18165 (42.81%) |
| ERAM / DSP | 41 / 19 |
| Setup WNS / TNS / FEP | **−2527 ps** / −1968.4 ns / 1119 |
| Hold WNS | +20 ps |
| bit | 1,789,539 B，md5 `8C7ABC19E7A229FC1BC6FED987533B09` |

## 失败尝试：自研窄版除法器（`opt/`，**已回退**）

- 动机：AWB 两个 vendor `divider` IP ≈ 2148 LUT + 5498 reg。
- 做法：`rtl/isp/divider.v`（34 位被除数 / 20 位余数，声称延迟 50 拍）。
- **离线单脉冲 TB 曾 ALL PASS**（这是漏检的原因），门级面积也大幅下降：

  | 指标 | baseline | opt | 
  |---|---|---|
  | `#lut` | 25707 | 24201 |
  | `#reg` | 18474 | 14078 |
  | `#slice` | 96.98% | 83.55% |

### **但上板实测：整屏品红（RGB 崩溃）** —— 见桌面 `测试.jpg`

**根因**：`awb.v` 是**连续 start**（`start = I_tvalid_r1`，每拍一个新向量）。
自研除法器把被除数/除数放在**输入级共享寄存器** `a_r/d_r`，各级流水都读它 ——
连续 start 下，在途向量的操作数被后续向量覆盖 → **商全错** → AWB 增益错 → 品红。
单脉冲 TB 只有一个在途向量，故未暴露。
`tb_divider_stream.v`（连续 start + 每拍新向量）**复现失败**，确认根因。

> 另外：bug 版**没有把操作数随流水搬运**，所以那份"面积大降"有一部分是**假象**
> （少了 34 级 ×（除数+被除数）的流水寄存器）。带正确操作数流水后 FF 与 vendor 相当。

### 处置

- 回退：`.al` 的 `divider` 源改回 `ip/divider/divider_gate.v`；删除 `rtl/isp/divider.v`。
- 本目录 `opt/` 的报告/bit 是**失败版**，仅作留档，**勿烧录**。
- 教训：涉及"流式接口"的模块，测试台**必须用与真实调用一致的时序**（这里是连续 start）。

## 其他上板问题（待查，与除法器无关）

- 报"识别全黑"等 —— 需另查 CV 前端/掩膜路径（见后续更新）。
