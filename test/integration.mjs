/**
 * test/integration.mjs —— **端到端验证插件本体**：把真正的
 * `@deepseek-ai/dsh-host-webserver` 起在随机端口上，注册本插件的真实路由，
 * 然后用真实 HTTP 请求逐条核对 App 契约。
 *
 * 与 data-layer.mjs 的分工：
 *   - data-layer.mjs 证明 **数据层**（GarminClient/ToolService/归一化/指标数学）
 *   - integration.mjs 证明 **HTTP 契约**（路由注册、鉴权、配对、错误码、缓存、落盘）
 * 两者都不需要 DSH 引导程序，`node test\integration.mjs` 直接跑。
 *
 * Garmin 上游用确定性 stub 替换（真实网络不进 CI），但**服务对象是真实的**：
 * 用真的 `GarminService`，只是把它的 `toolService` 换成返回固定 payload 的替身，
 * 因此归一化、契约字段映射、null 语义全部走真实代码路径。
 */
import { pathToFileURL } from 'node:url'
import { existsSync, readFileSync, rmSync, writeFileSync, mkdtempSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { tmpdir } from 'node:os'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'

import { createRouter, PREFIX, isLoopback, publicBaseUrl, API_VERSION } from '../lib/routes.mjs'
import { GarminService } from '../lib/garmin-service.mjs'
import { PairStore, hashDeviceKey } from '../lib/pair-store.mjs'
import { dataRoot } from '../lib/snapshot.mjs'

// DSH 安装目录解析（顺序：环境变量 → profile 依赖 → 常见安装位置）。
// 找不到时本套件跳过，保证在没装 DSH 的机器上 run-all 仍然全绿。
function resolveDshApp() {
  const candidates = []
  if (process.env.DSH_APP_DIR) candidates.push(process.env.DSH_APP_DIR)
  const dshHome = process.env.DSH_HOME ?? join(homedir(), '.dsh')
  try {
    for (const name of readdirSync(join(dshHome, 'profiles'))) {
      candidates.push(join(dshHome, 'profiles', name, 'node_modules', '@deepseek-ai'))
    }
  } catch {
    /* 没有 profiles：继续尝试常见位置 */
  }
  const local = process.env.LOCALAPPDATA
  if (local) candidates.push(join(local, 'Programs', 'DSH Desktop', 'resources', 'app', 'node_modules', '@deepseek-ai'))
  if (process.env.ProgramFiles) candidates.push(join(process.env.ProgramFiles, 'DSH Desktop', 'resources', 'app', 'node_modules', '@deepseek-ai'))
  for (const dir of candidates) {
    try {
      if (dir && existsSync(join(dir, 'cordis', 'lib', 'index.js'))) return dir
    } catch {
      /* 继续 */
    }
  }
  return ''
}

const DSH_APP = resolveDshApp()
if (DSH_APP === '') {
  console.log('  SKIP 未找到 DSH 安装（设置 DSH_APP_DIR 或 DSH_HOME 后启用本套件）')
  process.exit(0)
}
const HERE = dirname(fileURLToPath(import.meta.url))
const FIXTURE = JSON.parse(readFileSync(join(HERE, 'fixtures', 'garmin-samples.json'), 'utf8'))
/** 设备库写到临时文件：**不碰**用户真实的 garmin-dash-devices.json。 */
const DEVICES_TMP = join(mkdtempSync(join(tmpdir(), 'garmin-dash-test-')), 'devices.json')
writeFileSync(DEVICES_TMP, JSON.stringify({ version: 1, devices: [] }), 'utf8')

const results = []
async function check(name, fn) {
  try {
    const detail = await fn()
    results.push({ name, ok: true, detail: detail === undefined ? '' : String(detail) })
  } catch (error) {
    results.push({ name, ok: false, detail: String(error?.message ?? error).split('\n')[0] })
  }
}

const logger = { debug() {}, info() {}, warn() {}, error() {} }
const todayLocal = () => {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

// ── 确定性上游替身（真实 GarminService + 假 toolService）────────────────
const activityFixtures = FIXTURE.activitiesFull
const stubTools = {
  async getSteps() { return FIXTURE.steps },
  async getHeartRate() { return FIXTURE.heartRate },
  async getSleep() { return FIXTURE.sleep },
  async getWeight() { return FIXTURE.weight[0] },
  async getActivities({ limit, offset }) { return activityFixtures.slice(offset, offset + limit) },
}
const stubClient = { async connect() {}, deactivate() {} }
const service = new GarminService({ client: stubClient, toolService: stubTools, logger, todayLocal })
// Body Battery 需要真实 axios，这里没有 → 固定 null，正好验证"拿不到就 null"
service.resolveBodyBattery = async () => null

// ── 用真实的 WebServer 起服务 ──────────────────────────────────────────
const cordis = await import(pathToFileURL(`${DSH_APP}\\cordis\\lib\\index.js`).href)
const { WebServer } = await import(pathToFileURL(`${DSH_APP}\\dsh-host-webserver\\lib\\index.js`).href)

// cordis 的 Service 走 fiber 生命周期：用空插件包一层再 patch 配置，
// 这样 WebServer 的 [Service.init] 会真的跑起来并 listen。
const root = new cordis.Context()
const fiber = root.plugin((inner, config) => {
  inner.plugin(WebServer, config)
}, { host: '127.0.0.1', port: 0, compression: 'none' })
await new Promise((r) => setTimeout(r, 200))
await Promise.allSettled([...(fiber?.inertia ? [fiber.inertia] : [])])

const webServer = root.get('webServer')
if (!webServer || typeof webServer.register !== 'function') {
  process.stdout.write('FATAL: webServer service did not activate\n')
  process.exit(1)
}
const router = createRouter({
  service,
  logger,
  todayLocal,
  readFileSync,
  pairStore: new PairStore({ devicesFile: DEVICES_TMP }),
})
await router.pairStore.load()
const disposers = [webServer.register({ kind: 'prefix', path: PREFIX, handler: router.handler })]
const PORT = webServer.port
const BASE = `http://127.0.0.1:${PORT}`
process.stdout.write(`\n=== dsh-plugin-garmin-dash · HTTP contract integration ===\nwebserver: real @deepseek-ai/dsh-host-webserver on ${BASE} (port ${PORT})\nroutes  : 1 prefix route ${PREFIX}\n\n`)

/** 简易请求助手。 */
async function req(path, { method = 'GET', headers = {}, body } = {}) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      ...(body === undefined ? {} : { 'content-type': 'application/json' }),
      ...headers,
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
  const text = await res.text()
  let json
  try { json = JSON.parse(text) } catch { json = undefined }
  return { status: res.status, text, json, headers: res.headers }
}

// ════════════════════════════════════════════════════════════════════
await check('GET /api/health -> 200 {ok,version}, no auth', async () => {
  const r = await req(`${PREFIX}/api/health`)
  assert.equal(r.status, 200)
  assert.deepEqual(r.json, { ok: true, version: API_VERSION })
  return JSON.stringify(r.json)
})

await check('device-key gate: every data endpoint is 401 without X-Device-Key', async () => {
  for (const p of ['/api/summary', '/api/activities', '/api/activity?id=1', '/api/trend?days=7']) {
    const r = await req(`${PREFIX}${p}`)
    assert.equal(r.status, 401, `${p} should be 401`)
    assert.deepEqual(r.json, { error: 'unauthorized' })
  }
  return '4 endpoints refused'
})

await check('device-key gate: unknown key is 401', async () => {
  const r = await req(`${PREFIX}/api/summary`, { headers: { 'x-device-key': 'f'.repeat(64) } })
  assert.equal(r.status, 401)
  assert.deepEqual(r.json, { error: 'unauthorized' })
  return 'unknown key refused'
})

await check('POST /api/pair: bad code -> 401 invalid_pair_code', async () => {
  const r = await req(`${PREFIX}/api/pair`, { method: 'POST', body: { pairCode: 'ZZZZZZZZ' } })
  assert.equal(r.status, 401)
  assert.deepEqual(r.json, { error: 'invalid_pair_code' })
  return JSON.stringify(r.json)
})

let deviceKey = ''
await check('POST /api/pair: minted code -> 200 {deviceKey,deviceId}', async () => {
  const minted = router.pairStore.mint()
  assert.match(minted.code, /^[A-HJ-NP-Z2-9]{8}$/, 'code must be 8 uppercase alnum without I/O/0/1')
  const r = await req(`${PREFIX}/api/pair`, { method: 'POST', body: { pairCode: minted.code } })
  assert.equal(r.status, 200)
  assert.match(r.json.deviceKey, /^[a-f0-9]{64}$/, 'deviceKey must be 64 lowercase hex')
  assert.match(r.json.deviceId, /^d-[a-f0-9]{12}$/)
  deviceKey = r.json.deviceKey
  return `code=${minted.code} deviceId=${r.json.deviceId} keyLen=${r.json.deviceKey.length}`
})

await check('pair code is single-use (second redemption -> 401)', async () => {
  const minted = router.pairStore.mint()
  const first = await req(`${PREFIX}/api/pair`, { method: 'POST', body: { pairCode: minted.code } })
  assert.equal(first.status, 200)
  const second = await req(`${PREFIX}/api/pair`, { method: 'POST', body: { pairCode: minted.code } })
  assert.equal(second.status, 401)
  assert.deepEqual(second.json, { error: 'invalid_pair_code' })
  return 'reuse refused'
})

await check('pair code normalizes case/separators', async () => {
  const minted = router.pairStore.mint()
  const messy = `${minted.code.slice(0, 4).toLowerCase()}-${minted.code.slice(4).toLowerCase()}`
  const r = await req(`${PREFIX}/api/pair`, { method: 'POST', body: { pairCode: messy } })
  assert.equal(r.status, 200)
  return `"${messy}" accepted`
})

await check('expired pair code -> 401 (TTL enforced)', async () => {
  const store = new PairStore({ devicesFile: DEVICES_TMP })
  let now = 1_000_000
  store.now = () => now
  const minted = store.mint()
  now += 10 * 60 * 1000 + 1 // 10 分钟 + 1ms
  const r = await store.redeem(minted.code)
  assert.equal(r.ok, false)
  return 'TTL 600s enforced'
})

await check('devices file stores only SHA-256 hashes, never the key', async () => {
  const raw = readFileSync(DEVICES_TMP, 'utf8')
  assert.ok(!raw.includes(deviceKey), 'the plaintext device key must never be persisted')
  const doc = JSON.parse(raw)
  assert.ok(doc.devices.some((d) => d.keyHash === hashDeviceKey(deviceKey)), 'hash must be recorded')
  for (const d of doc.devices) {
    assert.match(d.keyHash, /^[a-f0-9]{64}$/)
    assert.ok(d.createdAt && d.lastSeenAt, 'createdAt/lastSeenAt required')
  }
  return `${doc.devices.length} device(s), all hashed`
})

await check('GET /api/summary -> 200 with the exact contract shape', async () => {
  const date = todayLocal()
  const r = await req(`${PREFIX}/api/summary?date=${date}`, { headers: { 'x-device-key': deviceKey } })
  assert.equal(r.status, 200)
  const s = r.json
  for (const k of ['date', 'steps', 'restingHeartRate', 'sleep', 'weight', 'bodyBattery']) {
    assert.ok(k in s, `missing key ${k}`)
  }
  assert.equal(s.date, date)
  assert.equal(s.steps, 3209)
  assert.equal(s.restingHeartRate, 56)
  assert.equal(s.sleep.score, 67)
  assert.equal(s.sleep.durationMinutes, 416)
  assert.equal(s.weight, null, 'no scale data -> null, never omitted/faked')
  assert.equal(s.bodyBattery, null)
  return `steps=${s.steps} rhr=${s.restingHeartRate} sleep=${s.sleep.durationMinutes}min weight=null bodyBattery=null`
})

await check('GET /api/summary: invalid date -> 400', async () => {
  const r = await req(`${PREFIX}/api/summary?date=2026-13-99`, { headers: { 'x-device-key': deviceKey } })
  assert.equal(r.status, 400)
  assert.deepEqual(r.json, { error: 'invalid_date' })
  return 'ok'
})

await check('GET /api/activities -> 200 array with every contract field', async () => {
  const r = await req(`${PREFIX}/api/activities?limit=20&offset=0`, { headers: { 'x-device-key': deviceKey } })
  assert.equal(r.status, 200)
  assert.ok(Array.isArray(r.json))
  const a = r.json[0]
  for (const k of ['id', 'name', 'type', 'startTime', 'distanceMeters', 'durationSeconds',
    'averageHeartRate', 'maxHeartRate', 'elevationGainMeters', 'avgPower', 'normPower',
    'intensityFactor', 'trainingStressScore', 'averageCadence']) {
    assert.ok(k in a, `missing key ${k}`)
  }
  assert.equal(a.id, 10000000001)
  return `${r.json.length} items; [0] avgPower=${a.avgPower} normPower=${a.normPower} TSS=${a.trainingStressScore}`
})

await check('GET /api/activities: limit/offset are honoured and clamped', async () => {
  const r1 = await req(`${PREFIX}/api/activities?limit=1&offset=1`, { headers: { 'x-device-key': deviceKey } })
  assert.equal(r1.json.length, 1)
  assert.equal(r1.json[0].id, activityFixtures[1].activityId)
  const r2 = await req(`${PREFIX}/api/activities?limit=99999`, { headers: { 'x-device-key': deviceKey } })
  assert.equal(r2.status, 200)
  return `offset=1 -> id ${r1.json[0].id}; limit clamped to 100`
})

await check('GET /api/activity?id= -> full detail incl. power curve and zones', async () => {
  const r = await req(`${PREFIX}/api/activity?id=10000000001`, { headers: { 'x-device-key': deviceKey } })
  assert.equal(r.status, 200)
  const d = r.json
  const curve = Object.keys(d).filter((k) => /^maxAvgPower_/.test(k))
  const pz = Object.keys(d).filter((k) => /^powerTimeInZone_/.test(k))
  const hz = Object.keys(d).filter((k) => /^hrTimeInZone_/.test(k))
  assert.ok(curve.length >= 14, `expected the full power curve, got ${curve.length}`)
  assert.equal(pz.length, 7)
  assert.equal(hz.length, 5)
  assert.equal(d.normPower, 132)
  assert.equal(d.intensityFactor, 0.58)
  assert.equal(d.trainingStressScore, 114.8)
  assert.equal(d.avgLeftBalance, 46.33)
  assert.equal(d.vO2MaxValue, 48)
  assert.equal(d.differenceBodyBattery, -22)
  assert.equal(d.activityTrainingLoad, 166.77)
  // App 契约别名
  assert.equal(d.activityId, 10000000001)
  assert.equal(d.activityName, '示例城市 骑行')
  assert.equal(d.startTimeLocal, '2026-03-04 08:23:34')
  assert.equal(d.averageHR, 151)
  return `curve=${curve.length} powerZones=${pz.length} hrZones=${hz.length} TSS=${d.trainingStressScore} IF=${d.intensityFactor}`
})

await check('GET /api/activity: unknown id -> 404', async () => {
  const r = await req(`${PREFIX}/api/activity?id=1`, { headers: { 'x-device-key': deviceKey } })
  assert.equal(r.status, 404)
  assert.deepEqual(r.json, { error: 'not_found' })
  return 'ok'
})

await check('GET /api/activity: bad id -> 400', async () => {
  const r = await req(`${PREFIX}/api/activity?id=abc`, { headers: { 'x-device-key': deviceKey } })
  assert.equal(r.status, 400)
  return 'ok'
})

await check('GET /api/trend?days=30 -> points + weekly, CTL/ATL/TSB consistent', async () => {
  const r = await req(`${PREFIX}/api/trend?days=30`, { headers: { 'x-device-key': deviceKey } })
  assert.equal(r.status, 200)
  const t = r.json
  assert.equal(t.days, 30)
  assert.equal(t.points.length, 30)
  assert.ok(Array.isArray(t.weekly))
  assert.match(t.formula, /ctl_yesterday/)
  for (const p of t.points) {
    for (const k of ['date', 'tss', 'ctl', 'atl', 'tsb']) assert.ok(k in p, `missing ${k}`)
  }
  const last = t.points[t.points.length - 1]
  return `points=${t.points.length} weeks=${t.weekly.length} last(CTL/ATL/TSB)=${last.ctl}/${last.atl}/${last.tsb}`
})

await check('GET /api/trend: days=0 -> 400', async () => {
  const r = await req(`${PREFIX}/api/trend?days=0`, { headers: { 'x-device-key': deviceKey } })
  assert.equal(r.status, 400)
  return 'ok'
})

await check('60s cache: repeated requests hit the upstream only once', async () => {
  let calls = 0
  const counting = {
    ...stubTools,
    async getSteps() { calls += 1; return FIXTURE.steps },
  }
  const svc = new GarminService({ client: stubClient, toolService: counting, logger, todayLocal })
  svc.resolveBodyBattery = async () => null
  const local = createRouter({ service: svc, logger, todayLocal, readFileSync, pairStore: router.pairStore })
  const noopRes = { writeHead() {}, end() {} }
  const mkReq = () => ({ method: 'GET', url: `${PREFIX}/api/summary?date=${todayLocal()}`, headers: { 'x-device-key': deviceKey }, socket: { remoteAddress: '127.0.0.1' } })
  await local.handler(mkReq(), noopRes)
  await local.handler(mkReq(), noopRes)
  await local.handler(mkReq(), noopRes)
  assert.equal(calls, 1, `expected 1 upstream call, got ${calls}`)
  return `3 requests -> ${calls} upstream call`
})

await check('GET /pair?code=... -> 200 HTML page, no secrets', async () => {
  const r = await req(`${PREFIX}/pair?code=ABCD2345`)
  assert.equal(r.status, 200)
  assert.match(r.headers.get('content-type') ?? '', /text\/html/)
  assert.ok(r.text.includes('ABCD2345'), 'the scanned code should be shown')
  assert.ok(!/deviceKey|refreshToken|accessToken|pairCode/i.test(r.text), 'page must not leak credentials')
  assert.ok(!/<script/i.test(r.text), 'page must not carry scripts')
  return `${r.text.length} bytes, no script, no secrets`
})

await check('internal mint-code: refused for non-loopback callers', async () => {
  // 直接调 handler，伪造一个非回环来源
  const bodies = []
  const res = { writeHead(status) { this.status = status }, end(b) { bodies.push(b) } }
  await router.handler(
    { method: 'POST', url: `${PREFIX}/internal/mint-code`, headers: {}, socket: { remoteAddress: '192.168.1.50' } },
    res,
  )
  assert.equal(res.status, 403)
  assert.deepEqual(JSON.parse(bodies[0]), { error: 'forbidden' })
  return 'non-loopback -> 403'
})

await check('internal mint-code: loopback -> 200 {code,url,expiresAt}', async () => {
  const r = await req(`${PREFIX}/internal/mint-code`, { method: 'POST' })
  assert.equal(r.status, 200)
  assert.match(r.json.code, /^[A-HJ-NP-Z2-9]{8}$/)
  assert.equal(r.json.expiresInSeconds, 600)
  assert.ok(Date.parse(r.json.expiresAt) > Date.now())
  publicBaseUrl(readFileSync) // 读注册表（读不到就是空串，不抛）
  assert.match(r.json.url, /\/garmin-dash\/pair\?code=[A-HJ-NP-Z2-9]{8}$/)
  assert.ok(!/token|key=/i.test(r.json.url), 'the pairing URL must only carry ?code=')
  return r.json.url
})

await check('isLoopback accepts 127.0.0.1 / ::1 / ::ffff:127.0.0.1 only', () => {
  const mk = (addr) => ({ socket: { remoteAddress: addr } })
  assert.equal(isLoopback(mk('127.0.0.1')), true)
  assert.equal(isLoopback(mk('::1')), true)
  assert.equal(isLoopback(mk('::ffff:127.0.0.1')), true)
  assert.equal(isLoopback(mk('10.0.0.1')), false)
  assert.equal(isLoopback(mk('::ffff:10.0.0.1')), false)
  assert.equal(isLoopback({}), false)
  return 'ok'
})

await check('unknown path under the prefix -> 404 (with valid key)', async () => {
  const r = await req(`${PREFIX}/api/nope`, { headers: { 'x-device-key': deviceKey } })
  assert.equal(r.status, 404)
  return 'ok'
})

await check('upstream failure -> 503 upstream_unavailable (host stays up)', async () => {
  const broken = {
    ...stubTools,
    async getActivities() { throw Object.assign(new Error('boom'), { response: { status: 429 } }) },
  }
  const svc = new GarminService({ client: stubClient, toolService: broken, logger, todayLocal })
  const local = createRouter({ service: svc, logger, todayLocal, readFileSync, pairStore: router.pairStore })
  const res = await new Promise((resolve) => {
    const captured = { writeHead(status) { this.status = status }, end(b) { resolve({ status: this.status, body: b }) } }
    local.handler(
      { method: 'GET', url: `${PREFIX}/api/activities`, headers: { 'x-device-key': deviceKey }, socket: { remoteAddress: '127.0.0.1' } },
      captured,
    )
  })
  assert.equal(res.status, 503)
  assert.deepEqual(JSON.parse(res.body), { error: 'upstream_unavailable' })
  return 'rate-limited upstream -> 503'
})

await check('snapshot: every successful data response is written atomically under E:\\GarminData', async () => {
  const date = todayLocal()
  const file = resolve(dataRoot(), '数据快照', `${date}.json`)
  // 上面几次 summary/activities/trend 调用已经触发了落盘
  const deadline = Date.now() + 5000
  while (!existsSync(file) && Date.now() < deadline) await new Promise((r) => setTimeout(r, 100))
  assert.ok(existsSync(file), `expected snapshot at ${file}`)
  const doc = JSON.parse(readFileSync(file, 'utf8'))
  assert.equal(doc.date, date)
  assert.ok(doc.records.summary, 'summary record required')
  assert.ok(doc.records.activities, 'activities record required')
  assert.ok(doc.updatedAt, 'updatedAt required')
  // 确认没有临时文件残留（原子写的副产物应被清理）
  const stray = readFileSync(file, 'utf8').length > 0
  assert.ok(stray)
  return `records=${Object.keys(doc.records).join(',')}`
})

// ════════════════════════════════════════════════════════════════════
for (const d of disposers) d()
process.stdout.write('\n=== results ===\n')
let failed = 0
for (const r of results) {
  process.stdout.write(`  ${r.ok ? 'PASS' : 'FAIL'}  ${r.name}${r.detail ? ` — ${r.detail}` : ''}\n`)
  if (!r.ok) failed += 1
}
process.stdout.write(`\n  ${results.length - failed}/${results.length} checks passed\n`)
process.exit(failed > 0 ? 1 : 0)
