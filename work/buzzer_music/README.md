# buzzer_music — 用板载蜂鸣器播放 MIDI 主旋律

独立 TD 工程，用 HX1P35A 开发板的板载蜂鸣器播放 MIDI 文件
`@R__piano - 1000年生きてる.mid` 的主旋律，循环不断。

## 硬件

| 信号 | FPGA | 说明 |
|---|---|---|
| `I_sys_clk` | C4 | 板载 50MHz 有源晶振 |
| `I_key1` | D5 | KEY1，按下=0；播放/暂停切换（20ms 消抖） |
| `O_buzzer` | C12 | 蜂鸣器，**低电平响**（经三极管驱动） |
| `O_led_play` | D10 | LED1，高电平点亮；点亮=正在播放 |

> **蜂鸣器回路里串着拨码开关 SW5**：SW5 拨下=接通、拨上=断开。播放前确认 SW5 拨到接通一侧，否则无论如何都不会响。
> 详细引脚依据见 [`docs/hardware/HW_HX1P35A_BOARD.md`](../../docs/hardware/HW_HX1P35A_BOARD.md) §2/§9/§10/§12。

## 功能

- 上电后自动开始播放，循环不断。
- 按 KEY1 暂停，再按继续；按住只切换一次。
- LED1 点亮表示正在播放；暂停时熄灭。
- 蜂鸣器在休止/暂停/吐音间隙输出高电平（不响、不耗流）。

## MIDI 来源与主旋律提取

源文件：`C:\Users\Z___C\Downloads\@R__piano - 1000年生きてる.mid`
（type 1，480 PPQN，2 个钢琴音轨，全程 100 BPM，全长约 187.8 s）。

- track 0 为右手旋律（E3~E6，820 个音符），track 1 为左手伴奏（A0~A4）。
- 蜂鸣器单声道只能发一个音高，取 track 0 在每个时刻正在发声的**最高音**（top-voice）作为旋律线，无音发声时为休止。
- 时间按 `set_tempo` 分段换算到毫秒（本曲全程 600000 µs/quarter = 100 BPM，1 tick = 1.25 ms）。
- 每个事件 = `{note[7:0], dur_ms[15:0]}`，note=0 表示休止；节奏总时长由各事件 `dur_ms` 之和决定。
- 旋律结束追加 800 ms 休止，让循环重启有一个自然呼吸。

提取脚本：[`tools/gen/gen_song.py`](tools/gen/gen_song.py)，依赖 `mido`。运行：

```powershell
pip install mido
python tools/gen/gen_song.py            # 默认读 Downloads 下的目标 MIDI
python tools/gen/gen_song.py --midi <path> --outdir <rtl 目录>
```

产物（已随仓库提交，无需重新生成即可综合）：

- [`rtl/song_data.vh`](rtl/song_data.vh)：`song_rom[i] = ...;` 初始化（1518 个有效事件，ROM 深度 2048）。
- [`rtl/note_table.vh`](rtl/note_table.vh)：`note2half(note)` 函数，MIDI 音符到 50MHz 方波半周期时钟数
  `half = CLK_HZ/(2*freq)`，`freq = 440*2^((note-69)/12)`，note≤0 返回 0（休止）。

生成结果：1518 个事件（1013 音符 + 505 休止），播放时长 186.2 s，音域 E3~E6。

## 设计

`rtl/buzzer_music_top.v` 单顶层，无 IP、无 PLL：

1. **上电复位**：`por_cnt` 数满 `POR_CYCLES` 后释放 `rst_n`（板卡无独立复位按键）。
2. **输入同步 + 消抖**：KEY1 经 2FF 同步 + 20ms 稳定判定，下降沿产生 `key_press` 单拍脉冲。
3. **播放/暂停**：`playing` 上电置 1（自动播放），每次 `key_press` 翻转；`O_led_play = playing`。
4. **1ms 节拍**：`ms_cnt` 分频 `MS_DIV=50000` 产生 `ms_tick`。
5. **歌曲 ROM**：`reg [23:0] song_rom [0:2047]`，初始值由 `song_data.vh` 写入；同步读
   `rd_data <= song_rom[rd_addr]`。
6. **序列机**（两态）：`S_LOAD` 锁存预取的 `rd_data` 为当前事件并预取下一地址；读到
   `dur==0`（padding/曲终）直接跳回地址 0 循环。`S_PLAY` 按 `ms_tick` 递减 `dur_left`，到期回 `S_LOAD`。
7. **吐音间隙**：每个音符在 `dur` 末尾留 `GAP_MS=20` ms 静音，节奏总时长不变；`tone_left` 控制发声窗口。
8. **方波发生**：`half = note2half(cur_note)`；`half_cnt` 数到 `half-1` 翻转 `O_buzzer`；
   暂停/休止/吐音段保持 `O_buzzer=1`（静音、不耗流）。

## TD 工程

- 工程文件：`td_project/buzzer_music.al`
- 器件：`PH1P35MDG324`，速度等级 `-3`
- 顶层：`buzzer_music_top`
- 约束：`constraints/pin.adc`、`constraints/timing.sdc`
- 无 IP、无 PLL

### 命令行构建

`tools/build_td.ps1` 一键综合 + 布局布线，并把 bit 拷到 `artifacts/buzzer_music.bit`：

```powershell
powershell -ExecutionPolicy Bypass -File tools/build_td.ps1
```

实现要点（与 `work/camera_hdmi_720p/tools/td_run/` 同一套路）：TD 自动生成的 `run.bat`
把可执行名错写成 `td_commands_prompt_commands_prompt.exe`（该文件不存在），导致 `launch_runs`
的工作进程根本起不来、`wait_run` 无限轮询。因此本工程**绕开 `launch_runs`**：脚本自己建
`td_project/buzzer_music_Runs/{syn_1,phy_1}/` 目录，放入 `tools/td_run/buzzer_music.prj`
与 `syn_1.settings.cfg`/`phy_1.settings.cfg` 模板（填好 `device_name`/`package_name`），再
直接在 run 目录里跑 `td_commands_prompt.exe …/DefaultFlow.tcl`（syn 先、phy 后）。

`tools/td_run/` 提供可复现的模板（受 git 跟踪）：

| 文件 | 作用 |
|---|---|
| `buzzer_music.prj` | run 目录用的工程文件（源码/约束路径按 run 目录深度算好 `../../../`） |
| `syn_1.settings.cfg` / `phy_1.settings.cfg` | DefaultFlow.tcl 的参数（device/package/top/start_step/end_step；phy 用 `parent ../syn_1` 读 `buzzer_music_gate.db`） |
| `syn_1.run.bat` / `phy_1.run.bat` | 自愈版批处理（先恢复 `settings.cfg` 再跑 DefaultFlow.tcl），可双击重建 |

> `td_project/buzzer_music_Runs/`、`*.bit`、`*.db` 等编译产物已被 `.gitignore` 排除，不提交。

### 实测结果（2026-10-30，TD 6.2.1 命令行流程）

| 阶段 | Setup WNS | Hold WNS | 违例 |
|---|---|---|---|
| syn（gate） | +12.086 ns | +0.502 ns | 0 |
| phy（final） | **+13.216 ns** | **+0.041 ns** | 0 |

资源（phy final）：

| 资源 | 用量 | 总量 |
|---|---|---|
| LUT6 | 230 | 21,216（1.08%） |
| Slice / reg | 232 / 123 | 21,216 / 42,432 |
| ERAM20K | 2（歌曲 ROM） | 108 |
| DSP / PLL | 0 / 0 | — |
| IO | 4（2 in / 2 out） | 160 |

bit：`artifacts/buzzer_music.bit`（1747.59 KB，MD5 `99D1DF36118964B3B4F17BA14B01EFE9`）。

## 仿真自检

`tools/sim/tb_buzzer_music.v` 覆盖：

1. `song_data.vh` 被正确包含：`song_rom[0..2]` 与生成器输出一致；
2. `note2half` 查表与公式一致（peek `dut.half` vs `440*2^((n-69)/12)`，容差 ±1 取整）；
3. 上电自动播放：`O_led_play=1`；
4. 第一音 G5：`O_buzzer` 方波周期 = `2*note2half(79)`（测两下降沿）；
5. 按 KEY1 暂停：`O_led_play=0`、`O_buzzer` 静音（高）；
6. 再按恢复：`O_led_play=1`、`O_buzzer` 重新翻转。

运行：

```powershell
powershell -ExecutionPolicy Bypass -File tools/sim/run.ps1
```

当前结果：**PASS**（ROM/note2half/自动播放/方波周期/暂停-恢复全部通过）。

## 上板检查清单

1. SW5 拨到蜂鸣器接通一侧（拨下）。
2. 用 TD Programmer 烧录 `artifacts/buzzer_music.bit`（或重新跑 `tools/build_td.ps1` 生成），确认 LED1 亮、电源正常。
3. 上电即应听到主旋律开始播放并循环。
4. 按 KEY1 暂停（LED1 灭、蜂鸣器静音），再按继续（LED1 亮、继续播放）。
5. 若无声：先核对 SW5；再用示波器确认 C12 在播放时有方波、暂停时为高电平。
