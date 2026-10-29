# Changelog

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

## [0.1.0] — 2026-10-27

首个可发行版本。这套配置在 Windows + DeepSeek Harness 44.7.0 + `openseek-lcm@0.1.1`
上实测通过（验收 17/17，成本模型与线上账单量级一致）。

### 新增

- `patches/cordis.balanced.yml` — 省 token 档：水位 73%、逐字尾部约 12 万 token
- `patches/cordis.memory-heavy.yml` — 记忆敏感档：水位 60%、逐字尾部约 28 万 token
- `scripts/install.ps1` / `install.sh` — 幂等安装器，带 id 冲突检测与自动备份
- `scripts/dsh-backup.ps1` — 会话日志 + 归档一致快照 + 配置覆盖层的三层备份
- `scripts/dsh-backup-idle.ps1` — 空闲感知调度器（键鼠空闲 + DSH 忙锁 + 会话安静 + 间隔到期）
- `scripts/dsh-pwsh-hook.ps1` — AI 回合忙锁（可选加固）
- `scripts/install-tasks.ps1` — 注册/卸载 Windows 计划任务。**静默**：任务调 `wscript.exe` 跑自动生成的
  `.vbs`，VBS 用 `Run(cmd, 0, False)` 以窗口样式 0 启动 PowerShell，不闪控制台
- `scripts/clean-agents.ps1` — 清除记忆文件里被 Markdown 编辑器塞入的 base64 图片，
  保留 alt 文字与文档结构，并报告省下的 token
- `tests/acceptance.mjs` — 验收：模拟三次压缩后逐字召回 11 条细节
- `tests/cost-model.mjs` — 三场景成本对比
- `tools/lcm-inspect.mjs` — 归档体检 / 只读 SQL / 绕过 FTS 的原文搜索
- `templates/AGENTS.md.example` — 工作区记忆模板（含强制检索规则与在场记录结构）
- `docs/深入原理.md` — 摘要为什么有损、归档为什么无损、缓存为什么是省钱大头
- `docs/维护手册.md` — 运维检查清单、症状→原因→修法诊断树、升级路径、参数公式、
  直接查库的 SQL、**从零写同类插件的实现思路**、11 条实测踩坑

### 已知问题

- `install.ps1` 依赖 Windows PowerShell 5.1+；脚本文件必须带 UTF-8 BOM，否则中文注释会让 5.1 的解析器报语法错误
- `dsh-pwsh-hook.ps1` 的 `http hook install file` 语法未在多个 DSH 版本上验证，安装前请先试跑
- `worktree` scope 以工作目录为键，迁移工作目录后旧会话切不到（`session` / `root` 仍可用）

### 验证记录

```
$ node tests/acceptance.mjs
=== 1. 忠实捕获 ===
PASS  归档捕获了全部消息  -- message_count=246 / events=246
PASS  capture_failures=0
=== 2. 模拟三次压缩，直到上下文里什么都不剩 ===
PASS  模型当前上下文中已不含任何原始细节（只剩摘要）  -- 372 字符
=== 3. 逐字召回（工作流） ===
PASS    " 5433 " / " PostgreSQL " / " config/db.yaml " / " 操作前必须先确认 "
PASS    " ELIFECYCLE " / " 20.11.0 "
=== 4. 逐字召回（记忆敏感场景） ===
PASS    " 小雨 " / " 12 月 3 日 " / " 千与千寻 " / " 晚安 " / " 周末早上 "
=== 5. 隔离 ===
PASS  工作流会话里搜不到另一条线的名字
=== 6. 跨会话 ===
PASS  worktree 范围召回到另一个会话里的回忆
=== 7. 摘要树可下钻到原文 ===
PASS  lcm_expand includeRaw 能取回原文片段

细节召回：工作流 6/6，记忆敏感 5/5
17/17 项通过
```
