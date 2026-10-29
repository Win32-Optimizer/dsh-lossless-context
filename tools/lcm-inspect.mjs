#!/usr/bin/env node
/**
 * lcm 归档体检 / 查询工具
 *
 * 只读打开 lcm.db，不会修改任何东西。DSH 运行中也可以安全使用。
 *
 * 用法：
 *   node tools/lcm-inspect.mjs                      # 体检报告
 *   node tools/lcm-inspect.mjs --json               # 机器可读
 *   node tools/lcm-inspect.mjs --db <path>          # 指定库
 *   node tools/lcm-inspect.mjs --sql "select ..."   # 跑任意只读 SQL
 *   node tools/lcm-inspect.mjs --show <keyword>     # 直接搜消息原文（不经过 FTS）
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
const dbPath = argOf('db', path.join(DSH_HOME, 'storages', 'dsh-plugin-lcm', 'lcm.db'));
const asJson = argv.includes('--json');
const sql = argOf('sql', null);
const show = argOf('show', null);

if (!fs.existsSync(dbPath)) {
  console.error(`找不到归档库：${dbPath}`);
  console.error('插件可能没安装，或当前 profile 没加载它。');
  process.exit(1);
}

const db = new DatabaseSync(dbPath, { readOnly: true });
const one = (q, ...a) => db.prepare(q).get(...a);
const all = (q, ...a) => db.prepare(q).all(...a);
const count = (t) => {
  try { return one(`select count(*) c from ${t}`).c; } catch { return null; }
};

// ── 自由 SQL 模式 ───────────────────────────────────────────────────────────
if (sql) {
  if (/^\s*(insert|update|delete|drop|alter|create|vacuum|attach|pragma)\b/i.test(sql)) {
    console.error('只读模式，拒绝执行写操作。');
    process.exit(2);
  }
  const rows = all(sql);
  if (asJson) console.log(JSON.stringify(rows, null, 2));
  else if (rows.length) console.table(rows);
  else console.log('(空结果)');
  db.close();
  process.exit(0);
}

// ── 直接搜原文（不经过 FTS，用于排查"索引坏了"）─────────────────────────────
if (show) {
  const like = `%${show}%`;
  const rows = all(
    `select session_id, seq, role, datetime(created_at/1000,'unixepoch','localtime') t,
            substr(text,1,300) snippet
       from messages where text like ? order by created_at desc limit 20`,
    like
  );
  if (!rows.length) {
    console.log(`消息表里没有包含「${show}」的内容（说明确实没归档进来，不是索引问题）。`);
  } else if (asJson) {
    console.log(JSON.stringify(rows, null, 2));
  } else {
    console.table(rows);
  }
  db.close();
  process.exit(0);
}

// ── 体检报告 ───────────────────────────────────────────────────────────────
const report = {
  file: dbPath,
  bytes: fs.statSync(dbPath).size,
  integrity: one('PRAGMA integrity_check').integrity_check,
  schema_version: (() => { try { return one("select value v from meta where key='schema_version'").v; } catch { return null; } })(),
  counts: {},
  sessions: [],
  summary_tree: [],
  biggest_artifacts: [],
  warnings: [],
};

for (const t of ['sessions', 'messages', 'summary_nodes', 'summary_edges', 'artifacts', 'artifact_blobs', 'resumes', 'events']) {
  report.counts[t] = count(t);
}

// FTS 是否可用 + 文档数是否和消息数一致
try {
  report.counts.message_fts = one('select count(*) c from message_fts').c;
} catch (e) {
  report.counts.message_fts = null;
  report.warnings.push(`FTS 不可用：${e.message}`);
}

report.sessions = all(
  `select s.session_id, s.cwd,
          (select count(*) from messages m where m.session_id = s.session_id) msgs,
          (select max(created_at) from messages m where m.session_id = s.session_id) newest,
          s.pinned, s.compacted_at
     from sessions s
     order by coalesce(newest, s.updated_at) desc
     limit 15`
);

report.summary_tree = all(
  `select session_id, level, count(*) nodes
     from summary_nodes group by session_id, level
     order by session_id, level`
);

report.biggest_artifacts = all(
  `select artifact_id, char_count, substr(preview_text,1,80) preview
     from artifacts order by char_count desc limit 5`
);

// ── 一致性检查 ─────────────────────────────────────────────────────────────
if (report.counts.messages != null && report.counts.message_fts != null &&
    report.counts.messages !== report.counts.message_fts) {
  report.warnings.push(
    `消息数(${report.counts.messages}) 与 FTS 文档数(${report.counts.message_fts}) 不一致 → 在 DSH 里跑 /lcm doctor apply`
  );
}
if (report.counts.messages === 0) {
  report.warnings.push('归档里一条消息都没有 → 检查插件是否加载、是否重启过 DSH');
}
if (report.integrity !== 'ok') {
  report.warnings.push(`SQLite 完整性检查未通过：${report.integrity}`);
}
const orphan = (() => {
  try { return one('select count(*) c from artifact_blobs where orphaned_at is not null').c; } catch { return 0; }
})();
if (orphan > 50) report.warnings.push(`有 ${orphan} 个可回收的孤儿 blob → 在 DSH 里跑 /lcm gc apply`);

if (asJson) {
  console.log(JSON.stringify(report, null, 2));
} else {
  console.log('\n=== lcm 归档体检 ===');
  console.log(`文件        ${report.file}`);
  console.log(`大小        ${(report.bytes / 1024 / 1024).toFixed(2)} MB`);
  console.log(`schema      v${report.schema_version ?? '?'}`);
  console.log(`完整性      ${report.integrity}`);
  console.log('\n计数');
  for (const [k, v] of Object.entries(report.counts)) console.log(`  ${k.padEnd(16)} ${v ?? 'n/a'}`);
  console.log('\n会话（最近 15 个）');
  console.table(report.sessions.map((s) => ({
    session: s.session_id.slice(0, 22),
    msgs: s.msgs,
    pinned: s.pinned ? 'yes' : '',
    compacted: s.compacted_at ? 'yes' : '',
    cwd: (s.cwd ?? '').slice(-28),
  })));
  if (report.summary_tree.length) {
    console.log('摘要树');
    console.table(report.summary_tree.map((r) => ({ session: r.session_id.slice(0, 22), level: r.level, nodes: r.nodes })));
  }
  if (report.biggest_artifacts.length && report.biggest_artifacts[0].char_count > 0) {
    console.log('最大的 artifact');
    console.table(report.biggest_artifacts);
  }
  if (report.warnings.length) {
    console.log('\n⚠ 需要注意');
    for (const w of report.warnings) console.log(`  · ${w}`);
  } else {
    console.log('\n✓ 没有发现问题');
  }
  console.log('');
}

db.close();
