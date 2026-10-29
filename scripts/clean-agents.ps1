#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
    清洗 Markdown 记忆文件里的 base64 图片垃圾。
.DESCRIPTION
    Typora / Obsidian / 某些网页编辑器粘贴图片时，会把图片写成
    `![](data:image/png;base64,iVBORw0KG...)`。那串 base64 有几千到几十万字符，
    如果文件被当成工作区记忆（AGENTS.md）整份读进提示词，就是纯白烧 token。

    本脚本做四件事（默认只报告，加 -Apply 才改文件）：
      1. 把 `![alt](data:image/...;base64,...)` 整段替换成 `![alt](图片已移除)`
      2. 把孤立的 `data:image/...;base64,...` （没有 markdown 包裹的）也清掉
      3. 清掉连续 3 行以上的空白
      4. 报告节省了多少字符 / 估算省了多少 token

    改文件前自动备份为 `<原名>.bak-<时间戳>`。
.PARAMETER Path
    要清洗的文件。默认 <工作区>\AGENTS.md。
.PARAMETER Apply
    真正写入。不加只做演示（dry run）。
.PARAMETER Threshold
    base64 串至少多长才算垃圾。默认 200 字符，避免误伤短引用。
.EXAMPLE
    ./clean-agents.ps1                                   # 报告
    ./clean-agents.ps1 -Apply                            # 清理默认文件
    ./clean-agents.ps1 -Path "C:\x\AGENTS.md" -Apply     # 指定文件
#>
[CmdletBinding()]
param(
    [string]$Path = (Join-Path (Get-Location) 'AGENTS.md'),
    [switch]$Apply,
    [int]$Threshold = 200
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host "找不到文件：$Path" -ForegroundColor Red
    exit 1
}

$raw  = [System.IO.File]::ReadAllText($Path, $utf8)
$orig = $raw.Length

# ── 1. markdown 图片包裹的 data URI ─────────────────────────────────────────
$imgPattern = '!\[([^\]]*)\]\(\s*data:image/[^;]+;base64,[A-Za-z0-9+/=\s]{' + $Threshold + ',}\s*\)'
$imgCount = ([regex]::Matches($raw, $imgPattern)).Count
$raw = [regex]::Replace($raw, $imgPattern, '![$1](图片已移除)')

# ── 2. 裸的 data URI（没有 markdown 包裹）──────────────────────────────────
$barePattern = 'data:image/[^;]+;base64,[A-Za-z0-9+/=\s]{' + $Threshold + ',}'
$bareCount = ([regex]::Matches($raw, $barePattern)).Count
$raw = [regex]::Replace($raw, $barePattern, '[图片已移除]')

# ── 3. 压缩多余空行 ─────────────────────────────────────────────────────────
$raw = [regex]::Replace($raw, "(\r?\n){4,}", "`n`n`n")
$raw = $raw.TrimEnd() + "`n"

$new = $raw.Length
$saved = $orig - $new

Write-Host ""
Write-Host "清洗报告：$Path" -ForegroundColor Cyan
Write-Host ("  原始大小      {0,10:N0} 字符" -f $orig)
Write-Host ("  清洗后        {0,10:N0} 字符" -f $new)
Write-Host ("  省下          {0,10:N0} 字符  (约 {1:N0} token)" -f $saved, [Math]::Round($saved / 1.6))
Write-Host ("  markdown 图片 {0,10} 处" -f $imgCount)
Write-Host ("  裸 data URI   {0,10} 处" -f $bareCount)
Write-Host ""

if ($saved -le 0 -and $imgCount -eq 0 -and $bareCount -eq 0) {
    Write-Host "文件是干净的，不需要改。" -ForegroundColor Green
    exit 0
}

if (-not $Apply) {
    Write-Host "以上是 dry run。加 -Apply 才会真正写入（会先备份）。" -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

$backup = "$Path.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
Copy-Item -LiteralPath $Path -Destination $backup -Force
[System.IO.File]::WriteAllText($Path, $raw, $utf8)
Write-Host "已写入：$Path" -ForegroundColor Green
Write-Host "已备份：$backup" -ForegroundColor Green
Write-Host ""
Write-Host "提醒：AGENTS.md 只在新会话首次请求时加载。要让清洗结果生效，请开一个新会话。" -ForegroundColor Yellow
Write-Host ""
