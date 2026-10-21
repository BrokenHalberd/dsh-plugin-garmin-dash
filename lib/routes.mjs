/**
 * routes.mjs — `/garmin-dash` 的 HTTP 契约实现。
 *
 * ── 注册机制（照抄 @linxin666/dsh-remote-web-ui）──────────────────────
 * 路由对象形状与注册调用完全复刻该插件的做法：
 *   - `src/routes.ts:1022-1041` 构造 `WebRoute[]`：`{ kind: 'exact'|'prefix', path, handler }`
 *   - `lib/types/routes.js:951` 附近 handler 自己 `writeHead(...)` + `end(...)`
 *   - `lib/types/index.js:732` 注册：`routes.map(route => ctx.webServer.register(route))`
 * `@deepseek-ai/dsh-host-webserver/lib/index.js:177-184` 的 `register()` 对
 * `kind === 'exact'` 用精确表、否则用前缀表；`match()`（同文件 323-332 行）先查
 * 精确表，再取**最长前缀**，且用 `new URL(req.url).pathname` 匹配 —— 因此
 * 查询串永远不会参与匹配，`?date=`/`?limit=` 由 handler 自己解析。
 *
 * 本插件只注册**一个 prefix 路由** `/garmin-dash`，在内部自己分派：
 * 好处是 (a) 与其它插件零路径冲突风险（前缀只此一家），(b) 新增端点不需要
 * 再动注册表，(c) 与 remote-web-ui 的 `/api/pair/*` 那套 exact 路由互不干扰。
 *
 * ── 认证 ──────────────────────────────────────────────────────────
 * `/garmin-dash/api/health` 与 `/garmin-dash/pair` 免鉴权；其余端点要求
 * `X-Device-Key`。`/garmin-dash/internal/mint-code` 额外要求**回环来源**。
 *
 * ── 缓存 ──────────────────────────────────────────────────────────
 * 60 秒 TTL（见 cache.mjs 注释）。App 轮询不会打到 Garmin。
 */
import { existsSync } from 'node:fs'
import { spawn } from 'node:child_process'
import { paths, dshHome, selfCheck } from './config.mjs'
import { setupPageHtml } from './setup-page.mjs'
import { renderQrPng, qrAvailable } from './qr.mjs'
import { PairStore, normalizePairCode } from './pair-store.mjs'
import { TtlCache } from './cache.mjs'
import { writeSnapshot, localDate } from './snapshot.mjs'
import { classifyError } from './garmin-service.mjs'
import { pairPageHtml, escapeHtml } from './pages.mjs'
import { computeLoadSeries, weeklyTotals, tssOf, toLocalDate, dateRange, addDays, WARMUP_DAYS } from './trend.mjs'

/** 契约版本（`GET /health` 的 version 字段）。 */
export const API_VERSION = '1'
/** 缓存 TTL：60 秒。见 lib/cache.mjs 顶部注释。 */
export const CACHE_TTL_MS = 60_000
/** trend 缓存 TTL：5 分钟（重算要翻多页活动，且 CTL/ATL 是慢变量）。 */
export const TREND_CACHE_TTL_MS = 5 * 60_000
/** 路由前缀。 */
export const PREFIX = '/garmin-dash'

// ── App 内建聊天（DSH 完整会话）──────────────────────────────────────
// 设计：每条消息起一个短进程（dsh --profile headless），但始终用 --session-id
// 续接**同一个持久会话** → 完整会话记忆、跨消息/跨重启连续；该会话的存储位置
// 由工作区决定，因此工作区是结构性锁死的。
// 权限档双保险：headless profile 的 defaultPreset + 聊天子进程的 DSH_PERMISSION_MODE。
// 全部路径来自配置（lib/config.mjs）：显式配置 > 环境变量 > 历史路径 > 可移植默认值。

/** 判断来源是否为本机回环。 */
export function isLoopback(req) {
  const addr = req?.socket?.remoteAddress ?? ''
  return addr === '127.0.0.1' || addr === '::1' || addr === '::ffff:127.0.0.1'
}

/**
 * 读公共域名：`https://<registry.id>.dsh-market.com`。
 * 注册表读不到时返回空串（页面/CLI 会退化成"只显示配对码"）。
 * @param {(path: string) => string} readFileSync
 */
export function publicBaseUrl(readFileSync) {
  const override = process.env.GARMIN_DASH_PUBLIC_BASE?.trim()
  if (override) return override.replace(/\/+$/, '')
  try {
    const raw = readFileSync(paths.relayRegistryFile, 'utf8')
    const id = JSON.parse(raw)?.id
    if (typeof id === 'string' && /^[a-z0-9]{8,64}$/i.test(id)) return `https://${id}.dsh-market.com`
  } catch { /* 注册表缺失/损坏：退化为空 */ }
  return ''
}

/** 写 JSON 响应。 */
function sendJson(res, status, payload) {
  const body = JSON.stringify(payload)
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(body),
  })
  res.end(body)
}

/** 写 HTML 响应。 */
function sendHtml(res, status, body) {
  res.writeHead(status, {
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(body),
  })
  res.end(body)
}

/** 统一出口：有 raw 就按二进制/HTML 写，否则写 JSON。 */
function sendResult(res, result) {
  if (result && result.raw !== undefined) {
    const body = Buffer.isBuffer(result.raw) ? result.raw : Buffer.from(String(result.raw), 'utf8')
    res.writeHead(result.status ?? 200, {
      'content-type': result.type ?? 'application/octet-stream',
      'cache-control': 'no-store',
      'content-length': body.length,
    })
    res.end(body)
    return
  }
  return sendJson(res, result.status, result.payload)
}

/** 读取并解析 JSON 请求体（上限 8 KiB，防止内存滥用）。 */
export async function readJsonBody(req, limitBytes = 8192) {
  const chunks = []
  let size = 0
  for await (const chunk of req) {
    size += chunk.length
    if (size > limitBytes) throw new Error('request body too large')
    chunks.push(chunk)
  }
  if (size === 0) return {}
  const text = Buffer.concat(chunks).toString('utf8')
  const parsed = JSON.parse(text)
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('request body must be a JSON object')
  return parsed
}

/**
 * 构造 `/garmin-dash` 的处理器集合。
 *
 * @param {object} deps
 * @param {import('./garmin-service.mjs').GarminService} deps.service
 * @param {{ info: Function, warn: Function, debug: Function, error: Function }} deps.logger
 * @param {() => string} deps.todayLocal
 * @param {(path: string, enc: string) => string} deps.readFileSync
 * @param {PairStore} [deps.pairStore]
 * @param {number} [deps.cacheTtlMs]
 * @returns {{ handler: (req: any, res: any) => Promise<void>, pairStore: PairStore, cache: TtlCache }}
 */
export function createRouter(deps) {
  const { service, logger, todayLocal, readFileSync } = deps
  /** 本宿主 webserver 端口：回环调用同宿主的 remote-web-ui 配对端点用 */
  const port = Number.isFinite(deps.port) ? deps.port : 43121
  const pairStore = deps.pairStore ?? new PairStore()
  const cache = new TtlCache(deps.cacheTtlMs ?? CACHE_TTL_MS)

  /**
   * 落快照（旁路，永不抛出到 HTTP 层）。
   * @param {string} date
   * @param {string} endpoint
   * @param {unknown} data
   */
  const snapshot = (date, endpoint, data) => {
    void writeSnapshot({ date, endpoint, data }).catch((error) => {
      logger.warn(`[garmin-dash] snapshot failed for %s/%s: %s`, date, endpoint, String(error?.message ?? error))
    })
  }

  /** 参数解析：YYYY-MM-DD。 */
  const parseDate = (value, fallback) => {
    if (value === null || value === undefined || value === '') return fallback
    if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return undefined
    const parsed = new Date(`${value}T00:00:00`)
    return Number.isNaN(parsed.getTime()) ? undefined : value
  }

  /** 参数解析：正整数。 */
  const parsePositiveInt = (value, fallback, max) => {
    if (value === null || value === undefined || value === '') return fallback
    const n = Number(value)
    if (!Number.isFinite(n) || !Number.isInteger(n) || n < 0) return undefined
    return Math.min(n, max)
  }

  // --------------------------------------------------------------- endpoints

  const endpoints = {
    /** 1. GET /api/health —— 免鉴权。 */
    async health() {
      return { status: 200, payload: { ok: true, version: API_VERSION } }
    },

    /** 2. POST /api/pair —— 免鉴权，用一次性配对码换长期设备密钥。 */
    async pair(req, url) {
      if (req.method !== 'POST') return { status: 405, payload: { error: 'method_not_allowed' } }
      const ip = req.socket?.remoteAddress ?? 'unknown'
      if (pairStore.isBlocked(ip)) {
        logger.warn('[garmin-dash] pair attempt refused: too many failures from this address')
        return { status: 401, payload: { error: 'invalid_pair_code' } }
      }
      let body
      try {
        body = await readJsonBody(req)
      } catch {
        pairStore.recordFailure(ip)
        return { status: 401, payload: { error: 'invalid_pair_code' } }
      }
      const code = normalizePairCode(body.pairCode ?? url.searchParams.get('code') ?? '')
      if (code.length !== 8) {
        pairStore.recordFailure(ip)
        return { status: 401, payload: { error: 'invalid_pair_code' } }
      }
      const result = await pairStore.redeem(code, typeof body.name === 'string' ? { name: body.name } : {})
      if (!result.ok) {
        pairStore.recordFailure(ip)
        logger.info('[garmin-dash] pair attempt failed (bad/expired/used code)')
        return { status: 401, payload: { error: 'invalid_pair_code' } }
      }
      pairStore.clearFailures(ip)
      logger.info('[garmin-dash] device paired (id %s)', result.deviceId)
      return { status: 200, payload: { deviceKey: result.deviceKey, deviceId: result.deviceId } }
    },

    /** 4. GET /api/summary */
    async summary(req, url) {
      const today = todayLocal()
      const date = parseDate(url.searchParams.get('date'), today)
      if (date === undefined) return { status: 400, payload: { error: 'invalid_date' } }
      const data = await cache.wrap(`summary:${date}`, () => service.getSummary(date))
      snapshot(date, 'summary', data)
      return { status: 200, payload: data }
    },

    /** 5. GET /api/activities */
    async activities(req, url) {
      const limit = parsePositiveInt(url.searchParams.get('limit'), 20, 100)
      const offset = parsePositiveInt(url.searchParams.get('offset'), 0, 100_000)
      if (limit === undefined || offset === undefined) {
        return { status: 400, payload: { error: 'invalid_pagination' } }
      }
      // 按天窗口：分页拉取直到覆盖窗口（不用固定条数）
      const daysParam = url?.searchParams?.get('days')
      if (daysParam !== null && daysParam !== undefined) {
        const win = Math.max(1, Math.min(400, Number(daysParam) || 90))
        const cutStr = new Date(Date.now() - win * 86400000).toISOString().slice(0, 10)
        const all = []
        let page = 0
        while (page < 8) {
          let chunk = []
          try {
            chunk = await service.getActivities({ limit: 100, offset: page * 100 })
          } catch (error) {
            break
          }
          const items = Array.isArray(chunk) ? chunk : []
          if (items.length === 0) break
          for (const it of items) all.push(it)
          page++
          const oldest = String(items[items.length - 1]?.startTime ?? '').slice(0, 10)
          if (items.length < 100) break
          if (oldest !== '' && oldest < cutStr) break
        }
        const inWin = all.filter((a) => String(a?.startTime ?? '').slice(0, 10) >= cutStr)
        return { status: 200, payload: { days: win, from: cutStr, count: inWin.length, scanned: all.length, activities: inWin } }
      }
      const data = await cache.wrap(`activities:${limit}:${offset}`, () => service.getActivities({ limit, offset }))
      snapshot(todayLocal(), `activities`, { limit, offset, items: data })
      return { status: 200, payload: data }
    },

    /** 6. GET /api/activity —— 全量详情 */
    async activity(req, url) {
      const id = parsePositiveInt(url.searchParams.get('id'), undefined, Number.MAX_SAFE_INTEGER)
      if (id === undefined || id === 0) return { status: 400, payload: { error: 'invalid_activity_id' } }
      const data = await cache.wrap(`activity:${id}`, () => service.getActivityDetail(id))
      const date = toLocalDate(data.startTimeLocal ?? data.startTime) ?? todayLocal()
      snapshot(date, `activity:${id}`, data)
      return { status: 200, payload: data }
    },

    /** 7. GET /api/trend */
    async trend(req, url) {
      const days = parsePositiveInt(url.searchParams.get('days'), 90, 730)
      if (days === undefined || days === 0) return { status: 400, payload: { error: 'invalid_days' } }
      const data = await cache.wrap(`trend:${days}`, () => buildTrend(service, days, todayLocal()), TREND_CACHE_TTL_MS)
      snapshot(todayLocal(), `trend`, data)
      return { status: 200, payload: data }
    },

    /** 内部：铸造配对码（仅回环）。 */
    async mintCode(req) {
      if (req.method !== 'POST') return { status: 405, payload: { error: 'method_not_allowed' } }
      if (!isLoopback(req)) {
        logger.warn('[garmin-dash] refused non-loopback mint-code request')
        return { status: 403, payload: { error: 'forbidden' } }
      }
      const minted = pairStore.mint()
      const base = publicBaseUrl(readFileSync)
      const url = `${base}${PREFIX}/pair?code=${minted.code}`
      logger.info('[garmin-dash] pairing code minted (expires in %ds)', minted.expiresInSeconds)
      return {
        status: 200,
        payload: { code: minted.code, url, expiresAt: minted.expiresAt, expiresInSeconds: minted.expiresInSeconds },
      }
    },
  }

  // ------------------------------------------------------------- dispatcher

  /**
   * 读取设备密钥并校验。
   * @returns {boolean}
   */
  /**
   * 「DSH 对话」入口：向同宿主的 remote-web-ui 申请一次性配对链接。
   *
   * 为什么这样做：App 里要能直接和 DSH 对话（数据分析、课程规划），而完整的
   * DSH Web GUI 本身已经是手机适配界面。手机在 App 内打开这个链接即完成配对
   * （10 分钟、单次有效），此后 App 内可长期直接对话——既不用去浏览器再扫码，
   * 也不需要把 harness token 交给 App。
   */
  endpoints.dshLink = async () => {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/api/pair/issue`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: '{}',
      })
      if (!response.ok) {
        return { status: 503, payload: { error: 'pair_issue_failed', http: response.status } }
      }
      const data = await response.json()
      const target = data?.url ?? data?.link ?? null
      if (typeof target !== 'string' || target.length === 0) {
        return { status: 503, payload: { error: 'pair_issue_empty' } }
      }
      return { status: 200, payload: { url: target, ttlSeconds: 600 } }
    } catch (error) {
      logger.warn('[garmin-dash] dsh-link failed: %s', String(error?.message ?? error))
      return { status: 503, payload: { error: 'pair_issue_unreachable' } }
    }
  }
  /**
   * App 内建聊天：把一条用户消息送进**固定的持久会话**，返回助手回复。
   *
   * 为什么用子进程而不是宿主内直连 agent：headless 应用天然就是「一轮一进程」，
   * 而会话本身持久化在 DSH_HOME 里，所以拿到的是**完整会话记忆**（已实测：
   * 第二轮能答出第一轮给的事实），同时工作区（cwd）与权限档（环境变量）都由
   * 后端固定，App 侧没有任何入口能改。
   */
  endpoints.chat = async (req) => {
    let body
    try {
      body = await readJsonBody(req, 16384)
    } catch {
      return { status: 400, payload: { error: 'bad_request' } }
    }
    const text = typeof body?.text === 'string' ? body.text.trim() : ''
    if (text.length === 0) {
      return { status: 400, payload: { error: 'empty_message' } }
    }
    if (text.length > 8000) {
      return { status: 400, payload: { error: 'message_too_long' } }
    }
    const incoming = typeof body?.sessionId === 'string' ? body.sessionId.trim() : ''
    const sessionId = /^session-[0-9a-f-]{8,}$/i.test(incoming) ? incoming : undefined

    const args = ['--expose-internals', paths.desktopCli, '--profile', paths.chatProfile, '--json']
    if (sessionId !== undefined) args.push('--session-id', sessionId)
    args.push(text)

    return await new Promise((resolve) => {
      let child
      try {
        child = spawn(paths.desktopExe, args, {
          cwd: paths.chatWorkspace,
          env: {
            ...process.env,
            ELECTRON_RUN_AS_NODE: '1',
            DSH_HOME: dshHome(),
            // 权限档锁死：与 headless profile 的 defaultPreset 一致
            DSH_PERMISSION_MODE: 'workspace-write',
          },
          windowsHide: true,
        })
      } catch (error) {
        logger.warn('[garmin-dash] chat spawn failed: %s', String(error?.message ?? error))
        resolve({ status: 503, payload: { error: 'chat_unavailable' } })
        return
      }

      let stdout = ''
      let stderr = ''
      let settled = false
      const done = (payload, status) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        resolve({ status, payload })
      }
      const timer = setTimeout(() => {
        try { child.kill() } catch { /* 已退出 */ }
        done({ error: 'chat_timeout' }, 504)
      }, paths.chatTimeoutMs)

      child.stdout?.on('data', (chunk) => { stdout += String(chunk) })
      child.stderr?.on('data', (chunk) => { if (stderr.length < 4000) stderr += String(chunk) })
      child.on('error', (error) => {
        logger.warn('[garmin-dash] chat process error: %s', String(error?.message ?? error))
        done({ error: 'chat_unavailable' }, 503)
      })
      child.on('close', (code) => {
        let reply = ''
        let newSessionId = sessionId ?? ''
        const tools = []
        for (const line of stdout.split('\n')) {
          const trimmed = line.trim()
          if (trimmed.length === 0) continue
          let event
          try { event = JSON.parse(trimmed) } catch { continue }
          if (event?.type === 'session' && typeof event.sessionId === 'string') newSessionId = event.sessionId
          else if (event?.type === 'final' && typeof event.text === 'string') reply = event.text
          else if (event?.type === 'tool_call' && typeof event.name === 'string' && tools.length < 24) tools.push(event.name)
        }
        if (reply.length === 0) {
          logger.warn('[garmin-dash] chat produced no reply (code %s): %s', code, stderr.slice(0, 300))
          done({ error: 'chat_failed', code }, 502)
          return
        }
        done({ reply, sessionId: newSessionId, tools }, 200)
      })
    })
  }
  // ── 部署引导（切片 2）────────────────────────────────────────────────
  /** 包内 App 产物路径（发布版会把未签名 HAP 放在 assets/ 下）。 */
  const appAsset = () => new URL('../assets/GarminDash-latest.hap', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')
  /** 插件版本（用于引导页展示）。 */
  const pluginVersion = () => {
    try {
      const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'))
      return pkg.version ?? '0.0.0'
    } catch {
      return '0.0.0'
    }
  }
  /** 公网基址：显式配置优先，否则从中继注册表推断。 */
  const publicBaseOf = () => {
    if (paths.publicBase) return paths.publicBase
    try {
      const raw = readFileSync(paths.relayRegistryFile, 'utf8')
      const parsed = JSON.parse(raw)
      const id = typeof parsed?.id === 'string' ? parsed.id : ''
      if (/^[a-z0-9]{8,64}$/i.test(id)) return `https://${id}.dsh-market.com`
    } catch {
      /* 未启用中继 */
    }
    return ''
  }

  /** 自检项（引导页与 /api/selfcheck 共用）。 */
  const buildChecks = async () => {
    const list = [{ level: 'ok', label: 'webServer（DSH 宿主服务）', detail: '插件已挂载路由' }]
    try {
      const probe = await deps.probe()
      list.push({ level: probe.bound ? 'ok' : 'error', label: 'Garmin 账号绑定', detail: probe.detail })
    } catch (error) {
      list.push({ level: 'error', label: 'Garmin 账号绑定', detail: `未就绪：${String(error?.message ?? error)}` })
    }
    for (const issue of selfCheck().issues) {
      list.push({ level: issue.level === 'warn' ? 'warn' : 'error', label: issue.label, detail: issue.detail })
    }
    list.push({
      level: paths.chatEnabled ? 'ok' : 'warn',
      label: '内建聊天（App 里的 DSH 对话）',
      detail: paths.chatEnabled ? `profile=${paths.chatProfile}` : '已在配置中关闭',
    })
    list.push({
      level: qrAvailable() ? 'ok' : 'warn',
      label: '二维码渲染库',
      detail: qrAvailable() ? 'qrcode 可用' : '未找到 qrcode：引导页降级为链接显示',
    })
    const base = publicBaseOf()
    list.push({ level: base ? 'ok' : 'warn', label: '公网访问（中继）', detail: base || '未启用：手机仅在同一局域网可用' })
    const asset = appAsset()
    list.push({ level: existsSync(asset) ? 'ok' : 'warn', label: '包内 App 产物', detail: existsSync(asset) ? 'assets/GarminDash-latest.hap' : '本包未附带（需自源码构建）' })
    return list
  }

  /** 引导页（仅本机回环可达）。 */
  endpoints.setup = async () => {
    const checks = await buildChecks()
    const html = setupPageHtml({
      checks,
      version: pluginVersion(),
      qrReady: qrAvailable(),
      publicBase: publicBaseOf(),
      hasAppAsset: existsSync(appAsset()),
    })
    return { status: 200, type: 'text/html; charset=utf-8', raw: html }
  }

  /** 自检 JSON（仅本机回环可达）。 */
  endpoints.selfCheck = async () => {
    const checks = await buildChecks()
    return { status: 200, payload: { ok: checks.every((c) => c.level !== 'error'), checks, version: pluginVersion() } }
  }

  /** 配对二维码 PNG：每次请求现铸一个新码（仅本机回环可达）。 */
  endpoints.pairQr = async () => {
    const minted = pairStore.mint()
    const base = publicBaseOf() || `http://127.0.0.1:${deps.port ?? 43121}`
    const url = `${base}${PREFIX}/pair?code=${minted.code}`
    const png = await renderQrPng(url, { width: 480 })
    if (png === null) {
      return { status: 503, payload: { error: 'qr_unavailable', url, code: minted.code } }
    }
    return { status: 200, type: 'image/png', raw: png }
  }

  /** App 产物下载（仅本机回环可达）。 */
  endpoints.appAsset = async () => {
    const asset = appAsset()
    if (!existsSync(asset)) return { status: 404, payload: { error: 'app_asset_missing' } }
    return { status: 200, type: 'application/octet-stream', raw: readFileSync(asset) }
  }
  /** 身体电量（需设备密钥）：当日高/低值 */
  endpoints.bodyBattery = async (req, url) => {
    const date = url?.searchParams?.get('date') ?? todayLocal()
    try {
      return { status: 200, payload: await deps.service.rawBodyBattery(date) }
    } catch (error) {
      return { status: 200, payload: { available: false, reason: String(error?.message ?? error) } }
    }
  }

  /** 路线数据（需设备密钥） */
  endpoints.route = async (req, url) => {
    const id = Number(url?.searchParams?.get('id') ?? 0)
    const maxPoints = Number(url?.searchParams?.get('points') ?? 600)
    if (!id) {
      return { status: 400, payload: { error: 'id required' } }
    }
    try {
      return { status: 200, payload: await deps.service.routeOf(id, maxPoints) }
    } catch (error) {
      return { status: 200, payload: { available: false, reason: String(error?.message ?? error) } }
    }
  }

  /** 路线探测（仅回环） */
  endpoints.routeProbe = async (req, url) => {
    const id = Number(url?.searchParams?.get('id') ?? 0)
    if (!id) {
      return { status: 400, payload: { error: 'id required' } }
    }
    try {
      return { status: 200, payload: await deps.service.rawRouteProbe(id) }
    } catch (error) {
      return { status: 200, payload: { ok: false, reason: String(error?.message ?? error) } }
    }
  }

  /** 身体电量探测（仅回环）：调 service 内的取数方法 */
  endpoints.bbProbe = async (req, url) => {
    const date = url?.searchParams?.get('date') ?? todayLocal()
    try {
      return { status: 200, payload: await deps.service.rawBodyBattery(date) }
    } catch (error) {
      return { status: 200, payload: { available: false, reason: String(error?.message ?? error) } }
    }
  }

  /** HRV 探测（仅本机回环）：看当前账号/设备有没有 HRV Status 数据 */
  endpoints.hrvProbe = async (req, url) => {
    const date = url?.searchParams?.get('date') ?? todayLocal()
    try {
      const service = deps.service
      const data = await service.rawHrv(date)
      return { status: 200, payload: data }
    } catch (error) {
      return { status: 200, payload: { available: false, reason: String(error?.message ?? error) } }
    }
  }

  /** 功率曲线聚合（需设备密钥）：后端算好，App 一次拿走 */
  endpoints.curve = async (req, url) => {
    const days = Number(url?.searchParams?.get('days') ?? 90)
    try {
      return { status: 200, payload: await deps.service.curveSummary(days) }
    } catch (error) {
      return { status: 200, payload: { error: String(error?.message ?? error) } }
    }
  }

  /** HRV 区间（需设备密钥）：一次拿 N 天 */
  endpoints.hrvRange = async (req, url) => {
    const days = Number(url?.searchParams?.get('days') ?? 14)
    try {
      return { status: 200, payload: await deps.service.rawHrvRange(days) }
    } catch (error) {
      return { status: 200, payload: { available: false, reason: String(error?.message ?? error), days: [] } }
    }
  }

  /** HRV 正式接口（需设备密钥） */
  endpoints.hrv = async (req, url) => {
    const date = url?.searchParams?.get('date') ?? todayLocal()
    try {
      const data = await deps.service.rawHrv(date)
      return { status: 200, payload: data }
    } catch (error) {
      return { status: 200, payload: { available: false, reason: String(error?.message ?? error) } }
    }
  }
  const authorize = (req) => {
    const key = req.headers['x-device-key']
    const value = Array.isArray(key) ? key[0] : key
    if (typeof value !== 'string' || value.length === 0) return false
    const ok = pairStore.verify(value)
    if (ok) pairStore.touch(value)
    return ok
  }

  /**
   * 主 handler：由 webServer 的前缀路由把 `/garmin-dash*` 全部交到这里。
   * 自己拥有整个响应生命周期（与 remote-web-ui 一致）。
   */
  async function handler(req, res) {
    /** @type {URL} */
    let url
    try {
      url = new URL(req.url ?? '/', 'http://127.0.0.1')
    } catch {
      sendJson(res, 400, { error: 'bad_request' })
      return
    }
    const path = url.pathname

    try {
      // —— 免鉴权 ——
      if (path === `${PREFIX}/api/health`) {
        const { status, payload } = await endpoints.health()
        return sendJson(res, status, payload)
      }
      if (path === `${PREFIX}/api/pair`) {
        const { status, payload } = await endpoints.pair(req, url)
        return sendJson(res, status, payload)
      }
      if (path === `${PREFIX}/pair` || path === `${PREFIX}/pair/`) {
        const code = normalizePairCode(url.searchParams.get('code') ?? '')
        const html = pairPageHtml({ code, ttlSeconds: 600, minted: false })
        return sendHtml(res, 200, html)
      }
      // —— 内部（仅回环）——
      if (path === `${PREFIX}/internal/mint-code`) {
        if (!isLoopback(req)) {
          logger.warn('[garmin-dash] refused non-loopback internal request')
          return sendJson(res, 403, { error: 'forbidden' })
        }
        const { status, payload } = await endpoints.mintCode(req)
        return sendJson(res, status, payload)
      }

      if (path === `${PREFIX}/internal/route-probe`) {
        if (!isLoopback(req)) {
          return sendJson(res, 403, { error: 'forbidden' })
        }
        const probe = await endpoints.routeProbe(req, url)
        return sendJson(res, probe.status, probe.payload)
      }

      if (path === `${PREFIX}/internal/bb-probe`) {
        if (!isLoopback(req)) {
          return sendJson(res, 403, { error: 'forbidden' })
        }
        const probe = await endpoints.bbProbe(req, url)
        return sendJson(res, probe.status, probe.payload)
      }

      if (path === `${PREFIX}/internal/hrv-probe`) {
        if (!isLoopback(req)) {
          return sendJson(res, 403, { error: 'forbidden' })
        }
        const probe = await endpoints.hrvProbe(req, url)
        return sendJson(res, probe.status, probe.payload)
      }

      // —— 部署引导（仅本机回环；不需要设备密钥）——
      if (path === `${PREFIX}/setup` || path === `${PREFIX}/pair-qr.png`
        || path === `${PREFIX}/app/latest.hap` || path === `${PREFIX}/api/selfcheck`) {
        if (!isLoopback(req)) {
          logger.warn('[garmin-dash] refused non-loopback setup request')
          return sendJson(res, 403, { error: 'loopback_only' })
        }
        let pub
        if (path === `${PREFIX}/setup`) pub = await endpoints.setup()
        else if (path === `${PREFIX}/api/selfcheck`) pub = await endpoints.selfCheck()
        else if (path === `${PREFIX}/pair-qr.png`) pub = await endpoints.pairQr()
        else pub = await endpoints.appAsset()
        return sendResult(res, pub)
      }

      // —— 需要设备密钥 ——
      if (!authorize(req)) {
        return sendJson(res, 401, { error: 'unauthorized' })
      }

      let result
      if (path === `${PREFIX}/api/summary`) result = await endpoints.summary(req, url)
      else if (path === `${PREFIX}/api/activities`) result = await endpoints.activities(req, url)
      else if (path === `${PREFIX}/api/activity`) result = await endpoints.activity(req, url)
      else if (path === `${PREFIX}/api/trend`) result = await endpoints.trend(req, url)
      else if (path === `${PREFIX}/api/dsh-link`) result = await endpoints.dshLink(req)
      else if (path === `${PREFIX}/api/chat`) result = await endpoints.chat(req)
      else if (path === `${PREFIX}/api/hrv`) result = await endpoints.hrv(req, url)
      else if (path === `${PREFIX}/api/hrv-range`) result = await endpoints.hrvRange(req, url)
      else if (path === `${PREFIX}/api/curve`) result = await endpoints.curve(req, url)
      else if (path === `${PREFIX}/api/body-battery`) result = await endpoints.bodyBattery(req, url)
      else if (path === `${PREFIX}/api/route`) result = await endpoints.route(req, url)
      else return sendJson(res, 404, { error: 'not_found' })
      return sendResult(res, result)
    } catch (error) {
      const kind = classifyError(error)
      if (error?.code === 'not-found' || kind === 'bad-request') {
        return sendJson(res, 404, { error: 'not_found' })
      }
      // 上游限流 / 会话失效 / 网络问题：一律 503，绝不把宿主带崩。
      logger.warn('[garmin-dash] upstream failure (%s) on %s', kind, path)
      logger.debug('[garmin-dash] %s', String(error?.stack ?? error?.message ?? error))
      return sendJson(res, 503, { error: 'upstream_unavailable' })
    }
  }




  return { handler, pairStore, cache, endpoints }
}

/**
 * 计算 trend（导出以便单测与离线脚本复用）。
 *
 * @param {import('./garmin-service.mjs').GarminService} service
 * @param {number} days
 * @param {string} today
 */
export async function buildTrend(service, days, today) {
  const end = today
  const start = addDays(end, -(days - 1))
  const warmupStart = addDays(start, -WARMUP_DAYS)
  const activities = await service.getActivitiesBetween(warmupStart, end)

  /** @type {Map<string, number>} */
  const tssByDate = new Map()
  for (const activity of activities) {
    const date = activity.date
    if (date === null) continue
    tssByDate.set(date, (tssByDate.get(date) ?? 0) + tssOf(activity))
  }

  const points = computeLoadSeries({ start, end, warmupStart, tssByDate })
  const windowActivities = activities.filter((a) => a.date !== null && a.date >= start && a.date <= end)
  return {
    days,
    start,
    end,
    points,
    weekly: weeklyTotals(windowActivities),
    activityCount: windowActivities.length,
    warmupDays: WARMUP_DAYS,
    formula: 'ctl_today = ctl_yesterday + (tss_today - ctl_yesterday)/42; atl_today = atl_yesterday + (tss_today - atl_yesterday)/7; tsb_today = ctl_today - atl_yesterday',
  }
}

export { escapeHtml, dateRange, localDate }
