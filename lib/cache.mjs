/**
 * cache.mjs — 极小的 TTL 缓存（滑动窗口内复用上游结果）。
 *
 * 设计取舍（保守）：
 *   - 默认 TTL 60 秒。手机 UI 轮询 `/summary`、`/activities` 时不会把请求打到
 *     Garmin；而 60 秒远小于 Garmin 数据本身的更新粒度（睡眠/步数按小时级刷新，
 *     活动在结束后才出现），所以用户感知不到延迟。
 *   - 缓存键由调用方给出；`/activity`（单活动全量详情）与 `/trend` 也走同一缓存，
 *     但 TTL 不同（见 routes.mjs 中的 `CACHE_TTL_MS`）。
 *   - **失败不缓存**：只有成功结果才写入，否则一次网络抖动会让 60 秒内一直返回错误。
 *   - **在途请求合并**：同一个键并发请求只触发一次上游调用（手机首屏会同时发
 *     summary+activities，避免重复打上游）。
 */

/** 每个 entry：{ value, expiresAt }；`inflight` 单独存 Promise。 */
export class TtlCache {
  /**
   * @param {number} ttlMs 默认存活毫秒数（<=0 表示禁用缓存）
   * @param {() => number} [now] 可注入时钟，便于测试
   */
  constructor(ttlMs = 60_000, now = () => Date.now()) {
    this.ttlMs = ttlMs
    this.now = now
    /** @type {Map<string, { value: unknown, expiresAt: number }>} */
    this.entries = new Map()
    /** @type {Map<string, Promise<unknown>>} */
    this.inflight = new Map()
  }

  /** 当前缓存条目数（测试/诊断用）。 */
  get size() {
    return this.entries.size
  }

  /**
   * 取缓存值；未命中或已过期返回 undefined。
   * @param {string} key
   */
  get(key) {
    if (this.ttlMs <= 0) return undefined
    const hit = this.entries.get(key)
    if (hit === undefined) return undefined
    if (hit.expiresAt <= this.now()) {
      this.entries.delete(key)
      return undefined
    }
    return hit.value
  }

  /**
   * 命中缓存直接返回；否则执行 producer 并缓存成功结果。
   * 同一 key 的并发调用共享同一个 producer promise。
   * @template T
   * @param {string} key
   * @param {() => Promise<T>} producer
   * @param {number} [ttlMs] 覆盖默认 TTL
   * @returns {Promise<T>}
   */
  async wrap(key, producer, ttlMs = this.ttlMs) {
    const cached = this.get(key)
    if (cached !== undefined) return /** @type {T} */ (cached)
    const pending = this.inflight.get(key)
    if (pending !== undefined) return /** @type {Promise<T>} */ (pending)
    const task = (async () => producer())()
      .then((value) => {
        if (ttlMs > 0) this.entries.set(key, { value, expiresAt: this.now() + ttlMs })
        return value
      })
      .finally(() => {
        this.inflight.delete(key)
      })
    this.inflight.set(key, task)
    return task
  }

  /** 清空（账号配置变化 / 手动刷新时调用）。 */
  clear() {
    this.entries.clear()
  }
}
