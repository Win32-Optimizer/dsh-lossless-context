#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
    把 dsh-lossless-context 的配置合并进指定的 DeepSeek Harness profile。
.DESCRIPTION
    做三件事：
      1. 找到 <DSH_HOME> 和 profile 目录，确认 openseek-lcm 已安装；
      2. 备份现有的 cordis.patch.yml，检查里面是否已经有同名 id；
      3. 没有冲突就把选定的补丁段追加进去（有冲突则只报告，不动文件）。

    幂等：重复运行不会重复追加。已存在同名 id 时会提示你手动合并。
.PARAMETER Profile
    要配置的 profile 名。默认 desktop（DSH 桌面版）。
.PARAMETER Mode
    balanced（默认，省 token）或 memory-heavy（记忆敏感场景）。
.PARAMETER DshHome
    DSH 主目录。默认读 $env:DSH_HOME，否则 ~/.dsh。
.EXAMPLE
    ./scripts/install.ps1
    ./scripts/install.ps1 -Mode memory-heavy
    ./scripts/install.ps1 -Profile web -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Profile = 'desktop',
    [ValidateSet('balanced', 'memory-heavy')]
    [string]$Mode = 'balanced',
    [string]$DshHome = $env:DSH_HOME
)

$ErrorActionPreference = 'Stop'
$script:utf8 = New-Object System.Text.UTF8Encoding($false)   # 无 BOM，DSH 读得最稳

function Say([string]$m)  { Write-Host $m }
function Ok([string]$m)   { Write-Host "  [ok]   $m" -ForegroundColor Green }
function Warn2([string]$m){ Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Die([string]$m)  { Write-Host "  [fail] $m" -ForegroundColor Red; exit 1 }

# ── 0. 定位 DSH_HOME ────────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($DshHome)) { $DshHome = Join-Path $env:USERPROFILE '.dsh' }
Say ""
Say "dsh-lossless-context installer"
Say "  DSH_HOME : $DshHome"
Say "  profile  : $Profile"
Say "  mode     : $Mode"
Say ""

if (-not (Test-Path -LiteralPath $DshHome)) { Die "找不到 DSH_HOME：$DshHome" }

$repoRoot  = Split-Path -Parent $PSScriptRoot
$patchFile = Join-Path (Join-Path $repoRoot 'patches') ("cordis.$Mode.yml")
$target    = Join-Path (Join-Path (Join-Path $DshHome 'profiles') $Profile) 'cordis.patch.yml'

if (-not (Test-Path -LiteralPath $patchFile)) { Die "找不到补丁模板：$patchFile" }
if (-not (Test-Path -LiteralPath $target))    { Die "找不到 profile 覆盖层：$target`n  先用 DSH 启动一次该 profile，或确认 -Profile 名字。" }

# ── 1. 检查 openseek-lcm ────────────────────────────────────────────────────
$profileDir = Split-Path -Parent $target
$lcmDir     = Join-Path (Join-Path $profileDir 'node_modules') 'openseek-lcm'
if (Test-Path -LiteralPath $lcmDir) {
    Ok "openseek-lcm 已安装"
} else {
    Warn2 "openseek-lcm 没装。安装命令（先关掉 DSH）："
    Warn2 "  dsh plugin --profile $Profile add openseek-lcm"
    Warn2 "装完再跑一次本脚本。"
}

# ── 2. 读现有 patch，查 id 冲突 ─────────────────────────────────────────────
$existing = [System.IO.File]::ReadAllText($target, $script:utf8)
$incoming = [System.IO.File]::ReadAllText($patchFile, $script:utf8)

$ids = @()
foreach ($m in [regex]::Matches($incoming, '(?m)^-\s+id:\s*([A-Za-z0-9_\-]+)')) { $ids += $m.Groups[1].Value }

$conflicts = @()
foreach ($id in $ids) {
    if ($existing -match ('(?m)^-\s+id:\s*' + [regex]::Escape($id) + '\s*$')) { $conflicts += $id }
}

if ($conflicts.Count -gt 0) {
    Say ""
    Warn2 "这些 id 在现有 patch 里已经存在，不会重复追加："
    foreach ($c in $conflicts) { Warn2 "  - $c" }
    Say ""
    Say "  请手动把 patches/cordis.$Mode.yml 里对应的段落，覆盖到"
    Say "  $target"
    Say "  里已有的同名段落上（注意缩进：顶层列表，'- id:' 顶格）。"
    Say ""
    Say "  没有做任何修改。"
    exit 0
}

# ── 3. 追加 ─────────────────────────────────────────────────────────────────
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = "$target.bak-$stamp"

$header = @"

# ─────────────────────────────────────────────────────────────────────────────
#  dsh-lossless-context（$Mode）
#  安装于 $stamp
#  卸载：删掉本段以下的所有内容，并重启 DSH
# ─────────────────────────────────────────────────────────────────────────────

"@

$merged = ($existing.TrimEnd() + "`n" + $header + $incoming.TrimEnd() + "`n")

if ($PSCmdlet.ShouldProcess($target, "追加 $($ids.Count) 个配置段（$($ids -join ', ')）")) {
    Copy-Item -LiteralPath $target -Destination $backup -Force
    [System.IO.File]::WriteAllText($target, $merged, $script:utf8)
    Ok "已追加 $($ids.Count) 段：$($ids -join ', ')"
    Ok "原文件已备份：$backup"
    Say ""
    Say "下一步："
    Say "  1. 完全退出并重新打开 DeepSeek Harness（插件代码只在启动时加载）"
    Say "  2. 在任意会话输入  /lcm status  确认 archive 已就绪"
    Say "  3. 想验证「压缩后仍能找回原文」，跑：node tests/acceptance.mjs"
    Say ""
}
