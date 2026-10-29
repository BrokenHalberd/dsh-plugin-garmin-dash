/**
 * garmin-direct.mjs — 后端自己的佳明直连客户端（不经过 garmin-connect 插件）
 *
 * 为什么需要它：插件（garmin-connect）内部的 axios 实例在会话文件被更新后会整体失效
 * （所有请求 request_failed），而我们的业务只依赖两类能力：
 *   1) 用 refresh_token 换 access_token（协议已实测通过）
 *   2) 带 Bearer 打 connectapi
 * 所以自己实现这两步，把"会话文件"当作唯一真源：谁刷新都把结果写回同一份文件。
 *
 * 关键协议（逆向 + 实测）：
 *   POST https://diauth.garmin.com/di-oauth2-service/oauth/token
 *   Authorization: Basic base64(client_id + ":")
 *   Content-Type: application/x-www-form-urlencoded
 *   grant_type=refresh_token & client_id=... & refresh_token=...
 *   → 返回 access_token / refresh_token（**轮换**）/ expires_in / refresh_token_expires_in
 *   缺 Garmin 原生头会返回 200 + HTML 登录页（必须带上）
 */
import { readFileSync, readdirSync, writeFileSync, renameSync, existsSync, statSync } from 'node:fs'
import { join } from 'node:path'
import https from 'node:https'

export const CLIENT_ID = 'GARMIN_CONNECT_MOBILE_ANDROID_DI_2025Q2'
export const API_BASE = 'https://connectapi.garmin.com'
const DIAUTH = 'https://diauth.garmin.com/di-oauth2-service/oauth/token'

/** IPv4 优先的 agent：本机 IPv6 到 garmin 会超时 */
const agent = new https.Agent({ family: 4, keepAlive: true, maxSockets: 8 })

function nativeHeaders() {
  return {
    'Accept-Encoding': 'identity',
    'Accept-Language': 'en-US,en;q=0.9',
    'Cache-Control': 'no-cache',
    'User-Agent': 'GCM-Android-5.23',
    'X-App-Ver': '10861',
    'X-Garmin-Client-Platform': 'Android',
    'X-Garmin-Paired-App-Version': '10861',
    'X-Garmin-User-Agent': 'com.garmin.android.apps.connectmobile',
    'X-GCExperience': 'GC5',
    'X-Lang': 'en',
  }
}

function accountsDir() {
  const root = process.env.GARMIN_ACCOUNTS_DIR?.trim()
    || join(process.env.LOCALAPPDATA ?? '', 'dsh-plugin-garmin-connect', 'accounts')
  return root
}

/** 选 refresh 到期最晚的那份会话文件（即当前账号） */
export function pickSessionFile() {
  const dir = accountsDir()
  if (!existsSync(dir)) return undefined
  let best
  for (const name of readdirSync(dir)) {
    if (!name.endsWith('.session.json')) continue
    const path = join(dir, name)
    try {
      const j = JSON.parse(readFileSync(path, 'utf8'))
      const exp = Number(j?.tokens?.refreshExpiresAtMs ?? 0)
      if (!best || exp > best.exp) best = { path, exp, session: j, mtime: statSync(path).mtimeMs }
    } catch { /* 跳过坏文件 */ }
  }
  return best
}

/** 写回会话文件（原子替换；插件下次读取即可拿到新 token） */
function persistSession(path, session) {
  const tmp = `${path}.tmp-${process.pid}`
  writeFileSync(tmp, JSON.stringify(session, null, 2), 'utf8')
  renameSync(tmp, path)
}

let cache = { access: '', expMs: 0 }

/** 用 refresh_token 换新的 access_token（并回写轮换后的 refresh_token） */
export async function refreshToken() {
  const picked = pickSessionFile()
  if (!picked) throw new Error('no session file')
  const rt = picked.session?.tokens?.refreshToken
  if (typeof rt !== 'string' || rt.length === 0) throw new Error('no refresh_token in session file')
  const refreshExp = Number(picked.session?.tokens?.refreshExpiresAtMs ?? 0)
  if (refreshExp > 0 && refreshExp <= Date.now()) throw new Error('refresh_token expired')

  const body = new URLSearchParams({
    grant_type: 'refresh_token',
    client_id: CLIENT_ID,
    refresh_token: rt,
  }).toString()

  const res = await fetch(DIAUTH, {
    method: 'POST',
    headers: {
      ...nativeHeaders(),
      Accept: 'application/json',
      Authorization: 'Basic ' + Buffer.from(`${CLIENT_ID}:`).toString('base64'),
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body,
  })
  const text = await res.text()
  if (res.status !== 200) throw new Error(`refresh HTTP ${res.status}: ${text.slice(0, 120)}`)
  let j
  try { j = JSON.parse(text) } catch { throw new Error('refresh returned non-JSON (login page?)') }
  if (typeof j.access_token !== 'string' || j.access_token.length === 0) {
    throw new Error('refresh response has no access_token')
  }

  const now = Date.now()
  const accessExp = now + (Number(j.expires_in) > 0 ? Number(j.expires_in) * 1000 : 3600e3)
  const refreshExpNew = Number(j.refresh_token_expires_in) > 0
    ? now + Number(j.refresh_token_expires_in) * 1000
    : refreshExp

  picked.session.tokens.accessToken = j.access_token
  picked.session.tokens.accessExpiresAtMs = accessExp
  if (typeof j.refresh_token === 'string' && j.refresh_token.length > 0) {
    picked.session.tokens.refreshToken = j.refresh_token
    picked.session.tokens.refreshExpiresAtMs = refreshExpNew
  }
  persistSession(picked.path, picked.session)

  cache = { access: j.access_token, expMs: accessExp }
  return { accessToken: j.access_token, accessExpiresAtMs: accessExp, file: picked.path }
}

/** 拿一个可用的 access_token（快过期就续期一次） */
export async function ensureAccessToken() {
  if (cache.access && cache.expMs > Date.now() + 60_000) return cache.access
  const picked = pickSessionFile()
  const at = picked?.session?.tokens?.accessToken
  const exp = Number(picked?.session?.tokens?.accessExpiresAtMs ?? 0)
  if (typeof at === 'string' && at.length > 0 && (exp === 0 || exp > Date.now() + 60_000)) {
    cache = { access: at, expMs: exp }
    return at
  }
  const r = await refreshToken()
  return r.accessToken
}

/** 直连 GET（JSON） */
export async function garminGet(path, { timeoutMs = 15000 } = {}) {
  const token = await ensureAccessToken()
  const url = path.startsWith('http') ? path : API_BASE + path
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)
  try {
    const res = await fetch(url, {
      method: 'GET',
      headers: {
        ...nativeHeaders(),
        Accept: 'application/json',
        Authorization: `Bearer ${token}`,
      },
      signal: controller.signal,
    })
    const text = await res.text()
    if (res.status === 401) {
      // token 失效 → 立刻续期后重试一次
      await refreshToken()
      return garminGet(path, { timeoutMs })
    }
    if (res.status < 200 || res.status >= 300) {
      throw new Error(`Garmin HTTP ${res.status}: ${text.slice(0, 120)}`)
    }
    return text.length === 0 ? null : JSON.parse(text)
  } finally {
    clearTimeout(timer)
  }
}

/** displayName（dailySummary 需要）：user-settings 优先，socialProfile 兜底 */
export async function resolveDisplayName() {
  for (const p of ['/userprofile-service/userprofile/user-settings', '/userprofile-service/socialProfile']) {
    try {
      const j = await garminGet(p, { timeoutMs: 8000 })
      const name = j?.displayName
      if (typeof name === 'string' && name.length > 0) return name
    } catch { /* 下一个候选 */ }
  }
  return undefined
}

export { agent }
