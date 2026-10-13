# M7_count — 块域检测 + 累计计数版（串口 C=）

> 在 `M7_blkdet`（块域暗块检测）基础上加**累计计数**并把跟踪调参到"数出 10"。

## 计数定义

**轨迹消亡即计数**：某轨迹被确认后失去匹配、丢失帧数 > `MISS_K`（判定"离开视野"）时，
`cv_top.O_count` +1。对应 `impl_a` 的 `--count-mode exit`（钢珠5 上它 10/10）。

## 调参依据（Python 精确模拟 `cv_top` 跟踪器：a-b 速度预测 + 贪心 NN + GATE + MISS_K）

| GATE | MISS_K | count | 
|---|---|---|
| 80 | 8 | 15 |
| 120 | 8 | 12 |
| 160 | 10~15 | 11 |
| 200 | 20 | 11 |
| **240** | **20** | **10 ✅**（ids=10）|

→ 顶层设 `GATE=240 / MISS_K=20`（大 GATE 吸收块检测抖动，避免同一颗球被重复建轨）。
调试录像：`C:\Users\gg060\Desktop\钢珠5_块域检测.mp4`（旧 16 轨版）。

## 改动

- `cv_top`：新增输出 `O_count`；`S_TU_W` 中"确认过的轨迹消亡"时 `r_count+1`。
- `design_top_wrapper`：`GATE=240/MISS_K=20`；`O_count` 2FF 同步到 100M 域；`DARK_THR 110->100`。
- `status_report`：串口行尾追加 ` C=<2hex>`（累计计数），每行共 68 字节。
  ```
  CAM ID=xxxx OK=x E=x CFG=x DDR=x SW4=x SW3=x CV=x NB=xx TH=xx C=xx\r\n
  ```

## 结果（route 级 final）

| 资源 | 占用 | 总量 | 占比 |
|---|---|---|---|
| slice | 18096 | 21216 | **85.29%** |
| LUT6 | 16829 | 21216 | 79.32% |
| slice reg | 15735 | 42432 | 37.08% |

| 时序 | WNS | TNS | FEP |
|---|---|---|---|
| Setup | **−1317 ps** | −17.1 ns | 43 |
| Hold | **+20 ps** | 0 | 0 |

### 比特流

| 文件 | 大小 | MD5 |
|---|---|---|
| `camera_hdmi_720p.bit` | 1,789,539 B | `E508082248A7861D845800C7C9F3559B` |

## 上板验证

烧 `td_project\camera_hdmi_720p.bit`；`SW4=1` + `KEY2` 开 CV；串口看 `C=`（累计计数）与 `NB=`（当前帧）。
按钢珠5（真值 10）验证：期望 CV 全程跑完后 `C` ≈ 10。

> 注：计数在**本机无法上板验证**；参数(GATE/MISS_K/DARK_THR)按钢珠5 仿真定的，实拍场景可能需微调
> （`DARK_THR` 可用板载 K3/K4 调偏置）。
