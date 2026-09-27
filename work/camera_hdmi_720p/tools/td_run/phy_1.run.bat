@echo off
rem ============================================================
rem camera_hdmi_720p / phy_1 —— 自愈版命令行构建脚本（模板）
rem 用法：复制到 td_project/camera_hdmi_720p_Runs/phy_1/run.bat
rem 先恢复含 IP 约束(IpADCList/IpSDCList)的 settings.cfg，再跑 TD 命令行流程。
rem 注意：phy 依赖 syn 的 *_gate.db，顺序必须 syn_1 → phy_1。
rem ============================================================
set HD_SDIR=%~dp0
cd /d "%HD_SDIR%"
set TPL=%~dp0..\..\..\tools\td_run\phy_1.settings.cfg
if not exist "%TPL%" (
    echo [run.bat] template missing: %TPL%
    pause
    exit /b 1
)
copy /Y "%TPL%" "settings.cfg" >nul
echo [run.bat] settings.cfg restored from tools/td_run (IpADCList/IpSDCList included).
D:/Anlogic/TD_6.2.1_Engineer_6.2.168.116/bin/td_commands_prompt.exe D:\Anlogic\TD_6.2.1_Engineer_6.2.168.116\arch/../doc/scripts/DefaultFlow.tcl
pause
