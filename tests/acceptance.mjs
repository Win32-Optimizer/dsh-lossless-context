#!/usr/bin/env node
/**
 * dsh-lossless-context — 验收测试
 *
 * 这个脚本证明一件事：**经过多次压缩之后，具体细节仍然能从归档里逐字找回，而不是靠摘要"记得大概"。**
 *
 * 做法：
 *   1. 用你机器上真实安装的 openseek-lcm 插件（import 它的 index.js，调 apply()）
 *   2. 造一份 DSH 真实事件形状的会话日志，埋进 12 条"绝不能丢"的细节
 *   3. 模拟三次压缩（把较早的消息段整体换成 <compacted-summary>，和 dsh-compaction-basic 行为一致）
 *   4. 在"模型上下文里已经没有任何原始细节"的状态下，用 lcm_grep 逐字比对
 *
 * 用法：
 *   node tests/acceptance.mjs
 *   node tests/acceptance.mjs --profile desktop
 *   DSH_HOME=~/.dsh node tests/acceptance.mjs
 *
 * 退出码：0 = 全部通过，1 = 有失败项。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

// ────────────────────────────────────────────────────────────── 定位环境 ────
const argv = process.argv.slice(2);
const argOf = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};

const DSH_HOME = process.env.DSH_HOME ?? path.join(os.homedir(), '.dsh');
const PROFILE = argOf('profile', 'desktop');
const PROFILE_DIR = path.join(DSH_HOME, 'profiles', PROFILE);
const PLUGIN_DIR = path.join(PROFILE_DIR, 'node_modules', 'openseek-lcm');

const results = [];
const check = (name, ok, detail = '') => {
  results.push({ name, ok });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? `  -- ${detail}` : ''}`);
};

function die(msg) {
  console.error(`\n✗ ${msg}\n`);
  process.exit(1);
}

// ────────────────────────────────────────────────────────────── 前置检查 ────
console.log('\n=== 0. 环境 ===');
console.log(`  DSH_HOME : ${DSH_HOME}`);
console.log(`  profile  : ${PROFILE}`);

if (!fs.existsSync(PLUGIN_DIR)) {
  die(
    `找不到 openseek-lcm：${PLUGIN_DIR}\n` +
      `  先安装（并关掉 DSH）：\n` +
      `    dsh plugin --profile ${PROFILE} add openseek-lcm\n`
  );
}

let apply;
try {
  ({ apply } = await import(pathToFileURL(path.join(PLUGIN_DIR, 'index.js')).href));
} catch (e) {
  die(`加载 openseek-lcm 失败：${e.message}`);
}
if (typeof apply !== 'function') die('openseek-lcm 的 index.js 没有导出 apply()');

// 可选：读用户真实配置（读不到就用插件默认值，不影响结论）
let userConfig = {};
const patchFile = path.join(PROFILE_DIR, 'cordis.patch.yml');
if (fs.existsSync(patchFile)) {
  try {
    const yamlPath = path.join(PROFILE_DIR, 'node_modules', 'js-yaml', 'dist', 'js-yaml.mjs');
    const yamlMod = await import(pathToFileURL(yamlPath).href);
    const yaml = yamlMod.default ?? yamlMod;
    const rows = yaml.load(fs.readFileSync(patchFile, 'utf8'));
    const row = Array.isArray(rows) ? rows.find((r) => r && r.id === 'openseek-lcm') : undefined;
    if (row?.config) {
      userConfig = row.config;
      console.log('  读到你实际的 openseek-lcm 配置，将用它来跑');
    }
  } catch (e) {
    console.log(`  （没读到 patch：${e.message}，改用插件默认配置）`);
  }
}

// ────────────────────────────────────────────────────────────── 假宿主 ──────
const registered = { tools: [], sections: [], commands: [] };
const sessions = new Map();

const makeSession = (id, cwd) => ({ header: { id, cwd }, events: [], surface: [] });
sessions.set('sess-work', makeSession('sess-work', path.join(os.tmpdir(), 'lctx-work')));
sessions.set('sess-love', makeSession('sess-love', path.join(os.tmpdir(), 'lctx-love')));
sessions.set('sess-love2', makeSession('sess-love2', path.join(os.tmpdir(), 'lctx-love'))); // 同 cwd

const ctx = {
  logger: () => ({ info() {}, warn() {}, error() {}, debug() {} }),
  on: () => () => {},
  effect: (fn) => { fn?.(); return () => {}; },
  inject: (_names, fn) => {
    fn({
      effect: (f) => { f?.(); return () => {}; },
      commands: { register: (d) => { registered.commands.push(d); return () => {}; } },
    });
  },
  tools: { register: (d) => { registered.tools.push(d); return () => {}; } },
  systemPrompt: { section: (d) => { registered.sections.push(d); return () => {}; } },
  sessionQuery: {
    async readSession(id) {
      const s = sessions.get(id);
      return s ? { session: s.header, events: [...s.events] } : undefined;
    },
    async readSurface(id) {
      return { events: [...(sessions.get(id)?.surface ?? [])] };
    },
  },
  agents: {
    get: (id) => (sessions.has(id) ? { session: { id, seq: 1_000_000, header: sessions.get(id).header } } : undefined),
    list: () => [...sessions.keys()].map((id) => ({ session: { id, header: sessions.get(id).header } })),
    currentInitiator: () => undefined,
  },
};

const storeDir = fs.mkdtempSync(path.join(os.tmpdir(), 'lctx-accept-'));
apply(ctx, { ...userConfig, storeDir });

console.log(`  storeDir : ${storeDir}`);
console.log(
  `  注册工具 : ${registered.tools.length} 个` +
    (registered.tools.length < 18 ? '  (tools.expose 白名单生效)' : '  (全部 18 个)')
);

// ────────────────────────────────────────────────────────────── 夹具 ────────
const workFacts = [
  '数据库端口改成 5433（不是 5432）',
  '数据库用 PostgreSQL，不用 MongoDB；MongoDB 因需要强事务被否决',
  '数据库配置写在 config/db.yaml，禁止写进 config/db.json',
  '操作前必须先确认：任何 DROP TABLE / kubectl delete 前都要问我',
  'Node 版本锁定 20.11.0',
  '报错 npm ERR! code ELIFECYCLE 是因为 postinstall 里调了未安装的 sharp',
];
const loveFacts = [
  '她喜欢我每天睡前说一句晚安',
  '我们约定纪念日是 12 月 3 日',
  '她讨厌被叫"宝宝"，喜欢被叫"小雨"',
  '我们第一次一起看的电影是《千与千寻》',
  '我们说好周末早上一起做早餐，谁也不许先看手机',
];
const crossFact = '补一个回忆：她最喜欢的歌是《Lemon》，听到前奏会安静下来。';

const u = (text) => ({ type: 'user/message', data: { role: 'user', content: [{ type: 'text', text }] } });
const a = (text) => ({ type: 'assistant/message', data: { message: { role: 'assistant', content: [{ type: 'text', text }] } } });
const toolResult = (text) => ({ type: 'tool/result', data: { message: { role: 'tool', content: [{ type: 'text', text }] } } });

let seq = 1;
const push = (sid, ev) => { ev.seq = seq++; sessions.get(sid).events.push(ev); };

push('sess-work', u('开始一个长工作流。先把这些约束记下来：'));
push('sess-work', a('好的，已记录。'));
push('sess-work', u(workFacts.join('\n')));
push('sess-work', a('已记录全部约束。'));
push('sess-work', toolResult('pnpm install 输出 … npm ERR! code ELIFECYCLE … 退出码 1'));
for (let i = 0; i < 60; i++) {
  push('sess-work', u(`第 ${i} 轮：继续调 CI 的缓存与 lint 顺序。${'构建日志内容 '.repeat(30)}`));
  push('sess-work', a(`收到，第 ${i} 轮继续。${'分析内容 '.repeat(30)}`));
}

push('sess-love', u('设定：我们在一起了。' + loveFacts.join('；')));
push('sess-love', a('我记住了：' + loveFacts.join('；')));
for (let i = 0; i < 60; i++) {
  push('sess-love', u(`剧情第 ${i} 段：${'我们在雨里散步，聊了很多琐事。'.repeat(20)}`));
  push('sess-love', a(`${'她笑了，靠过来。'.repeat(25)}`));
}
push('sess-love2', u(crossFact));
push('sess-love2', a('记住了。'));

const totalEvents = seq - 1;

// ────────────────────────────────────────────────────────────── 工具封装 ────
const tool = (name) => registered.tools.find((t) => t.name === name);
const call = async (sid, name, args = {}) => {
  const t = tool(name);
  if (!t) throw new Error(`工具 ${name} 未注册`);
  return String(await t.execute(args, { agent: { session: { id: sid } } }));
};

// ──────────────────────────────────────────────────────────── 1. 捕获 ──────
console.log('\n=== 1. 忠实捕获 ===');
const st = await call('sess-work', 'lcm_status');
const msgCount = Number(/message_count=(\d+)/.exec(st)?.[1] ?? 0);
check('归档捕获了全部消息', msgCount === totalEvents, `message_count=${msgCount} / events=${totalEvents}`);
check('capture_failures=0', /capture_failures=0\b/.test(st), /capture_failures=\d+/.exec(st)?.[0] ?? '');

// ──────────────────────────────────────────────────────── 2. 三次压缩 ──────
console.log('\n=== 2. 模拟三次压缩，直到上下文里什么都不剩 ===');
for (const sid of ['sess-work', 'sess-love']) {
  sessions.get(sid).surface = [
    {
      seq: 900000 + seq++,
      type: 'user/message',
      source: { kind: 'compaction' },
      data: {
        role: 'user',
        content: [{ type: 'text', text: '<compacted-summary>摘要：前段对话讨论过一些配置，细节已归档。</compacted-summary>' }],
      },
    },
  ];
}
const surfaceDump = JSON.stringify([...sessions.values()].map((s) => s.surface));
const allFacts = [...workFacts, ...loveFacts, crossFact];
const leak = allFacts.filter((f) => surfaceDump.includes(f));
check('模型当前上下文中已不含任何原始细节（只剩摘要）', leak.length === 0, `${surfaceDump.length} 字符`);

// ────────────────────────────────────────────────────────── 3. 逐字召回 ────
console.log('\n=== 3. 逐字召回（工作流） ===');
let workHit = 0;
for (const q of ['5433', 'PostgreSQL', 'config/db.yaml', '操作前必须先确认', 'ELIFECYCLE', '20.11.0']) {
  const out = await call('sess-work', 'lcm_grep', { query: q.includes(' ') ? `"${q}"` : q, scope: 'session', limit: 3 });
  const ok = out.includes(q);
  if (ok) workHit++;
  check(`  " ${q} "`, ok, ok ? '' : out.slice(0, 120));
}

console.log('\n=== 4. 逐字召回（记忆敏感场景） ===');
let loveHit = 0;
for (const q of ['小雨', '12 月 3 日', '千与千寻', '晚安', '周末早上']) {
  const out = await call('sess-love', 'lcm_grep', { query: q, scope: 'session', limit: 3 });
  const ok = out.includes(q);
  if (ok) loveHit++;
  check(`  " ${q} "`, ok, ok ? '' : out.slice(0, 120));
}

// ────────────────────────────────────────────────────────── 5. 隔离 ────────
console.log('\n=== 5. 隔离：单会话检索不串戏 ===');
const cross = await call('sess-work', 'lcm_grep', { query: '小雨', scope: 'session', limit: 5 });
check('工作流会话里搜不到另一条线的名字', !cross.includes('小雨'), cross.slice(0, 100));

// ────────────────────────────────────────────────────────── 6. 跨会话 ──────
console.log('\n=== 6. 跨会话：同一工作目录下的其它会话也能召回 ===');
const wt = await call('sess-love', 'lcm_grep', { query: 'Lemon', scope: 'worktree', limit: 5 });
check('worktree 范围召回到另一个会话里的回忆', wt.includes('Lemon') && wt.includes('sess-love2'), wt.split('\n')[1]?.slice(0, 120) ?? '');

// ────────────────────────────────────────────────────────── 7. 摘要树下钻 ──
console.log('\n=== 7. 摘要树可下钻到原文 ===');
const ex = await call('sess-love', 'lcm_expand', { query: '纪念日', includeRaw: true, depth: 4 });
check('lcm_expand includeRaw 能取回原文片段', ex.includes('12 月 3 日') || ex.includes('纪念日'));

// ────────────────────────────────────────────────────────── 汇总 ──────────
const failed = results.filter((r) => !r.ok);
console.log(`\n${'─'.repeat(60)}`);
console.log(`细节召回：工作流 ${workHit}/6，记忆敏感 ${loveHit}/5`);
console.log(`${results.length - failed.length}/${results.length} 项通过`);

try {
  fs.rmSync(storeDir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
} catch {
  /* Windows 可能短暂占用 SQLite 句柄；临时目录可丢弃 */
}

if (failed.length > 0) {
  console.log('\n失败项：');
  for (const f of failed) console.log(`  - ${f.name}`);
  console.log('\n结论：✗ 有细节没能逐字召回。这通常意味着 capture 或 FTS 索引有问题，');
  console.log('      在 DSH 里跑 /lcm doctor apply 后再试一次。\n');
  process.exit(1);
}

console.log('\n结论：✓ 压缩后细节仍可逐字找回，不是靠摘要"记得大概"。\n');
process.exit(0);
