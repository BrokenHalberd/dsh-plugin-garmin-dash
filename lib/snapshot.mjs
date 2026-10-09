/**
 * snapshot.mjs — 把每次成功的数据响应落到 `<数据目录>\数据快照\YYYY-MM-DD.json`。
 *
 * 契约（任务书第 8 条）：
 *   - 一天一个文件，按端点分键**合并更新**（不是覆盖整个文件）。
 *   - **原子写**：先写同目录临时文件，再 `rename` 覆盖目标（同卷 rename 在
 *     Windows/NTFS 上是原子的，POSIX 亦然）。崩溃/断电只会留下临时文件，
 *     不会留下半个 JSON。
 *   - **绝不写到 `<数据目录>\` 之外**：所有路径都先 `resolve` 再前缀校验，
 *     任何越界写入直接抛错（见 `assertInsideRoot`）。
 *   - 快照失败**不影响** HTTP 响应：调用方用 `void writeSnapshot(...).catch(...)`，
 *     落盘只是旁路。
 */
import { mkdir, readFile, rename, writeFile, unlink, readdir, stat } from 'node:fs/promises'
import { resolve, sep } from 'node:path'
import { randomBytes } from 'node:crypto'
import { paths } from './config.mjs'

/** 数据根目录（运行期解析，随 profile 配置变化）。 */
export const dataRoot = () => paths.dataRoot
/** 快照目录。 */
export const snapshotDir = () => resolve(paths.dataRoot, '数据快照')

/**
 * 校验目标路径落在 root 之内（防目录穿越）。
 * @param {string} root 允许的根目录（绝对路径）
 * @param {string} target 目标绝对路径
 * @returns {string} 规范化后的目标路径
 */
export function assertInsideRoot(root, target) {
  const rootAbs = resolve(root)
  const targetAbs = resolve(target)
  if (targetAbs !== rootAbs && !targetAbs.startsWith(rootAbs.endsWith(sep) ? rootAbs : rootAbs + sep)) {
    throw new Error(`snapshot: refusing to write outside ${rootAbs}`)
  }
  return targetAbs
}

/** 本地时区的 YYYY-MM-DD。 */
export function localDate(d = new Date()) {
  const y = d.getFullYear()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${y}-${m}-${day}`
}

/** 内存中的串行化锁：同一文件的并发合并写不会互相覆盖读-改-写窗口。 */
const fileLocks = new Map()

/**
 * @template T
 * @param {string} key
 * @param {() => Promise<T>} fn
 * @returns {Promise<T>}
 */
function withLock(key, fn) {
  const prev = fileLocks.get(key) ?? Promise.resolve()
  const next = prev.then(fn, fn)
  fileLocks.set(key, next.then(() => undefined, () => undefined))
  return next
}

/**
 * 原子写文件：同目录临时文件 + rename。
 * @param {string} path 目标绝对路径（必须已在 dataRoot() 之内）
 * @param {string} text 内容
 */
async function writeFileAtomic(path, text) {
  await mkdir(resolve(path, '..'), { recursive: true })
  const tmp = `${path}.${process.pid}.${randomBytes(4).toString('hex')}.tmp`
  try {
    await writeFile(tmp, text, { encoding: 'utf8' })
    await rename(tmp, path)
  } catch (error) {
    await unlink(tmp).catch(() => undefined)
    throw error
  }
}

/**
 * 读取当天快照（不存在或损坏时返回空骨架）。
 * @param {string} date
 */
async function readSnapshot(date) {
  const path = assertInsideRoot(dataRoot(), resolve(snapshotDir(), `${date}.json`))
  try {
    const text = await readFile(path, 'utf8')
    const parsed = JSON.parse(text)
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : { date, records: {} }
  } catch {
    return { date, records: {} }
  }
}

/**
 * 清理崩溃/强杀留下的临时文件（`<date>.json.<pid>.<rand>.tmp`）。
 *
 * 为什么需要：`writeFileAtomic` 在 rename 之前被强杀（进程被杀、断电）会留下
 * 临时文件。它不影响正确性（读取端只认 `YYYY-MM-DD.json`），但会污染目录，
 * 而且 `<数据目录>\数据快照\` 是给人看的工作区。这里每次写快照前顺手扫一遍，
 * 只删**本目录内**、后缀 `.tmp`、且超过 10 分钟没被动过的文件。
 * 超过 10 分钟这个门槛保证不会误删另一个并发进程正在写的临时文件。
 *
 * @param {number} [olderThanMs] 只清理早于该时长的临时文件
 * @returns {Promise<number>} 清理数量
 */
export async function sweepStaleTempFiles(olderThanMs = 10 * 60 * 1000) {
  let removed = 0
  try {
    const names = await readdir(snapshotDir())
    const cutoff = Date.now() - olderThanMs
    for (const name of names) {
      if (!name.endsWith('.tmp')) continue
      const path = assertInsideRoot(dataRoot(), resolve(snapshotDir(), name))
      try {
        const info = await stat(path)
        if (info.mtimeMs > cutoff) continue
        await unlink(path)
        removed += 1
      } catch { /* 已被别的进程清掉：忽略 */ }
    }
  } catch { /* 目录还不存在：正常 */ }
  return removed
}

/**
 * 合并写入一条快照记录。
 * @param {object} args
 * @param {string} args.date 快照归属日期（YYYY-MM-DD）
 * @param {string} args.endpoint 端点标识，如 `summary` / `activities` / `trend` / `activity`
 * @param {unknown} args.data 已序列化友好的数据
 * @param {string} [args.updatedAt] ISO 时间戳
 * @returns {Promise<string>} 写入的绝对路径
 */
export async function writeSnapshot({ date, endpoint, data, updatedAt = new Date().toISOString() }) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(String(date))) throw new Error('snapshot: invalid date')
  const path = assertInsideRoot(dataRoot(), resolve(snapshotDir(), `${date}.json`))
  return withLock(path, async () => {
    const doc = await readSnapshot(date)
    doc.date = date
    doc.updatedAt = updatedAt
    doc.records = doc.records ?? {}
    doc.records[endpoint] = { updatedAt, data }
    await writeFileAtomic(path, JSON.stringify(doc, null, 2))
    // 顺手清理历史残留（每天最多清一次，避免每次请求都 readdir）
    await sweepStaleTempFiles().catch(() => 0)
    return path
  })
}

/**
 * 读取某天已落盘的快照（供离线/诊断使用，不参与 HTTP 路径）。
 * @param {string} date
 */
export async function readSnapshotForDate(date) {
  return readSnapshot(date)
}
