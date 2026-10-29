# Verilog 语法检查脚本（本地）
# 用法:
#   powershell -ExecutionPolicy Bypass -File tools/lint.ps1
#   powershell -ExecutionPolicy Bypass -File tools/lint.ps1 -Paths work
#   powershell -ExecutionPolicy Bypass -File tools/lint.ps1 -Paths work\camera_hdmi_720p
# 依赖: iverilog (Icarus Verilog)。未安装时仅列出待检查文件并跳过。
# 策略: 跳过 ip/ 与 *.enc.* 文件；按顶层目录分组编译；过滤 "Unknown module type"
#       （厂商 IP/原语引用，iverilog 无 Anlogic 原语库，非语法错误）
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

# 选择语法标准：优先 -g2012，本地 0.9.7 不支持时回退 -g2005
$genFlag = "-g2012"
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$probe = & iverilog -g2012 -tnull -o NUL 2>&1
$ErrorActionPreference = $prevEAP
if ($LASTEXITCODE -ne 0 -and ("$probe" -match "Unsupported Language generation")) {
    $genFlag = "-g2005"
}

$patterns = @("*.v", "*.sv", "*.vh")

function Lint-Group {
    param([string]$Label, [string[]]$Files)
    if ($Files.Count -eq 0) {
        Write-Host "[$Label] 无源文件，跳过"
        return $true
    }
    Write-Host "[$Label] 检查 $($Files.Count) 个文件"
    $tmpOut = Join-Path $env:TEMP "lint_${Label}.out"
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $raw = & iverilog $genFlag -tnull -o $tmpOut $Files 2>&1
    $ErrorActionPreference = $prevEAP
    $allErrors = @($raw | Where-Object { $_ -match "error:" })
    $realErrors = @($allErrors | Where-Object { $_ -notmatch "Unknown module type" })
    if ($realErrors.Count -gt 0) {
        Write-Host "[$Label] FAIL" -ForegroundColor Red
        foreach ($line in $realErrors) {
            Write-Host "  $line" -ForegroundColor Red
        }
        return $false
    }
    Write-Host "[$Label] OK" -ForegroundColor Green
    $skipped = @($allErrors | Where-Object { $_ -match "Unknown module type" })
    if ($skipped.Count -gt 0) {
        Write-Host "  已忽略 $($skipped.Count) 条厂商 IP/原语引用" -ForegroundColor DarkGray
    }
    return $true
}

# 把传入的路径展开成顶层分组目录
$groups = [System.Collections.Generic.SortedSet[string]]::new()
foreach ($p in $Paths) {
    $full = Join-Path $repoRoot $p
    if (-not (Test-Path -LiteralPath $full)) { continue }
    if ((Get-Item -LiteralPath $full).PSIsContainer) {
        # 若是 work/，按其一级子目录分组；否则把该目录本身作为一组
        $name = $p.TrimEnd('/\')
        if ($name -eq "work") {
            Get-ChildItem -LiteralPath $full -Directory | ForEach-Object {
                $rel = $_.FullName.Substring($repoRoot.Length + 1)
                [void]$groups.Add($rel)
            }
        } else {
            [void]$groups.Add($name)
        }
    }
}

$anyFail = $false
foreach ($group in $groups) {
    $groupRoot = Join-Path $repoRoot $group
    $files = Get-ChildItem -Path $groupRoot -Recurse -File -Include $patterns |
        Where-Object {
            $_.Name -notlike "*.enc.v" -and
            $_.Name -notlike "*.enc.sv" -and
            $_.FullName -notmatch "[\\/]ip[\\/]" -and
            $_.FullName -notmatch "[\\/]retired[\\/]"
        } |
        ForEach-Object { $_.FullName }
    $ok = Lint-Group -Label $group -Files $files
    if (-not $ok) { $anyFail = $true }
}

if ($anyFail) { exit 1 }
exit 0
