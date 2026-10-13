# M7_phy — TD 命令行综合+布局布线构建记录

> 在**本机**用安路 Tang Dynasty 对 `work/camera_hdmi_720p` **命令行**跑通
> `syn → place → route → bitgen` 全流程，产物与关键数字留档。

## 构建环境

| 项 | 值 |
|---|---|
| 工具 | Tang Dynasty **v6.2.168116**（与本工程 `.al` 的 `TD_Version` 一致） |
| 安装路径 | `D:\Tangdynasty`（**注意**：`tools/td_run/*.run.bat` 里硬编码的 `D:/Anlogic/TD_6.2.1_...` 在本机不存在） |
| 器件 | PH1P35MDG324 `-3` |
| 顶层 | `design_top_wrapper` |

## 构建方式（无 `_Runs/`、无 `.prj`）

本机没有 TD GUI 生成的 `camera_hdmi_720p_Runs/` 与 `.prj`，故直接对 `.al` 跑：

```
td_commands_prompt.exe <script.tcl>          # 在 td_project/ 下运行（XML 相对路径按 CWD 解析）
  import_device ph1_35p.db -package PH1P35MDG324 -speed 3
  open_project camera_hdmi_720p.al
  elaborate -top design_top_wrapper
  read_adc ../constraints/pin.adc
  read_ip_adc -ip ddr2 -file ../ip/ddr2/ddr2/src/adc/ddr2.adc
  read_sdc ../constraints/timing.sdc
  read_sdc -ip ddr2 ../ip/ddr2/ddr2/src/sdc/ddr2.sdc
  optimize_rtl / optimize_gate -packarea / legalize_phy_inst / update_timing
  place / route / bitgen -bit camera_hdmi_720p.bit
```

### ⚠️ 必须的权宜（仓库缺陷）

仓库里 **缺 `ip/divider/divider.ipc`**，而 `.al` 只引用该文件 → TD 报
`HDL-8007 ERROR: divider is a black box`。本次用 TD 生成的网表 `ip/divider/divider_gate.v`
（模块名就是 `divider`）在**临时 `.al`** 里替代 `.ipc` 完成编译，跑完立即还原（`git diff` 为空）。
**建议**：把 `divider.ipc` 入库，或在 `.al` 里直接引用 `divider_gate.v`。

## 结果

### 时序（final）

| | WNS | TNS | FEP |
|---|---|---|---|
| Setup | **−2.669 ns** | −1997.2 ns | 1118 |
| Hold | **+0.020 ns** | 0 | 0 |

（`camera_hdmi_720p_phy.ts`：`SWNS -2.669ns / STNS -1997.220ns / HWNS 0.020ns`）

### 资源（route 后 `camera_hdmi_720p_phy.area`）

| 资源 | 占用 | 总量 | 占比 |
|---|---|---|---|
| LUT6 | 19511 | 21216 | **91.96%** |
| slice | 20451 | 21216 | **96.39%** |
| slice reg | 18090 | 42432 | 42.63% |
| ERAM20K | 39 | 108 | 36.11% |
| DSP | 18 | 40 | 45.00% |
| PLL / DDR byte / MIPI RX | 3 / 6 / 1 | 6 / 12 / 2 | 50 / 50 / 50 % |
| GCLK / SCLK | 9 / 22 | 32 / 48 | — |

### 比特流

| 文件 | 大小 | MD5 |
|---|---|---|
| `camera_hdmi_720p.bit` | 1,789,539 B | `EA052506E3AA3180E6988F09627E0E2F` |

## 结论

1. **可综合、可布局布线、可生成比特流**，无 error（DDR IP 约束已加载，无 `SYN-8534`）。
2. **时序有 Setup 违例（−2.67ns）**，与工程既有记录（M7 收敛 −1.83ns，本就存在 ISP `edge` 路径违例）同属已知问题域。
3. **资源极紧**：slice 96.39% / LUT6 91.96% —— **新增 CV 前端（约 +5~8k LUT）没有空间**，需先做资源优化（时间复用 / 帧缓存搬 DDR2 / 跟踪计数上 RISC-V MCU 硬核）。

## 文件

- `camera_hdmi_720p.bit`（gitignore）
- `camera_hdmi_720p_phy.area` / `camera_hdmi_720p_gate.area` / `camera_hdmi_720p_rtl.area`（gitignore）
- `camera_hdmi_720p_phy.ts` / `camera_hdmi_720p_pr.timing` / `camera_hdmi_720p_place.timing` / `camera_hdmi_720p_exception.timing`
- `syn_flow.status` / `place_flow.status` / `route_flow.status`
- `place_clock_utilization.txt` / `route_clock_utilization.txt`

> 本次构建的是**现有工程**（含 `cv_top`）；`Python/impl_hw` 新增的 5 个 CV 模块**不在**本次构建内（未接入 `.al`/顶层）。
