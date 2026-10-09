/**
 * config-loader.mjs — 离线复现 profile 的 entry 配置（只为实现 test/ 用，不在 HTTP 路径上）。
 *
 * 为什么需要它：`test/data-layer.mjs` 要在**没有 DSH 引导程序**的普通 Node 进程里
 * 拿到与宿主一致的 `dsh-plugin-garmin-connect` 原始配置。宿主那份配置来自
 * profile 的组合过程（`dsh-app-boot`）：
 *   package.json 的 `dsh.profile.bundles` 顺序 → 每个 bundle 的
 *   `dsh.bundle.patch`（cordis.patch.yml）→ profile 的 cordis.patch.yml → 命令行 overlay
 * 本模块只实现到"够用"的程度：
 *   - 支持 `- insert: [...]` 行与 `- id / name / config` 行
 *   - `config:` 下的映射用**逐行缩进解析**（标量 / 行内数组 / `!!js` 表达式字面量）
 *   - 不实现锚点、多行块标量、复杂嵌套（用不到）
 *
 * 明确标注为**测试专用**：宿主里的真实路径永远是 `ctx.get('loader')` 的 entry 树
 * （见 lib/config-resolution.mjs），不是这个文件。
 */
import { readFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'

/** 去掉行尾注释（只处理 ` #` 前有空白的情况，避免砍掉值里的 `#`）。 */
function stripComment(line) {
  const idx = line.search(/\s#/)
  return idx === -1 ? line : line.slice(0, idx)
}

/** 行内标量解析：引号、布尔、数字、`!!js "..."`、行内 JSON 数组。 */
function parseScalar(raw) {
  let text = raw.trim()
  if (text === '' || text === '~' || text === 'null') return null
  const jsTag = /^!!js\s+/.exec(text)
  if (jsTag) text = text.slice(jsTag[0].length).trim()
  if ((text.startsWith("'") && text.endsWith("'")) || (text.startsWith('"') && text.endsWith('"'))) {
    const inner = text.slice(1, -1)
    return text.startsWith('"') ? inner.replace(/\\"/g, '"') : inner.replace(/''/g, "'")
  }
  if (text.startsWith('[') || text.startsWith('{')) {
    try { return JSON.parse(text) } catch { /* 非 JSON 行内结构：当字符串 */ }
  }
  if (text === 'true') return true
  if (text === 'false') return false
  if (/^-?\d+$/.test(text)) return Number(text)
  return text
}

/**
 * 解析一个 cordis patch 文件，返回 patch 行数组。
 * @param {string} file
 * @returns {Array<{ id?: string, name?: string, insert?: any[], config?: any }>}
 */
export function parsePatchFile(file) {
  if (!existsSync(file)) return []
  const lines = readFileSync(file, 'utf8').split(/\r?\n/)
  /** @type {any[]} */
  const rows = []
  let row = null
  // config 解析状态
  let inConfig = false
  let configIndent = -1
  /** 栈：每层 { indent, obj }，用于支持 accounts: 下的对象数组 */
  let stack = []
  let listKey = null

  const flush = () => {
    if (row !== null) rows.push(row)
    row = null
    inConfig = false
    configIndent = -1
    stack = []
    listKey = null
  }

  for (const original of lines) {
    const line = stripComment(original)
    if (line.trim() === '' || line.trim().startsWith('#')) continue
    const indent = line.length - line.trimStart().length

    // 顶层行
    if (indent === 0) {
      flush()
      if (line.startsWith('- insert:')) {
        row = { insert: [] }
        continue
      }
      if (line.startsWith('- ')) {
        row = {}
        const rest = line.slice(2)
        const [k, ...v] = rest.split(':')
        const value = v.join(':').trim()
        if (value === '' || value === undefined) row[k.trim()] = null
        else row[k.trim()] = parseScalar(value)
        continue
      }
      continue
    }

    if (row === null) continue

    // insert 列表项
    if (Array.isArray(row.insert) && !inConfig && /^-\s/.test(line.trim()) === false && indent > 0) {
      // `- id: x` 形式
    }
    const trimmed = line.trim()

    if (!inConfig) {
      const insertItem = /^-\s+(\w+):\s*(.*)$/.exec(trimmed)
      if (Array.isArray(row.insert) && insertItem) {
        const item = {}
        item[insertItem[1]] = parseScalar(insertItem[2])
        row.insert.push(item)
        continue
      }
      const insertCont = /^(\w+):\s*(.*)$/.exec(trimmed)
      if (Array.isArray(row.insert) && insertCont && row.insert.length > 0) {
        row.insert[row.insert.length - 1][insertCont[1]] = parseScalar(insertCont[2])
        continue
      }
      const top = /^(\w+):\s*(.*)$/.exec(trimmed)
      if (top) {
        if (top[1] === 'config' && top[2].trim() === '') {
          inConfig = true
          configIndent = indent
          row.config = {}
          stack = [{ indent, obj: row.config }]
        } else {
          row[top[1]] = parseScalar(top[2])
        }
        continue
      }
      continue
    }

    // ---- config 内部
    if (indent <= configIndent) {
      // config 结束，交给下一轮顶层逻辑重新处理这一行
      inConfig = false
      flush()
      // 重新解析这一行（极少数情况会走到，简单起见忽略）
      continue
    }

    // 列表项 `- key: value`
    const listItem = /^-\s+(\w+):\s*(.*)$/.exec(trimmed)
    if (listItem && listKey !== null) {
      const target = stack[stack.length - 1].obj
      if (!Array.isArray(target[listKey])) target[listKey] = []
      const item = {}
      item[listItem[1]] = parseScalar(listItem[2])
      target[listKey].push(item)
      stack.push({ indent, obj: item })
      continue
    }
    // 列表项续行
    const contItem = /^(\w+):\s*(.*)$/.exec(trimmed)
    if (contItem && listKey !== null && indent > (stack[stack.length - 1]?.indent ?? -1)) {
      const target = stack[stack.length - 1].obj
      if (target && !Array.isArray(target)) {
        target[contItem[1]] = parseScalar(contItem[2])
        continue
      }
    }
    // 普通 map 键
    const mapKey = /^(\w+):\s*(.*)$/.exec(trimmed)
    if (mapKey) {
      const target = stack[stack.length - 1].obj
      if (mapKey[2].trim() === '') {
        target[mapKey[1]] = {}
        listKey = mapKey[1]
        stack.push({ indent, obj: target[mapKey[1]] })
      } else {
        target[mapKey[1]] = parseScalar(mapKey[2])
        listKey = null
      }
      continue
    }
  }
  flush()
  return rows
}

/**
 * 按 profile 的组合顺序收集 patch 行，并为每个 entry id 合并 config
 * （后出现的层覆盖前面的：与 dsh-config-editor 的 `composeEntries` 语义一致）。
 *
 * @param {string} profileDir
 * @param {(specifier: string) => string} resolveBundleDir
 * @returns {Map<string, { id: string, name: string, config: any }>}
 */
export function composeProfileEntries(profileDir, resolveBundleDir) {
  /** @type {Map<string, any>} */
  const entries = new Map()
  const layers = []

  const profileJson = JSON.parse(readFileSync(join(profileDir, 'package.json'), 'utf8'))
  const bundles = profileJson?.dsh?.profile?.bundles ?? []
  for (const bundle of bundles) {
    const dir = resolveBundleDir(bundle)
    if (!dir) continue
    let patchPath = join(dir, 'cordis.patch.yml')
    try {
      const pkg = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'))
      if (typeof pkg?.dsh?.bundle?.patch === 'string') patchPath = join(dir, pkg.dsh.bundle.patch)
    } catch { /* 用默认文件名 */ }
    layers.push(parsePatchFile(patchPath))
  }
  layers.push(parsePatchFile(join(profileDir, 'cordis.patch.yml')))

  for (const layer of layers) {
    for (const row of layer) {
      if (Array.isArray(row.insert)) {
        for (const item of row.insert) {
          if (!item?.id) continue
          entries.set(item.id, { id: item.id, name: item.name, config: item.config ?? {} })
        }
        continue
      }
      if (!row.id) continue
      const prev = entries.get(row.id)
      if (!prev) {
        entries.set(row.id, { id: row.id, name: row.name, config: row.config ?? {} })
        continue
      }
      if (row.name !== undefined) prev.name = row.name
      if (row.config !== undefined) prev.config = { ...prev.config, ...row.config }
    }
  }
  return entries
}

export { dirname }
