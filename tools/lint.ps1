# Verilog 语法检查脚本（本地）
# 用法:
#   powershell -ExecutionPolicy Bypass -File tools/lint.ps1 -Paths work
#   powershell -ExecutionPolicy Bypass -File tools/lint.ps1 -Paths ref,work
# 依赖: iverilog (Icarus Verilog)。未安装时仅列出待检查文件并跳过。
param(
    [string[]]$Paths = @("work")
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$iverilog = Get-Command iverilog -ErrorAction SilentlyContinue

if (-not $iverilog) {
    Write-Warning "未找到 iverilog，跳过语法检查。安装: https://bleyer.org/icarus/ 或 choco install iverilog"
    exit 0
}

$patterns = @("*.v", "*.sv", "*.vh")
$files = foreach ($p in $Paths) {
    $full = Join-Path $repoRoot $p
    if (Test-Path -LiteralPath $full) {
        Get-ChildItem -LiteralPath $full -Recurse -File -Include $patterns |
            Where-Object { $_.Name -notlike "*.enc.v" }
    }
}

if (-not $files) {
    Write-Host "没有需要检查的源文件。"
    exit 0
}

$tmpOut = Join-Path $env:TEMP "lint_null.out"
$failed = 0
foreach ($f in $files) {
    $out = & iverilog -g2012 -tnull -o $tmpOut $f.FullName 2>&1
    if ($LASTEXITCODE -ne 0) {
        $failed++
        Write-Host "[FAIL] $($f.FullName.Replace($repoRoot + '\', ''))" -ForegroundColor Red
        $out | ForEach-Object { Write-Host "       $_" }
    }
}

Write-Host ""
Write-Host "共检查 $($files.Count) 个文件，失败 $failed 个。" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
exit $(if ($failed -gt 0) { 1 } else { 0 })
