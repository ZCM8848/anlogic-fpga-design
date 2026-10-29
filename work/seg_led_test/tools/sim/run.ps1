# seg_led_test simulation helper (iverilog 0.9.7)
$ErrorActionPreference = "Stop"

$proj = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$rtl  = Join-Path $proj "rtl\seg_led_test_top.v"
$tb   = Join-Path $PSScriptRoot "tb_seg_led_test.v"
$out  = Join-Path $PSScriptRoot "seg_led_test.vvp"

$env:PATH = "D:\iverilog\bin;D:\iverilog\lib;" + $env:PATH

& "D:\iverilog\bin\iverilog.exe" -g2005 -o $out $rtl $tb
if ($LASTEXITCODE -ne 0) {
    throw "iverilog compile failed"
}

$sim = & "D:\iverilog\bin\vvp.exe" $out 2>&1
$sim | Write-Output
if ($sim -notmatch "\[PASS\]") {
    throw "simulation failed"
}
