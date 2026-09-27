# td_run — TD 命令行构建的 run 参数模板（受 git 跟踪）

## 是什么

`td_project/camera_hdmi_720p_Runs/<run>/settings.cfg` 是 TD 流程脚本 `DefaultFlow.tcl` 的参数文件：

- **命令行方式**（`run.bat` / `td_commands_prompt.exe <TD>/doc/scripts/DefaultFlow.tcl`，在 run 目录内执行）
  会 `source ./settings.cfg` —— 本目录的两份模板就是这两个文件的可复现版本；
- **GUI 的 Run 按钮不读它**：TD 用内部参数运行，并在 reset/launch 时按内部模型**重写** `settings.cfg`
  （`reset_run` 甚至会删掉 phy_1 的那份）→ 一旦被覆盖，DDR IP 的约束就不再加载，合成报
  `SYN-8534 ... location, please add inst constraint`（11:55 那次失败的根因）。
- 因此：**凡涉及 IP 约束的构建一律走命令行（双击 run.bat），不要在 GUI 里按 Run。**
  GUI 仅用于 Programmer 下载、看结果。

> settings.cfg 里的相对路径是按 run 目录深度（`td_project/<prj>_Runs/<run>/`）算好的，别改目录层级。

## 为什么必须保留 IpADCList / IpSDCList 两行

DDR2 的引脚约束（45 条 ippin）与 PHY 硬核位置约束（14 条 ipinst：`ac_byte[*]/dx_byte[*]/ioclk[*]/u_pll0/u_pll1/bkref[*]`）
都在 IP 自带的 `ip/ddr2/ddr2/src/adc/ddr2.adc` 里，**必须**经下面两行加载：

```tcl
set IpADCList { ddr2 ../../../ip/ddr2/ddr2/src/adc/ddr2.adc }
set IpSDCList { ddr2 ../../../ip/ddr2/ddr2/src/sdc/ddr2.sdc }
```

流程会把它变成 `read_ip_adc -ip ddr2 -file <上面路径>` 与 `read_sdc -ip ddr2 <上面路径>` ——
**带 `-ip ddr2` 作用域**，所以 `ddr2.adc` 里 IP 根相对路径（`ph1p_ddrmc_wrapper/...`）才会解析到实际层次
`u_ph1p35_324_ddr_wrapper/u_ddr2/...`。`ddr2` = IP 组件名（`ddr2.xml` 的 `ipxact:name`）。
写法照厂商 lab 工程（`camera_to_dsi_display_Runs/*/settings.cfg`）。

## 怎么重建

1. syn：双击 `camera_hdmi_720p_Runs/syn_1/run.bat`（脚本会先从本目录**恢复** syn_1.settings.cfg）
2. phy：双击 `camera_hdmi_720p_Runs/phy_1/run.bat`（同上；phy 依赖 syn 产出的 `*_gate.db`，所以顺序不能反）
3. 两个 run.bat 都是自愈版：先 `copy /Y` 恢复模板再跑流程，防 GUI 覆盖后忘记恢复。

## 日志与产物在哪

- 命令行运行的完整日志 = **控制台输出**（构建时可重定向保存，如 `> build.log 2>&1`）；
- `run.log` 是 **GUI 运行**留下的日志文件，命令行运行**不会**更新它 —— 排查时别看错文件；
- 关键数字：syn 看 `flow.status`（Setup/Hold WNS）；phy 看 `camera_hdmi_720p_phy.ts`、
  `camera_hdmi_720p_pr.timing`、`route_flow.status`；比特流 `phy_1/camera_hdmi_720p.bit`。
