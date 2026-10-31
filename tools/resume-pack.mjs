#!/usr/bin/env node
/**
 * 会话恢复包生成器
 *
 * 用途：某个会话被服务端内容策略拒收（HTTP 400 "Content Exists Risk"）后，
 *       整个会话会永久不可用（每次请求都会重放那条被拒内容）。
 *       本工具从本地归档 lcm.db 里取出最近若干轮**纯对话原文**，
 *       生成一份可以直接粘贴进「新会话」的恢复包。
 *
 * 只读：不修改 lcm.db，不碰会话日志。
 *
 * 用法：
 *   node tools/resume-pack.mjs                      # 自动选最近有对话的会话
 *   node tools/resume-pack.mjs --list               # 列出所有会话
 *   node tools/resume-pack.mjs --session <前缀>     # 指定会话
 *   node tools/resume-pack.mjs --turns 10           # 最近 10 轮（默认 8）
 *   node tools/resume-pack.mjs --out D:\pack.md     # 写到文件
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

const DSH_HOME = process.env.DSH_HOME ?? path.join(os.homedir(), '.dsh');
const DB = argOf('db', path.join(DSH_HOME, 'storages', 'dsh-plugin-lcm', 'lcm.db'));
const TURNS = Number(argOf('turns', 8));
const WANT = argOf('session', null);
const OUT = argOf('out', null);
const LIST = argv.includes('--list');

if (!fs.existsSync(DB)) {
  console.error(`找不到归档库：${DB}`);
  process.exit(1);
}

const db = new DatabaseSync(DB, { readOnly: true });

const sessions = db.prepare(`
  select s.session_id, s.cwd, s.title,
         (select max(created_at) from messages m where m.session_id = s.session_id) newest,
         (select count(*) from messages m where m.session_id = s.session_id and m.role in ('user','assistant')) msgs
    from sessions s
   where (select count(*) from messages m where m.session_id = s.session_id and m.role in ('user','assistant')) > 0
   order by newest desc
`).all();

if (!sessions.length) { console.error('归档里没有对话消息。'); process.exit(1); }

if (LIST) {
  console.log('会话（最近优先）：\n');
  for (const s of sessions) {
    const t = new Date(s.newest).toLocaleString('zh-CN');
    console.log(`  ${s.session_id}`);
    console.log(`     ${s.msgs} 条   ${t}   ${s.cwd ?? ''}`);
  }
  db.close();
  process.exit(0);
}

const target = WANT
  ? sessions.find((s) => s.session_id === WANT || s.session_id.startsWith(WANT))
  : sessions[0];

if (!target) {
  console.error(`找不到会话：${WANT}\n用 --list 看可用的。`);
  process.exit(1);
}

// 只取 user / assistant，从 info_json 里抽纯 text 块（丢掉 tool-call / 工具结果）
const rows = db.prepare(`
  select seq, role, created_at, text, info_json
    from messages
   where session_id = ? and deleted_at is null and role in ('user','assistant')
   order by seq desc
   limit ?
`).all(target.session_id, TURNS * 2);
db.close();
rows.reverse();

function textOf(r) {
  // 优先用 info_json 的 content 数组，只要 text 块
  try {
    const info = JSON.parse(r.info_json ?? '{}');
    const blocks = Array.isArray(info.content) ? info.content : [];
    const parts = blocks
      .filter((b) => b && b.type === 'text' && typeof b.text === 'string')
      .map((b) => b.text);
    if (parts.length) return parts.join('\n').trim();
  } catch { /* 落回 text */ }
  // 兜底：从拼接文本里剔除工具块
  return String(r.text ?? '')
    .split('\n')
    .filter((l) => !/^\[tool-call |^\[tool-addition |^\[tool-removal |^\s*\[full \d+ chars externalized/.test(l))
    .join('\n')
    .trim();
}

/** 判断一段文本像不像"模型的英文推理残留"，是就丢掉。 */
function looksLikeReasoning(s) {
  const n = s.length;
  if (n < 30) return false;
  const cjk = (s.match(/[\u4e00-\u9fff]/g) ?? []).length;
  const ascii = (s.match(/[A-Za-z]/g) ?? []).length;
  // 中文字符占比低于 15%、且 ASCII 字母很多 → 判为推理
  return cjk / n < 0.15 && ascii > n * 0.45;
}

const dialog = rows
  .map((r) => ({ role: r.role, body: textOf(r) }))
  .filter((r) => r.body.length > 0 && !looksLikeReasoning(r.body));

if (!dialog.length) {
  console.error('这个会话里没有可用的纯文本对话。');
  process.exit(1);
}

const lines = [];
lines.push('# 会话恢复包');
lines.push('');
lines.push(`> 来源会话：\`${target.session_id}\``);
lines.push(`> 工作目录：\`${target.cwd ?? '未知'}\``);
lines.push(`> 生成时间：${new Date().toLocaleString('zh-CN')}`);
lines.push(`> 共 ${dialog.length} 条消息（约 ${Math.ceil(dialog.length / 2)} 轮）`);
lines.push('');
lines.push('## 怎么用');
lines.push('');
lines.push('1. 在这个工作区**开一个新会话**（记得用「角色扮演（纯叙事）」preset）；');
lines.push('2. 把下面「开场消息」整段复制过去发出去；');
lines.push('3. 她会接着往下走，不会重新开始。');
lines.push('');
lines.push('> 为什么要这样做：原会话被服务端内容策略拒收后，每次请求都在重放那条内容，');
lines.push('> 所以只能换会话。**记忆本身没丢**——原文都在归档里。');
lines.push('');
lines.push('---');
lines.push('');
lines.push('## 开场消息（复制这一段）');
lines.push('');
lines.push('```text');
lines.push('接着上次继续。下面是我们最近的对话原文，不要复述，直接往下接：');
lines.push('');

for (const r of dialog) {
  const who = r.role === 'user' ? '他' : '她';
  lines.push(`【${who}】`);
  lines.push(r.body.replace(/\n{3,}/g, '\n\n'));
  lines.push('');
}

lines.push('```');
lines.push('');

const pack = lines.join('\n');

if (OUT) {
  fs.writeFileSync(OUT, pack, 'utf8');
  console.log(`已写入：${OUT}`);
  console.log(`会话 ${target.session_id.slice(0, 20)}…  共 ${dialog.length} 条消息`);
} else {
  console.log(pack);
}
