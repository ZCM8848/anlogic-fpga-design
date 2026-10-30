# 串口热调参上位机

通过板载 USB-UART 与 MCU 通信，在线修改 `VISION_PARAMS`，不需要重新编译或烧录 ELF。参数保存在 MCU 的 DLM 运行副本中，掉电后恢复 `VISION_PARAMS_DEFAULT`。

## 运行

```powershell
cd work\camera_hdmi_720p\tools\param_tuner
pip install -r requirements.txt
python param_tuner.py
```

连接 USB-UART 后选择 COM 口，点击“连接”。连接成功会自动发送 `VER` 和 `GET`，把当前参数填入界面。

## 操作

- **读取参数**：发送 `GET`
- **应用**：对修改过的参数发送 `SET`，最后发送 `APPLY`。`APPLY` 会写入 FPGA 寄存器并清空轨迹
- **恢复默认**：发送 `DEFAULT`，恢复 `VISION_PARAMS_DEFAULT`
- **重新采样背景**：发送 `RECAPTURE`，约 0.5 秒，期间数码管显示 `--------`
- **保存预设 / 加载预设**：本机 JSON 文件，不写入板子

调参完成后，如果希望上电就是这组参数，需要把数值写回 `mcu_fw/main.c` 的 `VISION_PARAMS_DEFAULT`，重新编译 ELF 并烧录 bin。

## 协议

串口 115200 8N1，ASCII 行，`\n` 结尾。

```text
VER
GET
SET <name> <value>
APPLY
DEFAULT
RECAPTURE
```

响应：

```text
PVER 1
PARAM <name>=<value>
OK SET <name> <value>
OK APPLY
OK DEFAULT
OK RECAPTURE START
OK RECAPTURE
ERR unknown <name>
ERR range <name> <lo>..<hi>
ERR value <value>
```

## 参数说明

- `bg_capture_delay`、`bg_settle_frames` 只在启动阶段使用，运行时修改不会改变已完成的背景采集流程
- `APPLY` 会清空轨迹，避免旧轨迹对应已失效的分割结果
- `exposure` 或 `gain` 改变后建议再执行一次“重新采样背景”
- `MAX_RUNS`、`MAX_LABELS`、`MAX_DET`、`MAX_TRK` 是编译期容量，不能通过串口修改

## 打包

```powershell
pip install pyinstaller
pyinstaller --noconfirm --onefile --windowed --name camera_param_tuner param_tuner.py
```

生成的 `dist\camera_param_tuner.exe` 可以单独复制到没有 Python 的电脑上运行。
