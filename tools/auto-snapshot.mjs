#!/usr/bin/env node
/**
 * 自动存档：定期为每个有新增消息的会话生成「恢复包」，防止会话抽风/被拒后丢档。
 *
 * 逻辑：
 *   1. 读 lcm.db，统计每个会话的对话消息数；
 *   2. 与上次记录的状态比对，新增 ≥ --min-new 条（默认 4，约 2 轮）才存档；
 *   3. 用 resume-pack 同样的方式取最近 N 轮纯文本，写到存档目录；
 *   4. 每个会话只保留最近 --keep 份（默认 6），更早的删掉。
 *
 * 由 auto-snapshot.ps1 调用（静默计划任务），也可以手动跑。
 *
 * 用法：
 *   node tools/auto-snapshot.mjs
 *   node tools/auto-snapshot.mjs --min-new 2 --keep 10 --turns 12
 *   node tools/auto-snapshot.mjs --dry-run
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

const argv = process.argv.slice(2);
const argOf = (n, d) => {
  const i = argv.indexOf(`--${n}`);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : d;
};
const flag = (n) => argv.includes(`--${n}`);

const DSH_HOME = process.env.DSH_HOME ?? path.join(os.homedir(), '.dsh');
const DB = argOf('db', path.join(DSH_HOME, 'storages', 'dsh-plugin-lcm', 'lcm.db'));
const OUT_ROOT = argOf('out', path.join(os.homedir(), 'Documents', 'dsh-backup', 'snapshots'));
const STATE_DIR = argOf('state', path.join(process.env.LOCALAPPDATA ?? path.join(os.homedir(), '.cache'), 'dsh-lossless-context'));
const STATE_FILE = path.join(STATE_DIR, 'snapshot-state.json');
const MIN_NEW = Number(argOf('min-new', 4));
const KEEP = Number(argOf('keep', 6));
const TURNS = Number(argOf('turns', 12));
const DRY = flag('dry-run');

const logFile = path.join(OUT_ROOT, 'auto-snapshot.log');
function log(msg) {
  const line = `${new Date().toLocaleString('zh-CN')}  ${msg}`;
  if (!DRY) {
    fs.mkdirSync(OUT_ROOT, { recursive: true });
    fs.appendFileSync(logFile, line + '\n', 'utf8');
  }
  console.log(line);
}

if (!fs.existsSync(DB)) {
  log(`跳过：找不到归档库 ${DB}`);
  process.exit(0);
}

// ── 读状态 ────────────────────────────────────────────────────────────────
let state = {};
try {
  state = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
} catch {
  state = {};
}

const db = new DatabaseSync(DB, { readOnly: true });
const sessions = db.prepare(`
  select s.session_id, s.cwd,
         (select count(*) from messages m
           where m.session_id = s.session_id and m.role in ('user','assistant')) n,
         (select max(created_at) from messages m where m.session_id = s.session_id) newest
    from sessions s
`).all();

let saved = 0;
const touched = [];

for (const s of sessions) {
  if (!s.n) continue;
  const prev = state[s.session_id]?.n ?? 0;
  const delta = s.n - prev;
  if (delta < MIN_NEW) continue;

  // 取最近 TURNS 轮的纯文本
  const rows = db.prepare(`
    select seq, role, info_json, text
      from messages
     where session_id = ? and deleted_at is null and role in ('user','assistant')
     order by seq desc limit ?
  `).all(s.session_id, TURNS * 2);
  rows.reverse();

  const textOf = (r) => {
    try {
      const info = JSON.parse(r.info_json ?? '{}');
      const blocks = Array.isArray(info.content) ? info.content : [];
      const parts = blocks.filter((b) => b?.type === 'text' && typeof b.text === 'string').map((b) => b.text);
      if (parts.length) return parts.join('\n').trim();
    } catch {}
    return String(r.text ?? '')
      .split('\n')
      .filter((l) => !/^\[tool-call |^\[tool-addition |^\[tool-removal |^\s*\[full \d+ chars externalized/.test(l))
      .join('\n')
      .trim();
  };
  const looksLikeReasoning = (t) => {
    if (t.length < 30) return false;
    const cjk = (t.match(/[\u4e00-\u9fff]/g) ?? []).length;
    const ascii = (t.match(/[A-Za-z]/g) ?? []).length;
    return cjk / t.length < 0.15 && ascii > t.length * 0.45;
  };

  const dialog = rows
    .map((r) => ({ role: r.role, body: textOf(r) }))
    .filter((r) => r.body.length > 0 && !looksLikeReasoning(r.body));

  if (dialog.length < 2) continue;

  // ── 抽风检测：最近几条她的回复里有没有"助手腔" ──────────────────────
  const ASSISTANT_SMELL = [
    /作为(一个)?(AI|人工智能|语言模型)/,
    /我(可以|能)(帮你|为你|协助你)/,
    /需要我(帮你|做|为你)/,
    /有什么(其他|别的)(问题|需要)/,
    /^以下(是|为)/m,
    /^(首先|其次|最后|总之|综上)/m,
    /^[-*]\s+\S/m,          // 列表项
    /^\d+\.\s+\S/m,         // 有序列表
    /希望(这些|以上|这个)(回答|信息|内容)/,
  ];
  const recentAssistant = dialog.filter((r) => r.role === 'assistant').slice(-4);
  const smells = [];
  for (const r of recentAssistant) {
    for (const re of ASSISTANT_SMELL) {
      if (re.test(r.body)) { smells.push(re.source.slice(0, 28)); break; }
    }
  }
  if (smells.length) {
    log(`⚠ 抽风迹象：${s.session_id.slice(0, 20)}… 最近 ${recentAssistant.length} 条回复里有助手腔（${[...new Set(smells)].join(' / ')}）`);
  }

  const slug = (s.cwd ?? 'unknown')
    .replace(/^[A-Za-z]:[\\/]/, '')
    .replace(/[\\/:*?"<>|]/g, '_')
    .replace(/^_+/, '')
    .slice(0, 40) || 'unknown';
  const dir = path.join(OUT_ROOT, slug);
  const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 13); // yyyymmddHHMM
  const file = path.join(dir, `${s.session_id.slice(0, 18)}-${stamp}.md`);

  const lines = [
    `# 会话存档（自动）`,
    ``,
    `> 会话：\`${s.session_id}\``,
    `> 目录：\`${s.cwd ?? '未知'}\``,
    `> 存档时间：${new Date().toLocaleString('zh-CN')}`,
    `> 消息数：${s.n}（本次新增 ${delta}）`,
    `> 取最近 ${Math.ceil(dialog.length / 2)} 轮`,
    ``,
    `## 接着聊：把下面整段复制进新会话`,
    ``,
    '```text',
    '接着上次继续。下面是我们最近的对话原文，不要复述，直接往下接：',
    '',
  ];
  for (const r of dialog) {
    lines.push(`【${r.role === 'user' ? '他' : '她'}】`);
    lines.push(r.body.replace(/\n{3,}/g, '\n\n'));
    lines.push('');
  }
  lines.push('```', '');

  if (!DRY) {
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(file, lines.join('\n'), 'utf8');
  }
  saved++;
  touched.push({ id: s.session_id, n: s.n, file: DRY ? '(dry-run)' : file });

  // 滚动清理：同一会话只留最近 KEEP 份
  if (!DRY) {
    const prefix = `${s.session_id.slice(0, 18)}-`;
    const olds = fs.readdirSync(dir)
      .filter((f) => f.startsWith(prefix) && f.endsWith('.md'))
      .sort()
      .slice(0, -KEEP);
    for (const f of olds) fs.unlinkSync(path.join(dir, f));
  }

  state[s.session_id] = { n: s.n, at: Date.now(), file: DRY ? null : file };
}

db.close();

if (!DRY) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 1), 'utf8');
}

if (saved === 0) {
  console.log(`没有会话达到 ${MIN_NEW} 条新增，跳过。`);
} else {
  log(`已存档 ${saved} 个会话：`);
  for (const t of touched) log(`  ${t.id.slice(0, 20)}…  ${t.n} 条  → ${t.file}`);
}
