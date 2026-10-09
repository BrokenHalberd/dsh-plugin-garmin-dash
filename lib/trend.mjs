/**
 * trend.mjs — 训练负荷（TSS/CTL/ATL/TSB）与周汇总。
 *
 * ── EMA 公式（任务书指定，注释即文档）────────────────────────────────
 *   CTL_today = CTL_yesterday + (TSS_today - CTL_yesterday) / 42
 *   ATL_today = ATL_yesterday + (TSS_today - ATL_yesterday) / 7
 *   TSB_today = CTL_today - ATL_yesterday        （经典 Coggan 定义：用"昨天"的
 *                                                疲劳对比"今天"的体能，避免同一天
 *                                                的 TSS 把自己的差值抹平）
 * 42 天 = 长期体能（fitness），7 天 = 短期疲劳（fatigue）。
 * 时间常数 τ = N 时，日衰减系数 k = 1/N，等价写法 CTL = CTL*(1-1/42) + TSS/42。
 * 无活动的日子 TSS 记 0，EMA 仍然推进（这正是该模型的意义：不训练就掉体能）。
 *
 * ── 种子（warm-up）处理 ────────────────────────────────────────────
 * EMA 需要"昨天"的值。窗口第一天没有历史时，如果直接用 0 起步，前 ~42 天的
 * CTL 会被系统性低估。因此调用方会多取 `WARMUP_DAYS` 天的活动数据用于推进，
 * 但只把用户请求的窗口作为 `points` 返回。这是有意的近似：
 *   - 若真实训练史早于 warm-up 起点，早期 CTL 仍会偏低（模型本身的性质）；
 *   - 本实现从不编造历史 TSS，只用真实活动推进，缺数据就是缺数据。
 */

/** CTL 时间常数（天）。 */
export const CTL_TAU = 42
/** ATL 时间常数（天）。 */
export const ATL_TAU = 7
/** 为让 EMA 收敛额外向前取的天数（离线可调）。 */
export const WARMUP_DAYS = 120

/** 本地时区 YYYY-MM-DD。 */
export function toLocalDate(value) {
  if (typeof value !== 'string' || value.length < 10) return null
  const head = value.slice(0, 10)
  if (/^\d{4}-\d{2}-\d{2}$/.test(head)) return head
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) return null
  const y = parsed.getFullYear()
  const m = String(parsed.getMonth() + 1).padStart(2, '0')
  const d = String(parsed.getDate()).padStart(2, '0')
  return `${y}-${m}-${d}`
}

/** 在 YYYY-MM-DD 上加减天数（按本地日历推进，避免 UTC 偏移误差）。 */
export function addDays(date, delta) {
  const [y, m, d] = date.split('-').map(Number)
  const dt = new Date(y, m - 1, d)
  dt.setDate(dt.getDate() + delta)
  const yy = dt.getFullYear()
  const mm = String(dt.getMonth() + 1).padStart(2, '0')
  const dd = String(dt.getDate()).padStart(2, '0')
  return `${yy}-${mm}-${dd}`
}

/** 生成 [start, end] 闭区间的日期序列。 */
export function dateRange(start, end) {
  const out = []
  let cursor = start
  for (let guard = 0; guard < 10_000; guard += 1) {
    out.push(cursor)
    if (cursor >= end) break
    cursor = addDays(cursor, 1)
  }
  return out
}

/** 数值或 null（NaN/Infinity/非数字都归 null）。 */
export function numOrNull(value) {
  if (value === null || value === undefined || value === '') return null
  const n = typeof value === 'number' ? value : Number(value)
  return Number.isFinite(n) ? n : null
}

/** 保留 n 位小数（null 透传）。 */
export function round(value, digits = 2) {
  const n = numOrNull(value)
  if (n === null) return null
  const f = 10 ** digits
  return Math.round(n * f) / f
}

/**
 * 从活动里取 TSS。
 * Garmin 的 `trainingStressScore` 只在有功率/心率模型的活动中出现；
 * 缺失即 0（不猜、不用其它字段顶替）。
 * @param {any} activity
 */
export function tssOf(activity) {
  const raw = activity?.trainingStressScore
    ?? activity?.activityTrainingLoad
    ?? activity?.tss
    ?? null
  const n = numOrNull(raw)
  return n === null ? 0 : Math.max(0, n)
}

/**
 * 计算每日序列 + CTL/ATL/TSB。
 * @param {object} args
 * @param {string} args.start 窗口首日（含）
 * @param {string} args.end 窗口末日（含）
 * @param {string} args.warmupStart EMA 推进起点（含），必须 <= start
 * @param {Map<string, number>} args.tssByDate 每日 TSS 合计
 * @returns {Array<{ date: string, tss: number, ctl: number, atl: number, tsb: number }>}
 */
export function computeLoadSeries({ start, end, warmupStart, tssByDate }) {
  const series = []
  let ctl = 0
  let atl = 0
  /** 上一日**已输出**的 ATL（用于 TSB 的经典定义）。 */
  let atlPrev = 0
  const r1 = (x) => Math.round(x * 10) / 10
  for (const date of dateRange(warmupStart, end)) {
    const tss = tssByDate.get(date) ?? 0
    // CTL_today = CTL_yesterday + (TSS_today - CTL_yesterday) / 42
    ctl = ctl + (tss - ctl) / CTL_TAU
    // ATL_today = ATL_yesterday + (TSS_today - ATL_yesterday) / 7
    atl = atl + (tss - atl) / ATL_TAU
    if (date < start) {
      atlPrev = r1(atl)
      continue
    }
    series.push({
      date,
      tss: r1(tss),
      ctl: r1(ctl),
      atl: r1(atl),
      // TSB = CTL_today - ATL_yesterday（用与输出同精度的值，保证行内自洽）
      tsb: r1(r1(ctl) - atlPrev),
    })
    atlPrev = r1(atl)
  }
  return series
}

/**
 * 周汇总（ISO 周：周一为一周首日）。
 * @param {Array<{ date: string, distanceMeters: number|null, durationSeconds: number|null, tss: number }>} activities
 * @returns {Array<{ weekStart: string, distanceMeters: number, durationSeconds: number, tss: number }>}
 */
export function weeklyTotals(activities) {
  /** @type {Map<string, { weekStart: string, distanceMeters: number, durationSeconds: number, tss: number }>} */
  const weeks = new Map()
  for (const activity of activities) {
    const date = toLocalDate(activity?.date ?? activity?.startTime)
    if (date === null) continue
    const weekStart = isoWeekStart(date)
    const row = weeks.get(weekStart) ?? { weekStart, distanceMeters: 0, durationSeconds: 0, tss: 0 }
    row.distanceMeters += numOrNull(activity.distanceMeters) ?? 0
    row.durationSeconds += numOrNull(activity.durationSeconds) ?? 0
    // 必须是归一化后的字段名：Garmin 原始/归一化活动里叫 trainingStressScore，
    // 直接读 activity.tss 会永远得 0（曾因此每周汇总 TSS 全 0）。
    row.tss += tssOf(activity)
    weeks.set(weekStart, row)
  }
  return [...weeks.values()]
    .map((row) => ({
      weekStart: row.weekStart,
      distanceMeters: Math.round(row.distanceMeters * 100) / 100,
      durationSeconds: Math.round(row.durationSeconds),
      tss: Math.round(row.tss * 10) / 10,
    }))
    .sort((a, b) => (a.weekStart < b.weekStart ? -1 : 1))
}

/** 该日期所在 ISO 周的周一（本地日历）。 */
export function isoWeekStart(date) {
  const [y, m, d] = date.split('-').map(Number)
  const dt = new Date(y, m - 1, d)
  // getDay(): 0=周日 … 6=周六；ISO 周以周一为首日。
  const shift = (dt.getDay() + 6) % 7
  return addDays(date, -shift)
}
