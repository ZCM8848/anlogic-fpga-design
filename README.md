# Anlogic FPGA Design

全国大学生嵌入式芯片与系统设计竞赛项目仓库（私有）。基于**安路（Anlogic）PH1P35 / HX1P35A** 平台，围绕 MIPI 摄像头采集 → ISP → HDMI/DSI 显示链路进行开发。

## 仓库内容

```
.
├─ work/                 # 团队自研代码（基于示例工程演进，主要开发区域）
├─ ref/                  # 参考资料（原始目录名保留）
│  ├─ 代码更新说明.txt
│  ├─ 全国大学生嵌入式芯片与系统设计竞赛'2026选题指南_康芯.docx
│  ├─ 设计参考文档/                      # lab_ex_1/2/3 说明文档
│  ├─ anlogic_example/
│  │  ├─ 安路HX1P35A比赛文档2026/         # lab_ex1/2/3 示例工程 + 寄存器表
│  │  └─ HX1P35安装驱动文档/              # 安装、驱动、烧写说明（PDF/docx）
│  └─ 2_Example/
│     ├─ DEMO_TD_6.2.1/DEMO/             # 官方 DEMO 工程源码
│     └─ DEMO实验介绍/                    # 0~36 号实验讲义（PDF）
├─ tools/lint.ps1        # 本地 Verilog 语法检查脚本
└─ .github/              # CI、PR / Issue 模板
```

## 开发环境

| 项目 | 版本 / 说明 |
| --- | --- |
| 开发工具 | 安路 TD（示例工程基于 **TD 6.2.1**） |
| 目标芯片 | PH1P35 / HX1P35A |
| 下载器驱动 | 见 `ref/anlogic_example/HX1P35安装驱动文档/` |

> 工具安装包、演示视频、常用软件体积较大且含商业/授权内容，**不入库**，请从团队共享盘获取（向组长索取链接）。

## 硬件参数参考

开发板（HX1P35A / PH1P35MDG324）与摄像头（SC520CS）的详细硬件参数已提炼为结构化文档，便于快速查阅：

- [`docs/hardware/`](docs/hardware/) — 芯片 / 开发板 / 摄像头 / 引脚总表 / 时钟复位（含 SC520CS 165 条寄存器表）
- 摄像头参数以 `work/camera_hdmi_720p` 中**已验证的代码**为准（见该目录 `README.md`）。

## 当前主项目

`work/camera_hdmi_720p` 是钢珠检测与 HDMI 720p60 显示工程：

- SC520CS 摄像头，1280×720@60，2-lane MIPI RAW10
- FPGA 完成 4×4 平均、背景差分、run 提取、门线显示和 OSD
- MCU 完成 CCL、筛选、跟踪、门线计数、背景重采和曝光/增益控制
- 识别态 UI 包含 Logo、`STEEL BALL`、Count、`DETECTED N`、`Anlogic HX1P35A`、FRAME 和门线
- 所有可见文字使用 MiSans Medium 1-bit ROM
- 蜂鸣器过门短鸣；静态测试图案下 K1 短按播放/暂停测试曲，画面显示 `MiSans by Xiaomi` 来源标注

发布产物：

```text
work/camera_hdmi_720p/artifacts/camera_hdmi_720p_buzzer_song_0A5A29B6.bit
MD5 0A5A29B62F7A80CD48AB30E497145C92

work/camera_hdmi_720p/artifacts/ph1p35_status_buzzer_song_7CB7577E.elf
MD5 7CB7577E94F0E78DD9F85C72A4B4E541
```

最终时序：Setup WNS +0.132 ns，Hold WNS +0.020 ns，0 违例，Slices 17,403 / 21,216（82.03%）。

## 快速开始

1. 安装安路 TD 6.2.1 并导入 License，安装下载器驱动。
2. 用 TD 打开示例工程，例如：
   `ref/anlogic_example/安路HX1P35A比赛文档2026/lab_ex1_mipi_hdmi_SC500_720P/lab_ex1_mipi_hdmi/td_project/camera_to_dsi_display.al`
3. 团队自己的功能在 `work/` 下开发，参考对应 lab 工程的约束与 IP 配置。

> **注意**：示例工程中的 `*.enc.v` 为厂商加密 IP，可参与综合但不可编辑；`td_project/*_Runs/`、`log/` 等为编译产物，已被 `.gitignore` 排除，不要提交。

## 贡献

请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)：分支模型、提交规范、PR 流程。
