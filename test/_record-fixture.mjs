#!/usr/bin/env node
/**
 * 从 stdin 读取一个 JSON 数组，写入 `test/fixtures/garmin-samples.json` 的指定键。
 * 用途：把 DSH 的 Garmin AI 工具真实返回的上游响应原样固化成测试样本
 * （`get_garmin_activities` 的 full-detail 结果）。
 *
 * 用法：node test/_record-fixture.mjs activitiesFull < payload.json
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const FIXTURE = join(HERE, 'fixtures', 'garmin-samples.json')

const key = process.argv[2]
if (!key) {
  process.stderr.write('usage: node _record-fixture.mjs <key> < payload.json\n')
  process.exit(1)
}

const chunks = []
for await (const chunk of process.stdin) chunks.push(chunk)
const payload = JSON.parse(Buffer.concat(chunks).toString('utf8'))

let doc
try {
  doc = JSON.parse(readFileSync(FIXTURE, 'utf8'))
} catch {
  doc = { _meta: {} }
}
doc[key] = payload
doc._meta = {
  ...(doc._meta ?? {}),
  [`${key}RecordedAt`]: new Date().toISOString(),
  note: 'Raw payloads as returned by the authenticated dsh-plugin-garmin-connect tool surface on this machine.',
}
writeFileSync(FIXTURE, JSON.stringify(doc, null, 2))
process.stdout.write(`recorded ${key}: ${Array.isArray(payload) ? `${payload.length} items` : typeof payload}\n`)
