/**
 * garmin-service.mjs — 把 dsh-plugin-garmin-connect 的数据层包成手机 App 需要的形状。
 *
 * 复用方式（任务书要求）：**不重写 HTTP 调用**，而是
 *   GarminClient(ctx, account.config, { allowUnconfigured: true })
 *     → GarminToolService(client, { activityDetail, fitDownloadDir, accountUsername, accountRegion })
 * 与 `dsh-plugin-garmin-connect/lib/index.js:13-17` 完全同构；因此
 *   - 会话恢复 / 令牌刷新 / DI 会话 / 限流重试 全部由上游客户端负责；
 *   - 活动字段的隐私过滤（凭据、ownerId、deviceId…）由上游 `sanitizeActivityValue` 负责，
 *     这里不再自己写一套黑名单。
 *
 * 本模块只做三件事：
 *   1. 把上游的"人类可读"字段名（sleepScore / weightKg …）映射成 App 契约字段。
 *   2. 保证缺失值是 `null`，绝不省略、绝不补零。
 *   3. 异常分类：区分"上游不可用（503）"与"参数错误（400）"。
 */

import { TtlCache } from './cache.mjs'

/**
 * 上游错误的粗分类。不引入上游错误类（避免额外耦合），只按可观测信号判断：
 *   - 认证/会话问题 → authentication（503，提示重新登录）
 *   - HTTP 429/5xx/网络错误 → rate-limit / upstream（503）
 *   - 参数校验 → bad-request（400）
 * @param {unknown} error
 * @returns {'authentication'|'rate-limit'|'upstream'|'bad-request'}
 */
export function classifyError(error) {
  const message = String(error?.message ?? error ?? '')
  const name = String(error?.constructor?.name ?? '')
  if (/authentication is required|GarminAuthenticationRequired|session token file does not match|rejected|expired/i.test(`${name} ${message}`)) {
    return 'authentication'
  }
  if (/PublicToolError/i.test(name) || /^Invalid /i.test(message)) return 'bad-request'
  const status = error?.response?.status ?? error?.status ?? error?.statusCode
  if (status === 429) return 'rate-limit'
  if (typeof status === 'number' && status >= 500) return 'upstream'
  if (/ECONNRESET|ETIMEDOUT|ENOTFOUND|EAI_AGAIN|socket hang up|timeout/i.test(message)) return 'upstream'
  if (/rate ?limit|too many requests/i.test(message)) return 'rate-limit'
  return 'upstream'
}

/** null 安全的数字。 */
const n = (v) => {
  if (v === null || v === undefined || v === '') return null
  const x = typeof v === 'number' ? v : Number(v)
  return Number.isFinite(x) ? x : null
}
/**
 * 第一个有限数字，并按 2 位小数归一。
 * 为什么要 round：Garmin 的派生指标常带二进制浮点噪声，例如
 *   实测 `trainingStressScore = 114.80000305175781`
 *   实测 `intensityFactor = 0.5820000171661377`
 * 直接透传会让手机端显示 "114.80000305175781"。2 位小数对训练指标
 * （TSS/IF/功率/心率/踏频/海拔）足够，且整数仍是整数。
 */
const firstNum = (...vals) => {
  for (const v of vals) {
    const x = n(v)
    if (x !== null) return Math.round(x * 100) / 100
  }
  return null
}

/**
 * 上游活动对象 → App 契约 `Activity`。
 *
 * **只认 Garmin 原始 payload 的字段名**（`averageHR` / `avgPower` /
 * `normPower` / `trainingStressScore` / `averageRunningCadenceInStepsPerMinute` …），
 * 不去读上游 `formatActivity()` 生成的便捷字段（`time` / `pace`）。原因：
 * 上游工具的 `detail` 模式是可配置的（`compact` 会丢掉功率族字段），
 * 而**原始 payload 字段在任何模式下语义稳定**。本插件统一用
 * `activityDetail: 'full'` 调上游，所以原始字段一定在。
 *
 * 这里的字段名对应关系来自实测 payload（见 test/fixtures/garmin-samples.json）：
 *   averageHR=151 maxHR=192 avgPower=155 maxPower=667 normPower=132
 *   trainingStressScore=114.80000305175781 intensityFactor=0.5820000171661377
 *   elevationGain=218.67 averageBikingCadenceInRevPerMinute=73
 * 注意上游 `sanitizeActivityValue` 已剔除 `deviceId` / `ownerId` / 凭据字段。
 * @param {any} raw
 */
export function normalizeActivity(raw) {
  if (!raw || typeof raw !== 'object') return null
  const id = firstNum(raw.activityId, raw.id)
  const startTime = raw.startTimeLocal ?? raw.startTime ?? null
  return {
    id: id === null ? null : Math.trunc(id),
    name: raw.activityName ?? raw.name ?? 'Unnamed',
    type: raw.activityType?.typeKey ?? raw.type ?? 'unknown',
    startTime: startTime === null ? null : String(startTime),
    date: typeof startTime === 'string' ? startTime.slice(0, 10) : null,
    distanceMeters: firstNum(raw.distance),
    durationSeconds: firstNum(raw.duration),
    averageHeartRate: firstNum(raw.averageHR),
    maxHeartRate: firstNum(raw.maxHR),
    elevationGainMeters: firstNum(raw.elevationGain),
    averageCadence: firstNum(
      raw.averageBikingCadenceInRevPerMinute,
      raw.averageRunningCadenceInStepsPerMinute,
      raw.averageSwimCadenceInStrokesPerMinute,
      raw.avgDoubleCadence,
    ),
    // 功率族（骑行/跑步功率计才有；没有就是 null，不补 0）
    avgPower: firstNum(raw.avgPower),
    maxPower: firstNum(raw.maxPower),
    normPower: firstNum(raw.normPower),
    intensityFactor: firstNum(raw.intensityFactor),
    trainingStressScore: firstNum(raw.trainingStressScore),
    activityTrainingLoad: firstNum(raw.activityTrainingLoad),
  }
}

/**
 * 上游睡眠对象 → App 契约 `SleepInfo`（分钟）。
 * @param {any} raw 上游 formatSleep 结果 { sleepScore, sleepDurationHours, deepSleepHours, ... }
 */
export function normalizeSleep(raw) {
  if (!raw || typeof raw !== 'object') return null
  const hoursToMinutes = (h) => {
    const x = n(h)
    return x === null ? null : Math.round(x * 60)
  }
  const info = {
    score: firstNum(raw.sleepScore, raw.score),
    durationMinutes: hoursToMinutes(raw.sleepDurationHours),
    deepMinutes: hoursToMinutes(raw.deepSleepHours),
    lightMinutes: hoursToMinutes(raw.lightSleepHours),
    remMinutes: hoursToMinutes(raw.remSleepHours),
    awakeMinutes: hoursToMinutes(raw.awakeDurationHours),
  }
  // 全空 → 视为没有睡眠数据（App 显示"暂无"）
  return Object.values(info).every((v) => v === null) ? null : info
}

/**
 * 上游体重对象 → App 契约 `WeightInfo`。
 * @param {any} raw 上游 formatWeight 结果
 * @param {string} fallbackDate
 */
export function normalizeWeight(raw, fallbackDate) {
  if (!raw || typeof raw !== 'object') return null
  const kg = firstNum(raw.weightKg, raw.weight)
  const info = {
    date: typeof raw.date === 'string' && raw.date ? raw.date : fallbackDate,
    kg,
    bodyFatPercent: firstNum(raw.bodyFatPercentage, raw.bodyFatPercent, raw.bodyFat),
    bmi: firstNum(raw.bmi),
  }
  if (info.kg === null && info.bodyFatPercent === null && info.bmi === null) return null
  return info
}

/**
 * GarminService：App 契约与上游数据层之间的唯一适配层。
 *
 * 缓存策略由调用方（routes.mjs）持有，这里保持"每次调用都真打上游"的语义，
 * 便于单独测试与复用。
 */
export class GarminService {
  /**
   * @param {object} args
   * @param {any} args.client GarminClient 实例
   * @param {any} args.toolService GarminToolService 实例
   * @param {{ info: Function, warn: Function, debug: Function, error: Function }} args.logger
   * @param {() => string} args.todayLocal 返回本地 YYYY-MM-DD
   */
  constructor({ client, toolService, logger, todayLocal }) {
    this.client = client
    this.toolService = toolService
    this.logger = logger
    this.todayLocal = todayLocal
    /** 首次 connect() 的共享 promise，避免并发重复登录。 */
    this.connected = null
    /** Body Battery 的独立小缓存（默认 5 分钟；它比步数变化更慢）。 */
    this.cacheBodyBattery = new TtlCache(5 * 60_000)
  }

  /** 懒连接：任何数据方法调用前确保会话可用。失败原样抛出，由路由分类。 */
  async ensureConnected() {
    if (this.connected === null) {
      this.connected = this.client.connect().catch((error) => {
        // 失败后允许下次重试（不把失败永久钉住）
        this.connected = null
        throw error
      })
    }
    return this.connected
  }

  /**
   * 当日概览。
   * 注意：步数/静息心率/睡眠/体重是 4 个独立上游端点，任何一个失败都不应
   * 让整个 summary 失败（App 首页要能显示部分数据）。因此这里逐个 try/catch，
   * 失败的那一项记 null，并把失败原因汇总到 `_partial`（非契约字段，诊断用）。
   *
   * @param {string} date YYYY-MM-DD
   */
  async getSummary(date) {
    await this.ensureConnected()
    const partialFailures = []
    const settle = async (label, fn, fallback) => {
      try {
        return await fn()
      } catch (error) {
        partialFailures.push(`${label}:${classifyError(error)}`)
        return fallback
      }
    }

    const [steps, heartRate, sleep, weight, bodyBattery, extras] = await Promise.all([
      settle('steps', () => this.toolService.getSteps({ startDate: date, endDate: date }), null),
      settle('heartRate', () => this.toolService.getHeartRate({ startDate: date, endDate: date }), null),
      settle('sleep', () => this.toolService.getSleep({ startDate: date, endDate: date }), null),
      settle('weight', () => this.toolService.getWeight({ startDate: date, endDate: date }), null),
      // Body Battery **不在**上游数据层的 6 个端点里，所以单独走一次只读请求，
      // 失败/不存在都只是 null（绝不猜）。见 resolveBodyBattery 的注释。
      this.resolveBodyBattery(date),
      this.resolveDayExtras(date),
    ])

    // 全部四项都失败 → 视为上游不可用，让路由返回 503（而不是 200 + 全 null）。
    if (partialFailures.length === 4) {
      throw new Error('upstream_unavailable: every summary sub-request failed')
    }

    const summary = {
      date,
      steps: firstNum(steps?.totalSteps),
      // 热量与压力：Garmin dailySummary 里就带这两项，一起给出（拿不到就 null ✓）
      calories: firstNum(extras?.calories),
      activeCalories: firstNum(extras?.activeCalories),
      stress: firstNum(extras?.stress),
      maxStress: firstNum(extras?.maxStress),
      restingHeartRate: firstNum(heartRate?.restingHR),
      maxHeartRate: firstNum(heartRate?.maxHR),
      sleep: normalizeSleep(sleep),
      weight: normalizeWeight(weight, date),
      bodyBattery: firstNum(bodyBattery),
    }
    if (partialFailures.length > 0) summary._partial = partialFailures
    return summary
  }

  /**
   * 当日热量消耗与压力（Garmin dailySummary）。
   * 复用 resolveBodyBattery 已验证的认证 axios（client.gc.client.client）。
   * 先拿 displayName，再查 dailySummary；任何异常一律 null ✓
   */
  async resolveDayExtras(date) {
    try {
      const axios = this.client?.gc?.client?.client
      if (axios === undefined) return null
      let name = this.cachedDisplayName
      if (name === undefined || name === null || name.length === 0) {
        const prof = await axios.get('https://connectapi.garmin.com/userprofile-service/socialProfile')
        name = prof?.data?.displayName
        this.cachedDisplayName = name
      }
      if (name === undefined || name === null || name.length === 0) return null
      const url = 'https://connectapi.garmin.com/usersummary-service/usersummary/daily/'
        + encodeURIComponent(name) + '?calendarDate=' + encodeURIComponent(date)
      const res = await axios.get(url)
      const d = res?.data ?? {}
      return {
        calories: firstNum(d.totalKilocalories ?? d.calories),
        activeCalories: firstNum(d.activeKilocalories),
        stress: firstNum(d.averageStressLevel ?? d.avgStressLevel),
        maxStress: firstNum(d.maxStressLevel),
      }
    } catch (error) {
      return null
    }
  }

  /**
   * 当日 Body Battery（0-100 整数）。
   *
   * 为什么单独写：Garmin 的 Body Battery 不在上游
   * `GarminClient` / `GarminToolService` 暴露的 6 个方法里，也没有出现在
   * AI 工具面上。但它**已经在对已认证的 axios 实例里**：
   * `client.gc.client.client`（`garmin-connect` 的 `HttpClient.client`，
   * 见 `garmin-connect/dist/common/HttpClient.js:75`），其请求拦截器会自动
   * 附上 `Bearer <oauth2 access_token>`、响应拦截器会自动刷新令牌
   * （同文件 130-138 / 76-129 行）。所以复用它发一次只读 GET 是安全的，
   * 不会绕过认证，也不会写任何东西。
   *
   * 契约要求"能拿到就给，拿不到必须 null"——因此这里**任何**异常
   * （端点不存在、无权限、字段缺失、网络错误）都返回 null，
   * 绝不返回 0 或旧值，也绝不让 summary 整体失败。
   *
   * @param {string} date YYYY-MM-DD
   * @returns {Promise<number|null>}
   */
  async resolveBodyBattery(date) {
    return this.cacheBodyBattery.wrap(date, async () => {
      const axios = this.client?.gc?.client?.client
      if (axios === undefined) return null
      const url = 'https://connectapi.garmin.com/usersummary-service/usersummary/daily/'
        + `bodyBattery?calendarDate=${encodeURIComponent(date)}`
      const response = await axios.get(url)
      const data = response?.data
      // Garmin 在不同账号/设备上返回的字段名不止一种；逐个尝试，都不认就 null。
      const value = data?.bodyBatteryMostRecentValue
        ?? data?.[data.length - 1]?.bodyBatteryLevel
        ?? data?.chargedValue
        ?? data?.currentValue
        ?? (Array.isArray(data) ? data[data.length - 1]?.value : undefined)
      const n = Number(value)
      return Number.isFinite(n) ? n : null
    }).catch(() => null)
  }

  /**
   * 最近活动列表。
   * @param {{ limit: number, offset: number }} args
   */
  async getActivities({ limit, offset }) {
    await this.ensureConnected()
    const raw = await this.toolService.getActivities({ limit, offset, detail: 'full' })
    const list = Array.isArray(raw) ? raw : []
    return list.map(normalizeActivity).filter((a) => a !== null)
  }

  /**
   * 单活动**全量**详情。
   * 上游 `activityDetail: 'full'` 会保留 power curve（maxAvgPower_1..18000）、
   * 功率/心率区间时间、左右平衡、normPower/TSS/IF、activityTrainingLoad、
   * vO2MaxValue、differenceBodyBattery 等，同时过滤凭据与 owner/device 字段。
   * 这里在原始 payload 之上**再补一层** App 契约别名（activityId/activityName/…），
   * 两套名字并存，App 与调试都能用。
   * @param {number} id
   */
  async getActivityDetail(id) {
    await this.ensureConnected()
    // 上游 tool service 没有"按 id 取详情"的方法，只有列表。为了不重写 HTTP，
    // 这里翻列表；**首页刻意用 limit=20**，与 `/api/activities` 默认页一致，
    // 这样 GarminClient 的 MemoryCache 会命中手机刚才那次列表请求，常见路径
    // 不会产生第二次网络请求。目标 id 不在前 3 页（60 条）时按 404 处理。
    let found
    for (let page = 0; found === undefined && page <= 2; page += 1) {
      const next = await this.toolService.getActivities({ limit: 20, offset: page * 20, detail: 'full' })
      const arr = Array.isArray(next) ? next : []
      if (arr.length === 0) break
      found = arr.find((a) => Number(a?.activityId ?? a?.id) === Number(id))
    }
    if (found === undefined) {
      const error = new Error(`activity ${id} not found in the most recent 60 activities`)
      error.code = 'not-found'
      throw error
    }
    const normalized = normalizeActivity(found) ?? {}
    return {
      ...found,
      // App 契约别名（Types.ets ActivityDetail）
      activityId: normalized.id,
      activityName: normalized.name,
      startTimeLocal: normalized.startTime,
      distance: normalized.distanceMeters,
      duration: normalized.durationSeconds,
      averageHR: normalized.averageHeartRate,
      maxHR: normalized.maxHeartRate,
      elevationGain: normalized.elevationGainMeters,
      avgPower: normalized.avgPower,
      maxPower: normalized.maxPower,
      normPower: normalized.normPower,
      intensityFactor: normalized.intensityFactor,
      trainingStressScore: normalized.trainingStressScore,
      activityTrainingLoad: normalized.activityTrainingLoad,
      averageBikingCadenceInRevPerMinute: normalized.averageCadence,
      // 以下三项上游 'full' 详情里有就给（已被 sanitize 过滤过），没有就 null。
      avgLeftBalance: firstNum(found.avgLeftBalance),
      vO2MaxValue: firstNum(found.vO2MaxValue),
      differenceBodyBattery: firstNum(found.differenceBodyBattery),
      aerobicTrainingEffect: firstNum(found.aerobicTrainingEffect),
      anaerobicTrainingEffect: firstNum(found.anaerobicTrainingEffect),
    }
  }

  /**
   * 取一段时间内的活动（用于 trend 计算），返回 App 契约的子集 + tss。
   * @param {string} start 含
   * @param {string} end 含
   */
  async getActivitiesBetween(start, end) {
    await this.ensureConnected()
    const out = []
    const pageSize = 50
    const maxPages = 20 // 最多 1000 条，够 200+ 天训练史
    for (let page = 0; page < maxPages; page += 1) {
      const batch = await this.toolService.getActivities({ limit: pageSize, offset: page * pageSize, detail: 'full' })
      const arr = Array.isArray(batch) ? batch : []
      if (arr.length === 0) break
      let reachedEarlier = false
      for (const raw of arr) {
        const activity = normalizeActivity(raw)
        if (activity === null || activity.date === null) continue
        if (activity.date < start) { reachedEarlier = true; continue }
        if (activity.date > end) continue
        out.push(activity)
      }
      if (arr.length < pageSize) break
      // 列表按时间倒序；一旦翻到窗口起点之前就可以停。
      if (reachedEarlier) break
    }
    return out
  }
  /**
   * 读取 Garmin 的 HRV 数据（HRV Status）。
   *
   * 实现要点（来自对 garmin-connect 运行时的实测）：
   *   · 该库有通用 `get(url, data)`，接受**完整 URL**（内部委托给 axios 包装层）
   *   · 真正装了 OAuth 拦截器的是最内层 axios 实例（gm.client.client）
   *   · 因此这里逐层降级尝试：GarminConnect → 包装层 → axios，并**记录错误原文**
   * @param {string} date YYYY-MM-DD
   */
  /**
   * 读取最近 N 天的 HRV（含今天）。逐日调用 rawHrv，任一天失败不影响其它天。
   * @param {number} days 1..60
   */
  /**
   * 功率曲线聚合（后端算好，App 一次请求拿走）。
   *
   * 逻辑：分页拉取活动（每页 100，最多 4 页）→ 取带功率活动（最多 30 次）→ 逐条取详情 →
   *   · 三个周期各自独立聚合：近 42 天 / 近 90 天 / 全部历史（各自按日期窗口筛选）
   *   · 累计 90 天内的功率区间时间
   *   · 三个周期各自的 eFTP（20 分钟最佳 × 0.95）
   * 结果在内存缓存 1 小时，避免重复打佳明。
   * @param {number} days 活动扫描天数（默认 90）
   */
  async curveSummary(days) {
    const span = Math.max(7, Math.min(365, Number(days) || 90))
    const now = Date.now()
    if (this._curveCache && now - this._curveCache.at < 3600000 && this._curveCache.span === span) {
      return this._curveCache.data
    }
    // 分页多拉：每页 100 条，最多 4 页；带功率活动够 40 条就停（避免无谓请求）
    const arr = []
    let pages = 0
    const hasPower = (a) => a && a.normPower !== null && a.normPower !== undefined && a.avgPower !== null && a.avgPower !== undefined
    for (let page = 0; page < 4; page++) {
      let chunk = null
      try {
        chunk = await this.getActivities({ limit: 100, offset: page * 100 })
      } catch (error) {
        break
      }
      const items = Array.isArray(chunk) ? chunk : (chunk?.activities ?? [])
      if (items.length === 0) {
        break
      }
      for (const it of items) {
        arr.push(it)
      }
      pages++
      if (arr.filter(hasPower).length >= 100 || items.length < 100) {
        break
      }
    }
    const c42 = this._dateStr(new Date(now - 42 * 86400000))
    const c90 = this._dateStr(new Date(now - 90 * 86400000))
    const dayOf = (a) => String(a?.startTime ?? a?.date ?? '').slice(0, 10)
    const picks = arr
      .filter((a) => a && a.normPower !== null && a.normPower !== undefined && a.avgPower !== null && a.avgPower !== undefined)
            .slice(0, 80)
    const pickDates = picks.map(dayOf)
    const secs = [1, 2, 5, 10, 20, 30, 60, 120, 300, 600, 1200, 1800, 3600, 7200, 18000]
    const p42 = secs.map(() => 0)
    const p90 = secs.map(() => 0)
    const pall = secs.map(() => 0)
    const zones = [0, 0, 0, 0, 0, 0, 0]
    let used = 0
    for (const pick of picks) {
      let d = null
      try {
        d = await this.getActivityDetail(pick.id)
      } catch (error) {
        continue
      }
      if (!d) {
        continue
      }
      used++
      const date = String(pick.startTime ?? '').slice(0, 10)
      for (let k = 0; k < secs.length; k++) {
        const v = d['maxAvgPower_' + secs[k]]
        if (typeof v !== 'number' || v <= 0) {
          continue
        }
        if (date >= c42 && v > p42[k]) p42[k] = v
        if (date >= c90 && v > p90[k]) p90[k] = v
        if (v > pall[k]) pall[k] = v
      }
      if (date >= c90) {
        for (let z = 1; z <= 7; z++) {
          const zv = d['powerTimeInZone_' + z]
          if (typeof zv === 'number' && zv > 0) zones[z - 1] += zv
        }
      }
    }
    const eftp = (arr15) => (arr15[10] > 0 ? Math.round(arr15[10] * 0.95) : null)
    const data = {
      days: span,
      count: used,
      scanned: arr.length,
      pages,
      p42,
      p90,
      pall,
      e42: eftp(p42),
      e90: eftp(p90),
      eall: eftp(pall),
      zones,
      windowFrom: c90,
      windowTo: this._dateStr(new Date(now)),
      pickDates,
      updatedAt: new Date().toISOString()
    }
    this._curveCache = { at: now, span, data }
    return data
  }

  /** YYYY-MM-DD（本地） */
  _dateStr(d) {
    const y = d.getFullYear()
    const m = String(d.getMonth() + 1).padStart(2, '0')
    const dd = String(d.getDate()).padStart(2, '0')
    return y + '-' + m + '-' + dd
  }

  async rawHrvRange(days) {
    const n = Math.max(1, Math.min(60, Number(days) || 14))
    const out = []
    const base = new Date()
    for (let i = 0; i < n; i++) {
      const d = new Date(base.getTime() - i * 86400000)
      const y = d.getFullYear()
      const m = String(d.getMonth() + 1).padStart(2, '0')
      const dd = String(d.getDate()).padStart(2, '0')
      const date = y + '-' + m + '-' + dd
      try {
        const one = await this.rawHrv(date)
        out.push({
          date,
          value: one.available ? one.lastNightAvg : null,
          status: one.available ? one.status : null,
          weeklyAvg: one.available ? one.weeklyAvg : null
        })
      } catch (error) {
        out.push({ date, value: null, status: null, weeklyAvg: null })
      }
    }
    const vals = out.map((o) => o.value).filter((v) => typeof v === 'number' && v > 0)
    return {
      available: vals.length > 0,
      days: out,
      count: vals.length,
      avg: vals.length > 0 ? Math.round((vals.reduce((a, b) => a + b, 0) / vals.length) * 10) / 10 : null,
      min: vals.length > 0 ? Math.min(...vals) : null,
      max: vals.length > 0 ? Math.max(...vals) : null
    }
  }

  /**
   * 身体电量（Body Battery）：库未封装，走带签名的包装层直连 Connect Web API。
   * 先取显示名 → 试每日摘要端点，再退到 bodybattery 统计端点；全部失败返回 available=false。
   * @param {string} date YYYY-MM-DD
   */
  /**
   * 身体电量（Body Battery）· 当日高/低值。
   * 上游库没封装 → 走带签名的包装层直连 Connect Web API：
   *   GET /usersummary-service/stats/bodybattery/daily/{date}/{date}
   *   返回 [{ calendarDate, values: { lowBodyBattery, highBodyBattery } }]
   * 显示名端点需要 calendarDate + displayName，本账号取显示名会 403，故不再尝试。
   * 结果缓存 1 小时。
   * @param {string} date YYYY-MM-DD
   */
  /**
   * 路线探测：取活动的 GPS 轨迹与逐点数据（仅用于看清结构）。
   * 端点：/activity-service/activity/{id}/details?maxChartSize&maxPolylineSize
   * @param {number} id 活动 id
   */
  /**
   * 路线数据（抽稀后给 App 画图）：{ points: [{lat,lon,speed,power,hr,dist}], bounds, stats }
   * 数据源：/activity-service/activity/{id}/details
   *   · geoPolylineDTO.polyline       → lat/lon/altitude/speed
   *   · activityDetailMetrics + metricDescriptors → directPower/directHeartRate/sumDistance
   * 抽稀：最多 maxPoints 个点（按等间隔取样，保留首末点）。缓存 6 小时（轨迹不会变）。
   * @param {number} id 活动 id
   * @param {number} maxPoints 最多返回多少个点（默认 600）
   */
  async routeOf(id, maxPoints) {
    const cap = Math.max(50, Math.min(2000, Number(maxPoints) || 600))
    const key = 'route:' + id
    if (!this._routeCache) {
      this._routeCache = new Map()
    }
    const hit = this._routeCache.get(key)
    if (hit && Date.now() - hit.at < 21600000) {
      return hit.data
    }
    const gm = this.client?.gc ?? this.client?.['gc'] ?? null
    if (gm === null) {
      return { available: false, reason: 'no_underlying_client' }
    }
    const api = gm.url?.GC_API ?? 'https://connectapi.garmin.com'
    const wrap = gm.client
    const path = '/activity-service/activity/' + id + '/details?maxChartSize=2000&maxPolylineSize=4000'
    let d = null
    try {
      const res = wrap && typeof wrap.get === 'function' ? await wrap.get(api + path) : await gm.get(api + path)
      d = res?.data ?? res
    } catch (error) {
      return { available: false, reason: 'request_failed', message: String(error?.message ?? error).slice(0, 160) }
    }
    const poly = d?.geoPolylineDTO?.polyline ?? []
    if (!Array.isArray(poly) || poly.length === 0) {
      return { available: false, reason: 'no_gps' }
    }
    // 逐点指标：按 metricDescriptors 的顺序解析（键可能因活动类型而不同）
    const descs = Array.isArray(d?.metricDescriptors) ? d.metricDescriptors : []
    const idxOf = (name) => descs.findIndex((x) => x && x.key === name)
    const iPad = {
      power: idxOf('directPower'),
      hr: idxOf('directHeartRate'),
      dist: idxOf('sumDistance'),
      speed: idxOf('directSpeed'),
      cad: idxOf('directBikeCadence'),
      lat: idxOf('directLatitude'),
      lon: idxOf('directLongitude'),
      elev: idxOf('directElevation')
    }
    const metrics = Array.isArray(d?.activityDetailMetrics) ? d.activityDetailMetrics : []
    const pick = (i, k) => {
      const at = iPad[k]
      if (at < 0 || i >= metrics.length) {
        return null
      }
      const row = metrics[i]?.metrics
      const v = Array.isArray(row) ? row[at] : null
      return typeof v === 'number' ? v : null
    }
    // 抽稀：等间隔取样
    const step = Math.max(1, Math.floor(poly.length / cap))
    const points = []
    for (let i = 0; i < poly.length; i += step) {
      const pt = poly[i]
      if (!pt || typeof pt.lat !== 'number' || typeof pt.lon !== 'number') {
        continue
      }
      const sp = typeof pt.speed === 'number' && pt.speed > 0 ? pt.speed : pick(i, 'speed')
      points.push({
        lat: Math.round(pt.lat * 1e6) / 1e6,
        lon: Math.round(pt.lon * 1e6) / 1e6,
        speed: typeof sp === 'number' && sp > 0 ? Math.round(sp * 10) / 10 : null,
        power: pick(i, 'power'),
        hr: pick(i, 'hr'),
        elev: pick(i, 'elev') === null ? (typeof pt.altitude === 'number' ? Math.round(pt.altitude * 10) / 10 : null) : Math.round(pick(i, 'elev') * 10) / 10,
        dist: pick(i, 'dist')
      })
    }
    if (points.length > 0) {
      const last = poly[poly.length - 1]
      points.push({ lat: Math.round(last.lat * 1e6) / 1e6, lon: Math.round(last.lon * 1e6) / 1e6, speed: null, power: null, hr: null, dist: null })
    }
    let minLat = 90, maxLat = -90, minLon = 180, maxLon = -180
    let sMin = 1e9, sMax = -1e9, pMin = 1e9, pMax = -1e9, pSum = 0, pCnt = 0
    for (const p of points) {
      if (p.lat < minLat) minLat = p.lat
      if (p.lat > maxLat) maxLat = p.lat
      if (p.lon < minLon) minLon = p.lon
      if (p.lon > maxLon) maxLon = p.lon
      if (p.speed !== null) {
        if (p.speed < sMin) sMin = p.speed
        if (p.speed > sMax) sMax = p.speed
      }
      if (p.power !== null && p.power > 0) {
        if (p.power < pMin) pMin = p.power
        if (p.power > pMax) pMax = p.power
        pSum += p.power
        pCnt++
      }
    }
    const data = {
      available: true,
      id,
      rawPoints: poly.length,
      points,
      bounds: { minLat, maxLat, minLon, maxLon },
      stats: {
        speedMin: sMin === 1e9 ? null : sMin,
        speedMax: sMax === -1e9 ? null : sMax,
        powerMin: pMin === 1e9 ? null : pMin,
        powerMax: pMax === -1e9 ? null : pMax,
        powerAvg: pCnt > 0 ? Math.round(pSum / pCnt) : null
      }
    }
    this._routeCache.set(key, { at: Date.now(), data })
    return data
  }

  async rawRouteProbe(id) {
    const gm = this.client?.gc ?? this.client?.['gc'] ?? null
    if (gm === null) {
      return { ok: false, reason: 'no_underlying_client' }
    }
    const api = gm.url?.GC_API ?? 'https://connectapi.garmin.com'
    const wrap = gm.client
    const path = '/activity-service/activity/' + id + '/details?maxChartSize=2000&maxPolylineSize=4000'
    try {
      const res = wrap && typeof wrap.get === 'function' ? await wrap.get(api + path) : await gm.get(api + path)
      const d = res?.data ?? res
      const out = { ok: true, topKeys: d && typeof d === 'object' ? Object.keys(d) : [] }
      const poly = d?.geoPolylineDTO?.polyline ?? d?.polyline ?? null
      out.polylineCount = Array.isArray(poly) ? poly.length : 0
      if (Array.isArray(poly) && poly.length > 0) {
        out.polylineSample = JSON.stringify(poly.slice(0, 2))
      }
      const metrics = d?.activityDetailMetrics
      out.metricCount = Array.isArray(metrics) ? metrics.length : 0
      if (Array.isArray(metrics) && metrics.length > 0) {
        out.metricKeys = d?.metricDescriptors ? d.metricDescriptors.map((x) => x.key).slice(0, 40) : []
        out.metricSample = JSON.stringify(metrics[0]).slice(0, 400)
      }
      return out
    } catch (error) {
      return { ok: false, reason: 'request_failed', message: String(error?.message ?? error).slice(0, 160) }
    }
  }

  async rawBodyBattery(date) {
    if (this._bbCache && this._bbCache.date === date && Date.now() - this._bbCache.at < 3600000) {
      return this._bbCache.payload
    }
    const gm = this.client?.gc ?? this.client?.['gc'] ?? null
    if (gm === null) {
      return { available: false, reason: 'no_underlying_client' }
    }
    const api = gm.url?.GC_API ?? 'https://connectapi.garmin.com'
    const wrap = gm.client
    const path = '/usersummary-service/stats/bodybattery/daily/' + date + '/' + date
    const tried = []
    try {
      const res = wrap && typeof wrap.get === 'function' ? await wrap.get(api + path) : await gm.get(api + path)
      const data = res?.data ?? res
      let high = null
      let low = null
      if (Array.isArray(data) && data.length > 0) {
        const vs = data[0]?.values
        if (vs && typeof vs.highBodyBattery === 'number') {
          high = vs.highBodyBattery
        }
        if (vs && typeof vs.lowBodyBattery === 'number') {
          low = vs.lowBodyBattery
        }
      }
      if (high === null && data && typeof data.bodyBatteryMostRecentValue === 'number') {
        high = data.bodyBatteryMostRecentValue
      }
      tried.push({ path, ok: true, high, low })
      if (high !== null) {
        const payload = { available: true, date, value: high, high, low, tried }
        this._bbCache = { at: Date.now(), date, payload }
        return payload
      }
      return { available: false, reason: 'no_data', date, tried, sample: JSON.stringify(data).slice(0, 500) }
    } catch (error) {
      tried.push({ path, ok: false, message: String(error?.message ?? error).slice(0, 140) })
      return { available: false, reason: 'request_failed', date, tried }
    }
  }

  async rawHrv(date) {
    const gm = this.client?.gc ?? this.client?.['gc'] ?? null
    if (gm === null) {
      return { available: false, reason: 'no_underlying_client' }
    }
    const api = gm.url?.GC_API ?? 'https://connectapi.garmin.com'
    const paths = [
      '/hrv-service/hrv/' + date,
      '/hrv-service/hrv/daily/' + date,
      '/wellness-service/wellness/dailyHrv/' + date
    ]
    // 逐层降级：GarminConnect.get → 包装层 get → 最内层 axios
    const layers = []
    if (typeof gm.get === 'function') layers.push({ via: 'garminConnect', fn: (u) => gm.get(u) })
    const wrap = gm.client
    if (wrap && typeof wrap.get === 'function') layers.push({ via: 'wrapper', fn: (u) => wrap.get(u) })
    const axios = wrap?.client
    if (axios && typeof axios.get === 'function') layers.push({ via: 'axios', fn: (u) => axios.get(u) })
    if (layers.length === 0) {
      return { available: false, reason: 'no_callable_layer' }
    }
    const tried = []
    for (const layer of layers) {
      for (const path of paths) {
        const url = api + path
        try {
          const res = await layer.fn(url)
          const data = res?.data ?? res
          tried.push({ via: layer.via, path, ok: true })
          const summary = data?.hrvSummary ?? data ?? null
          const lastNight = summary?.lastNightAvg ?? summary?.lastNight ?? null
          if (lastNight !== null && lastNight !== undefined) {
            return {
              available: true,
              date,
              lastNightAvg: lastNight,
              weeklyAvg: summary?.weeklyAvg ?? null,
              status: summary?.status ?? null,
              baselineLow: summary?.baseline?.lowUpper ?? null,
              baselineBalancedLow: summary?.baseline?.balancedLow ?? null,
              baselineBalancedUpper: summary?.baseline?.balancedUpper ?? null,
              feedback: summary?.feedbackPhrase ?? null,
              via: layer.via,
              tried
            }
          }
        } catch (error) {
          tried.push({
            via: layer.via,
            path,
            ok: false,
            status: error?.response?.status ?? null,
            message: String(error?.message ?? error).slice(0, 160)
          })
        }
      }
    }
    return { available: false, reason: 'no_data', date, tried }
  }
}
