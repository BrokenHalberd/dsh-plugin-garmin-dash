#!/usr/bin/env node
/**
 * dash-mint-pair-code —— 在**正在运行的宿主进程里**铸造一个配对码。
 *
 * 为什么必须走宿主：配对码按设计只存在宿主的**内存**里（10 分钟 TTL、单次使用），
 * 外部进程读不到。所以本 CLI 调宿主暴露的**仅回环**内部路由
 *   POST http://127.0.0.1:<port>/garmin-dash/internal/mint-code
 * 宿主侧对非 127.0.0.1/::1 来源一律 403（lib/routes.mjs 的 isLoopback）。
 *
 * 打印内容：
 *   1. 8 位配对码
 *   2. 可直接扫的配对 URL：`https://<固定域名>/garmin-dash/pair?code=XXXXXXXX`
 *      （固定域名取自 DSH_HOME 下的中继注册表，
 *        失败时退化为只显示码，并在 stderr 说明）
 *   3. 到期时间
 *
 * 用法：
 *   node <插件目录>\bin\mint-pair-code.mjs
 *   node <插件目录>\bin\mint-pair-code.mjs --json       # 机器可读
 *   node <插件目录>\bin\mint-pair-code.mjs --port 43121
 *   $env:GARMIN_DASH_PORT=43121; node ...
 */
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { dshHome } from '../lib/config.mjs'
import { request } from 'node:http'

const DEFAULT_PORTS = [43121, 43120, 43122]
const REGISTRY_FILE = join(dshHome(), 'remote-web-ui-registry', 'garmin.json')
const PROFILE_PATCH = join(dshHome(), 'profiles', process.env.GARMIN_PROFILE ?? 'garmin', 'cordis.patch.yml')
const PREFIX = '/garmin-dash'

/** 解析 argv 中的 `--port N` / `--json` / `--base URL`。 */
function parseArgs(argv) {
  const out = { json: false, ports: [], base: '' }
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]
    if (arg === '--json') out.json = true
    else if (arg === '--port') out.ports.push(Number(argv[++i]))
    else if (arg.startsWith('--port=')) out.ports.push(Number(arg.slice(7)))
    else if (arg === '--base') out.base = String(argv[++i] ?? '')
    else if (arg.startsWith('--base=')) out.base = arg.slice(7)
  }
  return out
}

/** 从 profile 补丁里抠出 webserver 的 port（不引入 yaml 依赖，只做定向正则）。 */
function portFromProfilePatch() {
  try {
    const text = readFileSync(PROFILE_PATCH, 'utf8')
    const match = /^\s*port:\s*(\d+)\s*$/m.exec(text)
    if (match) return Number(match[1])
  } catch { /* 补丁不存在 */ }
  return undefined
}

/** 候选端口，按可信度排序，去重。 */
function candidatePorts(cliPorts) {
  const list = [
    ...cliPorts,
    Number(process.env.GARMIN_DASH_PORT || 0),
    portFromProfilePatch() ?? 0,
    ...DEFAULT_PORTS,
  ].filter((p) => Number.isInteger(p) && p > 0 && p < 65536)
  return [...new Set(list)]
}

/** 读固定公网域名：https://<registry.id>.dsh-market.com */
function publicBaseFromRegistry() {
  try {
    const id = JSON.parse(readFileSync(REGISTRY_FILE, 'utf8'))?.id
    if (typeof id === 'string' && /^[a-z0-9]{8,64}$/i.test(id)) return `https://${id}.dsh-market.com`
  } catch { /* 注册表缺失 */ }
  return ''
}

/** 单次 POST，返回 { status, body }。 */
function post(port, path, timeoutMs = 8000) {
  return new Promise((resolve, reject) => {
    const req = request({
      host: '127.0.0.1',
      port,
      path,
      method: 'POST',
      headers: { 'content-length': 0 },
      timeout: timeoutMs,
    }, (res) => {
      const chunks = []
      res.on('data', (c) => chunks.push(c))
      res.on('end', () => resolve({ status: res.statusCode ?? 0, body: Buffer.concat(chunks).toString('utf8') }))
    })
    req.on('timeout', () => req.destroy(new Error('timeout')))
    req.on('error', reject)
    req.end()
  })
}

/** 探测某个端口的 /api/health（免鉴权），确认这就是我们的宿主。 */
async function probeHealth(port) {
  return new Promise((resolve) => {
    const req = request({
      host: '127.0.0.1', port, path: `${PREFIX}/api/health`, method: 'GET', timeout: 4000,
    }, (res) => {
      const chunks = []
      res.on('data', (c) => chunks.push(c))
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8')
        resolve(res.statusCode === 200 && /"ok"\s*:\s*true/.test(text))
      })
    })
    req.on('timeout', () => { req.destroy(); resolve(false) })
    req.on('error', () => resolve(false))
    req.end()
  })
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  const ports = candidatePorts(args.ports)

  let lastError = ''
  for (const port of ports) {
    if (!(await probeHealth(port))) continue
    try {
      const res = await post(port, `${PREFIX}/internal/mint-code`)
      if (res.status !== 200) {
        lastError = `host on 127.0.0.1:${port} answered HTTP ${res.status}`
        continue
      }
      const payload = JSON.parse(res.body)
      const base = args.base || publicBaseFromRegistry()
      const url = base ? `${base}${PREFIX}/pair?code=${payload.code}` : ''
      if (args.json) {
        process.stdout.write(`${JSON.stringify({ ...payload, url, port }, null, 2)}\n`)
        return 0
      }
      const lines = [
        '',
        '  ┌─ 佳明看板 · 设备配对码 ────────────────────────',
        `  │  配对码   ${payload.code}`,
        `  │  有效期   ${payload.expiresInSeconds} 秒（${payload.expiresAt}）`,
        '  │  单次使用：兑换成功后立即失效',
      ]
      if (url) lines.push(`  │  配对链接 ${url}`)
      else lines.push('  │  配对链接 (不可用：读不到固定域名注册表，请在 App 里手动输入配对码)')
      lines.push(`  │  宿主      127.0.0.1:${port}`, '  └────────────────────────────────────────────────', '')
      process.stdout.write(`${lines.join('\n')}\n`)
      return 0
    } catch (error) {
      lastError = String(error?.message ?? error)
    }
  }

  process.stderr.write([
    '',
    '  ✗ 无法铸造配对码：没有在回环地址上找到可用的 garmin-dash 宿主。',
    `    已尝试端口：${ports.join(', ')}`,
    lastError ? `    最后一次错误：${lastError}` : '',
    '    可能原因：宿主未运行 / 该 profile 尚未装入 dsh-plugin-garmin-dash / 端口不是默认值。',
    '    可用 --port <端口> 或环境变量 GARMIN_DASH_PORT 指定。',
    '',
  ].filter(Boolean).join('\n') + '\n')
  return 1
}

main().then((code) => process.exit(code), (error) => {
  process.stderr.write(`mint-pair-code failed: ${String(error?.message ?? error)}\n`)
  process.exit(1)
})
