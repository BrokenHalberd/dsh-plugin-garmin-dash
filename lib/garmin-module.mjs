import { paths } from './config.mjs'
/**
 * garmin-module.mjs — 定位并加载 `dsh-plugin-garmin-connect` 的数据层。
 *
 * 为什么不用裸包名 import：本插件装在 profile 的 node_modules 下
 * （`$DSH_HOME\profiles\garmin\node_modules\`），而
 * `dsh-plugin-garmin-connect` 的 `exports` 只暴露 `.` 与 `./client`
 * （见其 package.json 第 7-17 行），本插件需要的 `lib/client.js`、
 * `lib/tool-service.js` 都是子路径。两种办法：
 *   1. `import('dsh-plugin-garmin-connect/lib/client.js')` —— 依赖宿主/
 *       脚本进程能看到该包（pnpm 的 symlink 结构下可行，但离线脚本目录
 *       不一定在解析路径上）。
 *   2. **按候选根目录解析绝对路径**（本模块采用）—— 显式、可测、可
 *       用环境变量覆盖，且不要求 <插件目录> 自己带 node_modules。
 *
 * 解析顺序：
 *   1. `GARMIN_PLUGIN_DIR` 环境变量（最高优先级，便于换机/换 profile）
 *   2. profile 的 node_modules（本机实际安装位置）
 *   3. 相对本包的 node_modules（若将来把 garmin-connect 声明为依赖）
 *   4. 裸包名 import（最后兜底）
 */
import { existsSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { createRequire } from 'node:module'

const CANDIDATE_DIRS = [
  process.env.GARMIN_PLUGIN_DIR?.trim(),
  paths.garminPluginDir,
  resolve(import.meta.dirname ?? '.', '..', 'node_modules', 'dsh-plugin-garmin-connect'),
  resolve(import.meta.dirname ?? '.', '..', '..', 'node_modules', 'dsh-plugin-garmin-connect'),
].filter((d) => typeof d === 'string' && d.length > 0)

/** 返回找到的插件根目录，找不到返回 undefined。 */
export function garminPluginDir() {
  for (const dir of CANDIDATE_DIRS) {
    if (existsSync(join(dir, 'lib', 'client.js'))) return dir
  }
  return undefined
}

/** 通过 CJS require.resolve 再兜一层（覆盖 pnpm symlink 场景）。 */
function requireResolveDir() {
  try {
    const require = createRequire(import.meta.url)
    const entry = require.resolve('dsh-plugin-garmin-connect/package.json')
    return resolve(entry, '..')
  } catch {
    return undefined
  }
}

/**
 * 动态加载 garmin 插件的一个 lib 文件。
 * @param {string} relative 例如 'lib/client.js'
 * @returns {Promise<any>}
 */
export async function loadGarminModule(relative) {
  const errors = []
  const dir = garminPluginDir() ?? requireResolveDir()
  if (dir) {
    const file = join(dir, relative)
    if (existsSync(file)) return import(pathToFileURL(file).href)
    errors.push(`not found at ${file}`)
  } else {
    errors.push('plugin directory not found in any candidate location')
  }
  // 兜底：裸包名 + 子路径
  try {
    return await import(`dsh-plugin-garmin-connect/${relative}`)
  } catch (error) {
    errors.push(String(error?.message ?? error).split('\n')[0])
  }
  throw new Error(`garmin-module: cannot load ${relative}: ${errors.join(' | ')}`)
}

/** GarminClient 类。 */
export async function loadGarminClient() {
  return (await loadGarminModule('lib/client.js')).GarminClient
}

/** GarminToolService 类。 */
export async function loadGarminToolService() {
  return (await loadGarminModule('lib/tool-service.js')).GarminToolService
}

/**
 * garmin 插件自己的配置解析函数（`resolveAccountConfigs`）。
 * 用它而不是自己重写，保证与运行中的插件**逐字段一致**。
 */
export async function loadResolveAccountConfigs() {
  return (await loadGarminModule('lib/config.js')).resolveAccountConfigs
}
