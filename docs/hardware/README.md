# 硬件参数参考（供 LLM / 开发者查阅）

本目录把本项目用到的硬件平台的**详细参数**从散落的厂商 PDF 与工程源码中提炼为结构化 markdown，
目的是让 LLM（以及人）能快速、准确地检索开发板与摄像头的硬件事实，而不必逐页翻 PDF 或通读 RTL。

## 文档索引

| 文件 | 内容 |
|---|---|
| [`HW_PH1P35.md`](HW_PH1P35.md) | FPGA 芯片：型号/封装/资源/电源/时钟资源/MIPI DPHY/MCU 核/配置 |
| [`HW_MCU.md`](HW_MCU.md) | 内嵌 RISC-V MCU 实操细节：时钟要求/JTAG 模式/fabric AHB·APB 窗口/IP 配置/内部地址映射/FD 工具链/OpenOCD 排错/printf 坑 |
| [`HW_HX1P35A_BOARD.md`](HW_HX1P35A_BOARD.md) | 开发板：电源/时钟源/各外设与**引脚分配表** |
| [`HW_SC520CS.md`](HW_SC520CS.md) | 摄像头：传感器参数/工作模式/时序/I²C/MIPI + **寄存器表** + 镜头 |
| [`HW_PINMAP.md`](HW_PINMAP.md) | 引脚总表：FPGA 引脚 ↔ 板网络 ↔ 外设 ↔ 本项目用法 |
| [`HW_CLOCKS_RESET.md`](HW_CLOCKS_RESET.md) | 时钟方案与复位策略（板源/PLL/各时钟域） |

## 单一真相源（重要）

不同来源之间可能存在**版本差异或笔误**。发生冲突时，按以下优先级取值：

1. **本项目已上板验证的源码** —— 引脚约束 `work/camera_hdmi_720p/constraints/pin.adc`、
   相机寄存器表 `work/camera_hdmi_720p/rtl/camera/uics520reg_720p60.v`、
   PLL/时钟 `work/camera_hdmi_720p/ip/pll/`、工程顶层 `rtl/top/design_top_wrapper.v`。
2. **开发板手册**《新HX1P35A开发板手册-HDL版2604.pdf》。
3. **芯片官方数据手册** DS1300 / DS1301（安路 PH1P）。
4. **传感器官方文档**（思特威 SC520CS 数据手册 V1.6 / 设计应用指南 V1.4）。

> 本文档中的**摄像头参数以 `work/camera_hdmi_720p` 中经验证可用的实现为准**（用户指定），
> 数据手册参数作为背景/上限参考。凡与工作区源码不一致处，均以源码为准并已在文中标注。

## 来源文件清单

| 缩写 | 文件 |
|---|---|
| DS1300 | `ref/01_安路PH1P35官方资料/DS1300_PH1P_Datasheet (1).pdf`（V1.2, 186p） |
| DS1301 | `ref/01_安路PH1P35官方资料/DS1301_PH1P_FamilyOverview.pdf`（V1.1, 14p） |
| 板手册 | `ref/02_HX1P35A开发板资料/新HX1P35A开发板手册-HDL版2604.pdf`（26p） |
| 原理图 | `ref/02_HX1P35A开发板资料/HX1P35B_FT.pdf`（11p） |
| MCU 指南 | `ref/00_使用指南/PH1P35内MCU核使用指南.pdf`（27p） |
| SC520DS | `ref/SC520CS摄像头资料/SC520CS-03_数据手册_V1.6.pdf`（37p） |
| SC520APP | `ref/SC520CS摄像头资料/SC520CS_设计应用指南_V1.4_for-CSP.pdf`（15p） |
| 6504 镜头 | `ref/SC520CS摄像头资料/6504镜头.pdf`（1p） |
| 工程源码 | `work/camera_hdmi_720p/**` |

## 免责与维护

- 本目录内容摘自**厂商私有资料**，仅限本私有仓库内部使用，请勿外传。
- 引脚/寄存器等关键参数请与上表"单一真相源"交叉核对后再用于设计。
- 提取方式：Poppler `pdftotext` 抽文本 + 逐页转 PNG 视觉校对；若厂商文档更新，请同步更新本目录。
