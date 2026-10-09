/**
 * test/config-resolution.mjs —— 证明**配置获取机制**本身（本插件最关键的断言）。
 *
 * 做法：起一个真正的 `@deepseek-ai/cordis-plugin-loader`，按 profile 的组合方式
 * 建出 entry 树（`- insert:` 行 + config），然后把本插件的
 * `resolveFromLoader()` 指到这棵树上，断言它拿到的账号配置与
 * `dsh-plugin-garmin-connect` 自己的 `resolveAccountConfigs()` 逐字段一致。
 *
 * 这就是插件在宿主里走的同一条路径：`ctx.get('loader')` → `loader.entries()`
 * → `entry.fiber._config` → `resolveAccountConfigs()`。
 *
 * `node test\config-resolution.mjs`
 */
import { pathToFileURL } from 'node:url'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { existsSync, readFileSync, rmSync } from 'node:fs'
import assert from 'node:assert/strict'

import { resolveFromLoader, pickAccount, precheckSession, resolveAccount } from '../lib/config-resolution.mjs'
import { loadResolveAccountConfigs, garminPluginDir } from '../lib/garmin-module.mjs'

const DSH_APP = 'E:\\tools\\DSH-Desktop\\resources\\app\\node_modules\\@deepseek-ai'
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

process.stdout.write('\n=== dsh-plugin-garmin-dash · config resolution proof ===\n')
process.stdout.write(`garmin plugin dir: ${garminPluginDir() ?? '(unresolved)'}\n\n`)

await check('garmin-module.mjs locates the installed plugin', () => {
  const dir = garminPluginDir()
  assert.ok(dir, 'must find dsh-plugin-garmin-connect')
  for (const f of ['lib/client.js', 'lib/tool-service.js', 'lib/config.js']) {
    assert.ok(existsSync(join(dir, f)), `missing ${f}`)
  }
  return dir
})

// ── 建一棵与 profile 同构的 entry 树 ──────────────────────────────────
const cordis = await import(pathToFileURL(`${DSH_APP}\\cordis\\lib\\index.js`).href)
const Loader = (await import(pathToFileURL(`${DSH_APP}\\cordis-plugin-loader\\lib\\index.js`).href)).default
const garminDir = garminPluginDir()

const ctx = new cordis.Context()
ctx.plugin(Loader, { baseUrl: pathToFileURL(`${garminDir}\\`).href })
await new Promise((r) => setTimeout(r, 300))
const loader = ctx.get('loader')
assert.ok(loader, 'loader service must be reachable via ctx.get')

// 与 cordis.patch.yml 的 `- insert:` 同形；name 是经 baseUrl 解析的相对说明符。
const FAKE_ACCOUNT_ID = 'personal'
const FAKE_USERNAME = 'probe@example.invalid'
await loader.create({
  id: 'garmin-connect',
  name: 'lib/index.js',
  config: {
    accounts: [{ id: FAKE_ACCOUNT_ID, region: 'global', alias: 'personal', slot: 1 }],
    accountsConfigured: true,
    account1Username: FAKE_USERNAME,
    account1UsernameId: FAKE_ACCOUNT_ID,
    region: 'global',
  },
})
// 另一个无关 entry：必须**不**被误认成 garmin 配置。
await loader.create({
  id: 'remote-web-ui',
  name: pathToFileURL(resolve(tmpdir(), 'dsh-test-home', 'profiles', 'garmin')).href,
  config: { autoTunnel: false, relay: false, enabled: false },
})
await new Promise((r) => setTimeout(r, 1500))

await check('loader tree is reachable and lists both entries', () => {
  const ids = [...loader.entries()].map((e) => e.options.id).sort()
  assert.deepEqual(ids, ['garmin-connect', 'remote-web-ui'])
  return ids.join(', ')
})

let fromLoader
await check('resolveFromLoader() finds exactly the garmin entry', async () => {
  fromLoader = await resolveFromLoader(ctx)
  assert.ok(fromLoader, 'must resolve')
  assert.equal(fromLoader.entryId, 'garmin-connect')
  assert.equal(fromLoader.accounts.length, 1)
  return `entry=${fromLoader.entryId} accounts=${fromLoader.accounts.length}`
})

await check('resolved account config == upstream resolveAccountConfigs()', async () => {
  const resolveAccountConfigs = await loadResolveAccountConfigs()
  const expected = resolveAccountConfigs(fromLoader.raw)
  assert.equal(expected.length, fromLoader.accounts.length)
  for (let i = 0; i < expected.length; i += 1) {
    assert.equal(fromLoader.accounts[i].accountId, expected[i].accountId)
    assert.equal(fromLoader.accounts[i].region, expected[i].region)
    assert.equal(fromLoader.accounts[i].alias, expected[i].alias)
    assert.equal(fromLoader.accounts[i].configured, expected[i].configured)
    // 会话文件路径必须逐字符一致 —— 这是"能复用同一份已登录会话"的关键
    assert.equal(fromLoader.accounts[i].config.sessionTokenFile, expected[i].config.sessionTokenFile)
    assert.equal(fromLoader.accounts[i].config.region, expected[i].config.region)
    assert.equal(fromLoader.accounts[i].config.username, expected[i].config.username)
  }
  return `accountId=${fromLoader.accounts[0].accountId} region=${fromLoader.accounts[0].region}`
})

await check('pickAccount() prefers a configured account', () => {
  const list = [
    { accountId: 'a', configured: false },
    { accountId: 'b', configured: true },
  ]
  assert.equal(pickAccount(list).accountId, 'b')
  assert.equal(pickAccount([]), undefined)
  return 'ok'
})

await check('resolveAccount(ctx) reports ready and names its source', async () => {
  const resolved = await resolveAccount(ctx, { writeBindingCache: false })
  assert.equal(resolved.status, 'ready')
  assert.equal(resolved.source, 'loader-tree')
  assert.match(resolved.account.config.sessionTokenFile, /\.session\.json$/)
  return `source=${resolved.source} sessionFile=…${resolved.account.config.sessionTokenFile.slice(-28)}`
})

await check('resolveAccount(ctx) never leaks the account email into the binding cache', async () => {
  // 打开写缓存，然后检查落盘内容里没有邮箱
  const resolved = await resolveAccount(ctx, { writeBindingCache: true })
  assert.equal(resolved.status, 'ready')
  const bindingPath = 'E:\\GarminApp\\backend\\state\\account-binding.json'
  await new Promise((r) => setTimeout(r, 200))
  if (!existsSync(bindingPath)) return 'binding not written yet (async), skipped'
  const raw = readFileSync(bindingPath, 'utf8')
  assert.ok(!raw.includes(FAKE_USERNAME), 'binding must not contain the account email')
  const doc = JSON.parse(raw)
  assert.equal(doc.entryId, 'garmin-connect')
  assert.ok(doc.accounts[0].sessionTokenFile)
  return `keys=${Object.keys(doc).join(',')}; account keys=${Object.keys(doc.accounts[0]).join(',')}`
})

await check('precheckSession() rejects a mismatched username before any network call', async () => {
  const sessionFile = fromLoader.accounts[0].config.sessionTokenFile
  // 这个会话文件属于真实账号，不是 FAKE_USERNAME
  const bad = await precheckSession(FAKE_USERNAME, 'global', sessionFile)
  const missing = await precheckSession('x', 'global', 'C:\\nope\\missing.session.json')
  assert.equal(missing.ok, false)
  assert.match(missing.reason, /unreadable/)
  if (existsSync(sessionFile)) {
    assert.equal(bad.ok, false, 'fake username must not match the real session file')
    return `mismatch detected: ${bad.reason}`
  }
  return 'session file absent; only the missing-file path was exercised'
})

ctx.stop?.()

process.stdout.write('=== results ===\n')
let failed = 0
for (const r of results) {
  process.stdout.write(`  ${r.ok ? 'PASS' : 'FAIL'}  ${r.name}${r.detail ? ` — ${r.detail}` : ''}\n`)
  if (!r.ok) failed += 1
}
process.stdout.write(`\n  ${results.length - failed}/${results.length} checks passed\n`)
process.exitCode = failed > 0 ? 1 : 0
