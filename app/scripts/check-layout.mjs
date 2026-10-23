#!/usr/bin/env node
/**
 * 首页卡片布局检查器（docs/LAYOUT.md 的可执行部分）
 * 用法：node scripts/check-layout.mjs   退出码 0=PASS / 1=FAIL
 *
 * 规则来源：这套布局被改坏过 8 次，每条断言都对应一次真实事故。
 * 容器：Grid + columnsTemplate('1fr 1fr') + rowsGap + GridItemAlignment.STRETCH
 * 卡片：width('100%')，禁止任何 height / minHeight / 自带 margin
 */

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const HERE = dirname(fileURLToPath(import.meta.url))
const STATUS = join(HERE, '..', 'entry/src/main/ets/view/StatusView.ets')
const CARD_COMP = join(HERE, '..', 'entry/src/main/ets/components/StatCard.ets')

const src = readFileSync(STATUS, 'utf8').replace(/\r\n/g, '\n')
const cardSrc = readFileSync(CARD_COMP, 'utf8').replace(/\r\n/g, '\n')
const passes = []
const failures = []
const warns = []

const ok = (m) => passes.push(m)
const bad = (m, hint) => failures.push(hint ? `${m}\n    ↳ ${hint}` : m)

/** 抽函数体（花括号配对） */
function extractBody(sig) {
  const idx = src.indexOf(sig)
  if (idx < 0) return null
  const brace = src.indexOf('{', idx)
  if (brace < 0) return null
  let depth = 0
  for (let i = brace; i < src.length; i++) {
    if (src[i] === '{') depth++
    else if (src[i] === '}') {
      depth--
      if (depth === 0) return src.slice(idx, i + 1)
    }
  }
  return null
}

// ── 1. 容器：Grid（两列）+ STRETCH（行内等高）─────────────────────────
const hasGrid = /Grid\(\)\s*\{/.test(src)
const hasCols = /\.columnsTemplate\('1fr 1fr'\)/.test(src)
const hasStretch = /\.alignItems\(GridItemAlignment\.STRETCH\)/.test(src)
const hasRowsGap = /\.rowsGap\(CARD_GAP\)/.test(src)
const hasColsGap = /\.columnsGap\(CARD_GAP\)/.test(src)

if (hasGrid && hasCols && hasStretch) {
  ok('容器是 Grid + columnsTemplate(1fr 1fr) + GridItemAlignment.STRETCH')
} else {
  bad('卡片容器不符合规范',
      `Grid=${hasGrid} columnsTemplate=${hasCols} STRETCH=${hasStretch}；` +
      "必须是 Grid() { 6×GridItem } + columnsTemplate('1fr 1fr') + " +
      'columnsGap(CARD_GAP) + rowsGap(CARD_GAP) + alignItems(GridItemAlignment.STRETCH)。' +
      'Grid 的格子才是行内天然等高的；Flex 换行下 Stretch 不生效')
}
if (hasRowsGap) ok('行间距 = Grid.rowsGap(CARD_GAP)')
else bad('缺少 .rowsGap(CARD_GAP)', '行距必须由 Grid 统一控制')
if (hasColsGap) ok('列间距 = Grid.columnsGap(CARD_GAP)')
else bad('缺少 .columnsGap(CARD_GAP)', '列距必须由 Grid 统一控制')

// ── 2. 不得残留 Flex 卡片网格 ────────────────────────────────────────
if (/Flex\(\{\s*wrap:\s*FlexWrap\.Wrap/.test(src)) {
  bad('源码里还有 Flex(wrap) 卡片网格', 'Flex 换行下 Stretch 不生效，改用 Grid')
} else {
  ok('没有残留的 Flex 卡片网格')
}

// ── 3. 卡片组件 StatCard：width 100%，无 height，无自带 margin ────────
if (cardSrc.includes(".width('100%')")) ok('StatCard 宽度 100%（占满网格单元）')
else bad('StatCard 缺少 .width(\'100%\')', '宽度由 Grid 的 columnsTemplate 决定')

if (/\.height\(/.test(cardSrc)) bad('StatCard 里出现 height', '高度必须由同行最高卡决定（STRETCH）')
else ok('StatCard 没有 height')

if (/\.constraintSize\(\{\s*minHeight/.test(cardSrc)) bad('StatCard 里出现 minHeight', '交给 STRETCH')
else ok('StatCard 没有 minHeight')

if (/\.margin\(\{\s*bottom:\s*CARD_GAP\s*\}\)/.test(cardSrc)) {
  bad('StatCard 自带 margin(bottom)', '会与 rowsGap 叠加导致间距翻倍；间距只用 Grid 的 gap')
} else {
  ok('StatCard 没有自带行间距')
}

if (/export const CARD_GAP:\s*number\s*=\s*10/.test(cardSrc)) ok('CARD_GAP 常量定义在组件文件 ✓')
else bad('组件文件缺少 CARD_GAP 常量')

// ── 3.7 段落间距：三处大卡/网格之间必须有 margin(bottom: CARD_GAP) ──────
// 这三个是从"整页无间隙"事故里恢复出来的，不能被后续改动删掉
const gapCount = (src.match(/\.margin\(\{\s*bottom:\s*CARD_GAP\s*\}\)/g) || []).length
if (gapCount >= 3) ok(`段落间距 margin(bottom: CARD_GAP) 共 ${gapCount} 处（TSB / hrvCard / Grid）`)
else bad(`段落间距 margin(bottom: CARD_GAP) 只有 ${gapCount} 处，应为 3 处`,
         'TSB 卡、hrvCard、Grid 各自都需要，缺一个就会出现某两段紧贴')

if (/^s+\.margin\(\{\s*top:\s*8\s*\}\)/m.test(src) && /sleepStages/.test(src)) {
  bad('sleepStages 里还有 margin(top) 类残留', '会与 Grid 的 margin(bottom) 叠加，间距翻倍')
} else {
  ok('sleepStages 没有叠加 margin(top)')
}

// ── 3.8 FAB 安全区：滚动内容底部必须留出悬浮按钮的空间 ──────────────
if (/padding\(\{\s*left:\s*12,\s*right:\s*12,\s*bottom:\s*96\s*\}\)/.test(src)) {
  ok('滚动内容有底部安全区 96（避免 FAB 遮挡最后一张卡）')
} else {
  bad('滚动内容缺少底部安全区', '应写成 .padding({ left: 12, right: 12, bottom: 96 })，否则悬浮对话按钮会盖住底部卡片')
}

// ── 4. 卡片数量与两列排布 ────────────────────────────────────────────
const cardCalls = (src.match(/StatCard\(\{/g) || []).length
const bbCalls = 0 // bbCard 已并入 StatCard（accent 模式）
const total = cardCalls + bbCalls
if (total === 6) ok('卡片数量 6（3 行 × 2 列）')
else bad(`卡片数量是 ${total}，与规范记录的 6 张不一致`, '增删卡片后请同步更新 docs/LAYOUT.md 第 6 节顺序表')
if (total % 2 === 0) ok('卡片数量为偶数，两列可整齐排布')
else bad('卡片数量为奇数，最后一行会留半格空洞')

// ── 5. 警告：其他 Builder 里按值传状态（历史事故模式）────────────────
const re = /this\.(metric\w+|leftRow\w*|rightItem)\(([^)]*)\)/g
let m
while ((m = re.exec(src)) !== null) {
  if (/\bthis\.\w+/.test(m[2])) warns.push(`this.${m[1]}(${m[2].slice(0, 60)})`)
}

// ── 输出 ─────────────────────────────────────────────────────────────
console.log('')
console.log('══ 首页卡片布局检查 ══')
console.log(`文件: ${STATUS}`)
console.log('')
for (const p of passes) console.log(`  ✅ ${p}`)
if (warns.length > 0) {
  console.log('')
  for (const w of warns) console.log(`  ⚠️  ${w}  （按值传状态，历史事故模式，请复核）`)
}
if (failures.length > 0) {
  console.log('')
  for (const f of failures) console.log(`  ❌ ${f}\n`)
  console.log(`结果: FAIL（${failures.length} 项违反规范）`)
  console.log('规范: docs/LAYOUT.md')
  process.exit(1)
}
console.log('')
console.log(`结果: PASS（${passes.length} 项检查全部通过）`)
