/**
 * config-resolution.mjs — 本插件最关键的机制：**由第二个 cordis 插件拿到
 * garmin-connect 正在使用的账号配置**。
 *
 * ── 结论（已实测，见 _probe5.mjs / test/config-resolution.mjs）──────────
 * 不需要重造配置，也不需要破解密码：**正在运行的那个 garmin-connect 实例的
 * 配置就挂在 loader 的 entry 树上**，第二个插件直接读即可。
 *
 * 证据链：
 *   1. `@deepseek-ai/cordis-plugin-loader/src/index.ts:44-46` 把 `loader` 声明为
 *      cordis 服务（`interface Context { loader: Loader }`），任何插件都能
 *      `ctx.get('loader')`。
 *   2. `src/config/tree.ts:27-33`：`EntryTree.entries()` 是生成器，遍历
 *      `store` 里所有 entry（含嵌套子树），所以 `[...loader.entries()]` 能拿到
 *      整个 profile 的 entry 列表。
 *   3. `src/config/entry.ts:207-235`：`Entry.init()` 把**组合后的**配置交给
 *      cordis；cordis `Fiber` 把原始配置存在 `fiber._config`、把 schema 校验
 *      （即 `Config['~standard'].validate`，会填默认值）后的结果存在 `fiber.config`。
 *      实测：`entry.fiber.config` 在 cordis 4.0.4 上取不到（是方法而非字段），
 *      `entry.fiber._config` 与 `entry.options.config` 都是组合后的原始配置。
 *   4. `dsh-plugin-garmin-connect/lib/index.js:13-17` 用
 *      `resolveAccountConfigs(config)` 从该配置推出每个账号的
 *      `{ accountId, slot, region, alias, configured, config }`，其中
 *      `config.sessionTokenFile` 就是磁盘上那份已登录的会话文件。
 *
 * 因此本模块：找到 garmin entry → 取它的配置 → 用 garmin 插件**自己的**
 * `resolveAccountConfigs()` 推出账号配置 → 交给 `GarminClient`。
 * 这条路与运行中的插件走的是同一个纯函数，账号/区域/会话文件三者必然一致。
 *
 * 三级回退（按可靠性排序），每级都会记录 `source` 以便诊断：
 *   A. `loader-tree`     —— 上面的主路径（运行中的宿主 100% 可用）
 *   B. `binding-file`    —— 插件解析成功时把**非敏感**绑定写到
 *                           `<插件目录>\state\account-binding.json`
 *                           （只有 alias/region/sessionTokenFile，没有邮箱）。
 *                           离线脚本（test/data-layer.mjs）用它复现同一账号。
 *   C. `disk-scan`       —— 最后兜底：扫 `accounts/*.session.json` 挑一份仍在
 *                           有效期内的会话；**没有任何用户名时无法通过
 *                           `sessionFileMatchesAccount` 校验**，所以这一级只用于
 *                           给出可诊断的错误，不会伪造成功。
 */
import { readFile, readdir, writeFile, mkdir, rename, unlink } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'
import { loadResolveAccountConfigs, garminPluginDir } from './garmin-module.mjs'

import { paths } from './config.mjs'
export const BINDING_FILE = 'E:\\GarminApp\\backend\\state\\account-binding.json'

/** 只在 garmin-connect 配置里出现的字段，用来在 entry 树中认人。 */
const GARMIN_MARKER_KEYS = [
  'accountsConfigured',
  'globalConfigured',
  'cnConfigured',
  'account1UsernameId',
  'account2UsernameId',
  'account3UsernameId',
]

/** 动态加载 garmin 插件的配置解析器（路径解析见 garmin-module.mjs）。 */
async function importGarmin() {
  return { resolveAccountConfigs: await loadResolveAccountConfigs() }
}

/** 插件实例自己的非敏感身份指纹（不含账号邮箱）。 */
function entryFingerprint(entry) {
  return `${entry.options.id ?? '?'}`
}

/**
 * 把 entry 上组合后的原始配置取出来。
 * @param {any} entry
 */
function rawConfigOf(entry) {
  const fiber = entry?.fiber
  const candidates = [fiber?._config, entry?.options?.config]
  for (const candidate of candidates) {
    if (candidate && typeof candidate === 'object' && !Array.isArray(candidate)) return candidate
  }
  return undefined
}

/** 该 entry 是否像 garmin-connect。 */
function looksLikeGarminEntry(entry) {
  const raw = rawConfigOf(entry)
  if (raw === undefined) return false
  const keys = Object.keys(raw)
  const score = GARMIN_MARKER_KEYS.reduce((n, k) => n + (keys.includes(k) ? 1 : 0), 0)
  if (score >= 2) return true
  // 包名匹配（profile 里 name 通常是 'dsh-plugin-garmin-connect' 或解析后的绝对路径）
  const name = String(entry?.options?.name ?? '')
  return score >= 1 && /garmin/i.test(name)
}

/**
 * 方案 A：从 loader entry 树里解析。
 * @param {any} ctx cordis Context
 * @returns {Promise<{ accounts: any[], entryId: string, raw: any } | undefined>}
 */
export async function resolveFromLoader(ctx) {
  const loader = ctx?.get?.('loader')
  if (!loader || typeof loader.entries !== 'function') return undefined
  const matches = []
  for (const entry of loader.entries()) {
    if (looksLikeGarminEntry(entry)) matches.push(entry)
  }
  if (matches.length === 0) return undefined
  const entry = matches[0]
  const raw = rawConfigOf(entry)
  const { resolveAccountConfigs } = await importGarmin()
  const accounts = resolveAccountConfigs(raw)
  return { accounts, entryId: entryFingerprint(entry), raw }
}

/**
 * 方案 B：读插件自己写下的非敏感绑定缓存。
 * 绑定里含 `sessionTokenFile`（路径，非凭据）与 `region`；**不含邮箱**，
 * 因此不能单独喂给 GarminClient（会话文件校验需要用户名）。
 * @returns {Promise<any | undefined>}
 */
export async function readBinding() {
  try {
    const parsed = JSON.parse(await readFile(BINDING_FILE, 'utf8'))
    if (!parsed || typeof parsed !== 'object') return undefined
    return parsed
  } catch {
    return undefined
  }
}

/**
 * 原子写绑定缓存（只有非敏感字段）。
 * @param {{ entryId: string, accounts: Array<{ accountId: string, region: string, alias: string, sessionTokenFile: string }> }} binding
 */
export async function writeBinding(binding) {
  // 白名单字段，杜绝把用户名/密钥写进缓存。
  const safe = {
    version: 1,
    updatedAt: new Date().toISOString(),
    entryId: String(binding.entryId ?? ''),
    accounts: (binding.accounts ?? []).map((a) => ({
      accountId: String(a.accountId ?? ''),
      region: a.region === 'cn' ? 'cn' : 'global',
      alias: String(a.alias ?? ''),
      sessionTokenFile: String(a.sessionTokenFile ?? ''),
      sessionFileExists: Boolean(a.sessionFileExists),
      sessionRefreshExpiresAt: a.sessionRefreshExpiresAt ?? null,
    })),
  }
  const path = resolve(BINDING_FILE)
  const tmp = `${path}.${process.pid}.tmp`
  try {
    await mkdir(dirname(path), { recursive: true })
    await writeFile(tmp, JSON.stringify(safe, null, 2), { encoding: 'utf8' })
    await rename(tmp, path)
  } catch {
    await unlink(tmp).catch(() => undefined)
  }
}

/**
 * 方案 C：扫盘找候选会话（只给诊断信息，不产出可用账号配置）。
 * @returns {Promise<Array<{ file: string, region: string, refreshExpiresAt: string|null }>>}
 */
export async function scanSessionFiles() {
  const out = []
  try {
    for (const name of await readdir(paths.accountsDir)) {
      if (!name.endsWith('.session.json')) continue
      let region = 'global'
      let refreshExpiresAt = null
      try {
        const parsed = JSON.parse(await readFile(resolve(paths.accountsDir, name), 'utf8'))
        if (parsed?.account?.region === 'cn') region = 'cn'
        if (typeof parsed?.tokens?.refreshExpiresAtMs === 'number') {
          refreshExpiresAt = new Date(parsed.tokens.refreshExpiresAtMs).toISOString()
        }
      } catch { /* 忽略损坏文件 */ }
      out.push({ file: resolve(paths.accountsDir, name), region, refreshExpiresAt })
    }
  } catch { /* 目录不存在 */ }
  return out
}

/**
 * 主入口：解析出可用的 garmin 账号配置。
 *
 * @param {any} ctx cordis Context（可为 undefined —— 离线脚本场景）
 * @param {object} [options]
 * @param {boolean} [options.preferLoader] 是否优先走 loader（脚本里可关掉）
 * @param {boolean} [options.writeBindingCache] 成功后是否写绑定缓存
 * @returns {Promise<{ status: 'ready', source: string, account: any } | { status: 'unconfigured', source: string, accounts: any[] } | { status: 'error', source: string, reason: string, candidates?: any[] }>}
 */
export async function resolveAccount(ctx, options = {}) {
  const { preferLoader = true, writeBindingCache = true } = options
  const errors = []

  // ---- A. loader entry 树（运行中的宿主主路径）
  if (preferLoader && ctx) {
    try {
      const fromLoader = await resolveFromLoader(ctx)
      if (fromLoader && fromLoader.accounts.length > 0) {
        const account = pickAccount(fromLoader.accounts)
        if (account) {
          if (writeBindingCache) {
            // 会话文件是否在盘上 / refresh 何时到期：只记**事实**，不记凭据。
            const sessionFile = account.config?.sessionTokenFile ?? ''
            let sessionFileExists = false
            let sessionRefreshExpiresAt = null
            if (sessionFile) {
              try {
                const parsed = JSON.parse(await readFile(resolve(sessionFile), 'utf8'))
                sessionFileExists = true
                if (typeof parsed?.tokens?.refreshExpiresAtMs === 'number') {
                  sessionRefreshExpiresAt = new Date(parsed.tokens.refreshExpiresAtMs).toISOString()
                }
              } catch { /* 文件不存在或不可读：如实记 false */ }
            }
            void writeBinding({
              entryId: fromLoader.entryId,
              accounts: fromLoader.accounts.map((a) => ({
                accountId: a.accountId,
                region: a.region,
                alias: a.alias,
                sessionTokenFile: a.config?.sessionTokenFile ?? '',
                sessionFileExists,
                sessionRefreshExpiresAt,
              })),
            })
          }
          if (account.configured === false) {
            return { status: 'unconfigured', source: 'loader-tree', accounts: fromLoader.accounts }
          }
          return { status: 'ready', source: 'loader-tree', account }
        }
        return { status: 'unconfigured', source: 'loader-tree', accounts: fromLoader.accounts }
      }
    } catch (error) {
      errors.push(`loader-tree: ${String(error?.message ?? error)}`)
    }
  }

  // ---- B. 绑定缓存（离线脚本复现同一账号）
  const binding = await readBinding()
  if (binding?.accounts?.length) {
    // 绑定里没有邮箱 → 只有显式提供用户名时才可用（见 resolveAccountForScript）。
    return { status: 'error', source: 'binding-file', reason: 'binding carries no username; use resolveAccountForScript()', candidates: binding.accounts }
  }

  // ---- C. 扫描空手而归
  const candidates = await scanSessionFiles()
  if (candidates.length === 0) {
    return {
      status: 'error',
      source: 'none',
      reason: errors.length ? errors.join(' | ') : 'no garmin account binding found in the loader tree, binding cache, or session directory',
    }
  }
  return {
    status: 'error',
    source: 'disk-scan',
    reason: 'session files exist but no username binding is available; GarminClient rejects a session whose account hash cannot be verified',
    candidates,
  }
}

/** 从账号列表里挑一个可用的（优先 configured）。 */
export function pickAccount(accounts) {
  if (!Array.isArray(accounts) || accounts.length === 0) return undefined
  return accounts.find((a) => a?.configured) ?? accounts[0]
}

/**
 * 相对路径的插件定位（供 index.mjs 与离线脚本共用）：
 * 若 garmin-connect 不在候选目录里，可用环境变量 `GARMIN_PLUGIN_DIR` 显式指定。
 */
export function garminModulePath() {
  return garminPluginDir() ?? '(unresolved: set GARMIN_PLUGIN_DIR)'
}

/**
 * 离线（无 DSH）场景的账号配置装配。
 *
 * 用途：`test/data-layer.mjs` 要在没有 DSH、没有 loader 的进程里构造**同一个**
 * GarminClient。做法是把三件已证实的事实拼起来：
 *   1. 用户名 —— 唯一无法从磁盘反推的字段（会话文件只存 `sha256(lower(trim(email)))`）。
 *      来源优先级：显式入参 → `GARMIN_USERNAME` 环境变量 → 绑定缓存里的 `username`
 *      （插件写缓存时**默认不写**用户名；只有 `GARMIN_DASH_BIND_USERNAME=1` 时才写）。
 *   2. 区域 —— 会话文件 `account.region`，或绑定缓存里的 region。
 *   3. 会话文件 —— 绑定缓存里的 `sessionTokenFile`；否则在 accounts 目录里挑
 *      refresh 令牌仍在有效期内、且最近刷新的那一份。
 *
 * 走这条路的调用方拿到的账号配置与插件在宿主里解析出来的**逐字段一致**，
 * 因为用户名/区域/会话文件三个字段都对上了（`sessionFileMatchesAccount`
 * 会自己再校验一遍用户名哈希，错一个字节就会抛错，不会静默用错账号）。
 *
 * @param {object} [options]
 * @param {string} [options.username]
 * @param {string} [options.region]
 * @param {string} [options.sessionTokenFile]
 * @returns {Promise<{ status: 'ready', source: string, config: any } | { status: 'error', source: string, reason: string, candidates?: any[] }>}
 */
export async function resolveAccountForScript(options = {}) {
  const binding = await readBinding()
  const candidates = await scanSessionFiles()

  const username = (options.username ?? process.env.GARMIN_USERNAME ?? binding?.username ?? '').trim()
  let region = (options.region ?? process.env.GARMIN_REGION ?? '').trim()
  if (region !== 'cn' && region !== 'global') region = ''

  let sessionTokenFile = (options.sessionTokenFile ?? '').trim()

  // 绑定缓存优先（它记的就是宿主正在用的那一份）
  let source = 'explicit'
  if (!sessionTokenFile && binding?.accounts?.length) {
    const bound = binding.accounts.find((a) => (region ? a.region === region : true)) ?? binding.accounts[0]
    if (bound?.sessionTokenFile) {
      sessionTokenFile = bound.sessionTokenFile
      region = region || bound.region
      source = 'binding-file'
    }
  }

  if (!sessionTokenFile) {
    // 挑「refresh 未过期且最新」的那份会话文件。
    const now = Date.now()
    const usable = candidates
      .filter((c) => c.refreshExpiresAt === null || Date.parse(c.refreshExpiresAt) > now)
      .sort((a, b) => Date.parse(b.refreshExpiresAt ?? 0) - Date.parse(a.refreshExpiresAt ?? 0))
    if (usable.length > 0) {
      sessionTokenFile = usable[0].file
      region = region || usable[0].region
      source = 'disk-scan'
    }
  }

  if (!username) {
    return {
      status: 'error',
      source: 'username-missing',
      reason: 'GarminClient verifies sha256(lower(trim(username))) against the session file; supply the account email (GARMIN_USERNAME) or run once inside DSH so the binding cache is written',
      candidates,
    }
  }
  if (!sessionTokenFile) {
    return { status: 'error', source: 'session-missing', reason: 'no usable Garmin session file found', candidates }
  }
  return {
    status: 'ready',
    source,
    config: {
      username,
      region: region || 'global',
      sessionTokenFile,
    },
  }
}

/**
 * `sessionFileMatchesAccount` 的本地复现：在**不发起任何网络请求**的前提下，
 * 提前判断「这个用户名 + 这份会话文件」能否通过 GarminClient 的校验。
 * 用于给用户精确报错，而不是等一次失败的登录。
 *
 * 依据：`dsh-plugin-garmin-connect/lib/session-store.js:476-482`
 *   usernameHash = sha256(username.trim().normalize('NFKC').toLowerCase())
 *
 * @param {string} username
 * @param {string} region
 * @param {string} sessionFilePath
 * @returns {Promise<{ ok: boolean, reason?: string, refreshExpiresAt?: string }>}
 */
export async function precheckSession(username, region, sessionFilePath) {
  const { createHash } = await import('node:crypto')
  let parsed
  try {
    parsed = JSON.parse(await readFile(resolve(sessionFilePath), 'utf8'))
  } catch (error) {
    return { ok: false, reason: `session file unreadable: ${String(error?.message ?? error)}` }
  }
  const expected = createHash('sha256')
    .update(String(username).trim().normalize('NFKC').toLowerCase())
    .digest('hex')
  const actual = parsed?.account?.usernameHash
  if (typeof actual !== 'string') return { ok: false, reason: 'session file has no account binding' }
  if (actual !== expected) return { ok: false, reason: 'session file is bound to a different Garmin account' }
  if (parsed?.account?.region !== region) return { ok: false, reason: 'session file is bound to a different region' }
  const exp = parsed?.tokens?.refreshExpiresAtMs
  const refreshExpiresAt = typeof exp === 'number' ? new Date(exp).toISOString() : undefined
  if (typeof exp === 'number' && exp <= Date.now()) return { ok: false, reason: 'session refresh token expired', refreshExpiresAt }
  return { ok: true, refreshExpiresAt }
}
