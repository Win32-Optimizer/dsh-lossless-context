#!/usr/bin/env node
/**
 * dsh-lossless-context — 成本模型
 *
 * 回答一个问题：相比「每轮重发全部历史」，这套方案大概省多少？
 *
 * 三个场景：
 *   A  不开缓存，每轮重发全部历史
 *   B  开了 DeepSeek 上下文硬盘缓存，每轮重发全部历史
 *   C  B + 压缩（旧历史折成检查点，只保留逐字尾部）
 *
 * 注意：这里的数字是**计费输入 token**，不是"上下文有多大"。
 * 缓存不减少请求里的 token 数，它改变的是单价。
 *
 * 用法：
 *   node tests/cost-model.mjs
 *   node tests/cost-model.mjs --threshold 629145 --retain 277401
 */
const argOf = (n, d) => {
  const i = process.argv.indexOf(`--${n}`);
  return i >= 0 && process.argv[i + 1] ? Number(process.argv[i + 1]) : d;
};

// deepseek-flash 官方价（元 / 百万 token）
const PRICE = {
  flash_peak: { hit: 0.04, miss: 2, out: 8 },
  flash_idle: { hit: 0.02, miss: 1, out: 4 },
  v4pro_peak: { hit: 0.3, miss: 9, out: 27 },
  v4pro_idle: { hit: 0.15, miss: 4.5, out: 13.5 },
};

// 默认值对应 balanced 档（thresholdRatio 0.75 / retainRatio 0.15）
const W = 1048576;                 // deepseek-flash 上下文窗口
const THRESHOLD = argOf('threshold', 768000);
const RETAIN = argOf('retain', 118886);
const SUMMARY_TOKENS = 4000;       // 一个检查点大约多大

function simulate({ turns, tokensPerTurn = 3000, cacheOn = true, compactOn = true, newSuffix = 1200, hitDecay = 0.55 }) {
  let prefixBlocks = 0;
  let context = 0;
  const acc = { requests: 0, input: 0, miss: 0, hit: 0, compactionMiss: 0, compactions: 0, maxContext: 0 };

  for (let t = 1; t <= turns; t++) {
    if (compactOn && context + tokensPerTurn > THRESHOLD) {
      acc.compactionMiss += Math.min(context, THRESHOLD);
      acc.compactions++;
      context = RETAIN + SUMMARY_TOKENS;
      prefixBlocks = 0;
    }
    const hit = cacheOn ? Math.floor(prefixBlocks * hitDecay) : 0;
    const miss = context - hit + newSuffix;
    acc.requests++;
    acc.input += context + newSuffix;
    acc.hit += hit;
    acc.miss += miss;
    context += tokensPerTurn;
    prefixBlocks = context;
    acc.maxContext = Math.max(acc.maxContext, context);
  }
  return acc;
}

const money = (acc, p) => (acc.miss / 1e6) * p.miss + (acc.hit / 1e6) * p.hit + (acc.compactionMiss / 1e6) * p.miss;

console.log('\ndsh-lossless-context · 成本模型');
console.log(`  压缩水位 ${THRESHOLD.toLocaleString()} token，逐字尾部 ${RETAIN.toLocaleString()} token`);
console.log('  价格取 deepseek-flash 高峰档：命中 ¥0.04/M，未命中 ¥2/M\n');

const scenarios = [
  ['A  全量重发 · 不开缓存      ', { cacheOn: false, compactOn: false }],
  ['B  全量重发 · 开缓存        ', { cacheOn: true, compactOn: false }],
  ['C  本方案（压缩+缓存）      ', { cacheOn: true, compactOn: true }],
];

for (const turns of [150, 400, 1000]) {
  console.log(`─── 约 ${turns} 轮会话（每轮新增 ~3,000 token）`);
  const rows = scenarios.map(([label, opt]) => {
    const acc = simulate({ turns, ...opt });
    return { label, acc, cost: money(acc, PRICE.flash_peak) };
  });
  const base = rows[0];
  for (const r of rows) {
    const dInput = ((r.acc.input - base.acc.input) / base.acc.input) * -100;
    const dCost = ((r.cost - base.cost) / base.cost) * -100;
    console.log(
      `  ${r.label} 计费输入=${(r.acc.input / 1e6).toFixed(2)}M` +
        `  miss=${(r.acc.miss / 1e6).toFixed(2)}M hit=${(r.acc.hit / 1e6).toFixed(2)}M` +
        `  压缩${String(r.acc.compactions).padStart(2)}次` +
        `  ¥${r.cost.toFixed(2).padStart(8)}` +
        `  vs A: 输入${dInput.toFixed(0)}% / 费用${dCost.toFixed(0)}%`
    );
  }
  console.log('');
}

console.log('读这张表要注意：');
console.log('  · 「输入 token 变少」来自压缩；「钱变少」的大头来自缓存（命中价是未命中的 1/50）。');
console.log('  · 短会话（150 轮以内）压缩帮不上忙 —— 根本没到水位。');
console.log('  · 压缩后每轮仍有固定下限：检查点 + 逐字尾部 ≈ '
  + ((RETAIN + SUMMARY_TOKENS) / 1000).toFixed(0) + 'K token。');
console.log('  · 想更省：先降 retainRatio，别先动 thresholdRatio（水位一低压缩更勤，反而更贵）。\n');
