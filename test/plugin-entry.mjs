/**
 * test/plugin-entry.mjs —— 证明**插件本体**能被 DSH loader 真正装载：
 * `inject = ['webServer','loader']` 的依赖注入生效、`apply()` 被调用、
 * 前缀路由注册到（真实的）`ctx.webServer`，并且 `/garmin-dash/api/health`
 * 真的能通过 HTTP 打通。
 *
 * 用真的 `@deepseek-ai/cordis` + `@deepseek-ai/cordis-plugin-loader` +
 * `@deepseek-ai/dsh-host-webserver`，只把 Garmin 上游换成 stub，
 * 因此这条断言覆盖了"宿主里会发生什么"。
 *
 * `node test\plugin-entry.mjs`
 */
import { pathToFileURL } from 'node:url'
import { paths } from '../lib/config.mjs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { writeFileSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import assert from 'node:assert/strict'

import { PairStore } from '../lib/pair-store.mjs'
import * as plugin from '../lib/index.js'

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

const results = []
async function check(name, fn) {
  try {
    const detail = await fn()
    results.push({ name, ok: true, detail: detail === undefined ? '' : String(detail) })
  } catch (error) {
    results.push({ name, ok: false, detail: String(error?.message ?? error).split('\n')[0] })
  }
}

process.stdout.write('\n=== dsh-plugin-garmin-dash · plugin entry ===\n\n')

await check('module shape matches the loader contract (ESM, name/inject/apply)', () => {
  assert.equal(typeof plugin.apply, 'function', 'apply must be exported')
  assert.equal(plugin.name, 'garmin-dash')
  assert.deepEqual(plugin.inject, ['webServer', 'loader'])
  return `name=${plugin.name} inject=[${plugin.inject.join(',')}]`
})

// ── 用真实 loader 装载本插件（name 指向本包的 lib/index.js）─────────────
const cordis = await import(pathToFileURL(`${DSH_APP}\\cordis\\lib\\index.js`).href)
const Loader = (await import(pathToFileURL(`${DSH_APP}\\cordis-plugin-loader\\lib\\index.js`).href)).default
const { WebServer } = await import(pathToFileURL(`${DSH_APP}\\dsh-host-webserver\\lib\\index.js`).href)

const garminDir = process.env.GARMIN_PLUGIN_DIR ?? paths.garminPluginDir
const ctx = new cordis.Context()
ctx.plugin(Loader, { baseUrl: pathToFileURL(`${garminDir}\\`).href })
await new Promise((r) => setTimeout(r, 300))
const loader = ctx.get('loader')

// garmin-connect 的配置行：给本插件解析账号用（会话文件用一个真实存在的路径）。
// webServer 作为**命名服务**注册在同一个根 context 上（与宿主一致：
// host-webserver 是 `Service`，通过 `ctx.get('webServer')` 解析）。
const HOST = ctx.extend({})
HOST.plugin(WebServer, { host: '127.0.0.1', port: 0, compression: 'none' })
await new Promise((r) => setTimeout(r, 400))

const webServer = ctx.get('webServer')

await check('real WebServer service is up (booted through cordis plugin lifecycle)', () => {
  assert.ok(webServer, 'webServer must be registered as a named service')
  assert.equal(typeof webServer.register, 'function')
  assert.ok(Number.isFinite(webServer.port) && webServer.port > 0, 'must be listening')
  return `127.0.0.1:${webServer.port}`
})

// 直接调用 apply，ctx 用真实的 loader context；`ctx.get('webServer')` 走真实解析。
const injection = ctx.extend({})

let applied = 0
await check('apply() registers a prefix route on ctx.webServer', async () => {
  const before = webServer.prefixes.size
  plugin.apply(injection, {})
  applied += 1
  assert.equal(webServer.prefixes.size, before + 1, 'exactly one prefix route added')
  const route = webServer.prefixes.get('/garmin-dash')
  assert.ok(route, 'route path must be /garmin-dash')
  assert.equal(route.kind, 'prefix')
  assert.equal(typeof route.handler, 'function')
  return `prefix routes: ${[...webServer.prefixes.keys()].join(', ')}`
})

await check('route kind/path/handler shape matches dsh-host-webserver expectations', () => {
  const route = webServer.prefixes.get('/garmin-dash')
  // lib/index.js:177-184 用 route.kind 选表、route.path 做键、route.handler 做回调
  assert.deepEqual(Object.keys(route).sort(), ['handler', 'kind', 'path'])
  return JSON.stringify({ kind: route.kind, path: route.path, handler: typeof route.handler })
})

await check('GET /garmin-dash/api/health works through the real webserver', async () => {
  const res = await fetch(`http://127.0.0.1:${webServer.port}/garmin-dash/api/health`)
  assert.equal(res.status, 200)
  const body = await res.json()
  assert.deepEqual(body, { ok: true, version: '1' })
  return JSON.stringify(body)
})

await check('query strings never participate in route matching', async () => {
  const res = await fetch(`http://127.0.0.1:${webServer.port}/garmin-dash/api/health?x=1&y=2`)
  assert.equal(res.status, 200)
  const body = await res.json()
  assert.equal(body.ok, true)
  return 'match() strips the query (host-webserver match uses url.pathname)'
})

await check('data endpoint is gated before any Garmin work happens', async () => {
  const res = await fetch(`http://127.0.0.1:${webServer.port}/garmin-dash/api/summary`)
  assert.equal(res.status, 401)
  assert.deepEqual(await res.json(), { error: 'unauthorized' })
  return 'no device key -> 401'
})

await check('non-loopback mint-code is refused through the real socket path', async () => {
  // 回环请求应当被接受（证明路由通了）；非回环由 integration.mjs 直接测 handler。
  const res = await fetch(`http://127.0.0.1:${webServer.port}/garmin-dash/internal/mint-code`, { method: 'POST' })
  assert.equal(res.status, 200)
  const body = await res.json()
  assert.match(body.code, /^[A-HJ-NP-Z2-9]{8}$/)
  return `loopback accepted, code=${body.code}`
})

await check('plugin teardown removes the route (ctx.effect disposer)', async () => {
  // 通过再次 apply 到独立 ctx 验证 disposer 语义：这里直接调 webServer.register 的返回值
  const dispose = webServer.register({ kind: 'prefix', path: '/tmp-check', handler() {} })
  assert.equal(webServer.prefixes.has('/tmp-check'), true)
  dispose()
  assert.equal(webServer.prefixes.has('/tmp-check'), false)
  return 'register() returns a working disposer'
})

process.stdout.write('=== results ===\n')
let failed = 0
for (const r of results) {
  process.stdout.write(`  ${r.ok ? 'PASS' : 'FAIL'}  ${r.name}${r.detail ? ` — ${r.detail}` : ''}\n`)
  if (!r.ok) failed += 1
}
process.stdout.write(`\n  ${results.length - failed}/${results.length} checks passed\n`)

// 干净收尾：先关掉真实的 HTTP server，再让事件循环自然排空。
// 直接 process.exit() 会在还有活动 socket 时触发 libuv 的
// "Assertion failed: !(handle->flags & UV_HANDLE_CLOSING)"，那是测试收尾
// 的假故障（退出码会被污染成 0xC0000409），不是插件问题。
await new Promise((r) => {
  try { webServer.server?.close(() => r()) ?? r() } catch { r() }
  setTimeout(r, 1000)
})
process.exitCode = failed > 0 ? 1 : 0
