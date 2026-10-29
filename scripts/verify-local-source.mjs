/**
 * 验证「手机直连」与「后端」两条通道的数据是否逐项等价。
 *
 * USAGE:
 *   # 后端（默认本机 43121）
 *   GARMIN_DASH_BASE=http://127.0.0.1:43121/garmin-dash/api \n *   GARMIN_DASH_KEY=<你的 deviceKey> \n *   node scripts/verify-local-source.mjs
 *
 * 说明：脚本走的是插件自带的 garmin-direct.mjs（直连佳明），
 * 与后端 /api/* 做 16 项对比；全部一致说明端上移植的语义没走样。
 */
// 验证 GarminLocalSource 的移植语义 == 后端语义：用直连复刻一遍，与后端结果逐项对比
import { garminGet, resolveDisplayName } from '../lib/garmin-direct.mjs'
import { readFileSync } from 'node:fs'

const BASE = process.env.GARMIN_DASH_BASE || 'http://127.0.0.1:43121/garmin-dash/api'
const KEY = process.env.GARMIN_DASH_KEY || readFileSync('E:/DSH-Garmin/.diag-key', 'utf8').trim()

function today() {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}
const D = today()

async function backend(path) {
  const res = await fetch(BASE + path, { headers: { 'X-Device-Key': KEY } })
  return res.status === 200 ? await res.json() : { __code: res.status }
}

const CTL_TAU = 42
const ATL_TAU = 7
const round1 = (x) => Math.round(x * 10) / 10
const addDays = (date, delta) => {
  const [y, m, d] = date.split('-').map(Number)
  const dt = new Date(y, m - 1, d)
  dt.setDate(dt.getDate() + delta)
  return `${dt.getFullYear()}-${String(dt.getMonth() + 1).padStart(2, '0')}-${String(dt.getDate()).padStart(2, '0')}`
}
const dateRange = (start, end) => {
  const out = []
  let c = start
  for (let i = 0; i < 10000; i++) { out.push(c); if (c >= end) break; c = addDays(c, 1) }
  return out
}

// ── 本地复刻 ──────────────────────────────────────────────
async function localSummary(date) {
  let daily = null
  try {
    const dn = await resolveDisplayName()
    daily = await garminGet(`/usersummary-service/usersummary/daily/${encodeURIComponent(dn)}?calendarDate=${date}`)
  } catch { daily = null }

  let sleepMin = null
  try {
    const s = await garminGet(`/sleep-service/sleep/dailySleepData?date=${date}`)
    const dto = s?.dailySleepDTO
    if (dto) sleepMin = Math.round((dto.sleepTimeSeconds ?? 0) / 60)
  } catch { sleepMin = null }

  let bb = null
  try {
    const arr = await garminGet(`/usersummary-service/stats/bodybattery/daily/${date}/${date}`)
    bb = arr?.[0]?.values?.highBodyBattery ?? arr?.[0]?.values?.lowBodyBattery ?? null
  } catch { bb = null }

  return { steps: daily?.totalSteps ?? null, rhr: daily?.restingHeartRate ?? null, sleepMin, bb }
}

async function localHrv(date) {
  const paths = ['/hrv-service/hrv/', '/hrv-service/hrv/daily/', '/wellness-service/wellness/dailyHrv/']
  const one = async (d) => {
    for (const p of paths) {
      try {
        const j = await garminGet(p + d)
        const s = j?.hrvSummary ?? j
        if (s?.lastNightAvg != null) return { lastNight: s.lastNightAvg, status: s.status ?? null }
      } catch { /* next */ }
    }
    return null
  }
  const t = await one(date)
  if (t) return { ...t, backfilled: false }
  for (let i = 1; i <= 7; i++) {
    const g = await one(addDays(date, -i))
    if (g) return { ...g, backfilled: true }
  }
  return null
}

async function localBodyBattery(date) {
  const arr = await garminGet(`/usersummary-service/stats/bodybattery/daily/${date}/${date}`)
  const v = arr?.[0]?.values ?? {}
  return { available: v.highBodyBattery != null, value: v.highBodyBattery ?? v.lowBodyBattery ?? null, high: v.highBodyBattery ?? null, low: v.lowBodyBattery ?? null }
}

async function localCurve(days) {
  const secs = [1, 2, 5, 10, 20, 30, 60, 120, 300, 600, 1200, 1800, 3600, 7200, 18000]
  const p42 = secs.map(() => 0), p90 = secs.map(() => 0), pall = secs.map(() => 0)
  const now = new Date()
  const c42 = addDays(today(), -42), c90 = addDays(today(), -90)
  const picks = []
  let scanned = 0
  let pages = 0
  for (let page = 0; page < 4; page++) {
    let arr = []
    try { arr = await garminGet(`/activitylist-service/activities/search/activities?start=${page * 100}&limit=100`) } catch { break }
    if (!Array.isArray(arr) || arr.length === 0) break
    scanned += arr.length
    pages++
    for (const a of arr) {
      if (a?.normPower != null && a?.avgPower != null) picks.push(a)
    }
    if (picks.length >= 100 || arr.length < 100) break
  }
  let used = 0
  for (const p of picks.slice(0, 80)) {
    const date = String(p.startTimeLocal ?? '').slice(0, 10)
    if (!date) continue
    const hasAnyCurve = secs.some((s) => typeof p[`maxAvgPower_${s}`] === 'number')
    if (!hasAnyCurve) continue
    used++
    for (let k = 0; k < secs.length; k++) {
      const v = p[`maxAvgPower_${secs[k]}`]
      if (typeof v !== 'number' || v <= 0) continue
      if (date >= c42 && v > p42[k]) p42[k] = v
      if (date >= c90 && v > p90[k]) p90[k] = v
      if (v > pall[k]) pall[k] = v
    }
  }
  const eftp = (a) => (a[10] > 0 ? Math.round(a[10] * 0.95) : null)
  return { count: used, scanned, pages, e90: eftp(p90), p90_1s: p90[0] }
}

async function localTrend(days) {
  const span = Math.max(7, Math.min(365, days))
  const end = today()
  const start = addDays(end, -(span - 1))
  const warmupStart = addDays(start, -120)
  const tss = new Map()
  for (let page = 0; page < 12; page++) {
    let arr = []
    try { arr = await garminGet(`/activitylist-service/activities/search/activities?start=${page * 50}&limit=50`) } catch { break }
    if (!Array.isArray(arr) || arr.length === 0) break
    let reached = false
    for (const a of arr) {
      const d = String(a.startTimeLocal ?? '').slice(0, 10)
      if (!d) continue
      if (d < warmupStart) { reached = true; continue }
      if (d > end) continue
      const v = Number(a.trainingStressScore ?? a.activityTrainingLoad ?? 0)
      tss.set(d, (tss.get(d) ?? 0) + (Number.isFinite(v) && v > 0 ? v : 0))
    }
    if (reached || arr.length < 50) break
  }
  let ctl = 0, atl = 0, atlPrev = 0
  let last = null
  for (const date of dateRange(warmupStart, end)) {
    const t = tss.get(date) ?? 0
    ctl = ctl + (t - ctl) / CTL_TAU
    atl = atl + (t - atl) / ATL_TAU
    if (date < start) { atlPrev = round1(atl); continue }
    last = { date, tss: round1(t), ctl: round1(ctl), atl: round1(atl), tsb: round1(round1(ctl) - atlPrev) }
    atlPrev = round1(atl)
  }
  return { points: dateRange(start, end).length, last }
}

// ── 对比 ─────────────────────────────────────────────────
const rows = []
const cmp = (label, local, remote, detail) => rows.push({ label, local, remote, ok: detail, })

const bSum = await backend(`/summary?date=${D}`)
const lSum = await localSummary(D)
cmp('summary.steps', lSum.steps, bSum.steps, lSum.steps === bSum.steps)
cmp('summary.rhr', lSum.rhr, bSum.restingHeartRate, lSum.rhr === bSum.restingHeartRate)
cmp('summary.sleepMin', lSum.sleepMin, bSum.sleep ? bSum.sleep.durationMinutes : null,
  lSum.sleepMin === (bSum.sleep ? bSum.sleep.durationMinutes : null))
cmp('summary.bodyBattery', lSum.bb, bSum.bodyBattery, lSum.bb === bSum.bodyBattery)

const bHrv = await backend(`/hrv?date=${D}`)
const lHrv = await localHrv(D)
cmp('hrv.lastNight', lHrv ? lHrv.lastNight : null, bHrv.lastNightAvg,
  (lHrv ? lHrv.lastNight : null) === bHrv.lastNightAvg)
cmp('hrv.status', lHrv ? lHrv.status : null, bHrv.status, (lHrv ? lHrv.status : null) === bHrv.status)

const bBb = await backend(`/body-battery?date=${D}`)
const lBb = await localBodyBattery(D)
cmp('bb.value', lBb.value, bBb.value, lBb.value === bBb.value)
cmp('bb.high', lBb.high, bBb.high, lBb.high === bBb.high)
cmp('bb.low', lBb.low, bBb.low, lBb.low === bBb.low)

const bCur = await backend('/curve?days=90')
const lCur = await localCurve(90)
cmp('curve.count', lCur.count, bCur.count, lCur.count === bCur.count)
cmp('curve.scanned', lCur.scanned, bCur.scanned, lCur.scanned === bCur.scanned)
cmp('curve.e90', lCur.e90, bCur.e90, lCur.e90 === bCur.e90)
cmp('curve.p90_1s', lCur.p90_1s, bCur.p90 ? bCur.p90[0] : null, lCur.p90_1s === (bCur.p90 ? bCur.p90[0] : null))

const bTr = await backend('/trend?days=30')
const lTr = await localTrend(30)
const bLast = bTr.points && bTr.points.length ? bTr.points[bTr.points.length - 1] : null
cmp('trend.points', lTr.points, bTr.points ? bTr.points.length : 0, lTr.points === (bTr.points ? bTr.points.length : 0))
cmp('trend.ctl', lTr.last ? lTr.last.ctl : null, bLast ? bLast.ctl : null, (lTr.last ? lTr.last.ctl : null) === (bLast ? bLast.ctl : null))
cmp('trend.tsb', lTr.last ? lTr.last.tsb : null, bLast ? bLast.tsb : null, (lTr.last ? lTr.last.tsb : null) === (bLast ? bLast.tsb : null))

const pad = (s, n) => String(s).padEnd(n)
console.log('  ' + pad('项', 22) + pad('本地(直连)', 16) + pad('后端', 16) + '一致')
console.log('  ' + '-'.repeat(70))
for (const r of rows) {
  console.log('  ' + pad(r.label, 22) + pad(String(r.local), 16) + pad(String(r.remote), 16) + (r.ok ? '✓' : '✗'))
}
const bad = rows.filter((r) => !r.ok)
console.log('\n  一致 ' + (rows.length - bad.length) + '/' + rows.length + (bad.length ? '  不一致: ' + bad.map((b) => b.label).join(', ') : ''))
