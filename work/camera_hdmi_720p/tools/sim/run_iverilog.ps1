# run_iverilog.ps1 - one-shot iverilog RTL sim runner
# Usage (from work/camera_hdmi_720p):
#   .\tools\sim\run_iverilog.ps1                              # default tb
#   .\tools\sim\run_iverilog.ps1 -Tb tb_apb_status_slave
# Requires iverilog at D:\iverilog\bin (auto-added to PATH if missing).
# Pure-ASCII on purpose: PS 5.1 mis-decodes UTF8-without-BOM Chinese comments.

param(
    [string]$Tb = "tb_apb_status_slave",
    [string]$IverilogBin = "D:\iverilog\bin"
)

$ErrorActionPreference = "Stop"
if (-not (Get-Command iverilog -ErrorAction SilentlyContinue)) {
    if (Test-Path $IverilogBin) { $env:Path = "$IverilogBin;$env:Path" }
    else { Write-Error "iverilog not on PATH and $IverilogBin missing"; exit 2 }
}

# Map testbench name to the RTL file(s) under test.
$rtlFiles = @()
switch ($Tb) {
    "tb_apb_status_slave" { $rtlFiles += "rtl\mcu\apb_status_slave.v" }
    default { Write-Error "Unknown testbench: $Tb (register its RTL in this script)"; exit 2 }
}

$out = "tools\sim\$Tb.vvp"
Write-Host "==> iverilog -g2005 $rtlFiles tools\sim\$Tb.v"
iverilog -g2005 -o $out -s $Tb @($rtlFiles + "tools\sim\$Tb.v")
if ($LASTEXITCODE -ne 0) { Write-Error "compile failed"; exit 1 }
Write-Host "==> vvp $out"
vvp $out
$rc = $LASTEXITCODE
Write-Host "==> sim exit $rc"
Remove-Item $out -ErrorAction SilentlyContinue
exit $rc
