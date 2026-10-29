/**
 * config.mjs —— 插件配置与路径解析（可分享版的核心）。
 *
 * ── 设计原则（为什么这样做）────────────────────────────────────────
 * 1. **代码里不出现任何具体机器的路径**。默认值全部从环境推导：
 *    `DSH_HOME` → 用户主目录，跨机器可移植。
 * 2. **部署相关的具体路径写进 DSH profile 的插件配置**（cordis patch 的
 *    `plugins: garmin-dash: {...}`），而不是硬编码在源码里 —— 这样同一个包
 *    在不同机器上只是配置不同。
 * 3. **向后兼容**：若某个历史路径（如 `<数据目录>`）确实存在，且用户没有
 *    显式配置，则自动沿用它 —— 老部署升级后行为不变，新部署拿到可移植默认值。
 *
 * 优先级：显式配置 > 环境变量 > 历史路径（存在时） > 可移植默认值。
 */
import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join, dirname } from 'node:path'

/** DSH 主目录（跨机器可移植）。 */
export function dshHome() {
  const env = process.env.DSH_HOME?.trim()
  if (env) return env
  return join(homedir(), '.dsh')
}

/** 若历史路径存在则沿用，否则用可移植默认值。 */
function preferExisting(legacy, fallback) {
  try {
    if (legacy && existsSync(legacy)) return legacy
  } catch {
    /* 权限异常等：退回默认值 */
  }
  return fallback
}

/**
 * 本机历史路径（仅用于"升级后行为不变"；新机器上这些路径不存在，不会生效）。
 * 集中在这里，便于审计与将来删除。
 */
/** 依次取第一个存在的路径（DSH 安装位置变过两次，硬编码必坏） */
function probeFirst(cands) {
  for (const one of cands) {
    try {
      if (typeof one === 'string' && one.length > 0 && existsSync(one)) return one
    } catch (error) { /* 忽略 */ }
  }
  return cands[0]
}

const LEGACY = {
  dataRoot: 'E:\\GarminData',
  devicesFile: join(dshHome(), 'garmin-dash-devices.json'),
  accountsDir: join(homedir(), 'AppData', 'Local', 'dsh-plugin-garmin-connect', 'accounts'),
  garminPluginDir: join(dshHome(), 'profiles', 'garmin', 'node_modules', 'dsh-plugin-garmin-connect'),
  desktopExe: probeFirst([
    'C:/Users/12623/AppData/Local/Programs/DSH NEXT/DSH NEXT.exe',
    'E:/tools/DSH-Desktop/DSH Desktop/DSH Desktop.exe',
  ]),
  desktopCli: probeFirst([
    'C:/Users/12623/AppData/Local/Programs/DSH NEXT/resources/app.asar/lib/desktop-cli.js',
    'E:/tools/DSH-Desktop/DSH Desktop/resources/app/lib/desktop-cli.js',
  ]),
  relayRegistryFile: join(dshHome(), 'remote-web-ui-registry', 'garmin.json'),
}

/** 运行期生效的路径（由 configure() 写入；模块只读它）。 */
export const paths = {
  /** 数据与快照落盘目录；同时是内建聊天会话的工作区。 */
  dataRoot: preferExisting(LEGACY.dataRoot, join(dshHome(), 'garmin-dash', 'data')),
  /** 配对设备库（只存密钥哈希）。 */
  devicesFile: LEGACY.devicesFile,
  /** garmin-connect 的账号绑定目录。 */
  accountsDir: LEGACY.accountsDir,
  /** garmin-connect 插件安装目录（裸包名解析失败时的回退）。 */
  garminPluginDir: LEGACY.garminPluginDir,
  /** DSH Desktop 可执行文件（内建聊天用）。 */
  desktopExe: LEGACY.desktopExe,
  /** DSH CLI 入口（内建聊天用）。 */
  desktopCli: LEGACY.desktopCli,
  /** 内建聊天使用的 profile。 */
  chatProfile: 'headless',
  /** 内建聊天单条消息超时（毫秒）。 */
  chatTimeoutMs: 240_000,
  /** 是否启用内建聊天端点。 */
  chatEnabled: true,
  /** 公网基址（如 https://xxxx.dsh-market.com）；空 = 自动从中继注册表推断。 */
  publicBase: '',
  /** 中继（remote-web-ui）注册表文件，用于自动推断公网域名。 */
  relayRegistryFile: LEGACY.relayRegistryFile,
}

/**
 * 用插件配置覆盖默认值。
 * @param {any} config cordis 传入的插件配置（可能为 undefined）
 * @returns {typeof paths} 生效后的路径对象
 */
export function configure(config) {
  const c = config ?? {}
  const pick = (value, key) => {
    if (typeof value === 'string' && value.trim().length > 0) paths[key] = value.trim()
  }
  pick(c.dataRoot, 'dataRoot')
  pick(c.devicesFile, 'devicesFile')
  pick(c.accountsDir, 'accountsDir')
  pick(c.garminPluginDir, 'garminPluginDir')
  pick(c.publicBase, 'publicBase')
  pick(c.relayRegistryFile, 'relayRegistryFile')

  const chat = c.chat ?? {}
  pick(chat.profile, 'chatProfile')
  if (typeof chat.enabled === 'boolean') paths.chatEnabled = chat.enabled
  if (Number.isFinite(chat.timeoutMs) && chat.timeoutMs > 1000) paths.chatTimeoutMs = chat.timeoutMs
  // 聊天工作区默认跟随数据目录；也可单独指定
  paths.chatWorkspace = (typeof chat.workspace === 'string' && chat.workspace.trim().length > 0)
    ? chat.workspace.trim()
    : (typeof c.dataRoot === 'string' && c.dataRoot.trim().length > 0 ? c.dataRoot.trim() : paths.dataRoot)
  // 桌面可执行文件 / CLI 路径：允许在 chat 段内覆盖
  pick(chat.dshExe, 'desktopExe')
  pick(chat.dshCli, 'desktopCli')

  // 环境变量兜底（便于容器/脚本部署）
  const envMap = {
    GARMIN_DASH_DATA_ROOT: 'dataRoot',
    GARMIN_DASH_DEVICES: 'devicesFile',
    GARMIN_DASH_ACCOUNTS_DIR: 'accountsDir',
    GARMIN_PLUGIN_DIR: 'garminPluginDir',
    GARMIN_DASH_PUBLIC_BASE: 'publicBase',
    DSH_DESKTOP_EXE: 'desktopExe',
    DSH_DESKTOP_CLI: 'desktopCli',
    GARMIN_CHAT_WORKSPACE: 'chatWorkspace',
    GARMIN_CHAT_PROFILE: 'chatProfile',
  }
  for (const [env, key] of Object.entries(envMap)) {
    const v = process.env[env]?.trim()
    if (v) paths[key] = v
  }

  if (!paths.chatWorkspace) paths.chatWorkspace = paths.dataRoot
  return paths
}

/** 目录级自检：返回人类可读的问题列表（供 setup 页与日志使用）。 */
export function selfCheck() {
  const issues = []
  const check = (label, p, mustExist = true) => {
    if (!p) {
      issues.push({ level: 'error', label, detail: '未配置路径' })
      return
    }
    const ok = existsSync(p)
    if (!ok && mustExist) issues.push({ level: 'warn', label, detail: `不存在：${p}` })
  }
  check('数据目录（快照/报告）', paths.dataRoot)
  check('garmin-connect 插件目录', paths.garminPluginDir)
  check('garmin-connect 账号目录', paths.accountsDir)
  check('DSH Desktop 可执行文件', paths.desktopExe)
  check('DSH CLI 入口', paths.desktopCli)
  return { ok: issues.filter((i) => i.level === 'error').length === 0, issues, paths: { ...paths } }
}

/** 供日志打印：只给目录名，避免泄露完整用户路径。 */
export function describePaths() {
  return {
    dataRoot: paths.dataRoot,
    chatWorkspace: paths.chatWorkspace,
    chatEnabled: paths.chatEnabled,
    chatProfile: paths.chatProfile,
    publicBase: paths.publicBase || '(auto)',
  }
}

export { dirname }
