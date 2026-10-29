# build_td.ps1 - buzzer_music TD command-line build (DefaultFlow.tcl direct, no launch_runs)
#
# The TD-auto-generated run.bat references a non-existent exe
# (td_commands_prompt_commands_prompt.exe), so launch_runs' worker never starts
# and wait_run polls forever. Workaround (proven in work/camera_hdmi_720p/tools/td_run):
#   create the run dirs + buzzer_music.prj + settings.cfg ourselves, then run
#   td_commands_prompt.exe DefaultFlow.tcl INSIDE each run dir (syn first, then phy).
# DefaultFlow.tcl only needs ./settings.cfg + ./<prj_name>.prj in the run dir.
# ASCII-only script to avoid CP936/UTF-8 parse issues in PowerShell.
param(
    [int]$SynTimeoutSec = 300,
    [int]$PhyTimeoutSec = 600
)
$ErrorActionPreference = "Stop"

$projRoot  = Split-Path -Parent $PSScriptRoot
$tdExe     = "D:\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin\td_commands_prompt.exe"
$flowTcl   = "D:/Anlogic/TD_6.2.1_Engineer_6.2.168.116/doc/scripts/DefaultFlow.tcl"
$buildRoot = Join-Path $env:TEMP "opencode\buzzer_music_build"

function Kill-TdProcs {
    foreach ($n in @("td", "td_commands_prompt", "alps", "bw", "run")) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---- 1) clean slate ----
Kill-TdProcs
Start-Sleep -Seconds 1
if (Test-Path $buildRoot) { Remove-Item $buildRoot -Recurse -Force }
New-Item -ItemType Directory -Path $buildRoot | Out-Null
foreach ($sub in @("rtl", "constraints", "td_project", "tools")) {
    Copy-Item -Path (Join-Path $projRoot $sub) -Destination $buildRoot -Recurse
}

$runsDir  = Join-Path $buildRoot "td_project\buzzer_music_Runs"
$synDir   = Join-Path $runsDir "syn_1"
$phyDir   = Join-Path $runsDir "phy_1"
$tdRunTpl = Join-Path $projRoot "tools\td_run"

# ---- 2) create run dirs + .prj + settings.cfg ourselves (no launch_runs) ----
New-Item -ItemType Directory -Path $synDir -Force | Out-Null
New-Item -ItemType Directory -Path $phyDir -Force | Out-Null
foreach ($d in @($synDir, $phyDir)) {
    Copy-Item -Path (Join-Path $tdRunTpl "buzzer_music.prj") -Destination (Join-Path $d "buzzer_music.prj") -Force
}
Copy-Item -Path (Join-Path $tdRunTpl "syn_1.settings.cfg") -Destination (Join-Path $synDir "settings.cfg") -Force
Copy-Item -Path (Join-Path $tdRunTpl "phy_1.settings.cfg") -Destination (Join-Path $phyDir "settings.cfg") -Force
Write-Host "==== run dirs prepared (settings.cfg + buzzer_music.prj) ===="

# ---- helper: run DefaultFlow.tcl in a run dir, capture stdout, with timeout ----
function Run-Flow($dir, $tag, $timeoutSec) {
    $stdoutLog = Join-Path $dir "$tag.stdout.log"
    Write-Host "==== $tag : DefaultFlow.tcl (cwd=$dir) ===="
    $start = Get-Date
    $p = Start-Process -FilePath $tdExe -ArgumentList $flowTcl `
          -WorkingDirectory $dir `
          -RedirectStandardOutput $stdoutLog -RedirectStandardError (Join-Path $dir "$tag.stderr.log") `
          -PassThru -NoNewWindow
    $ok = $p.WaitForExit($timeoutSec * 1000)
    if (-not $ok) {
        Write-Host "$tag TIMEOUT (${timeoutSec}s), killing" -ForegroundColor Yellow
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        Kill-TdProcs
    }
    $elapsed = ((Get-Date) - $start).TotalSeconds
    Write-Host "$tag elapsed: $([math]::Round($elapsed,1)) s"
    return $stdoutLog
}

# ---- 3) syn ----
$synLog = Run-Flow $synDir "syn_1" $SynTimeoutSec
$synText = if (Test-Path $synLog) { Get-Content $synLog -Raw } else { "" }
$synOk = ($synText -match "Run success") -or (Test-Path (Join-Path $synDir "buzzer_music_gate.db"))
Write-Host "syn_1 : $(if ($synOk) {'OK'} else {'FAIL'})"
if (-not $synOk) {
    Write-Host "---- syn_1 stdout tail ----"
    $synText -split "`n" | Select-Object -Last 40 | Write-Output
    exit 1
}
$fs = Join-Path $synDir "flow.status"
if (Test-Path $fs) {
    Write-Host "---- syn flow.status ----"
    Get-Content $fs | Select-String -Pattern "WNS|TNS|Setup|Hold|LUT|DFF|Slice|ERAM|DSP|IO" |
        ForEach-Object { $_.Line } | Select-Object -First 20
}

# ---- 4) phy ----
$phyLog = Run-Flow $phyDir "phy_1" $PhyTimeoutSec
$phyText = if (Test-Path $phyLog) { Get-Content $phyLog -Raw } else { "" }
$phyOk = ($phyText -match "Run success") -or (Get-ChildItem -Path $phyDir -Filter "*.bit" -ErrorAction SilentlyContinue)
Write-Host "phy_1 : $(if ($phyOk) {'OK'} else {'FAIL'})"
if (-not $phyOk) {
    Write-Host "---- phy_1 stdout tail ----"
    $phyText -split "`n" | Select-Object -Last 40 | Write-Output
    exit 1
}
$rf = Join-Path $phyDir "route_flow.status"
if (Test-Path $rf) {
    Write-Host "---- phy route_flow.status ----"
    Get-Content $rf | Select-String -Pattern "SWNS|HWNS|TNS|HTNS|Setup|Hold|Slice|LUT|DFF|ERAM|DSP|IO" |
        ForEach-Object { $_.Line } | Select-Object -First 25
}
$bit = Get-ChildItem -Path $phyDir -Filter "*.bit" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($bit) {
    $artDir = Join-Path $projRoot "artifacts"
    New-Item -ItemType Directory -Path $artDir -Force | Out-Null
    Copy-Item -Path $bit.FullName -Destination (Join-Path $artDir "buzzer_music.bit") -Force
    $md5 = (Get-FileHash (Join-Path $artDir "buzzer_music.bit") -Algorithm MD5).Hash
    Write-Host "BIT: $($bit.FullName) ($([math]::Round($bit.Length/1KB,2)) KB)" -ForegroundColor Green
    Write-Host "copied to artifacts/buzzer_music.bit  MD5 $md5" -ForegroundColor Green
    Write-Host "BUILD OK" -ForegroundColor Green
    exit 0
}
Write-Host "BUILD OK but no .bit found" -ForegroundColor Yellow
exit 0
