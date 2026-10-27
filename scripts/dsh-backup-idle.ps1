#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
    空闲感知的备份调度器：只在「你不在电脑前 + DSH 没在跑 AI 回合」时才备份。
.DESCRIPTION
    配合计划任务使用：任务只负责每 30 分钟唤醒本脚本一次，能不能动手由本脚本判断。

    四个条件全部满足才跑：
      1. 键鼠空闲 >= IdleMinutes（读 Windows 工作站空闲时钟）
      2. DSH 不在跑 AI 回合（备份目录里没有 ACTIVE.lock）
      3. 会话日志已安静 >= FreshMinutes
      4. 距上次成功 >= IntervalHours

.PARAMETER Kind
    Daily（默认）或 Snapshot。两者用不同的「上次成功」时间戳，互不干扰。
.PARAMETER IntervalHours
    同类任务两次备份之间的最小间隔（小时）。
.EXAMPLE
    # 每日全量
    ./scripts/dsh-backup-idle.ps1 -Kind Daily -IntervalHours 24
    # 每 6 小时的归档快照
    ./scripts/dsh-backup-idle.ps1 -Kind Snapshot -IntervalHours 6
#>
[CmdletBinding()]
param(
    [ValidateSet('Daily', 'Snapshot')]
    [string]$Kind = 'Daily',
    [double]$IntervalHours = 24,
    [int]$IdleMinutes = 10,
    [int]$FreshMinutes = 30,
    [string]$DshHome = $env:DSH_HOME,
    [string]$BackupRoot = (Join-Path (Join-Path $env:USERPROFILE 'Documents') 'dsh-backup')
)

$ErrorActionPreference = 'Continue'
if ([string]::IsNullOrWhiteSpace($DshHome)) { $DshHome = Join-Path $env:USERPROFILE '.dsh' }
New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null

$stateFile = Join-Path $BackupRoot ("last-{0}.timestamp" -f $Kind.ToLower())
$logFile   = Join-Path $BackupRoot 'idle-scheduler.log'

function Log([string]$msg) {
    $line = "{0}  [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Kind, $msg
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

# ── Windows 工作站空闲时钟 ──────────────────────────────────────────────────
if (-not ('Backup.IdleApi' -as [type])) {
    Add-Type -Name IdleApi -Namespace Backup -MemberDefinition @'
  [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
  public static uint IdleMilliseconds() {
    LASTINPUTINFO lii = new LASTINPUTINFO();
    lii.cbSize = (uint)Marshal.SizeOf(lii);
    if (!GetLastInputInfo(ref lii)) return 0;
    return (uint)(Environment.TickCount - lii.dwTime);
  }
'@
}
function Get-IdleMinutes { [Backup.IdleApi]::IdleMilliseconds() / 60000.0 }

$idle0 = Get-IdleMinutes
Log ("唤醒：键鼠空闲 {0:N1} 分钟" -f $idle0)

# ── 判定 1：DSH 是否在跑 AI 回合 ────────────────────────────────────────────
$lock = Join-Path $BackupRoot 'ACTIVE.lock'
if (Test-Path -LiteralPath $lock) {
    $age = ((Get-Date) - (Get-Item -LiteralPath $lock).LastWriteTime).TotalSeconds
    if ($age -lt 7200) { Log ("跳过：DSH 正在执行 AI 回合（锁 {0:N0}s 前更新）" -f $age); exit 0 }
    Log "清理过期的活动锁"
    Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
}

# ── 判定 2：键鼠空闲 ────────────────────────────────────────────────────────
if ($idle0 -lt $IdleMinutes) { Log ("跳过：你还在用电脑（空闲不足 {0} 分钟）" -f $IdleMinutes); exit 0 }

# ── 判定 3：会话安静 ────────────────────────────────────────────────────────
$sessions = Join-Path $DshHome 'sessions'
$lastActivity = [datetime]::MinValue
if (Test-Path -LiteralPath $sessions) {
    foreach ($d in Get-ChildItem -LiteralPath $sessions -Directory -Recurse) {
        if ($d.LastWriteTime -gt $lastActivity) { $lastActivity = $d.LastWriteTime }
    }
}
$sinceSession = ((Get-Date) - $lastActivity).TotalMinutes
if ($sinceSession -lt $FreshMinutes) { Log ("跳过：{0:N0} 分钟前还在聊天" -f $sinceSession); exit 0 }

# ── 判定 4：到期 ────────────────────────────────────────────────────────────
if (Test-Path -LiteralPath $stateFile) {
    $last  = [datetime]::Parse((Get-Content -LiteralPath $stateFile -Raw).Trim())
    $hours = ((Get-Date) - $last).TotalHours
    if ($hours -lt $IntervalHours) { Log ("跳过：距上次成功 {0:N1}h < {1}h" -f $hours, $IntervalHours); exit 0 }
}

# ── 执行 ────────────────────────────────────────────────────────────────────
Log "满足全部空闲条件，开始备份"

$idle1 = Get-IdleMinutes
if ($idle1 -lt $IdleMinutes) { Log "跳过：判定后你回来了"; exit 0 }

$backup = Join-Path $PSScriptRoot 'dsh-backup.ps1'
$invokeArgs = @{
    DshHome          = $DshHome
    BackupRoot       = $BackupRoot
    IgnoreLock       = $true
    WaitIdleMinutes  = $IdleMinutes
}
if ($Kind -eq 'Snapshot') { $invokeArgs.SkipArchive = $false }

& $backup @invokeArgs
$exit = $LASTEXITCODE
if ($null -eq $exit) { $exit = 0 }

if ((Get-IdleMinutes) -lt 2) {
    Log "提示：备份期间检测到用户操作；结果仍然完整（VACUUM INTO 是原子的）"
}

if ($exit -eq 0) {
    Set-Content -LiteralPath $stateFile -Value (Get-Date -Format 'o') -Encoding UTF8
    Log "结束：OK"
} else {
    Log ("结束：备份脚本返回 {0}" -f $exit)
}
