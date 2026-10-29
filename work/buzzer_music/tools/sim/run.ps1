# buzzer_music simulation helper (iverilog)
$ErrorActionPreference = "Stop"

$proj = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$rtl  = Join-Path $proj "rtl\buzzer_music_top.v"
$tb   = Join-Path $PSScriptRoot "tb_buzzer_music.v"
$out  = Join-Path $PSScriptRoot "buzzer_music.vvp"

$env:PATH = "D:\iverilog\bin;D:\iverilog\lib;" + $env:PATH

# -I 指向 rtl 目录，让 \`include "song_data.vh" / "note_table.vh" 可被解析
$rtlDir = Join-Path $proj "rtl"

# -g2005：本地 iverilog 0.9.7 最高支持到 2005；**（幂）与实数函数、层次引用均可用
& "D:\iverilog\bin\iverilog.exe" -g2005 -I $rtlDir -o $out $rtl $tb
if ($LASTEXITCODE -ne 0) {
    throw "iverilog compile failed"
}

$sim = & "D:\iverilog\bin\vvp.exe" $out 2>&1
$sim | Write-Output
$passed = $false
foreach ($line in $sim) { if ("$line" -match "\[PASS\]") { $passed = $true; break } }
if (-not $passed) {
    throw "simulation failed"
}
