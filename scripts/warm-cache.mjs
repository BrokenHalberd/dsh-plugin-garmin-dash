/**
 * 预热活动缓存：把最近 N 条活动的「详情 + 轨迹（含 15 档功率曲线）」拉到后端磁盘缓存。
 *
 * 用法：
 *   node warm-cache.mjs [数量]
 *   GARMIN_DASH_BASE=... GARMIN_DASH_KEY=... node warm-cache.mjs 120
 */
import { readFileSync } from 'node:fs'

const BASE = process.env.GARMIN_DASH_BASE || 'http://127.0.0.1:43121/garmin-dash/api'
const KEY = process.env.GARMIN_DASH_KEY || readFileSync('E:/DSH-Garmin/.diag-key', 'utf8').trim()
const TARGET = Number(process.argv[2] || 60)

const H = { 'X-Device-Key': KEY }

async function jget(path) {
  const res = await fetch(BASE + path, { headers: H })
  if (!res.ok) throw new Error('HTTP ' + res.status + ' ' + path)
  return res.json()
}

// 1) 拉活动 id（分页）
const ids = []
for (let offset = 0; ids.length < TARGET && offset < 600; offset += 50) {
  const list = await jget('/activities?limit=50&offset=' + offset)
  const arr = Array.isArray(list) ? list : (list.activities || [])
  if (arr.length === 0) break
  for (const a of arr) {
    const id = Number(a.id || a.activityId)
    if (id > 0 && !ids.includes(id)) ids.push(id)
    if (ids.length >= TARGET) break
  }
  if (arr.length < 50) break
}
console.log('  目标 ' + TARGET + ' 条，取到 ' + ids.length + ' 个活动 id')

// 2) 逐条预热（详情 + 轨迹）
let ok = 0
let fail = 0
const t0 = Date.now()
for (let i = 0; i < ids.length; i += 1) {
  const id = ids[i]
  try {
    await jget('/activity?id=' + id)
    await jget('/route?id=' + id + '&points=600')
    ok += 1
  } catch (error) {
    fail += 1
    console.log('    ✗ ' + id + '  ' + String(error.message).slice(0, 60))
  }
  if ((i + 1) % 10 === 0) {
    const el = ((Date.now() - t0) / 1000).toFixed(1)
    console.log('    进度 ' + (i + 1) + '/' + ids.length + '  成功 ' + ok + '  失败 ' + fail + '  已用 ' + el + 's')
  }
}
console.log('  完成：成功 ' + ok + '，失败 ' + fail + '，用时 ' + ((Date.now() - t0) / 1000).toFixed(1) + 's')
