#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
    注册两个「空闲感知 + 完全静默」的备份计划任务。
.DESCRIPTION
    任务本身只负责定期唤醒调度器；能不能真备份由 dsh-backup-idle.ps1 判断
    （键鼠空闲 + DSH 不忙 + 会话安静 + 间隔到期）。所以你在不在电脑前都安全。

    静默做法：任务调用 wscript.exe 跑一个自动生成的 .vbs 包装层，
    VBS 用 WScript.Shell.Run(cmd, 0, False) 启动 PowerShell —— 窗口样式 0，
    所以不会闪控制台。

    注册：
      - DSH-Daily-Backup ：每天 03:30 唤醒，间隔 24h
      - DSH-LCM-Snapshot ：每 30 分钟唤醒，间隔 6h

.PARAMETER Remove
    卸载这两个任务及其 .vbs 包装层。
.PARAMETER DailyTime
    每日任务的唤醒时刻。默认 03:30。
.EXAMPLE
    ./scripts/install-tasks.ps1
    ./scripts/install-tasks.ps1 -Remove
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [string]$DailyTime = '00:00',
    [string]$DshHome = $env:DSH_HOME
)

$ErrorActionPreference = 'Stop'
$idle = Join-Path $PSScriptRoot 'dsh-backup-idle.ps1'

if (-not (Test-Path -LiteralPath $idle)) { Write-Host "找不到 $idle" -ForegroundColor Red; exit 1 }

$ps      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
$vbsDir  = Join-Path $env:LOCALAPPDATA 'dsh-lossless-context'

function Invoke-SchTasks([string[]]$arguments) {
    & schtasks.exe @arguments 2>&1 | ForEach-Object { Write-Host "  $_" }
    return $LASTEXITCODE
}

# 生成静默启动的 VBS 包装层
function New-SilentWrapper {
    param([string]$Name, [string]$IdleArgs)

    New-Item -ItemType Directory -Force -Path $vbsDir | Out-Null
    $vbs = Join-Path $vbsDir "$Name.vbs"

    # 用 Chr(34) 拼引号，避免 VBS 转义地狱；Run 的第二个参数 0 = 隐藏窗口
    $lines = @(
        "' dsh-lossless-context — 静默启动包装层（由 install-tasks.ps1 自动生成，勿手改）",
        "' 删除对应计划任务后，本文件也可以删。",
        'Dim q, cmd',
        'q = Chr(34)',
        ('cmd = q & "' + $ps + '" & q & " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & q & "' + $idle + '" & q & " ' + $IdleArgs + '"'),
        'CreateObject("WScript.Shell").Run cmd, 0, False'
    )

    # wscript 读 UTF-16 LE + BOM 最稳（路径里可能有中文）
    [System.IO.File]::WriteAllLines($vbs, $lines, (New-Object System.Text.UnicodeEncoding($false, $true)))
    return $vbs
}

if ($Remove) {
    Write-Host "卸载计划任务与静默包装层..." -ForegroundColor Cyan
    foreach ($n in 'DSH-Daily-Backup', 'DSH-LCM-Snapshot') {
        $code = Invoke-SchTasks @('/Delete', '/TN', $n, '/F')
        if ($code -eq 0) { Write-Host "  已删除任务 $n" -ForegroundColor Green }
        else { Write-Host "  任务 $n 不存在或删除失败（可忽略）" -ForegroundColor Yellow }
    }
    foreach ($n in 'DSH-Daily-Backup', 'DSH-LCM-Snapshot') {
        $v = Join-Path $vbsDir "$n.vbs"
        if (Test-Path -LiteralPath $v) { Remove-Item -LiteralPath $v -Force; Write-Host "  已删除包装层 $n.vbs" }
    }
    exit 0
}

Write-Host ""
Write-Host "注册「空闲感知 + 静默」备份任务" -ForegroundColor Cyan
Write-Host "  调度器 : $idle"
Write-Host "  包装层 : $vbsDir\*.vbs"
Write-Host ""

$vbs1 = New-SilentWrapper -Name 'DSH-Daily-Backup' -IdleArgs '-Kind Daily -IntervalHours 24'
$tr1  = "`"$wscript`" //B //Nologo `"$vbs1`""
$c1 = Invoke-SchTasks @('/Create', '/TN', 'DSH-Daily-Backup', '/TR', $tr1,
                        '/SC', 'DAILY', '/ST', $DailyTime, '/RI', '120', '/DU', '24:00', '/F')
if ($c1 -eq 0) { Write-Host "  [ok] DSH-Daily-Backup（每天 $DailyTime 起每 2 小时重试，间隔 24h，静默）" -ForegroundColor Green }
else { Write-Host "  [fail] DSH-Daily-Backup 注册失败" -ForegroundColor Red }

$vbs2 = New-SilentWrapper -Name 'DSH-LCM-Snapshot' -IdleArgs '-Kind Snapshot -IntervalHours 6'
$tr2  = "`"$wscript`" //B //Nologo `"$vbs2`""
$c2 = Invoke-SchTasks @('/Create', '/TN', 'DSH-LCM-Snapshot', '/TR', $tr2,
                        '/SC', 'MINUTE', '/MO', '30', '/F')
if ($c2 -eq 0) { Write-Host "  [ok] DSH-LCM-Snapshot（每 30 分钟，间隔 6h，静默）" -ForegroundColor Green }
else { Write-Host "  [fail] DSH-LCM-Snapshot 注册失败" -ForegroundColor Red }

Write-Host ""
Write-Host "提示：" -ForegroundColor Yellow
Write-Host "  · 静默 = 任务调 wscript 跑 VBS，VBS 以窗口样式 0 启动 PowerShell，不闪控制台。"
Write-Host "  · 立刻试一次： schtasks /Run /TN `"DSH-LCM-Snapshot`""
Write-Host "  · 调度日志  ： %USERPROFILE%\Documents\dsh-backup\idle-scheduler.log"
Write-Host "  · 卸载      ： ./scripts/install-tasks.ps1 -Remove"
Write-Host ""
