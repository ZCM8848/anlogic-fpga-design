@echo off
rem ============================================================
rem buzzer_music / phy_1 - self-healing command-line build
rem Run inside: td_project/buzzer_music_Runs/phy_1/
rem Restores settings.cfg from tools/td_run, then runs the TD flow.
rem phy depends on syn_1 *_gate.db: run syn_1 FIRST, then phy_1.
rem ASCII-only to avoid CP936/UTF-8 cmd issues.
rem Forward-slash TCL path: Tcl eats backslash escapes (e.g. \a = bell).
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
echo [run.bat] settings.cfg restored from tools/td_run.
D:/Anlogic/TD_6.2.1_Engineer_6.2.168.116/bin/td_commands_prompt.exe D:/Anlogic/TD_6.2.1_Engineer_6.2.168.116/doc/scripts/DefaultFlow.tcl
pause
