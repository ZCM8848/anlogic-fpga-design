# M7_redcnt —— 红框 + Anlogic logo 下方球计数

## 改动

| 文件 | 改动 |
|---|---|
| `rtl/cv/cv_top.v` | 识别框颜色 `24'h00FF00` → `24'hFF0000`；新增 4 位 BCD 球计数 `O_count_bcd`（9999 饱和）；关闭 CV 时保留累计值，再次开启时清零；新增 `I_det_data`，检测只用未叠 OSD 的相机画面 |
| `rtl/video/hdmi_mixer.v` | 新增 `O_video_raw`（与 `O_hdmi_de` 同拍）；新增 `I_ball_bcd` 与 `I_dyn_osd_on`；logo 正下方 (0,164) 渲染 `BALL:dddd`（16×16 字符单元、黄色） |
| `rtl/top/design_top_wrapper.v` | CV 开时 OSD 保持开启（logo + 球计数），帧计数关闭；hdmi_mixer 原始画面送 cv_top 检测；连接 `S_cv_count_bcd` |
| `tools/sim/cv_pipeline_sim.py` | 结果视频框色 BGR `(0,255,0)` → `(0,0,255)` |
| `README.md` / `docs/TECHNICAL_DETAILS.md` / `docs/CV_RTL_MIGRATION.md` / `work/test/VIDEO_VALIDATION.md` | 同步红框、球计数与 OSD 行为说明 |

## 构建

命令（工作目录 `work/camera_hdmi_720p/td_project`）：

```
D:\Tangdynasty\bin\td_commands_prompt.exe ..\tools\td_run\build_full.tcl
```

- bit：`td_project/camera_hdmi_720p.bit`，1,789,539 B，md5 `58DFA5A3272E381D086524A2D1E88BD1`
- syn：Setup WNS -3.095ns / Hold +114ps / 777 FEP（basic）
- phy：**Setup WNS -1.849ns / Hold +20ps / 782 FEP**
- 资源：slices 18992/21216（89.52%）、RAM 49、DSP 22、DRAMHARDCON 161
- 违例分布：负 slack 端点集中在 `cv_blkdet` 的 DRAM/乘法器、ISP AWB 与 status_report 跨域；新增 `hdmi_mixer` 球计数路径未进入负 slack 列表
- 组合环：仅剩既有 `u_isp_top/awb_O_tready_syn_2`（TMR-2509，上一版同样存在）；新增 OSD 逻辑无 `SYN-5033`
- 本工程 `rtl/` 的 `HDL-5007` 仍为既有两条（`I_lane_invert`、`O_raw_tready`），新增代码无截断警告

## 验证

- `tools/check_rtl.py`：35 条错误与改动前一致（`cv_blkdet`/`cv_norm_bg` 旧问题与未入 `.al` 的旧 CV 文件），改动文件无新增错误。
- 离线管线：`cv_pipeline_sim.py work/test/m12.mp4 ... --mask-osd` 输出 278 帧、计数 8；抽帧检测到红框像素 7283、绿色框像素 0。
- 钢珠16（1617 帧，`GATE=320`、`MISS_K=35`、`DARK_THR=135`）：COUNT=10，ids=23；事件帧 247/467/481/766/775/778/785/1202/1216/1226。
  - 生成 `钢珠16_计数结果.mp4`（真实画面 + 红框/白 ID）、`钢珠16_二值识别.mkv`（80×45 块掩膜，209 帧有识别）、`钢珠16_二值识别_叠加.mkv`（掩膜 + 红框/白 ID，217 帧有叠加）。
  - 阈值敏感性（旧版，长宽比拆分）：`DARK_THR=100` 计 4、`120` 计 9、`130` 计 8、`135` 计 10、`138～148` 计 8、`150` 计 13。默认 100 不适用于这段录像。
- local 环带 + 真实中心/显示框下移 + 边缘放宽/ROI/长宽比/同帧去重复测（2026-10-27）：`DARK_THR=135` 计 **9**（ids=13）；事件 254/466/475/766/770/777/1202/1208/1215。识别框内部尺寸全部 160×160，离场最多保留 1 帧。
- 上板待验：
  1. CV 状态 1/2 时 Anlogic logo 保持，logo 下方显示 `BALL:dddd`；
  2. 状态 1 真实画面 + 红框/白 ID，状态 2 块掩膜 + 红框/白 ID；
  3. 球离开画面时 `BALL` 与串口 `C=` 同步 +1；
  4. CV 关闭后 `BALL` 保留本次总数，再从 0 切到 1 时清零；
  5. OSD 模式（SW3=1、CV 关）仍显示 logo、球计数与帧计数。
