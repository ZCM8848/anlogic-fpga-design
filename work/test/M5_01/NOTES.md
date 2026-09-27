# M5-01 证据（仿真 + 构建）：M5-② 帧缓存链路 4 用例全通过 + syn/phy 零违例出 bit

## 怎么跑

```bash
cd work/camera_hdmi_720p
python tools/sim/fb_sim.py            # ~23s，stdout 即日志
```

本机无 iverilog，沿用 M3/M4 做法：Python 逐拍复刻 RTL 寄存器语义（组合读当前态 + 非阻塞提交），
模型对应关系：`FbWr`↔`fb_wr.v`、`FbRd`↔`fb_rd.v`、`DdrArb`↔`ddr_arb.v`、`FbCtrl`↔`fb_ctrl.v`，
外加 DDR 内存模型（读延迟、应用口间歇忙、指定窗口读挂起）。

## 用例与结果（全绿）

| 用例 | 注入 | 关键结果 |
|---|---|---|
| ① 正常帧流 | 读延迟 40、停顿 | 3 帧 172800 字全对；864k 检查点**不一致 0**；WR=3 RD=3 OV=0 UN=0 ER=0；丢组 0 |
| ② 压力 | 读延迟 120 + 间歇忙 | 同上零不一致、零丢组（预取余量验证） |
| ③ 读挂起看门狗 | 300000–306000 读永不返回 | 看门狗触发 ER+1、UN≥1；在写的帧判坏牺牲（WR=3/4）；**恢复后零不一致** |
| ④ 坏帧 | 帧 1 大量丢组 | 帧 1 不上屏（WR 不增、ER+1）；后续帧逐点全对 |

另有 DDR 内存抽查：3 槽 × 3 行（含每行末字）地址/内容/字序全对。

## 建板前拦下的 2 个 RTL 真缺陷

### 1. `ddr_arb` 重复采样（症状：行数据整体错位一个字、行末字缺失）

机制：仲裁器接受一条命令后当拍即回 `ST_IDLE` 重新采样 `I_rd_req/I_rd_addr`；但主机在 gnt 的
**下一拍**才更新自己的计数/地址（gnt 是寄存器输出），于是同一条已接受的地址被采样第二次 →
预取序列出现重复读，行内 80 字整体错位一个字、本行末字永不读回。

修复：接受后插入 1 拍冷却 `S_cd`（`ST_IDLE` 先消耗冷却、不采样；读写两条路径同处理）。

### 2. `fb_ctrl.O_rd_base` 换槽晚 1 拍（症状：每帧顶部一行残影）

机制：`O_rd_base` 原为纯寄存器（vs 拍 `<=` 新槽基址，下一拍才可见），而 `fb_rd` 的预取启动恰好
在 vs 次拍采样基址 → 新显示帧第 0 行的预取用了**旧槽基址**，画面上是上一帧的顶行数据。

修复：`O_rd_base` 改组合输出，vs 当拍预览待切槽基址（`S_rdy_axi` 条件下），与写侧 `O_wr_base`
既有做法（`assign O_wr_base = I_frame_start ? S_pick_base : S_base;`）对齐；内部寄存器更名 `S_rd_base`。

修复后两者在用例①的观测：不一致从 530541 点 → **0**。

## 一并修掉的 3 个仿真侧（非 RTL）缺陷（留档防复踩）

1. 填充启动判定必须用**拍首旧值**（RTL 在事件拍置 want_v、次拍启动；同拍启动会永不清 want → 无限重填）。
2. 空闲期时间跳跃必须等**所有挂起物**清空：`rd.events`、`rd.want_v`（已武装未启动的预取）、
   排空机 `dr_st`/待排空翻转 —— 漏一个就会把预取的启动拍跳掉（症状：预取整体迟 1500 拍、画面滞后 2 行）。
3. 打包写保护不能写成"自增后指针 < 80"（Python 顺序语义 vs RTL 非阻塞读旧值），否则每行第 80 字被跳过。

## 与上板相关的已知边界（设计允许，非缺陷）

读挂起（DDR 长时间不返回）时仲裁器被占住 → 排空饿死 → FIFO(8) 溢出丢组 → **在写的该帧判坏牺牲**
（用例③）；看门狗 4096 拍超时冲刷后自行恢复。真实 DDR 读延迟 ~40 拍，此路径仅为兜底。

## 构建（2026-09-27 13:35–13:44，命令行 syn→phy）

| 步骤 | 时间 | 结果 |
|---|---|---|
| syn_1 | 13:35:08 起 ~1 分钟 | opt_rtl 20s + opt_gate 21s 全过；**Setup WNS +860ps / Hold WNS +114ps，0 违例**；gate.db 生成 |
| phy_1 | 13:41:50–13:43:xx | place 45s + route 26s + fix_hold 2s + bitgen；**final（Timing Mode: final）Setup WNS +1376ps / Hold WNS +20ps，TNS/HTNS = 0，0 违例** |

- 比特流：`phy_1/camera_hdmi_720p.bit`（1,789,539 B，13:43），**md5 `05dbd1a71a1b190c4bcce470971b5782`**
- 关键证据（`syn_build_stdout.log` / `phy_build_stdout.log`，本目录）：
  - `read_ip_adc -ip ddr2` ✓；45×`set_ippin_assignment` + 16×`set_ipinst_assignment`，含
    `.../u_ddrphy_byte LOCATION = X0Y70Z0`（X0Y60Z0）→ IP 硬核位置约束全部进场
  - `SYN-8534` 0 次；自身 `rtl/` 的 `HDL-5007` **0 条**（27 条全在 `ip/ddr2` 与 HDMI 加密核内，正常噪声）；`HDL-7225` 0 条
  - `final_timing.rpt` 时钟扇出：usr_clk **2788** / HDMI_PIXEL 943 / MIPI_RX_BYTE 532 / ddr_clk 6 / HDMI_SERIAL 38 / pll_24m 1（各域线网都真接上）
- 面积（`camera_hdmi_720p_gate.area`）：LUT 7601（slice 26.7%）、**EBR 21/108（19.4%）**、DSP 0；
  **行缓存 BRAM 推断成功**（`u_fb_wr` 8 EBR + `u_fb_rd` 8 EBR）→ 计划里的风险④解除

### 构建期拦下的两个问题（均已修，提交 `ea5810b`）

1. **`HDL-8007 ERROR: <module> is a black box`×4**：TD 命令行流程 `open_project <run>/<prj>.prj` 打开的是
   **run 目录的 .prj**（不是 .al）；只改 `.al` 加文件，.prj 里没有这几个模块。修：新建
   `tools/td_run/sync_prj.py`（把 .al 清单里 .prj 缺失的条目定向补入，保留 CRLF），两个 run 目录同步后 38/38。
2. **`HDL-8007 ERROR: net 'S_dtgl0' is constantly driven from multiple places`**：`fb_wr.v` 里
   `S_dtgl0/S_dtgl1` 在主块复位段与排空引擎块各驱动一次（Verilog 多驱动）。修：删除主块里的重复复位行；
   `check_rtl.py` 新增 `check_multi_driver`（修复前样本 2/2 命中，修复后 0 误报）。

