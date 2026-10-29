# camera_eth_720p / host — 上位机工具说明

> FPGA 通过千兆网把 **1280×720@60 RAW10 Bayer** 帧用 UDP 广播出来（约 553 Mbps），
> 这个目录的脚本负责：收包 / 回放抓包 / 解 RAW10 / AWB / 显示 / 出图 / 出视频。
>
> 所有处理都在 PC 上做，FPGA 只做「MIPI → RAW10 → UDP」透传，不做 ISP。

---

## 0. 先决条件

| 项 | 要求 |
|---|---|
| 板子 | 已烧 `m1.bit`，网线接板载「以太网」口，摄像头 FPC 接好，补光灯打开 |
| PC 网络 | 该网口设 **192.168.1.100 / 24**（FPGA 是 192.168.1.200） |
| Python | 3.10+，`pip install numpy opencv-python pyserial` |
| 抓包 | Wireshark / dumpcap（本机默认 `D:\Program Files\Wireshark\`） |
| 可选 | ffmpeg（本机已装 8.1.2，当前脚本用 `cv2.VideoWriter`，不强制需要） |

> 控制台如果中文乱码：`chcp 65001`。

---

## 1. 五分钟上手

```powershell
cd work\camera_eth_720p\host

# ① 看板子状态（每秒一行）
python cam_monitor.py COM4

# ② 另开一个窗口，抓 10 秒包
& "D:\Program Files\Wireshark\dumpcap.exe" -D          # 找网卡编号，选带“以太网”的那个
& "D:\Program Files\Wireshark\dumpcap.exe" -i "\Device\NPF_{2AFD76B7-...}" -w cap.pcapng -a duration:10

# ③ 验帧
python cam_stream_check.py cap.pcapng

# ④ 解一帧看看
python raw10_pcap_decode.py cap.pcapng frame.png

# ⑤ 实时显示
python cam_view.py
```

抓包时看 dumpcap 最后一行必须是 `received/dropped: N/0`，**dropped 不为 0 说明 PC 侧丢包**，
先关掉别的吃 CPU 的程序再抓。

---

## 1.5 Web 控制台（推荐入口）

```powershell
python console.py
```

浏览器自动打开 `http://127.0.0.1:8770/`，一个黑底琥珀色的控制台：

- **LIVE FEED**：实时画面（UDP → AWB → 列校正 → 降噪），HUD 显示帧号/帧率/曝光/增益/包数
- **DEVICE**：串口 N/T/C/S/V 与状态位（CFG / SENSOR / OVF / RX）
- **IMAGE**：白平衡三档 —— `AWB AUTO`（逐帧灰世界）/ `LOCK`（冻结当前增益）/ `OFF`（原始通道不校正）
- **RECORD**：填会话名 → 选时长 → `START`；自动调 dumpcap 录到 `captures/<名字>/raw.pcapng`
- **OUTPUT**：勾选要生成的产物（meta / png / mp4 / raw），录制结束自动跑流水线
- **SESSIONS**：历史录制列表，可一键 `PROCESS` 或 `DIR` 打开目录
- **SYSTEM LOG**：dumpcap 与处理脚本的实时输出

一次完整操作：

```
输入会话名 → 选 10 s → 勾选产物 → ● START → 自动停止 → 自动生成全部产物
```

### 一次录制会产出什么

| 文件 | 说明 | 大小（10 秒） |
|---|---|---|
| `raw.pcapng` | **原始流，始终保留**（完整的 UDP 包 + 时间戳） | ~730 MB |
| `meta.jsonl` | 每帧一行：帧号 / 曝光 / 增益 / 传感器 ID / BGR 统计 / AWB 增益 | ~25 KB |
| `run.json` | 录制配方：时长、帧率、带宽、完整性、bit md5、git commit | ~1 KB |
| `preview.png` | 第一张完整帧（AWB + 拉伸 + demosaic） | ~2 MB |
| `out_60fps.mp4` | 真 60fps 渲染视频（AWB/列校正全片固定） | ~17 MB |
| `raw10.npy` | **无损 10bit 原始像素** `(N,720,1280) uint16`，算法可直接 mmap | ~1.84 MB/帧 |

`raw.pcapng` 是母版，`raw10.npy` 是它的像素级展开（方便算法直接吃），
`out_60fps.mp4` 只是给人看的渲染版本——三者不互相替代。

配置保存在 `host/console.json`（自动生成，记录网卡 GUID 和串口），换机器删掉即可重新探测。
网卡默认按 **192.168.1.100** 反查，找不到才退回 `dumpcap -D` 的描述匹配。

注意：

- 控制台占用 **UDP 4660** 和 **COM4**，运行时不要再开 `cam_view.py` / `cam_monitor.py`
- 预览约 10 fps（Python 处理瓶颈），**录制不受影响**，pcap 是完整 60fps
- 关闭：窗口里 `Ctrl+C`，或任务管理器结束 python

## 2. 数据格式（必读）

### 2.1 链路

| 项 | 值 |
|---|---|
| 源 / 目的 IP | `192.168.1.200` → `192.168.1.100` |
| 端口 | UDP `4660` → `4660` |
| MAC | 目的广播 `FF:FF:FF:FF:FF:FF`，源 `02:00:00:00:00:01` |
| IP total / UDP len | 1476 / 1456 |

### 2.2 帧结构

一帧 = **800 个数据包 × 1440 B = 1,152,000 B** = 1280×720×10bit，正好整除。

```
[以太网14][IPv4 20][UDP 8][应用头 8][数据 1440]
                            └ AA 55 | frame_id(2) | pkt_idx(2) | pkt_total(2)   ← 全部大端
```

- `pkt_idx` = 0..799，`pkt_total` = 800
- **`pkt_idx == 0xFFFF` 是元数据包**（每帧一个，在 800 个数据包之前发送）

### 2.3 元数据包（前 32 B 有效，其余填 0）

| 偏移 | 内容 |
|---|---|
| 0-1 | `A5 5A` 魔数（数据包是 `AA 55`） |
| 2-3 | frame_id |
| 4-5 | 曝光（半行，当前 1991 ≈ 16.6 ms） |
| 6-7 | 模拟增益档位（16/48/80/112/144/176 = 1x/2x/4x/8x/16x/32x，当前 48 = 2x） |
| 8-9 | 传感器 ID（SC520CS = 0xEE4B） |
| 10 | 状态：bit0 cfg_done、bit1 sensor_ok、bit2 fifo_ovf、bit3 lane_err |
| 11 | 版本 = 1 |
| 12-23 | 上一完整传感器帧的 B/G/R 累加和（各 32bit，**含**黑电平） |
| 24-27 | 总像素数 921600 = 0x000E1000 |
| 28-31 | `5A 5A A5 A5` |

B/R 各占 1/4 像素、G 占 1/2，算灰世界增益时要**先各自除以像素数**再比
（`cam_proc.awb_gains_from_meta()` 已经处理）。

### 2.4 RAW10 打包

每 5 字节 = 4 个像素（MIPI 标准）：

```
P0 = b0<<2 | (b4>>0 & 3)
P1 = b1<<2 | (b4>>2 & 3)
P2 = b2<<2 | (b4>>4 & 3)
P3 = b3<<2 | (b4>>6 & 3)
```

字节流顺序就是光栅顺序，**包边界会跨行**，按连续字节流处理即可。

- Bayer 相位：**BGGR** → `cv2.COLOR_BayerBG2BGR`
- 黑电平：约 **64**（10bit）
- 数值范围 0..1023

---

## 3. 工具清单

| 脚本 | 用途 | 需要板子在线 |
|---|---|---|
| `console.py` | **Web 控制台**：预览 + 录制 + 一键处理（推荐） | ✅ |
| `cam_monitor.py` | 串口状态（N/T/C/S/V） | ✅ |
| `cam_view.py` | 实时显示 / 存图 / 录像 | ✅ |
| `cam_stream_check.py` | 抓包统计：帧完整性、帧率、带宽 | ❌ |
| `pcap_meta.py` | 抓包 → `meta.jsonl` + `run.json` | ❌ |
| `pcap_export_raw.py` | 抓包 → `raw10.npy`（无损 10bit 原始帧） | ❌ |
| `raw10_pcap_decode.py` | 抓包 → 解一帧 → PNG | ❌ |
| `make_video.py` | 抓包 → 60fps mp4 | ❌ |
| `cam_proc.py` | 处理函数库（给算法 import） | — |
| `cam_gain_scan.py` | 按帧统计亮度（调试增益/曝光） | ❌ |
| `cam_frame_grab.py` | 按 frame_id 抓指定帧 | ❌ |
| `cam_phase_analysis.py` | 按帧内标记分组对比（调参用） | ❌ |
| `mdio_dbg.py` | **历史遗留**：MDIO 调试串口打印，现已不用 | ✅ |

### 3.1 `cam_monitor.py` — 串口状态

```powershell
python cam_monitor.py            # 自动找串口
python cam_monitor.py COM4
```

每秒一行：

```
N=0012 T=0034 C=0035 S=EE4B V=B
  N 以太网收到的帧数        T 已发视频帧（≈60/s）
  C 摄像头 RAW10 帧计数     S 传感器 ID（0xEE4B）
  V 状态位 bit0=cfg_done bit1=sensor_ok bit2=FIFO溢出 bit3=rx_alive
```

判读：
- `C` 不涨 → MIPI 没数据（FPC/供电/XCLK）
- `C` 涨但 `T` 不涨 → 打包/发送侧问题
- `V` 的 bit2 = 1 → FIFO 溢出（画面上会有撕裂）

### 3.2 `cam_view.py` — 实时显示

```powershell
python cam_view.py                       # 默认 12fps 上限
python cam_view.py --record out.mp4      # 边看边录
python cam_view.py --no-denoise          # 关双边滤波（更快）
python cam_view.py --seconds 10          # 10 秒后自动退出
```

按键：`q` 退出、`s` 存 PNG、`r` 开始/停止录像。

处理链：UDP 收包 → 重组 → AWB（优先用元数据统计）→ 列 FPN 校正（列剖面 EMA）
→ 自动拉伸 → demosaic → 双边滤波 → 窗口。

> 实时显示约 **8~12 fps**，瓶颈是 Python 的 720p 处理，不是网络。
> **录像是"预览片段"，不是真 60fps**——要真 60fps 请用抓包 + `make_video.py`。

### 3.3 `cam_stream_check.py` — 抓包体检

```powershell
python cam_stream_check.py cap.pcapng
```

输出：视频包/元数据包数量、总帧数、完整帧数、残帧、帧号断点、平均帧率、带宽。
正常参考：**59.5~60 fps / 551 Mbps / 帧号 0 断点 / 残帧只有抓包首尾 1~2 帧**。

### 3.4 `raw10_pcap_decode.py` — 抓包出一张图

```powershell
python raw10_pcap_decode.py cap.pcapng frame.png
```

- 取第一帧完整帧
- 有元数据包时用 FPGA 的 B/G/R 统计算 AWB，否则本帧灰世界
- 黑电平 64 → AWB → 0.5%~99.5% 拉伸 → BGGR demosaic
- 同时存一份 `frame_raw10.npy`（10bit 原始，给算法对比用）

### 3.5 `make_video.py` — 抓包出 60fps 视频

```powershell
python make_video.py cap.pcapng out.mp4            # 全部完整帧，60fps
python make_video.py cap.pcapng out.mp4 300 30     # 前 300 帧，30fps
```

- AWB / 列校正 / 拉伸用**前 30 帧统计后全片固定**，不会逐帧闪
- 598 帧（10 秒）约 100 秒渲染，输出约 17 MB
- 这是拿到"真 60fps 视频"的正确方式

### 3.6 `cam_proc.py` — 处理函数库

给算法直接 import，不产生副作用：

```python
from cam_proc import (frame_pixels, awb_gains, awb_gains_from_meta,
                      apply_awb, column_profile, column_correction,
                      to_bgr, denoise, parse_meta)

px  = frame_pixels(buf)              # 1,152,000 B → (720,1280) uint16
gb, gr = awb_gains(px)               # 灰世界
bal = apply_awb(px, gb, gr)          # 10bit 浮点
bgr = to_bgr(bal, lo, hi)            # 拉伸 + demosaic → uint8 BGR
bgr = denoise(bgr, 1)                # 双边
```

### 3.7 调试脚本

```powershell
python cam_gain_scan.py cap.pcapng 4    # 每帧采 4 个包，打印 mean/p99/max
python cam_frame_grab.py cap.pcapng 1192 1250   # 按 frame_id 存 grab_<fid>.png
python cam_phase_analysis.py cap.pcapng # 按帧内标记字节分组对比，存 phase_<mark>.png
```

这三个主要是 bring-up 时用的（增益扫描、抓指定帧、分档对比），日常用不到。

---

## 4. 典型工作流

```
录制（dumpcap，10~30s）
   ↓  raw.pcapng
体检（cam_stream_check）→ 确认 0 丢包、帧完整
   ↓
出图（raw10_pcap_decode）→ 看单帧效果 / 存 10bit npy
出视频（make_video）→ 真 60fps mp4
   ↓
算法开发（import cam_proc，遍历帧）
   ↓
实机联调（cam_view 的收包逻辑 / UDP 帧源）
```

**算法侧建议**：写一个 `process(bgr, meta)`，数据源在 `pcap 回放` 和 `UDP 实时` 之间切换。
两者用的都是 `cam_proc`，处理结果一致，只有最外层 `for` 不同。

---

## 5. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `cam_view` 一直 0 帧 | 收不到包 | 确认 PC IP=192.168.1.100；网线在「以太网」口；防火墙放行 Python 入站 UDP 4660 |
| 抓包有、socket 收不到 | 绑错网卡 / 防火墙 | 用 `bind 0.0.0.0:4660`；临时关防火墙验证 |
| 画面全黑（均值≈68） | 增益不够 / 没开补光灯 | 补光灯打开；或改 `CAM_AG_INIT`（16/48/80/112/144/176）重烧 |
| 画面一片白（≈1023） | 增益过大 / 直射光太强 | 降增益；或缩短曝光 |
| 满屏竖条纹 | 传感器列固定图案噪声（FPN） | `cam_proc.column_correction`；更好的办法是暗场标定 |
| 颜色偏紫/偏绿 | RAW Bayer 直出，本来就没有 AWB | 用 `raw10_pcap_decode` / `cam_view`（自带 AWB） |
| 帧不完整（残帧多） | dumpcap 丢包 / PC 太忙 | 看 dumpcap 的 dropped；关掉占 CPU 的程序；缩短单次抓包 |
| 图像有一条水平接缝 | 包流与 sensor 帧有固定偏移（启动时决定） | 只影响观感，不影响算法；必要时 PC 端按行平移 |
| 串口没输出 | COM 口号错 / 没烧新固件 | `cam_monitor.py` 自动找口；确认 115200 8N1 |
| `cam_view` 只有 8fps | Python 处理瓶颈（正常） | 用 `--no-denoise`；或改用 pcap 离线 |

---

## 6. 性能与限制

| 项 | 数值 |
|---|---|
| 网络 | 45,000 包/秒，551 Mbps，dumpcap 0 丢包 |
| 实时显示 | 8~12 fps（Python 720p 处理瓶颈） |
| 离线渲染 | ~5 帧/秒（双边滤波最贵），10 秒素材约 100 秒 |
| 10bit 原始一帧 | 1.84 MB（npy uint16） |
| 抓包体积 | 73 MB/秒（10 秒 ≈ 730 MB） |
| mp4 体积 | 约 1.7 MB/秒（10 秒 ≈ 17 MB） |

限制：
- 实时路径会跳帧显示，**不是 60fps 全量**
- mp4 是 8bit + 有损压缩，**不能当 RAW10 用**；要原始数据就留 pcap
- FPGA 不做 AWB/降噪/gamma，所有图像处理都在 PC

---

## 7. 文件约定

- 大文件（`*.pcapng`、`*.mp4`、`*.npy`）**不入 git**
- 建议素材放 `work/camera_eth_720p/captures/<日期_场景>/`，该目录已加入 `.gitignore`
- 仓库只保存代码、文档、以及体积很小的 `meta.jsonl` / `run.json`（如果需要复现实验）

---

## 8. 相关文档

- `../README.md` — 项目总览、数据通路、图像参数
- `../constraints/timing.sdc` — 时钟约束（含摄像头域的已知 hold 误报说明）
- `../../docs/hardware/HW_ETH_RGMII.md` — RGMII/PHY 实测笔记 + TD 工具链坑
- `../../docs/hardware/HW_SC520CS.md` — SC520CS 寄存器（曝光/增益/增益表）
