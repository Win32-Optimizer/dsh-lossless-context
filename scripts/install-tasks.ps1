#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
    注册两个「空闲感知」备份计划任务。
.DESCRIPTION
    任务本身只负责定期唤醒调度器；能不能真备份由 dsh-backup-idle.ps1 判断
    （键鼠空闲 + DSH 不忙 + 会话安静 + 间隔到期）。所以你在不在电脑前都安全。

    注册：
      - DSH-Daily-Backup ：每天 03:30 唤醒，间隔 24h
      - DSH-LCM-Snapshot ：每 30 分钟唤醒，间隔 6h

.PARAMETER Remove
    卸载这两个任务。
.EXAMPLE
    ./scripts/install-tasks.ps1
    ./scripts/install-tasks.ps1 -Remove
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [string]$DailyTime = '03:30'
)

$ErrorActionPreference = 'Stop'
$idle = Join-Path $PSScriptRoot 'dsh-backup-idle.ps1'

if (-not (Test-Path -LiteralPath $idle)) { Write-Host "找不到 $idle" -ForegroundColor Red; exit 1 }

function Invoke-SchTasks([string[]]$args) {
    & schtasks.exe @args 2>&1 | ForEach-Object { Write-Host "  $_" }
    return $LASTEXITCODE
}

if ($Remove) {
    Write-Host "卸载计划任务..." -ForegroundColor Cyan
    foreach ($n in 'DSH-Daily-Backup', 'DSH-LCM-Snapshot') {
        $code = Invoke-SchTasks @('/Delete', '/TN', $n, '/F')
        if ($code -eq 0) { Write-Host "  已删除 $n" -ForegroundColor Green }
        else { Write-Host "  $n 不存在或删除失败（可忽略）" -ForegroundColor Yellow }
    }
    exit 0
}

$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
Write-Host ""
Write-Host "注册空闲感知备份任务" -ForegroundColor Cyan
Write-Host "  调度器 : $idle"
Write-Host ""

# 每日：每天固定时刻唤醒一次，内部再判 24h 间隔
$tr1 = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$idle`" -Kind Daily -IntervalHours 24"
$c1 = Invoke-SchTasks @('/Create', '/TN', 'DSH-Daily-Backup', '/TR', $tr1,
                        '/SC', 'DAILY', '/ST', $DailyTime, '/F')
if ($c1 -eq 0) { Write-Host "  [ok] DSH-Daily-Backup（每天 $DailyTime 唤醒，间隔 24h）" -ForegroundColor Green }
else { Write-Host "  [fail] DSH-Daily-Backup 注册失败" -ForegroundColor Red }

# 快照：每 30 分钟唤醒一次，内部再判 6h 间隔
$tr2 = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$idle`" -Kind Snapshot -IntervalHours 6"
$c2 = Invoke-SchTasks @('/Create', '/TN', 'DSH-LCM-Snapshot', '/TR', $tr2,
                        '/SC', 'MINUTE', '/MO', '30', '/F')
if ($c2 -eq 0) { Write-Host "  [ok] DSH-LCM-Snapshot（每 30 分钟唤醒，间隔 6h）" -ForegroundColor Green }
else { Write-Host "  [fail] DSH-LCM-Snapshot 注册失败" -ForegroundColor Red }

Write-Host ""
Write-Host "提示：" -ForegroundColor Yellow
Write-Host "  · 任务只在你登录时运行（Interactive only），这是有意的。"
Write-Host "  · 想立刻试一次： schtasks /Run /TN `"DSH-LCM-Snapshot`""
Write-Host "  · 看调度日志  ： %USERPROFILE%\Documents\dsh-backup\idle-scheduler.log"
Write-Host "  · 卸载        ： ./scripts/install-tasks.ps1 -Remove"
Write-Host ""
