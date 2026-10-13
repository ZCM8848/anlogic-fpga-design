# M7_cv — CV 前端接入后的门级面积（中断留档）

> 本次会话在 TD 上把 `impl_hw` 的新 CV 前端接入 `design_top_wrapper` 后跑到
> `optimize_gate`，因会话中断未完成 place/route/bitgen。此目录保存该阶段结果。

## 改动（tracked）

- `rtl/cv/cv_top.v`：新增 `I_mask_ext` 端口 + `MASK_SRC=2`（外部掩膜）分支，
  Sobel 级用 `generate` 包裹 → `MASK_SRC=2` 时被综合剪掉。
- `rtl/top/design_top_wrapper.v`：例化 `cv_front_top`（取 `S_hdmi_out_de/vsync/data`），
  其 `O_mask` 接 `cv_top.I_mask_ext`；`cv_top` 参数 `MASK_SRC=2`。
- `td_project/camera_hdmi_720p.al`：**临时改造**——移除缺失的 `divider.ipc`，改引生成网表
  `ip/divider/divider_gate.v`；并把 5 个新 CV 模块加入编译清单。
  ⚠️ 提交前需决定：入库 `divider.ipc` 还是保留引用 `divider_gate.v`。

## 结果（optimize_gate，未做 place/route）

| 指标 | 基线(未接入) | 接入后 |
|---|---|---|
| `#slice*` | 20510 / 21216 = 96.67% | **20452 / 21216 = 96.40%** |
| `#slice reg` | 18393 | 18474 |
| `#eram` | 39 | 41 |
| `#dsp` | 18 | 19 |
| Setup WNS | -2.511 ns | -2.624 ns |
| Hold WNS | +0.114 ns | +0.114 ns |

分层：`u_cv_front`(cv_front_top) = 163 logic LUT + 512 dram + 130 seq + 2 ERAM + 1 DSP；
`u_cv_top` 因剪掉 Sobel 由 4695/1184 降到 **4438/672**。

**结论**：前端极小，剪 Sobel 腾出的资源 ≥ 前端开销 → **集成后占用不升反平（96.40%），能塞下**。

## 待办（下次继续）

1. 重跑完整流程（`syn→place→route→bitgen`）拿最终时序与比特流，确认布线后仍收敛/可下载。
2. 核对前端掩膜与 `cv_top` 的流水延迟对齐（掩膜比 `I_de` 晚约 5 拍 → 检测框可能有常数水平偏移，必要时加对齐延迟）。
3. 上板验证检测效果（本机无法验证）；`.al` 的 divider 归属需定稿。
