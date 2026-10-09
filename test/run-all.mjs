#!/usr/bin/env node
/**
 * test/run-all.mjs —— 依次跑完全部测试，汇总结果。
 *
 * 用法：
 *   node test\run-all.mjs            # 全部（data-layer 若无账号邮箱会以退出码 2 提示）
 *   node test\run-all.mjs --replay   # data-layer 走回放模式（不需要任何凭据）
 */
import { spawn } from 'node:child_process'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const extra = process.argv.slice(2)

const SUITES = [
  { name: 'config-resolution', file: 'config-resolution.mjs', args: [] },
  { name: 'plugin-entry', file: 'plugin-entry.mjs', args: [] },
  { name: 'integration', file: 'integration.mjs', args: [] },
  { name: 'data-layer', file: 'data-layer.mjs', args: extra },
]

/** 顺序执行（并行会互相抢端口/快照文件）。 */
function run(file, args) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [join(HERE, file), ...args], { stdio: 'inherit' })
    child.on('close', (code) => resolve(code ?? 1))
    child.on('error', () => resolve(1))
  })
}

let failures = 0
const summary = []
for (const suite of SUITES) {
  process.stdout.write(`\n########## ${suite.name} ##########\n`)
  const code = await run(suite.file, suite.args)
  summary.push({ name: suite.name, code })
  if (code !== 0) failures += 1
}

process.stdout.write('\n########## summary ##########\n')
for (const s of summary) {
  const label = s.code === 0 ? 'PASS' : s.code === 2 ? 'PREREQ-MISSING' : 'FAIL'
  process.stdout.write(`  ${label.padEnd(14)} ${s.name} (exit ${s.code})\n`)
}
process.stdout.write(`\n  ${summary.length - failures}/${summary.length} suites green\n`)
process.exitCode = failures > 0 ? 1 : 0
