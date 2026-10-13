# M7_cvfix — 修 cv_top 两个真缺陷后的可上板版

> 在钢珠5 上做 **RTL 级仿真验证**（不是 Python 代理）时发现并修复了 2 个真缺陷，重新全流程构建。

## 修了什么（commit `161723c`）

| # | 缺陷 | 现象 | 修复 |
|---|---|---|---|
| 1 | `EDGE_THR` 阈值链路只有 8bit（`base_thr=EDGE_THR[7:0]`） | 300 被静默截成 **44** → 掩膜爆量 15.6 万 px、`run_cnt=1024` 溢出、几乎无框 | `base_thr/thr_plus/eff_thr` 改 11bit 贯通（支持到 2047） |
| 2 | `track[]` 从不复位 | 仿真为 `x` → `!track[..].valid` 判成 `x` → 新建轨迹分支走不进 → 不建轨迹 | FSM reset 里 `track[k]<={TW{1'b0}}` |

## 验证方法（RTL 级）

`iverilog` 把钢珠5 第 200/201 帧真实像素喂进 `cv_top`（`MASK_SRC=1`, `EDGE_THR=300`），导出其机器视角：

| | 修复前 | 修复后 |
|---|---|---|
| run_cnt | 1024（溢出） | **183 / 192**（<1024，与 Python 计算一致）|
| 掩膜 | 153328 px（木纹全在） | **1261 px**（只剩球边缘弧）|
| 框 | 0 | **1 个球框**（x=101 y=269 w=34 h=22）|

机器视角图：`C:\Users\gg060\Desktop\钢珠5_RTL_机器视角.png`。

### 仍存在的局限
球的 Sobel 弧是**细线**，简化 CCL 会切碎 → 只完整框出 1 个球 + 若干碎片。改善方向：形态学闭/膨胀把弧连成环（+少量 LUT），或降 `MIN_FILL`。

## 构建（命令行全流程）

```
D:\Tangdynasty\bin\td_commands_prompt.exe ../tools/td_run/build_full.tcl   (CWD=td_project)
```
TD v6.2.168116；PH1P35MDG324 -3。本设计**很拥挤**，TD 的 place/route **偶发崩溃**（access violation + coredump），需重跑；本次第 2 次成功。

## 结果（route 级 final）

| 资源 | 占用 | 总量 | 占比 |
|---|---|---|---|
| slice | 19752 | 21216 | **93.10%** |
| LUT6 | 18491 | 21216 | 87.16% |
| slice reg | 17730 | 42432 | 41.78% |

| 时序 | WNS | TNS | FEP |
|---|---|---|---|
| Setup | **−1971 ps** | −1606.8 ns | 1131 |
| Hold | **+21 ps** | 0 | 0 |

### 比特流
| 文件 | 大小 | MD5 |
|---|---|---|
| `camera_hdmi_720p.bit` | 1,789,539 B | `C3FE9E4B9887A32E6FC9BCCA2CA9D3C9` |

## 上板验证要点

烧 `td_project\camera_hdmi_720p.bit`；`SW4=1` + `KEY2` 开 CV：
- 颜色应正常（不再品红）；
- 机器视角应看到钢珠边缘（掩膜）+ 框；串口 `CV/NB`。
- 若木纹/杂点导致 run 溢出（串口或画面异常），用板载 `K3/K4` 调阈值偏置（现在可到 2047）。

## 目录对照
- `M7_sob_restore/` — 回退后但含阈值截断 bug 的版本（slice 96.58%，**勿用**）
- `M7_cvfix/`（本目录）— 修复 2 缺陷后的版本（slice 93.10%）✅ 当前候选
- `M7_cv_phy/` — 更早的前端/除法器失败实验留档
