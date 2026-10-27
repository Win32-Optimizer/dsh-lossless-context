#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
    给 DSH 的 pwsh 工具当外层包装：命令执行期间对外表示「DSH 正在忙」，备份调度器据此避让。
.DESCRIPTION
    装成 DSH 的 shell 包装层后，每跑一条 shell 命令都会：
      1. 写 <备份目录>/ACTIVE.lock
      2. 原样转发参数去执行（通常是 -Command "<真实命令>"）
      3. 若 HoldSeconds 内没有新命令接手这把锁，就删掉它
         —— 即「一个 AI 回合里最后一条命令结束后，再等 HoldSeconds 才算空闲」

    安装（在 DSH 里执行一次）：
        http hook install file --id pwsh-guard "<本文件绝对路径>"
    卸载：
        http hook remove pwsh-guard

    注意：hook 的具体安装语法随 DSH 版本可能不同。装完先跑一条
    `Write-Output hook-test`，确认命令正常、且 ACTIVE.lock 出现过。
.PARAMETER HoldSeconds
    最后一条命令结束后，锁再保留多少秒。默认 30。
#>
[CmdletBinding(PositionalBinding = $true)]
param(
    [string]$HoldSeconds = 30,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Continue'

$lockDir = $env:LCM_BACKUP_ROOT
if ([string]::IsNullOrWhiteSpace($lockDir)) {
    $lockDir = Join-Path (Join-Path $env:USERPROFILE 'Documents') 'dsh-backup'
}
$lockFile  = Join-Path $lockDir 'ACTIVE.lock'
$stateFile = Join-Path $lockDir 'pwsh-hook.state'

try {
    New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
    $stamp = [DateTime]::UtcNow.ToString('o')
    Set-Content -LiteralPath $lockFile  -Value $stamp -Encoding UTF8
    Set-Content -LiteralPath $stateFile -Value $stamp -Encoding UTF8
} catch {
    # 锁写不进去也绝不能挡住用户的命令
    $stamp = $null
}

# 原样转发参数（http hook 会把原始参数追加在命令后面）
$shell = Get-Command pwsh -ErrorAction SilentlyContinue
try {
    if ($shell) { & $shell.Source @Rest } else { & powershell.exe @Rest }
} catch {
    Write-Error $_
}

# 没有新命令接手这把锁 → 这个 AI 回合已经结束，释放
if ($stamp) {
    Start-Sleep -Milliseconds 300
    $current = $null
    try { $current = (Get-Content -LiteralPath $stateFile -Raw -ErrorAction Stop).Trim() } catch { }
    if ($current -eq $stamp) {
        Start-Sleep -Seconds ([Math]::Max(1, [int]$HoldSeconds))
        $current = $null
        try { $current = (Get-Content -LiteralPath $stateFile -Raw -ErrorAction Stop).Trim() } catch { }
        if ($current -eq $stamp) { Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue }
    }
}
