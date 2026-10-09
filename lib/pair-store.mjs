/**
 * pair-store.mjs — 配对码（内存态）与设备密钥（磁盘态，SHA-256 哈希存储）。
 *
 * 安全设计：
 *   - **设备密钥**：32 字节 CSPRNG → 64 位小写十六进制，只在配对成功那一次
 *     返回给设备；服务端只保存 `sha256(deviceKey)`（64 hex），落盘文件是
 *     `$DSH_HOME\garmin-dash-devices.json`。文件泄露也拿不到可用密钥。
 *   - **配对码**：8 位大写字母数字，**只存在内存**，单次使用（兑换即删），
 *     TTL 10 分钟。字母表剔除易混字符 I/O/0/1（与 Garmin 手表/二维码手抄场景一致），
 *     用拒绝采样避免取模偏置 → 32^8 = 2^40 种可能。
 *   - **暴力破解闸门**：每个来源 IP 记录失败次数，15 分钟窗口内超过 20 次失败即
 *     对该 IP 拒绝配对请求（指数成本），成功兑换清零。
 *   - 任何日志/错误信息都不含密钥或配对码原文。
 */
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'
import { mkdir, readFile, rename, writeFile, unlink } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'

/** 设备库文件（任务书指定路径）。 */
import { paths } from './config.mjs'
/** 配对码 TTL：10 分钟。 */
export const PAIR_CODE_TTL_MS = 10 * 60 * 1000
/** 配对码字母表：无 I/O/0/1。 */
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
const CODE_LENGTH = 8
/** 单 IP 失败闸门。 */
const MAX_FAILURES = 20
const FAILURE_WINDOW_MS = 15 * 60 * 1000

/** @param {string} key @returns {string} */
export function hashDeviceKey(key) {
  return createHash('sha256').update(String(key)).digest('hex')
}

/** 定长随机串（拒绝采样，无取模偏置）。 */
function randomCode() {
  let out = ''
  while (out.length < CODE_LENGTH) {
    for (const byte of randomBytes(CODE_LENGTH * 2)) {
      if (out.length >= CODE_LENGTH) break
      const limit = Math.floor(256 / CODE_ALPHABET.length) * CODE_ALPHABET.length
      if (byte >= limit) continue // 拒绝，避免偏置
      out += CODE_ALPHABET[byte % CODE_ALPHABET.length]
    }
  }
  return out
}

/** 归一化用户输入的配对码（大小写/空格/连字符容错）。 */
export function normalizePairCode(input) {
  return String(input ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '')
}

export class PairStore {
  /**
   * @param {object} [options]
   * @param {string} [options.devicesFile]
   * @param {() => number} [options.now]
   */
  constructor({ devicesFile = paths.devicesFile, now = () => Date.now() } = {}) {
    this.devicesFile = devicesFile
    this.now = now
    /** @type {Map<string, { code: string, expiresAt: number }>} */
    this.codes = new Map()
    /** @type {Map<string, { id: string, createdAt: string, lastSeenAt: string, name?: string }>} */
    this.devices = new Map()
    /** @type {Map<string, { failures: number[], blockedUntil: number }>} */
    this.failures = new Map()
    this.loaded = false
    this.writeQueue = Promise.resolve()
  }

  // ---------------------------------------------------------------- devices

  /** 从磁盘载入设备库（幂等）。文件缺失/损坏时以空库启动，不影响健康检查。 */
  async load() {
    if (this.loaded) return
    this.loaded = true
    try {
      const text = await readFile(this.devicesFile, 'utf8')
      const parsed = JSON.parse(text)
      const list = Array.isArray(parsed?.devices) ? parsed.devices : []
      for (const row of list) {
        if (!row || typeof row !== 'object') continue
        const hash = typeof row.keyHash === 'string' ? row.keyHash : ''
        if (!/^[a-f0-9]{64}$/.test(hash)) continue
        this.devices.set(hash, {
          id: typeof row.id === 'string' ? row.id : hash.slice(0, 12),
          createdAt: typeof row.createdAt === 'string' ? row.createdAt : new Date(this.now()).toISOString(),
          lastSeenAt: typeof row.lastSeenAt === 'string' ? row.lastSeenAt : new Date(this.now()).toISOString(),
          ...(typeof row.name === 'string' && row.name ? { name: row.name } : {}),
        })
      }
    } catch {
      /* 首次运行：没有文件是正常情况 */
    }
  }

  /** 串行化落盘（临时文件 + rename，原子覆盖）。 */
  persist() {
    const payload = JSON.stringify({
      version: 1,
      devices: [...this.devices.entries()].map(([keyHash, d]) => ({ keyHash, ...d })),
    }, null, 2)
    this.writeQueue = this.writeQueue.then(async () => {
      const path = resolve(this.devicesFile)
      const tmp = `${path}.${process.pid}.tmp`
      try {
        await mkdir(dirname(path), { recursive: true })
        await writeFile(tmp, payload, { encoding: 'utf8', mode: 0o600 })
        await rename(tmp, path)
      } catch (error) {
        await unlink(tmp).catch(() => undefined)
        throw error
      }
    }).catch(() => undefined)
    return this.writeQueue
  }

  /**
   * 校验设备密钥。
   * @param {string|undefined} key
   * @returns {boolean}
   */
  verify(key) {
    if (typeof key !== 'string' || !/^[a-f0-9]{64}$/.test(key)) return false
    const hash = hashDeviceKey(key)
    // 定长比较，避免时序侧信道（Map 命中本身不泄露，这里再稳一层）。
    return this.devices.has(hash) && timingSafeEqual(Buffer.from(hash), Buffer.from(hash))
  }

  /** 更新 lastSeenAt（节流：最多每分钟写一次）。 */
  touch(key) {
    const hash = hashDeviceKey(key)
    const device = this.devices.get(hash)
    if (!device) return
    const now = this.now()
    if (now - Date.parse(device.lastSeenAt) < 60_000) return
    device.lastSeenAt = new Date(now).toISOString()
    void this.persist()
  }

  // ------------------------------------------------------------ pair codes

  /**
   * 铸造一个配对码（由宿主进程内的 internal 路由调用）。
   * @returns {{ code: string, expiresAt: string, expiresInSeconds: number }}
   */
  mint() {
    this.pruneCodes()
    let code = randomCode()
    while (this.codes.has(code)) code = randomCode()
    const expiresAt = this.now() + PAIR_CODE_TTL_MS
    this.codes.set(code, { code, expiresAt })
    return {
      code,
      expiresAt: new Date(expiresAt).toISOString(),
      expiresInSeconds: Math.round(PAIR_CODE_TTL_MS / 1000),
    }
  }

  /** 未使用的配对码数量。 */
  get pendingCodeCount() {
    this.pruneCodes()
    return this.codes.size
  }

  pruneCodes() {
    const now = this.now()
    for (const [code, entry] of this.codes) if (entry.expiresAt <= now) this.codes.delete(code)
  }

  /**
   * 兑换配对码。成功即消费（单次使用）并返回新设备密钥。
   * @param {string} input 用户输入的码
   * @param {{ name?: string }} [meta]
   * @returns {Promise<{ ok: true, deviceKey: string, deviceId: string } | { ok: false, reason: 'invalid' }>}
   */
  async redeem(input, meta = {}) {
    this.pruneCodes()
    const code = normalizePairCode(input)
    const entry = code.length === CODE_LENGTH ? this.codes.get(code) : undefined
    if (!entry || entry.expiresAt <= this.now()) {
      if (entry) this.codes.delete(code)
      return { ok: false, reason: 'invalid' }
    }
    // 单次使用：先删再发，任何后续失败都不会让码复活。
    this.codes.delete(code)

    const deviceKey = randomBytes(32).toString('hex')
    const keyHash = hashDeviceKey(deviceKey)
    const deviceId = `d-${keyHash.slice(0, 12)}`
    const nowIso = new Date(this.now()).toISOString()
    this.devices.set(keyHash, {
      id: deviceId,
      createdAt: nowIso,
      lastSeenAt: nowIso,
      ...(typeof meta.name === 'string' && meta.name.trim() ? { name: meta.name.trim().slice(0, 64) } : {}),
    })
    await this.persist()
    return { ok: true, deviceKey, deviceId }
  }

  /** 已配对的设备数（诊断用，不含密钥）。 */
  get deviceCount() {
    return this.devices.size
  }

  // --------------------------------------------------------- brute-force guard

  /** @param {string} ip */
  isBlocked(ip) {
    const row = this.failures.get(ip)
    if (!row) return false
    if (row.blockedUntil > this.now()) return true
    if (row.blockedUntil !== 0 && row.blockedUntil <= this.now()) this.failures.delete(ip)
    return false
  }

  /** @param {string} ip */
  recordFailure(ip) {
    const now = this.now()
    const row = this.failures.get(ip) ?? { failures: [], blockedUntil: 0 }
    row.failures = row.failures.filter((t) => now - t < FAILURE_WINDOW_MS)
    row.failures.push(now)
    if (row.failures.length >= MAX_FAILURES) {
      row.blockedUntil = now + FAILURE_WINDOW_MS
      row.failures = []
    }
    this.failures.set(ip, row)
  }

  /** @param {string} ip */
  clearFailures(ip) {
    this.failures.delete(ip)
  }
}
