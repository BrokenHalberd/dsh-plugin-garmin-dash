/**
 * qr.mjs —— 按需加载二维码渲染库（不引入任何新依赖）。
 *
 * 为什么不用 `import 'qrcode'`：本插件是 `link:` 安装的，Node 从插件目录向上
 * 找不到 DSH 自带的依赖。于是按以下顺序**显式**解析：
 *   1. 环境变量 `GARMIN_DASH_QRCODE_DIR`（部署方可指定）
 *   2. 宿主机进程入口推导出的 DSH 应用目录（最可移植：从 process.argv[1] 向上找）
 *   3. 全局 npm 目录
 * 任何一个可用即渲染 PNG；全部不可用则返回 null，引导页降级为"显示配对链接"。
 */
import { createRequire } from 'node:module'
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'

const require = createRequire(import.meta.url)

/** 从宿主机进程入口向上寻找 DSH 应用目录里的 node_modules。 */
function fromHostProcess() {
  const entry = process.argv?.[1]
  if (typeof entry !== 'string' || entry.length === 0) return []
  const out = []
  let dir = dirname(entry)
  for (let i = 0; i < 6; i += 1) {
    out.push(join(dir, 'node_modules', 'qrcode'))
    const parent = dirname(dir)
    if (parent === dir) break
    dir = parent
  }
  return out
}

function candidates() {
  const env = process.env.GARMIN_DASH_QRCODE_DIR?.trim()
  const list = []
  if (env) list.push(env, join(env, 'qrcode'))
  list.push(...fromHostProcess(), 'qrcode')
  const appData = process.env.APPDATA?.trim()
  if (appData) list.push(join(appData, 'npm', 'node_modules', 'qrcode'))
  return list
}

let cached
let cachedMod

/**
 * 解析 qrcode 库（带缓存）。
 * @returns {{ toDataURL: Function, toBuffer?: Function } | null}
 */
export function loadQr() {
  if (cached !== undefined) return cachedMod
  cached = false
  cachedMod = null
  for (const c of candidates()) {
    try {
      if (c !== 'qrcode' && !existsSync(c)) continue
      const mod = require(c)
      if (mod && typeof (mod.toDataURL === 'function' || mod.toBuffer === 'function')) {
        cached = true
        cachedMod = mod
        return cachedMod
      }
    } catch {
      /* 继续尝试下一个候选 */
    }
  }
  return null
}

/** 二维码是否可用（供自检展示）。 */
export function qrAvailable() {
  return loadQr() !== null
}

/**
 * 渲染二维码 PNG。
 * @param {string} text 内容
 * @param {{ width?: number, margin?: number }} [options]
 * @returns {Promise<Buffer | null>} PNG 缓冲；库不可用时为 null
 */
export async function renderQrPng(text, options = {}) {
  const qr = loadQr()
  if (!qr) return null
  const opts = { type: 'png', width: options.width ?? 480, margin: options.margin ?? 2, errorCorrectionLevel: 'M' }
  try {
    if (typeof qr.toBuffer === 'function') return await qr.toBuffer(text, opts)
    const dataUrl = await qr.toDataURL(text, opts)
    const base64 = String(dataUrl).split(',')[1] ?? ''
    return Buffer.from(base64, 'base64')
  } catch {
    return null
  }
}
