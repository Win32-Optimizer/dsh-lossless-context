#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
    注册 / 卸载「自动存档」计划任务（每 10 分钟静默运行一次）。
.DESCRIPTION
    任务本身只负责唤醒；要不要真的存档由 auto-snapshot.mjs 判断
    （用状态文件比对每个会话的消息数，没有新增就直接退出，不写任何东西）。

    静默做法和备份任务一致：任务调 wscript.exe 跑自动生成的 .vbs，
    VBS 用 Run(cmd, 0, False) 以窗口样式 0 启动 PowerShell。

    产出目录：%USERPROFILE%\Documents\dsh-backup\snapshots\<工作目录简写>\
    每个会话只保留最近 N 份（默认 6），滚动清理。

.PARAMETER IntervalMinutes
    唤醒间隔，默认 10 分钟。
.PARAMETER Remove
    卸载任务和包装层。
.EXAMPLE
    ./install-snapshot-task.ps1
    ./install-snapshot-task.ps1 -IntervalMinutes 5
    ./install-snapshot-task.ps1 -Remove
#>
[CmdletBinding()]
param(
    [int]$IntervalMinutes = 10,
    [string]$DshHome = $env:DSH_HOME,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$snapshotPs = Join-Path $PSScriptRoot 'auto-snapshot.ps1'
$ps         = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$wscript    = Join-Path $env:SystemRoot 'System32\wscript.exe'
$vbsDir     = Join-Path $env:LOCALAPPDATA 'dsh-lossless-context'
$taskName   = 'DSH-Auto-Snapshot'
$vbs        = Join-Path $vbsDir "$taskName.vbs"

function Invoke-SchTasks([string[]]$arguments) {
    & schtasks.exe @arguments 2>&1 | ForEach-Object { Write-Host "  $_" }
    return $LASTEXITCODE
}

if ($Remove) {
    Write-Host "卸载自动存档任务..." -ForegroundColor Cyan
    $code = Invoke-SchTasks @('/Delete', '/TN', $taskName, '/F')
    if ($code -eq 0) { Write-Host "  已删除任务 $taskName" -ForegroundColor Green }
    else { Write-Host "  任务不存在（可忽略）" -ForegroundColor Yellow }
    if (Test-Path -LiteralPath $vbs) { Remove-Item -LiteralPath $vbs -Force; Write-Host "  已删除包装层" }
    exit 0
}

if (-not (Test-Path -LiteralPath $snapshotPs)) {
    Write-Host "找不到 $snapshotPs" -ForegroundColor Red
    exit 1
}

# ── 生成静默包装层 ─────────────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $vbsDir | Out-Null
$vbsLines = @(
    "' dsh-lossless-context — 自动存档静默包装层（由 install-snapshot-task.ps1 生成）",
    'Dim q, cmd',
    'q = Chr(34)',
    ('cmd = q & "' + $ps + '" & q & " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & q & "' + $snapshotPs + '" & q'),
    'CreateObject("WScript.Shell").Run cmd, 0, False'
)
[System.IO.File]::WriteAllLines($vbs, $vbsLines, (New-Object System.Text.UnicodeEncoding($false, $true)))

$tr = "`"$wscript`" //B //Nologo `"$vbs`""
$c = Invoke-SchTasks @('/Create', '/TN', $taskName, '/TR', $tr, '/SC', 'MINUTE', '/MO', "$IntervalMinutes", '/F')

Write-Host ""
if ($c -eq 0) {
    Write-Host "  [ok] $taskName 已注册（每 $IntervalMinutes 分钟，静默）" -ForegroundColor Green
    Write-Host ""
    Write-Host "产出目录：$env:USERPROFILE\Documents\dsh-backup\snapshots\" -ForegroundColor Cyan
    Write-Host "运行日志：...\snapshots\auto-snapshot.log"
    Write-Host ""
    Write-Host "立刻试一次： schtasks /Run /TN `"$taskName`"" -ForegroundColor Yellow
    Write-Host "卸载      ： ./install-snapshot-task.ps1 -Remove" -ForegroundColor Yellow
} else {
    Write-Host "  [fail] 注册失败" -ForegroundColor Red
}
Write-Host ""
