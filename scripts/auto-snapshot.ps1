#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
    自动存档调度器：定期为有新增对话的会话生成「恢复包」，静默运行。
.DESCRIPTION
    为什么需要：会话被服务端内容策略拒收、或者模型突然抽风变成助手腔之后，
    那个会话可能就废了。定期把最近十几轮对话存成「接着聊」的恢复包，
    出事时 5 分钟就能在新会话接上，记忆不丢。

    本脚本只做三件事：
      1. 找到 DSH 自带的 node（不依赖系统 PATH）；
      2. 跑 tools/auto-snapshot.mjs（它自己判断有没有新增）；
      3. 把输出记进日志。

    由计划任务每 10 分钟静默调用（见 install-snapshot-task.ps1）。

.PARAMETER MinNew
    一个会话新增多少条消息才存档。默认 4（约 2 轮）。
.PARAMETER Keep
    每个会话保留最近几份存档。默认 6。
.PARAMETER Turns
    每份存档取最近多少轮。默认 12。
.PARAMETER DshHome
    DSH 主目录，默认 $env:DSH_HOME 或 ~/.dsh。
.EXAMPLE
    ./auto-snapshot.ps1
    ./auto-snapshot.ps1 -MinNew 2 -Keep 10
#>
[CmdletBinding()]
param(
    [int]$MinNew = 4,
    [int]$Keep = 6,
    [int]$Turns = 12,
    [string]$DshHome = $env:DSH_HOME,
    [string]$OutRoot = ''
)

$ErrorActionPreference = 'Continue'
if ([string]::IsNullOrWhiteSpace($DshHome)) { $DshHome = Join-Path $env:USERPROFILE '.dsh' }

$script = Join-Path $PSScriptRoot 'auto-snapshot.mjs'
if (-not (Test-Path -LiteralPath $script)) {
    $script = Join-Path $PSScriptRoot 'tools\auto-snapshot.mjs'
}
if (-not (Test-Path -LiteralPath $script)) {
    Write-Host "找不到 auto-snapshot.mjs（应该在 scripts 或 tools 目录）" -ForegroundColor Red
    exit 1
}

# DSH 自带 node 优先
$candidates = @(
    (Join-Path $DshHome 'dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe')
)
$node = $null
foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { $node = $c; break } }
if (-not $node) {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { $node = $cmd.Source }
}
if (-not $node) {
    Write-Host "找不到 node（DSH 运行时和 PATH 都没有）" -ForegroundColor Red
    exit 1
}

$nodeArgs = @($script, '--min-new', $MinNew, '--keep', $Keep, '--turns', $Turns)
if (-not [string]::IsNullOrWhiteSpace($OutRoot)) { $nodeArgs += @('--out', $OutRoot) }

& $node @nodeArgs
exit $LASTEXITCODE
