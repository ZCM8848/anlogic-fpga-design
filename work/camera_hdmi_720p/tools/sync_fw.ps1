<#
sync_fw.ps1 — 把仓库里的 MCU 固件源码同步进 FD 工程，并强制重编 main.c

背景：mcu_fw/main.c 与 FD 工程里的 main.c 原为"硬链同一份"，但编辑工具以
      "新建文件 + 改名"写盘，会打断硬链，导致 FD 一直编译旧内容
      （曾因此丢掉调试流：串口只有 CAM 行、没有 D 行）。
      故改为"每次改完 main.c 跑一次本脚本"。

做什么：
  1. 复制 mcu_fw/main.c → <FD 工程>/main.c
  2. 删除 <FD 工程>/build/obj/main.c.o(+.d)，强制 FD 重编该文件
  3. 校验两边 sha256 一致

用法：
  powershell -ExecutionPolicy Bypass -File tools/sync_fw.ps1
  powershell -ExecutionPolicy Bypass -File tools/sync_fw.ps1 -FdProject "D:\...\ph1p35_status"

之后：在 FD 里 Clean/Build → Debug 重新 load ELF → Resume。
#>
param(
    [string]$FdProject = "C:\Users\Z___C\FDWork\ph1p35_status"
)

$ErrorActionPreference = "Stop"

$src = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\mcu_fw\main.c"))
$dst = Join-Path $FdProject "main.c"

if (-not (Test-Path -LiteralPath $src)) { throw "源文件不存在: $src" }
if (-not (Test-Path -LiteralPath $FdProject)) {
    throw "FD 工程目录不存在: $FdProject  (用 -FdProject 指定)"
}

Write-Host "源  : $src"
Write-Host "目标: $dst"

# 1) 复制
Copy-Item -LiteralPath $src -Destination $dst -Force

# 2) 删除旧目标文件，逼 FD 重编
$removed = 0
foreach ($rel in @("build\obj\main.c.o", "build\obj\main.c.o.d")) {
    $p = Join-Path $FdProject $rel
    if (Test-Path -LiteralPath $p) {
        Remove-Item -LiteralPath $p -Force
        Write-Host "  已删 $p"
        $removed++
    }
}
if ($removed -eq 0) { Write-Host "  (未发现 main.c.o，或已被删)" }

# 3) 校验
$h1 = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
$h2 = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash
if ($h1 -ne $h2) { throw "同步后哈希不一致: $h1 vs $h2" }

Write-Host ("同步完成  sha256=" + $h1.Substring(0, 16) + "  size=" + (Get-Item -LiteralPath $dst).Length)
Write-Host "下一步：FD 里 Clean/Build → Debug load ELF → Resume"
