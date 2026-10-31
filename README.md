# dsh-lossless-context

> 给 [DeepSeek Harness](https://deepseek-harness.github.io/deepseek-harness/) 的无损上下文方案：
> **压缩只腾窗口，细节留在本地硬盘里，需要时能逐字找回。**

长会话的两个死结，这套配置各自对付一个：

| 死结 | 怎么解 |
|---|---|
| **每轮重发全部历史，token 烧光** | 到水位才压缩 + DeepSeek 上下文硬盘缓存（命中价是未命中的 1/50） |
| **摘要压缩必然丢细节，多轮后设计理由和被否方案彻底消失** | 原文逐字归档进本地 SQLite（FTS5 全文索引），压缩不碰归档，`lcm_grep` 按需取回原文 |

**结论先行：摘要不能当记忆。** 摘要是有损的，压缩率越高丢得越多，而且压缩会反复发生（旧摘要被再次合并），细节会一层层变淡。
能证明"原文没丢"的只有一种机制：**原文归档 + 按需精确回溯**。

---

## 它做什么

```
   会话事件 ──capture──▶ 本地 SQLite ──FTS5──▶ 检索
   (DSH 会话日志)        (messages /            │
                          摘要树 / artifact)     ▼
                                        lcm_grep / lcm_expand
                                                 │
   ┌─────────────────────────────────────────────┘
   │
   ▼
 压缩（compaction-basic）只改「发给模型的上下文」
 ── 摘要 + 最近 N 万 token 逐字原文
 ── 被折掉的段落？原文还在归档里
```

三个组件，各管一件事：

1. **`openseek-lcm`**（第三方插件，MIT）— 把每条消息逐字归档，提供 `lcm_grep` / `lcm_expand` / `lcm_artifact` 等回溯工具。压缩后第一轮会注入一条确定性的「压缩指针 + resume note」，告诉模型去哪找原文。
2. **`dsh-compaction-basic`**（DSH 自带）— 到水位才把较早历史折成检查点。这套配置做两件事：**把水位和逐字尾部调到你需要的档位**，以及**让摘要走便宜模型**（`deepseek-flash`），主对话模型不受影响。
3. **`dsh-compaction-tool-result-pruner`**（DSH 自带，默认开）— 它的**默认值会把长工具结果的中段整段砍掉**（8192/4096/1024 字符），而端口号、文件路径、报错字符串经常正好在中段。本方案把它放宽到 32000/24000/8000。

---

## 快速开始

### 前提

- DeepSeek Harness（桌面版或 CLI 均可）
- DeepSeek 官方 API key（本方案只针对 `deepseek-official`）

### 1. 装归档插件

先完全退出 DSH，然后：

```bash
dsh plugin --profile desktop add openseek-lcm
```

> `desktop` 是桌面版 profile 名。CLI 用户换成 `web` / `tui` / 你自己的 profile。

### 2. 合并配置

**Windows：**

```powershell
./scripts/install.ps1                  # 省 token 档
./scripts/install.ps1 -Mode memory-heavy   # 记忆敏感档
```

**macOS / Linux：**

```bash
chmod +x scripts/*.sh
./scripts/install.sh                   # 省 token 档
./scripts/install.sh memory-heavy      # 记忆敏感档
```

脚本会：找到 `<DSH_HOME>/profiles/<profile>/cordis.patch.yml` → 备份 → 检查是否已有同名 id → 没有冲突才追加。
**幂等**：重复跑不会重复追加；有冲突时只报告、不动文件。

### 3. 重启并确认

完全退出并重新打开 DSH，然后在任意会话输入：

```
/lcm status
```

看到 `capture_failures=0` 和 `message_count` 在涨就成功了。

### 4. 验证「压缩后还能找到原文」

```bash
node tests/acceptance.mjs
```

脚本会加载你机器上真实的插件、造一份会话日志、**模拟三次压缩直到上下文里什么都不剩**，然后逐字比对 11 条细节。

期望输出：

```
细节召回：工作流 6/6，记忆敏感 5/5
17/17 项通过
结论：✓ 压缩后细节仍可逐字找回，不是靠摘要"记得大概"。
```

---

## 两档参数，选一个

| | `balanced`（默认） | `memory-heavy` |
|---|---|---|
| 适用 | 长期写代码、长工作流 | 角色扮演、长期陪伴、长篇小说、心理咨询 |
| `thresholdRatio` | 0.75 | 0.60 |
| `retainRatio` | 0.15 | 0.35 |
| 触发水位 | 768,000 token（约 73%） | 629,145 token（约 60%） |
| 逐字保留 | ≈118,886 token（约 4 万字中文） | ≈277,401 token（约 9 万字中文） |
| 压缩后每轮固定携带 | ≈12 万 token | ≈28 万 token |

**水位怎么算的**（来自 `dsh-compaction-basic` 源码）：

```
阈值       = floor(min(W × thresholdRatio, (W − O) − headroomTokens))
逐字保留   = floor((W − O) × retainRatio)

W = 1,048,576   deepseek-flash 上下文窗口（官方定价页）
O = 256,000     请求输出预留（dsh-llm-deepseek 默认 maxTokens）
```

**为什么要给中文留缓冲**：DSH 的 token meter 用「每 token 4 字符」估算，而官方 README 明确写着「**CJK 文本与 JSON schema 在每 token 四字符下严重低估**」。中文约 1 字 = 1 token，所以「估算到 60%」时真实占用可能已经高得多。水位压低是留缓冲。

---

## 成本

```bash
node tests/cost-model.mjs
```

deepseek-flash 高峰价（¥2/M 未命中，¥0.04/M 命中）：

| 会话长度 | A 全量重发·无缓存 | B 全量重发·有缓存 | **C 本方案** | C 相对 A |
|---|---|---|---|---|
| 150 轮 | 33.70M / ¥67.41 | 33.70M / ¥31.27 | 33.70M / ¥31.27 | 费用 −54%（**全来自缓存**） |
| 400 轮 | 239.88M / ¥479.76 | 239.88M / ¥221.69 | **146.98M / ¥137.70** | **输入 −39%，费用 −71%** |
| 1000 轮 | 1499.70M / ¥2999.40 | 1499.70M / ¥1384.02 | **412.15M / ¥387.97** | **输入 −73%，费用 −87%** |

**别被这张表骗了**：

- **「输入 token 变少」来自压缩；「钱变少」的大头来自缓存。** 150 轮以内压缩一点忙都帮不上——根本没到水位。
- 每省 1M 未命中 token 省 ¥2（Flash 高峰）/ ¥9（Pro 高峰）；每省 1M 命中 token 只省 ¥0.04 / ¥0.30。
- 想让缓存持续命中：**系统提示和工具表在所有轮次保持一致**（本方案只暴露 5 个 lcm 工具，就是为此），不要做「按需增删工具」。
- 压缩会让「第一个被替换的 token 之后」的缓存失效，所以**稀疏压缩 >> 频繁小压缩**。

---

## 配置里那两个反直觉的决策

### 摘要走 Flash，主对话可以走 Pro

```yaml
- id: compaction-basic
  config:
    summarizationProvider: deepseek-official
    summarizationModel: deepseek-flash
```

压缩请求只产出一段 Markdown 检查点，用 ¥2/M 的模型足够，没必要用 ¥9/M 的 Pro。
**代价**：官方 README 写明「把摘要器路由到不同模型会放弃热前缀缓存复用」——压缩那一次的输入按未命中价计费。但整次压缩从 Pro 价降到 Flash 价，净划算。

### 工具白名单只留 5 个

```yaml
tools:
  expose: [lcm_status, lcm_resume, lcm_grep, lcm_expand, lcm_artifact]
```

18 个工具全开，意味着**每次请求**都要多带 18 份 schema。砍到 5 个既省钱又让前缀更稳定（缓存友好）。
需要 `lcm_doctor` / `lcm_retention_prune` / `lcm_blob_gc` 时，删掉 `expose` 整段即可。

---

## 备份（可选，但强烈建议）

原文只有一份，在 `<DSH_HOME>/sessions/`。归档可以重建，会话日志不行。

```powershell
# 手动
./scripts/dsh-backup.ps1

# 注册「空闲感知」计划任务：只在你离开电脑时才跑
./scripts/install-tasks.ps1
```

备份内容：会话日志 + `lcm.db` 的 `VACUUM INTO` 一致快照 + `cordis.patch.yml`（**不含 `.credentials.yaml`**）。

调度器（`dsh-backup-idle.ps1`）四个条件全满足才动手：

1. 键鼠空闲 ≥ 10 分钟（Windows 工作站空闲时钟）
2. DSH 不在跑 AI 回合（备份目录里没有 `ACTIVE.lock`）
3. 会话日志已安静 ≥ 30 分钟
4. 距上次成功 ≥ 设定间隔

拷贝前后各采样一次会话日志修改时间，**中途有写入就丢弃本次快照重来**——不会留下半个会话。

计划任务**完全静默**：任务调 `wscript.exe` 跑一个自动生成的 `.vbs`，VBS 用 `Run(cmd, 0, False)` 以隐藏窗口启动 PowerShell。不会闪控制台。

想连「AI 回合期间」也避让，可以装 pwsh hook（见 `scripts/dsh-pwsh-hook.ps1` 头部说明）。**这一步的安装语法随 DSH 版本可能不同，装之前先测**。

### 工作区记忆文件被编辑器塞了 base64？

Typora / Obsidian / 部分网页编辑器粘图时会写成 `![](data:image/png;base64,....)`。那串东西如果进了 `AGENTS.md`，每个新会话都会把它当提示词读一遍——白烧几千 token。

```powershell
./scripts/clean-agents.ps1 -Path "D:\你的工作区\AGENTS.md"           # 先看报告
./scripts/clean-agents.ps1 -Path "D:\你的工作区\AGENTS.md" -Apply    # 真清（自动备份）
```

它会把 `![alt](data:image/...;base64,...)` 换成 `![alt](图片已移除)`，保留 alt 文字和文档结构，并告诉你省了多少 token。

### 排查与深挖

```bash
node tools/lcm-inspect.mjs                        # 体检：完整性/计数/每会话统计/摘要树
node tools/lcm-inspect.mjs --show "某个关键词"     # 绕过 FTS 直接搜原文（判断是"没归档"还是"索引坏了"）
node tools/lcm-inspect.mjs --sql "select ..."     # 只读 SQL
```

完整的运维手册（诊断树、升级清单、参数公式、自己写插件的实现思路）见 [docs/维护手册.md](docs/维护手册.md)。

---

## 局限（请务必读完）

1. **模型不会自动去查硬盘。** 它只在判断「需要回忆」时才调 `lcm_grep`。检索是**按需**的，不是自动的。
   想让它在特定话题上稳定触发检索，最有效的办法是在工作区 `AGENTS.md` 里写死触发规则（见 `templates/AGENTS.md.example`）。
2. **摘要仍然是摘要。** 被折进检查点的那段历史，模型当下看到的是摘要。归档能找回原文，但**不会自动回到上下文里**。
3. **它不能替代「全量在上下文里」的体验。** 如果你的场景对「在场感」要求极高（长期陪伴类），**必须**配合 `AGENTS.md` 里的原文片段——光靠检索永远差一层。
4. **归档体积是实打实的。** 实测约 500 条消息 ≈ 3–8 MB（FTS 索引占大头）。定期 `/lcm compact apply`。
5. **`openseek-lcm` 是社区项目**（1 位作者，MIT，可商用）。它挂了不会丢原文——原文在 `sessions/` 里，禁用插件即可回退。
6. **token 水位是估算的。** 中文被低估，所以别把 `thresholdRatio` 调到 0.9。
7. **本方案不改变隐私边界。** 你的对话照样发到 `api.deepseek.com`；它只保证「本地多一份可检索的原文」，不保证「内容不出本机」。想要后者只能上本地模型。

---

## 目录结构

```
dsh-lossless-context/
├── patches/
│   ├── cordis.balanced.yml       # 省 token 档
│   └── cordis.memory-heavy.yml   # 记忆敏感档
├── scripts/
│   ├── install.ps1               # Windows 安装器
│   ├── install.sh                # macOS/Linux 安装器
│   ├── dsh-backup.ps1            # 备份（会话+归档+配置）
│   ├── dsh-backup-idle.ps1       # 空闲感知调度器
│   ├── dsh-pwsh-hook.ps1         # AI 回合忙锁（可选）
│   ├── clean-agents.ps1          # 清除记忆文件里的 base64 图片垃圾
│   ├── auto-snapshot.ps1         # 自动存档调度器（静默）
│   ├── install-snapshot-task.ps1 # 注册「自动存档」计划任务
│   └── install-tasks.ps1         # 注册静默计划任务（wscript + VBS 包装）
├── tests/
│   ├── acceptance.mjs            # 验收：压缩后逐字召回
│   └── cost-model.mjs            # 成本对比
├── tools/
│   ├── lcm-inspect.mjs           # 归档体检 / 只读查询（DSH 运行中可用）
│   ├── resume-pack.mjs           # 会话被内容策略拒收后，从归档生成「接着聊」的恢复包
│   └── auto-snapshot.mjs         # 定期自动存档 + 助手腔抽风检测
├── templates/
│   └── AGENTS.md.example         # 工作区记忆模板（含强制检索规则）
├── docs/
│   ├── 深入原理.md                # 摘要为什么有损、归档为什么无损、缓存为什么省钱
│   └── 维护手册.md                # 运维检查、诊断树、参数调优、自己写插件的实现思路
└── README.md
```

---

## 卸载

```powershell
# 1. 从 patch 里删掉 dsh-lossless-context 那一段（installer 会在文件里留标记注释）
# 2. 移除插件
dsh plugin --profile desktop remove openseek-lcm
# 3. 删归档（可选；会话日志不受影响）
Remove-Item -Recurse "$env:USERPROFILE\.dsh\storages\dsh-plugin-lcm"
# 4. 删计划任务
./scripts/install-tasks.ps1 -Remove
```

**原文永远在 `<DSH_HOME>/sessions/`，卸载不会丢。**

---

## 出处

- 模型/价格/上下文窗口：[DeepSeek《模型 & 价格》](https://api-docs.deepseek.com/zh-cn/quick_start/pricing)
- 缓存落盘与命中规则：[DeepSeek《上下文硬盘缓存》](https://api-docs.deepseek.com/zh-cn/guides/kv_cache)
- 压缩公式、`summarizationProvider`、摘要提示词：DSH 内 `@deepseek-ai/dsh-compaction-basic` 的 README 与源码
- 修剪器默认值：`@deepseek-ai/dsh-compaction-tool-result-pruner` 的 README
- 「CJK 被低估」：`@deepseek-ai/dsh-token-meter` 的 README
- `maxTokens` 默认 256,000：`@deepseek-ai/dsh-llm-deepseek` 的 README
- 归档插件：<https://github.com/Pub-Polaris/openseek-lcm>

## 许可

MIT。见 [LICENSE](LICENSE)。

本项目是**配置与工具层**，不分发任何第三方源码。`openseek-lcm` 是独立项目（MIT），DeepSeek Harness 及其组件版权归 DeepSeek, Inc.。本项目与二者均无隶属关系，也未获其背书。
