# M5-00 构建证据（2026-09-27 12:04–12:15）：DDR2 空载校准版首次成功构建

## 背景（首败根因）

M5-① 首次上板构建时 TD 报：

```
SYN-8534 ERROR: Can not get the inst "u_ph1p35_324_ddr_wrapper/u_ddr2/ph1p_ddrmc_wrapper/ph1p_ddrmc_top/u_ddr_phy/u_ddrphy_top/u_ddrphy/ac_byte[0]$ac_byte_used$u_ddrphy_ac_byte_wrapper/u_ddrphy_byte" location, please add inst constraint.
```

根因：IP 自带的 `ip/ddr2/ddr2/src/adc/ddr2.adc`（**45 条 ippin + 16 条 ipinst**）从未被加载。

机制：这些约束只能经 run 目录 `settings.cfg` 的 `IpADCList/IpSDCList`
→ 流程生成 `read_ip_adc -ip ddr2 -file ...` / `read_sdc -ip ddr2 ...`（带 IP 作用域）。
而 **TD GUI 的 Run 用内部参数运行、并重写 settings.cfg**（11:55 那次 reset 还把 phy_1 的整份删掉），
**只有命令行流程（run.bat → DefaultFlow.tcl）会 `source ./settings.cfg`**。

## 修复

- `tools/td_run/{syn_1,phy_1}.settings.cfg`：补齐 IpADCList/IpSDCList（照厂商 lab 工程写法）；
- `tools/td_run/*.run.bat` + run 目录内自愈版 run.bat：先 `copy /Y` 恢复模板再跑流程（防 GUI 覆盖后忘记恢复）。

## 构建结果

两份日志为本目录下 `syn_1_build_stdout.log` / `phy_1_build_stdout.log`（命令行运行的完整 stdout）。

| 步骤 | 时间 | 结果 |
|---|---|---|
| syn | 12:04:43–12:07:40 | opt_rtl 1m26s + opt_gate 1m16s 全过；`*_gate.db` 11.7MB；**Setup WNS +0.860ns / Hold WNS +0.114ns，0 违例** |
| phy | 12:08:49–12:15:45 | place/route/bitgen 全过；**final: Setup WNS +0.101ns / Hold WNS +0.022ns，TNS/HTNS = 0，0 违例** |

- 比特流：`phy_1/camera_hdmi_720p.bit`（1,789,539 B，md5 `460779cbd30d42262554c382bea10c5a`）
- 日志内关键证据行（syn_1_build_stdout.log）：
  - `:423` `read_ip_adc -ip ddr2 -file ../../../ip/ddr2/ddr2/src/adc/ddr2.adc`（3.2s 完成）
  - `:490` `read_sdc -ip ddr2 ../../../ip/ddr2/ddr2/src/sdc/ddr2.sdc`
  - `:469–484` `set_ipinst_assignment ddr2 .../ac_byte[0]...u_ddrphy_byte LOCATION = X0Y70Z0` 等 16 条（正是失败那次缺的那批）
  - `SYN-8534` 出现次数：**0**（对照：11:55 GUI 运行中出现 1 次并中止）

## 注意（排查时别看错文件）

`syn_1/run.log`（519 行）是 **11:55 GUI 失败运行**遗留的日志；**命令行运行不更新 run.log**，
其完整输出在控制台（本次已重定向保存为本目录两份 log）。

## 第二轮重建（2026-09-27 12:29–12:46）：修复串口回归后重建

首版 bit 上板发现回归：串口只有 CAM 行正常，MIPI+DDR 两行整段输出 0x00（每周期恒 128 字节）。
根因 = `status_report.v` 中 `pc <= 7'd144` / `dl[pc - 7'd145]`：144/145 超 7 位上限被静默截断
成 16/17（TD 日志有两条 `HDL-5007`）→ 比较永假 + 数组索引越界 → 输出 0。

修复（提交 `b9b3695`）：行边界改用 8 位 localparam；`check_rtl.py` 升级为裸字面量全量扫描
（旧文件 2/2 命中、修复后 0）；`i2c_master` 的 `3'd8` 显式写 `3'd0`（等效消警告）。

重建结果（日志：`syn_1_rebuild_stdout.log` / `phy_1_rebuild_stdout.log`）：

- syn：0 ERROR、`SYN-8534` ×0、本工程 `rtl/` 的 HDL-5007 ×0；Setup WNS 860ps / Hold WNS 114ps；
  IP 约束进场证据：`set_ippin_assignment` ×45 + `set_ipinst_assignment` ×16。
- phy：0 ERROR；final **SWNS +0.101ns / HWNS +0.020ns，TNS/HTNS = 0**；
  DDR PHY 硬核放置可见（`u_ddrphy_byte` LOCATION="X0Y70Z0"）。
- 新 bit：`phy_1/camera_hdmi_720p.bit`（1,789,539 B，12:46）md5 `b4ec8fb2a504dc722d2d4767472e0724`。

## 上板验收（待做）

下载**新** bit（md5 `b4ec8fb2a504dc722d2d4767472e0724`）后：

- 串口应出三行（每 500ms）：CAM 行照旧；MIPI 行照旧（含 `HS=1 F=… SW4=1 … RX=1`）；
  **第三行 DDR 行出现 `DDR RDY=1 ARDY=1 WRDY=1`** ← 本次关键验收点。
- 画面维持 M4 现状（滚动 + Bayer 网格 —— 本步未接视频通路，属预期）。
- `RDY` 一直 0 → 按预案换板上 100MHz 差分钟振作 ref_clk。
