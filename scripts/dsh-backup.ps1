#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
    备份 DeepSeek Harness 的会话原文、召回归档与配置覆盖层（不含凭据）。
.DESCRIPTION
    三层都备份：
      1. <DSH_HOME>/sessions/**/session.*.jsonl*  —— 追加式会话日志，唯一不可再生的原文
      2. <DSH_HOME>/storages/dsh-plugin-lcm/lcm.db —— 召回用 SQLite 归档（派生数据，可重建）
      3. <DSH_HOME>/profiles/*/cordis.patch.yml    —— 配置覆盖层

    归档库用 SQLite 官方推荐的 VACUUM INTO 做在线一致快照，DSH 不用停。

    一致性保护：
      · 备份目录里出现 ACTIVE.lock（DSH 正在跑 AI 回合）时默认跳过；
      · 拷贝会话日志前后各采样一次目录修改时间，中途有写入就丢弃本次快照重来。

.PARAMETER WaitIdleMinutes
    动手前要求会话日志至少已经安静这么多分钟。默认 10。
.PARAMETER KeepDays
    保留最近多少天的备份。默认 14。
.PARAMETER RcloneRemote
    可选。填了就接着 rclone copy 到云端，例如 onedrive:dsh-backup。
.EXAMPLE
    ./scripts/dsh-backup.ps1
    ./scripts/dsh-backup.ps1 -WaitIdleMinutes 0     # 立刻备份，不看空闲
#>
[CmdletBinding()]
param(
    [string]$DshHome = $env:DSH_HOME,
    [string]$BackupRoot = (Join-Path (Join-Path $env:USERPROFILE 'Documents') 'dsh-backup'),
    [int]$KeepDays = 14,
    [int]$WaitIdleMinutes = 10,
    [switch]$IgnoreLock,
    [switch]$SkipArchive,
    [string]$RcloneRemote = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($DshHome)) { $DshHome = Join-Path $env:USERPROFILE '.dsh' }

$utf8     = New-Object System.Text.UTF8Encoding($false)
$sessions = Join-Path $DshHome 'sessions'
$lockFile = Join-Path $BackupRoot 'ACTIVE.lock'
$logFile  = Join-Path $BackupRoot 'backup.log'
New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null

function Log([string]$msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

# ── 找 node：优先用 DSH 自带运行时，其次 PATH ────────────────────────────────
function Find-Node {
    $candidates = @(
        (Join-Path $DshHome 'dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe'),
        (Join-Path $DshHome 'dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node')
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# ── 0. 活动锁 ───────────────────────────────────────────────────────────────
if (-not $IgnoreLock -and (Test-Path -LiteralPath $lockFile)) {
    $age = ((Get-Date) - (Get-Item -LiteralPath $lockFile).LastWriteTime).TotalSeconds
    if ($age -lt 7200) { Log ("跳过：DSH 活动中（ACTIVE.lock {0:N0}s 前更新）" -f $age); exit 0 }
    Log "清理过期的 ACTIVE.lock"
    Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
}

# ── 1. 会话活跃度 ───────────────────────────────────────────────────────────
function Get-LastActivity {
    if (-not (Test-Path -LiteralPath $sessions)) { return [datetime]::MinValue }
    $latest = [datetime]::MinValue
    foreach ($d in Get-ChildItem -LiteralPath $sessions -Directory -Recurse) {
        if ($d.LastWriteTime -gt $latest) { $latest = $d.LastWriteTime }
    }
    $latest
}

$idle = ((Get-Date) - (Get-LastActivity)).TotalMinutes
if ($idle -lt $WaitIdleMinutes) {
    Log ("跳过：{0:N1} 分钟前还在会话，未达 {1} 分钟阈值" -f $idle, $WaitIdleMinutes)
    exit 0
}
Log ("开始：已安静 {0:N0} 分钟" -f $idle)

$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$staging = Join-Path $BackupRoot ('.staging-' + $stamp)
$final   = Join-Path $BackupRoot $stamp
New-Item -ItemType Directory -Force -Path $staging | Out-Null

try {
    # ── 2. 会话日志 ─────────────────────────────────────────────────────────
    $before = Get-LastActivity
    $count  = 0
    if (Test-Path -LiteralPath $sessions) {
        Get-ChildItem -LiteralPath $sessions -Recurse -File -Include 'session.*.jsonl*' | ForEach-Object {
            $rel = $_.FullName.Substring($sessions.Length).TrimStart('\', '/')
            $out = Join-Path (Join-Path $staging 'sessions') $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $out -Force
            $count++
        }
    }
    Start-Sleep -Milliseconds 700
    if ((Get-LastActivity) -gt $before) {
        Log "拷贝期间有写入 —— 丢弃本次快照，等下次空闲重来"
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        exit 0
    }
    Log ("会话日志：{0} 个文件" -f $count)

    # ── 3. 归档快照 ─────────────────────────────────────────────────────────
    if (-not $SkipArchive) {
        $db   = Join-Path $DshHome 'storages\dsh-plugin-lcm\lcm.db'
        $node = Find-Node
        if ((Test-Path -LiteralPath $db) -and $node) {
            $snap = Join-Path (Join-Path $staging 'archive') 'lcm.db'
            New-Item -ItemType Directory -Force -Path (Split-Path $snap) | Out-Null
            $code = "const {DatabaseSync}=require('node:sqlite');" +
                    "const d=new DatabaseSync(process.argv[1],{readOnly:true});" +
                    "const q=String.fromCharCode(39);" +
                    "d.exec('VACUUM INTO '+q+process.argv[2]+q);d.close();" +
                    "console.log('ok');"
            & $node -e $code $db $snap
            if ($LASTEXITCODE -eq 0) { Log "归档快照：archive/lcm.db" }
            else { Log "警告：归档快照失败（会话日志备份不受影响）" }
        } else {
            Log "跳过归档：lcm.db 不存在或找不到 node"
        }
    }

    # ── 4. 配置覆盖层（不含凭据）───────────────────────────────────────────
    $cfgCount = 0
    $profiles = Join-Path $DshHome 'profiles'
    if (Test-Path -LiteralPath $profiles) {
        Get-ChildItem -LiteralPath $profiles -Directory | ForEach-Object {
            $p = Join-Path $_.FullName 'cordis.patch.yml'
            if (Test-Path -LiteralPath $p) {
                $dst = Join-Path (Join-Path $staging 'config') ("{0}-cordis.patch.yml" -f $_.Name)
                New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
                Copy-Item -LiteralPath $p -Destination $dst -Force
                $cfgCount++
            }
        }
    }
    Log ("配置：{0} 份" -f $cfgCount)

    # ── 5. 原子落地 ─────────────────────────────────────────────────────────
    Move-Item -LiteralPath $staging -Destination $final
    Log ("完成：{0}" -f $final)

    # ── 6. 可选云同步 ───────────────────────────────────────────────────────
    if ($RcloneRemote) {
        Log "rclone copy -> $RcloneRemote"
        & rclone copy $final $RcloneRemote --create-empty-src-dirs
    }

    # ── 7. 保留策略（只删本脚本产生的备份）─────────────────────────────────
    Get-ChildItem -LiteralPath $BackupRoot -Directory |
        Where-Object { $_.Name -match '^\d{8}-\d{6}$' -and $_.LastWriteTime -lt (Get-Date).AddDays(-$KeepDays) } |
        ForEach-Object { Log "清理过期备份：$($_.Name)"; Remove-Item -LiteralPath $_.FullName -Recurse -Force }
} catch {
    Log "失败：$($_.Exception.Message)"
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    throw
}
