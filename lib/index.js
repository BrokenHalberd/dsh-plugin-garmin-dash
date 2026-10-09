/**
 * dsh-plugin-garmin-dash —— DSH 宿主插件入口。
 *
 * 职责：在 DSH webserver 上挂 `/garmin-dash` 前缀路由，把
 * `dsh-plugin-garmin-connect` 已经登录好的数据层暴露给手机 App。
 *
 * ── 模块格式 ──────────────────────────────────────────────────────
 * ESM（`package.json` 里 `"type": "module"`，`main: lib/index.js`）。
 * 依据：DSH loader 用 `EntryTree.import()` → `ModuleLoader.import()`
 * （`@deepseek-ai/cordis-plugin-loader/src/config/tree.ts:112-129`）走原生
 * `import()`，`Loader.unwrapExports()`（`src/index.ts:201-208`）兼容
 * CJS/ESM/default 三种形态。同 profile 里的
 * `@linxin666/dsh-remote-web-ui` 就是 ESM + `export const inject`，照抄该形态。
 *
 * ── 服务依赖 ──────────────────────────────────────────────────────
 * `inject = ['webServer', 'loader']`：
 *   - `webServer` —— `@deepseek-ai/dsh-host-webserver` 提供的命名服务，
 *     `ctx.webServer.register(route)` 注册路由（`lib/index.js:177-184`）。
 *   - `loader` —— `@deepseek-ai/cordis-plugin-loader` 的 `Loader` 服务，
 *     用来读 garmin-connect entry 的账号配置（见 lib/config-resolution.mjs）。
 * cordis 会等到这两个服务就绪才激活本插件；`loader` 若不可用也不会让插件
 * 卡死（`inject` 是硬依赖，但 loader 是 bundle 里必然存在的服务）。
 */
import { readFileSync } from 'node:fs'
import { loadGarminClient, loadGarminToolService } from './garmin-module.mjs'
import { resolveAccount } from './config-resolution.mjs'
import { GarminService } from './garmin-service.mjs'
import { createRouter, PREFIX, API_VERSION } from './routes.mjs'
import { PairStore } from './pair-store.mjs'
import { configure, describePaths } from './config.mjs'

export const name = 'garmin-dash'
export const inject = ['webServer', 'loader']

/** 账号配置的复用窗口：超过这个时间重新去 loader 树里看一眼（entry 重启会换实例）。 */
const ACCOUNT_TTL_MS = 5 * 60 * 1000

/** 本地时区 YYYY-MM-DD。 */
function todayLocal(date = new Date()) {
  const y = date.getFullYear()
  const m = String(date.getMonth() + 1).padStart(2, '0')
  const d = String(date.getDate()).padStart(2, '0')
  return `${y}-${m}-${d}`
}

/**
 * 插件本体。
 * @param {any} ctx cordis Context
 * @param {any} config 插件配置（本插件当前不需要配置项；保留形参以符合 loader 契约）
 */
export function apply(ctx, config) { // eslint-disable-line no-unused-vars
  const logger = ctx.logger

  const pairStore = new PairStore()
  /** 设备库载入是一次性的异步操作，路由自身不依赖它（verify 在未载入时返回 false）。 */
  void pairStore.load().catch(() => undefined)

  /** @type {{ service: GarminService, source: string } | undefined} */
  let current
  /** @type {Promise<GarminService> | undefined} */
  let pending
  let resolvedAt = 0

  /**
   * 构造 GarminService。**只有拿到账号配置后才建立 client**，
   * 因此账号还没配置好时插件也不会崩，只是所有数据端点返回 503。
   */
  const build = async () => {
    const resolved = await resolveAccount(ctx)
    if (resolved.status !== 'ready') {
      // 绝不打印邮箱/路径细节；只报机制与原因。
      logger.warn('[garmin-dash] garmin account binding not available (source=%s)', resolved.source)
      throw Object.assign(new Error('garmin_account_unavailable'), { kind: 'authentication' })
    }
    resolvedAt = Date.now()
    const account = resolved.account
    // 与 dsh-plugin-garmin-connect/lib/index.js:14-15 完全同构。
    // 类通过 garmin-module.mjs 解析（裸包名 / profile node_modules 双路径），
    // 因为上游 package.json 的 exports 没有暴露 ./lib/client.js 子路径。
    const [GarminClient, GarminToolService] = await Promise.all([loadGarminClient(), loadGarminToolService()])
    const client = new GarminClient(ctx, account.config, { allowUnconfigured: true })
    const toolService = new GarminToolService(client, {
      activityDetail: 'full', // 详情要全量：功率曲线 / 区间 / 训练负荷
      fitDownloadDir: account.config.fitDownloadDir ?? '',
      accountUsername: account.config.username ?? '',
      accountRegion: account.region,
    })
    const service = new GarminService({ client, toolService, logger, todayLocal })
    // 后台预热登录：不阻塞路由注册，失败也不影响宿主（首次数据请求会重试）。
    void service.ensureConnected().catch((error) => {
      logger.warn('[garmin-dash] initial garmin connect failed (%s)', error?.constructor?.name ?? 'Error')
    })
    logger.info('[garmin-dash] garmin account bound via %s', resolved.source)
    return service
  }

  /**
   * 取当前的 GarminService；按需（重新）解析账号配置。
   * 并发调用共享同一个 pending promise。
   * @returns {Promise<GarminService>}
   */
  const getService = async () => {
    if (current && Date.now() - resolvedAt < ACCOUNT_TTL_MS) return current.service
    if (pending === undefined) {
      pending = build()
        .then((service) => {
          current = { service, source: 'loader-tree' }
          return service
        })
        .finally(() => {
          pending = undefined
        })
    }
    return pending
  }

  const router = createRouter({
    // 路由层拿到的是"延迟解析"的门面：所有方法都先等账号就绪。
    // 这样路由可以在 apply 阶段同步注册，而账号解析可以慢慢来。
    service: new Proxy({}, {
      get: (_target, prop) => (...args) => getService().then((service) => service[prop](...args)),
    }),
    logger,
    todayLocal,
    readFileSync,
    pairStore,
    /**
     * 依赖自检用的轻量探针：只判断"账号是否绑定成功"，
     * 不触发额外登录（真正的取数仍走各数据端点）。
     */
    probe: async () => {
      try {
        await getService()
        return { bound: true, detail: '已绑定（复用 garmin-connect 的登录态）' }
      } catch (error) {
        return { bound: false, detail: `未绑定：${String(error?.message ?? error)}（请安装并登录 dsh-plugin-garmin-connect）` }
      }
    },
  })

  // ── 路由注册：照抄 @linxin666/dsh-remote-web-ui/lib/types/index.js:732
  //    `routes.map(route => ctx.webServer.register(route))`，
  //    并用 ctx.effect 保证插件卸载时路由一并撤销。
  const dispose = ctx.effect(() => {
    const disposers = [ctx.webServer.register({ kind: 'prefix', path: PREFIX, handler: router.handler })]
    logger.info('[garmin-dash] routes registered at %s (api version %s)', PREFIX, API_VERSION)
    return () => {
      for (const d of disposers) {
        try { d?.() } catch { /* 卸载路径不抛 */ }
      }
    }
  }, 'garmin-dash: routes')

  // ── 账号配置变化：丢弃已解析的账号，下次请求重新绑定。
  //    监听的事件名与参数形状来自 cordis-plugin-loader/src/index.ts:29-34
  //    （`loader/volatile-update`，payload 为变更的配置路径数组）。
  ctx.on('loader/volatile-update', (paths) => {
    const relevant = Array.isArray(paths)
      && paths.some((p) => Array.isArray(p) && ['accounts', 'accountsConfigured', 'region', 'globalUsername', 'cnUsername'].includes(p[0]))
    if (!relevant) return
    current = undefined
    resolvedAt = 0
    router.cache.clear()
    logger.info('[garmin-dash] garmin account config changed; service will rebind on next request')
  })

  ctx.effect(() => () => {
    dispose?.()
  }, 'garmin-dash: teardown')
}
