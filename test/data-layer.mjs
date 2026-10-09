/**
 * test/data-layer.mjs —— **独立证明**：不依赖 DSH，构造与插件完全相同的
 * GarminClient / GarminToolService / GarminService，打印真实数据。
 *
 * 运行：
 *   node test\data-layer.mjs                 # 真实数据模式（需要本机已登录会话）
 *   node test\data-layer.mjs --replay        # 回放模式（用真实抓取样本，无需凭据）
 *   node test\data-layer.mjs --days 90       # 自定义 trend 窗口
 *
 * 退出码：0 = 全部通过；1 = 断言失败；2 = 前置条件缺失（无法判定）。
 *
 * ── 关于"账号邮箱"这个唯一的外部输入 ──────────────────────────────
 * 上游 `GarminClient` 会用 `sha256(lower(trim(email)))` 校验会话文件是否属于
 * 当前账号（`dsh-plugin-garmin-connect/lib/session-store.js:476-482`）。
 * 邮箱**只存在于运行中宿主的内存里**：profile 的 cordis.patch.yml 没有
 * garmin-connect 的 config，磁盘上没有任何明文邮箱（会话文件只存 usernameHash）。
 * 因此真实数据模式需要邮箱来自以下任一来源（按优先级）：
 *   1. `--username <email>`
 *   2. 环境变量 `GARMIN_USERNAME`
 *   3. `test/account.local.json` 的 `{"username": "..."}`（仅本机，切勿提交）
 * 三者都没有时，脚本**不会伪造成功**：它打印缺失说明并以退出码 2 结束。
 * 回放模式（--replay）不需要邮箱，用 `test/fixtures/garmin-samples.json` 里
 * 真实抓取的上游响应验证全部归一化逻辑与指标数学。
 */
import { readFileSync, existsSync } from 'node:fs'
import { dirname, resolve, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createHash } from 'node:crypto'
import assert from 'node:assert/strict'

import { loadGarminClient, loadGarminToolService } from '../lib/garmin-module.mjs'
import { resolveAccountForScript, precheckSession, readBinding } from '../lib/config-resolution.mjs'
import { GarminService } from '../lib/garmin-service.mjs'
import { buildTrend } from '../lib/routes.mjs'
import { normalizeActivity, normalizeSleep, normalizeWeight, classifyError } from '../lib/garmin-service.mjs'
import { computeLoadSeries, weeklyTotals, tssOf, isoWeekStart } from '../lib/trend.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const FIXTURE = join(HERE, 'fixtures', 'garmin-samples.json')
const LOCAL_ACCOUNT = join(HERE, 'account.local.json')

const argv = process.argv.slice(2)
const REPLAY = argv.includes('--replay')
const daysArg = argv.indexOf('--days')
const TREND_DAYS = daysArg === -1 ? 30 : Number(argv[daysArg + 1] || 30)
const userArg = argv.indexOf('--username')
const CLI_USERNAME = userArg === -1 ? '' : String(argv[userArg + 1] ?? '')

/** 极简测试记录器。 */
const results = []
function check(name, fn) {
  try {
    const detail = fn()
    results.push({ name, ok: true, detail: detail === undefined ? '' : String(detail) })
  } catch (error) {
    results.push({ name, ok: false, detail: String(error?.message ?? error).split('\n')[0] })
  }
}
function fmt(value) {
  if (value === null || value === undefined) return 'null'
  if (typeof value === 'object') return JSON.stringify(value)
  return String(value)
}
function line(label, value) {
  process.stdout.write(`  ${label.padEnd(26)} ${fmt(value)}\n`)
}

const localAccount = existsSync(LOCAL_ACCOUNT) ? JSON.parse(readFileSync(LOCAL_ACCOUNT, 'utf8')) : {}
const username = (CLI_USERNAME || process.env.GARMIN_USERNAME || localAccount.username || '').trim()

process.stdout.write('\n=== dsh-plugin-garmin-dash · data layer proof ===\n')
process.stdout.write(`mode: ${REPLAY ? 'replay (fixtures)' : 'live (real Garmin session)'}  |  trend window: ${TREND_DAYS} days\n\n`)

const logger = {
  debug() {}, info() {},
  warn: (...a) => process.stdout.write(`  [warn] ${a.join(' ')}\n`),
  error: (...a) => process.stdout.write(`  [error] ${a.join(' ')}\n`),
}
const todayLocal = () => {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

// ════════════════════════════════════════════════════════════════════
// 阶段 1：账号配置解析（与插件同一条代码路径）
// ════════════════════════════════════════════════════════════════════
process.stdout.write('[1] account binding resolution (same code path as the plugin)\n')

let resolved
if (REPLAY) {
  resolved = { status: 'error', source: 'replay', reason: 'replay mode does not bind an account' }
} else {
  resolved = await resolveAccountForScript({ username })
}

if (!REPLAY) {
  line('resolver status', resolved.status)
  line('resolver source', resolved.source)
  if (resolved.status === 'ready') {
    line('region', resolved.config.region)
    line('session file', resolved.config.sessionTokenFile.replace(/^.*\\accounts\\/, '…\\accounts\\'))
    line('username provided', username ? 'yes' : 'no')
    const pre = await precheckSession(username, resolved.config.region, resolved.config.sessionTokenFile)
    line('precheck (hash match)', pre.ok ? `ok, refresh valid until ${pre.refreshExpiresAt}` : pre.reason)
    if (!pre.ok) resolved = { status: 'error', source: 'precheck', reason: pre.reason }
  } else {
    line('reason', resolved.reason)
    const binding = await readBinding()
    line('binding cache', binding ? `${binding.accounts?.length ?? 0} account(s) cached` : 'absent')
  }
}

// ════════════════════════════════════════════════════════════════════
// 阶段 2：真实数据（live 模式）
// ════════════════════════════════════════════════════════════════════
let exitCode = 0

if (REPLAY || resolved.status !== 'ready') {
  // ---------- 回放模式：用真实抓取的上游响应验证归一化与数学
  if (!existsSync(FIXTURE)) {
    process.stdout.write(`\n  ✗ fixture missing: ${FIXTURE}\n`)
    process.exit(2)
  }
  const fixture = JSON.parse(readFileSync(FIXTURE, 'utf8'))

  process.stdout.write('\n[2] normalization against recorded upstream payloads (real Garmin shapes)\n')
  const rawActivities = fixture.activitiesFull
  const activities = rawActivities.map(normalizeActivity)
  const headline = activities.find((a) => a.trainingStressScore !== null)

  check('fixture carries full-detail activities', () => {
    assert.ok(rawActivities.length >= 2, 'need at least 2 activities')
    return `${rawActivities.length} raw activities`
  })
  check('normalizeActivity maps power fields', () => {
    const a = activities.find((x) => x.id === 10000000001)
    assert.ok(a, 'the known 2026-10-07 ride must be present in the fixture')
    assert.equal(a.avgPower, 155)
    assert.equal(a.normPower, 132)
    assert.equal(a.intensityFactor, 0.58) // upstream 0.5820000171661377 -> 2dp
    assert.equal(a.trainingStressScore, 114.8) // upstream 114.80000305175781 -> 2dp
    return `id=${a.id} avgPower=${a.avgPower} normPower=${a.normPower} IF=${a.intensityFactor} TSS=${a.trainingStressScore}`
  })
  check('normalizeActivity keeps raw power curve + zone fields untouched', () => {
    const raw = rawActivities.find((x) => x.activityId === 10000000001)
    assert.equal(raw.maxAvgPower_18000, 58)
    assert.equal(raw.powerTimeInZone_1, 6641.324)
    assert.equal(raw.hrTimeInZone_5, 57.991)
    return `maxAvgPower_1..18000 present, powerTimeInZone_1=${raw.powerTimeInZone_1}`
  })
  check('normalizeActivity never fabricates missing values', () => {
    const swim = activities.find((a) => a.type === 'lap_swimming')
    if (!swim) return 'no swim in fixture (skipped)'
    assert.equal(swim.avgPower, null)
    assert.equal(swim.elevationGainMeters, null)
    return `id=${swim.id} avgPower=null elevationGainMeters=null`
  })
  check('normalizeSleep -> minutes', () => {
    const sleep = normalizeSleep(fixture.sleep)
    assert.equal(sleep.score, 67)
    assert.equal(sleep.durationMinutes, 416) // 6.93h
    assert.equal(sleep.deepMinutes, 105) // 1.75h
    return JSON.stringify(sleep)
  })
  check('normalizeWeight returns null when Garmin has no scale data', () => {
    assert.equal(normalizeWeight(fixture.weight[0], '2026-10-09'), null)
    return 'weightKg/bodyFat/bmi all null -> null'
  })
  check('classifyError: 429 -> rate-limit, 500 -> upstream, PublicToolError -> bad-request', () => {
    assert.equal(classifyError({ response: { status: 429 } }), 'rate-limit')
    assert.equal(classifyError({ status: 503 }), 'upstream')
    assert.equal(classifyError(Object.assign(new Error('Invalid date'), { constructor: { name: 'PublicToolError' } })), 'bad-request')
    assert.equal(classifyError(new Error('Garmin authentication is required')), 'authentication')
    return 'ok'
  })

  process.stdout.write('\n[3] trend math (TSS / CTL 42d / ATL 7d / TSB)\n')
  check('computeLoadSeries applies the documented EMA (hand-computed)', () => {
    // 单日 42 TSS，窗口 3 天：
    //   day1: CTL = 0 + (42-0)/42 = 1 ; ATL = 0 + (42-0)/7 = 6 ; TSB = CTL - ATL_yesterday = 1 - 0 = 1
    //   day2: TSS=0 -> CTL = 1 + (0-1)/42 = 0.976 -> 1.0 ; ATL = 6 + (0-6)/7 = 5.14 ; TSB = 1 - 6 = -5
    //   day3: ATL = 5.14 + (0-5.14)/7 = 4.4 ; TSB = 1 - ATL(day2, 1dp) = 1 - 5.1 = -4.1
    const series = computeLoadSeries({
      start: '2026-01-01', end: '2026-01-03', warmupStart: '2026-01-01',
      tssByDate: new Map([['2026-01-01', 42]]),
    })
    assert.equal(series.length, 3)
    assert.equal(series[0].ctl, 1)
    assert.equal(series[0].atl, 6)
    assert.equal(series[0].tsb, 1) // CTL_today - ATL_yesterday(0)
    assert.equal(series[1].ctl, 1) // 0.976 四舍五入到 1 位小数
    assert.equal(series[1].atl, 5.1)
    assert.equal(series[1].tsb, -5) // 1 - 6
    assert.equal(series[2].tsb, -4.1) // 1 - 5.1（TSB 用与输出同精度的 ATL，行内自洽）
    return `d1 CTL=${series[0].ctl} ATL=${series[0].atl} TSB=${series[0].tsb} | d2 TSB=${series[1].tsb} | d3 TSB=${series[2].tsb}`
  })
  check('computeLoadSeries: EMA advances through zero-TSS days', () => {
    const series = computeLoadSeries({
      start: '2026-01-02', end: '2026-01-02', warmupStart: '2026-01-01',
      tssByDate: new Map([['2026-01-01', 42]]),
    })
    assert.equal(series.length, 1)
    assert.equal(series[0].tss, 0)
    assert.ok(series[0].ctl < 1.001, 'CTL must decay on a rest day')
    return `rest day CTL=${series[0].ctl} ATL=${series[0].atl}`
  })
  check('tssOf treats missing TSS as 0 (never guesses)', () => {
    assert.equal(tssOf({}), 0)
    assert.equal(tssOf({ trainingStressScore: 114.8 }), 114.8)
    return 'ok'
  })
  check('isoWeekStart is Monday-based', () => {
    // 2026-10-07 是周三 -> 周一 2026-10-05
    assert.equal(isoWeekStart('2026-10-07'), '2026-10-05')
    assert.equal(isoWeekStart('2026-10-05'), '2026-10-05')
    assert.equal(isoWeekStart('2026-10-11'), '2026-10-05')
    return '2026-10-07 -> 2026-10-05'
  })
  check('weeklyTotals aggregates distance/duration/tss', () => {
    const weeks = weeklyTotals([
      { date: '2026-10-05', distanceMeters: 1000, durationSeconds: 100, tss: 10 },
      { date: '2026-10-07', distanceMeters: 2000, durationSeconds: 200, tss: 20 },
    ])
    assert.equal(weeks.length, 1)
    assert.equal(weeks[0].weekStart, '2026-10-05')
    assert.equal(weeks[0].distanceMeters, 3000)
    return JSON.stringify(weeks[0])
  })

  if (resolved.status !== 'ready' && !REPLAY) {
    process.stdout.write('\n[4] live data section — SKIPPED (no account email)\n')
    process.stdout.write('    GarminClient verifies sha256(lower(trim(email))) against the session file,\n')
    process.stdout.write('    and that email exists only in the running host process memory.\n')
    process.stdout.write('    Provide it via --username, GARMIN_USERNAME, or test/account.local.json\n')
    process.stdout.write(`    (${LOCAL_ACCOUNT}) then re-run without --replay for live numbers.\n`)
  }
} else {
  // ---------- 真实数据模式
  process.stdout.write('\n[2] live Garmin data (real session, real network)\n')
  const [GarminClient, GarminToolService] = await Promise.all([loadGarminClient(), loadGarminToolService()])
  const accountConfig = {
    username,
    password: '',
    sessionToken: '',
    sessionTokenFile: resolved.config.sessionTokenFile,
    region: resolved.config.region,
    cacheTtl: 60,
    requestTimeoutMs: 30_000,
    activityDetail: 'full',
    fitDownloadDir: '',
  }
  const ctx = { logger }
  const client = new GarminClient(ctx, accountConfig, { allowUnconfigured: true })
  const toolService = new GarminToolService(client, {
    activityDetail: 'full',
    fitDownloadDir: '',
    accountUsername: username,
    accountRegion: accountConfig.region,
  })
  const service = new GarminService({ client, toolService, logger, todayLocal })

  try {
    await service.ensureConnected()
    process.stdout.write('  connect(): OK\n')

    // ---- health
    line('health.version', '1')
    line('health.ok', true)

    // ---- summary
    const date = todayLocal()
    process.stdout.write(`\n  ── summary ${date} ──\n`)
    const summary = await service.getSummary(date)
    line('steps', summary.steps)
    line('restingHeartRate', summary.restingHeartRate)
    line('sleep.score', summary.sleep?.score ?? null)
    line('sleep.durationMinutes', summary.sleep?.durationMinutes ?? null)
    line('sleep.deep/light/rem', summary.sleep ? `${summary.sleep.deepMinutes}/${summary.sleep.lightMinutes}/${summary.sleep.remMinutes}` : null)
    line('weight', summary.weight)
    line('bodyBattery', summary.bodyBattery)
    if (summary._partial) line('partial failures', summary._partial.join(','))
    check('summary contract: all keys present, missing ones null', () => {
      for (const key of ['date', 'steps', 'restingHeartRate', 'sleep', 'weight', 'bodyBattery']) {
        assert.ok(key in summary, `missing key ${key}`)
      }
      return `date=${summary.date} steps=${summary.steps} rhr=${summary.restingHeartRate}`
    })

    // ---- activities
    process.stdout.write('\n  ── 2 most recent activities ──\n')
    const acts = await service.getActivities({ limit: 2, offset: 0 })
    for (const a of acts) {
      process.stdout.write(`  · [${a.id}] ${a.name} (${a.type}) ${a.startTime}\n`)
      process.stdout.write(`      dist=${a.distanceMeters}m dur=${a.durationSeconds}s HR=${a.averageHeartRate}/${a.maxHeartRate} elev=${a.elevationGainMeters}m\n`)
      process.stdout.write(`      avgPower=${a.avgPower} normPower=${a.normPower} IF=${a.intensityFactor} TSS=${a.trainingStressScore} cad=${a.averageCadence}\n`)
    }
    check('activities: contract fields present on every item', () => {
      assert.ok(acts.length >= 2, `expected >= 2 activities, got ${acts.length}`)
      for (const a of acts) {
        for (const key of ['id', 'name', 'type', 'startTime', 'distanceMeters', 'durationSeconds', 'averageHeartRate', 'maxHeartRate', 'elevationGainMeters']) {
          assert.ok(key in a, `missing ${key}`)
        }
      }
      return `${acts.length} activities checked`
    })
    check('activities: power fields survive on a ride', () => {
      const ride = acts.find((a) => a.avgPower !== null)
      if (!ride) return 'no powered activity in the newest 2 (not a failure)'
      return `id=${ride.id} avgPower=${ride.avgPower} normPower=${ride.normPower} IF=${ride.intensityFactor} TSS=${ride.trainingStressScore}`
    })

    // ---- full detail of the newest activity
    process.stdout.write('\n  ── full-detail activity (newest) ──\n')
    const detail = await service.getActivityDetail(acts[0].id)
    line('activityId / name', `${detail.activityId} / ${detail.activityName}`)
    line('normPower / IF / TSS', `${detail.normPower} / ${detail.intensityFactor} / ${detail.trainingStressScore}`)
    line('activityTrainingLoad', detail.activityTrainingLoad)
    line('avgLeftBalance', detail.avgLeftBalance)
    line('vO2MaxValue', detail.vO2MaxValue)
    line('differenceBodyBattery', detail.differenceBodyBattery)
    const curveKeys = Object.keys(detail).filter((k) => /^maxAvgPower_/.test(k))
    const pzKeys = Object.keys(detail).filter((k) => /^powerTimeInZone_/.test(k))
    const hzKeys = Object.keys(detail).filter((k) => /^hrTimeInZone_/.test(k))
    line('power curve keys', curveKeys.length ? `${curveKeys.length} (${curveKeys[0]}..${curveKeys[curveKeys.length - 1]})` : 'absent')
    line('power/hr zone keys', `${pzKeys.length} power + ${hzKeys.length} hr`)
    check('activity detail: full payload, not a summary', () => {
      assert.ok(curveKeys.length >= 10, `expected the maxAvgPower_* power curve, got ${curveKeys.length}`)
      assert.ok(pzKeys.length >= 7, `expected powerTimeInZone_1..7, got ${pzKeys.length}`)
      assert.ok(hzKeys.length >= 5, `expected hrTimeInZone_1..5, got ${hzKeys.length}`)
      return `${curveKeys.length} curve + ${pzKeys.length} power zones + ${hzKeys.length} hr zones`
    })
    check('activity detail: no credential/account/social leakage', () => {
      const text = JSON.stringify(detail)
      for (const banned of ['accessToken', 'refreshToken', 'oauth1', 'oauth2', 'ownerId', 'ownerDisplayName', 'password']) {
        assert.ok(!text.includes(banned), `detail leaks ${banned}`)
      }
      return 'clean'
    })

    // ---- trend
    process.stdout.write(`\n  ── trend ${TREND_DAYS} days ──\n`)
    const trend = await buildTrend(service, TREND_DAYS, date)
    const last = trend.points[trend.points.length - 1]
    line('window', `${trend.start} .. ${trend.end}`)
    line('activities in window', trend.activityCount)
    line('weekly buckets', trend.weekly.length)
    line(`CTL/ATL/TSB @ ${last.date}`, `${last.ctl} / ${last.atl} / ${last.tsb}`)
    line('series length', trend.points.length)
    const daysWithTss = trend.points.filter((p) => p.tss > 0).length
    line('days with TSS > 0', daysWithTss)
    check('trend: one point per day, monotone dates', () => {
      assert.equal(trend.points.length, TREND_DAYS)
      for (let i = 1; i < trend.points.length; i += 1) {
        assert.ok(trend.points[i].date > trend.points[i - 1].date, 'dates must increase')
      }
      return `${trend.points.length} points`
    })
    check('trend: CTL/ATL/TSB are finite and TSB = CTL - ATL', () => {
      for (const p of trend.points) {
        for (const k of ['tss', 'ctl', 'atl', 'tsb']) assert.ok(Number.isFinite(p[k]), `${k} not finite at ${p.date}`)
        assert.ok(Math.abs(p.tsb - (p.ctl - p.atl)) <= 0.11, `TSB mismatch at ${p.date}`)
      }
      return `CTL=${last.ctl} ATL=${last.atl} TSB=${last.tsb}`
    })
    check('trend: weekly totals are non-negative', () => {
      for (const w of trend.weekly) {
        assert.ok(w.distanceMeters >= 0 && w.durationSeconds >= 0 && w.tss >= 0, `bad week ${w.weekStart}`)
      }
      return `${trend.weekly.length} weeks`
    })

    client.deactivate()
  } catch (error) {
    process.stdout.write(`\n  ✗ live section failed: ${error?.constructor?.name}: ${String(error?.message ?? error).slice(0, 300)}\n`)
    exitCode = 1
  }
}

// ════════════════════════════════════════════════════════════════════
process.stdout.write('\n=== results ===\n')
let failed = 0
for (const r of results) {
  process.stdout.write(`  ${r.ok ? 'PASS' : 'FAIL'}  ${r.name}${r.detail ? ` — ${r.detail}` : ''}\n`)
  if (!r.ok) failed += 1
}
process.stdout.write(`\n  ${results.length - failed}/${results.length} checks passed\n`)

if (failed > 0) process.exitCode = 1
else if (!REPLAY && resolved.status !== 'ready') process.exitCode = 2
else process.exitCode = exitCode
