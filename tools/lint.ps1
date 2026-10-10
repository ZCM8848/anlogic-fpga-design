# Verilog 语法检查脚本（本地）
# 用法:
#   powershell -ExecutionPolicy Bypass -File tools/lint.ps1
#   powershell -ExecutionPolicy Bypass -File tools/lint.ps1 -Paths work
#   powershell -ExecutionPolicy Bypass -File tools/lint.ps1 -Paths ref,work
# 依赖: iverilog (Icarus Verilog)。未安装时仅列出待检查文件并跳过。
# 策略: 跳过 ip/ 和 .enc.* 文件；全量编译 rtl/ 文件；过滤 "Unknown module type"
#       （厂商 IP/原语引用，iverilog 无 Anlogic 原语库，非语法错误）。
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
            Where-Object {
                $_.Name -notlike "*.enc.v" -and
                $_.Name -notlike "*.enc.sv" -and
                $_.FullName -notmatch "[\\/]ip[\\/]" -and
                $_.FullName -notmatch "[\\/]retired[\\/]"
            }
    }
}

if (-not $files) {
    Write-Host "没有需要检查的源文件。"
    exit 0
}

$fileList = @($files) | ForEach-Object { $_.FullName }
Write-Host "待检查文件 ($($fileList.Count) 个)："
foreach ($f in $fileList) {
    Write-Host "  $($f.Replace($repoRoot + '\', ''))"
}

# 一次性编译所有 RTL 文件，跨文件模块引用自然解析
$tmpOut = Join-Path $env:TEMP "lint_null.out"
$raw = & iverilog -g2012 -tnull -o $tmpOut $fileList 2>&1
$exitCode = $LASTEXITCODE

# 过滤 "Unknown module type"（厂商 IP/原语引用，非语法错误）
$allErrors = @($raw | Where-Object { $_ -match "error:" })
$realErrors = @($allErrors | Where-Object { $_ -notmatch "Unknown module type" })
$skipped = @($allErrors | Where-Object { $_ -match "Unknown module type" })

if ($realErrors.Count -gt 0) {
    Write-Host ""
    Write-Host "[FAIL] 语法检查未通过，发现 $($realErrors.Count) 个真实错误：" -ForegroundColor Red
    foreach ($line in $realErrors) {
        Write-Host "  $line" -ForegroundColor Red
    }
    exit 1
}

Write-Host ""
Write-Host "OK: 语法检查通过" -ForegroundColor Green

if ($skipped.Count -gt 0) {
    Write-Host ""
    Write-Host "已忽略 $($skipped.Count) 条厂商 IP/原语引用（非语法错误）：" -ForegroundColor DarkGray
    foreach ($line in $skipped) {
        Write-Host "  $line" -ForegroundColor DarkGray
    }
}
exit 0
