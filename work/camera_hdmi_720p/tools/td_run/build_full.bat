@echo off
rem ============================================================
rem Full compile (syn -> place -> route -> bitgen) directly on the .al.
rem No _Runs/ and no .prj required. Writes camera_hdmi_720p.bit into td_project/.
rem ASCII-only on purpose (CP936/UTF-8 cmd issues).
rem ============================================================
set TDBIN=D:\Tangdynasty\bin\td_commands_prompt.exe
if not exist "%TDBIN%" (
    echo [build_full] TD not found: %TDBIN%
    echo Edit TDBIN in this file to your Tang Dynasty install.
    pause
    exit /b 1
)
rem CWD must be td_project/ (relative paths inside the .al resolve from here)
cd /d "%~dp0..\..\td_project"
echo [build_full] CWD = %CD%
echo [build_full] running: %TDBIN% ../tools/td_run/build_full.tcl
rem Forward slashes: Tcl eats backslash escapes (\t -> tab, \b -> backspace).
"%TDBIN%" "../tools/td_run/build_full.tcl"
echo [build_full] done. bit -> %CD%\camera_hdmi_720p.bit
pause
