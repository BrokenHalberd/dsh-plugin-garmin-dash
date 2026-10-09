/**
 * pages.mjs — 不挂 `/api` 前缀的极简 HTML 页面。
 *
 * `/garmin-dash/pair?code=XXXXXXXX` 是二维码里那个 URL 的落地页：
 * 用户扫到的是这个地址，App 自己解析 `code=` 后 POST `/garmin-dash/api/pair`。
 * 页面**不含任何密钥**（配对码本身就是一次性的、显示出来也无妨——它刚被印在
 * 用户自己的二维码里），也不引用任何外部资源（无 CDN、无字体、无脚本）。
 */

/** HTML 转义（防止 code 参数被当作标记注入）。 */
export function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;')
}

/**
 * 配对落地页。
 * @param {object} args
 * @param {string} args.code 归一化后的配对码（可为空）
 * @param {number} args.ttlSeconds 剩余有效秒数
 * @param {boolean} args.minted 该码是否由服务端确认过（仅用于文案）
 */
export function pairPageHtml({ code, ttlSeconds = 600, minted = false }) {
  const safeCode = escapeHtml(code)
  const minutes = Math.max(1, Math.round(ttlSeconds / 60))
  const body = code
    ? `
      <p class="lead">请在「佳明看板」手机 App 里完成配对。</p>
      <div class="code" aria-label="pairing code">${safeCode}</div>
      <p class="hint">打开 App → 「我的」→ 输入上面的配对码（或直接点开扫码进来的链接）。</p>
      <p class="hint dim">该配对码 ${minutes} 分钟内有效，且只能使用一次。</p>`
    : `
      <p class="lead">缺少配对码。</p>
      <p class="hint">请重新扫描二维码，或在电脑上运行 <code>dash-mint-pair-code</code> 生成新的配对码。</p>`
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>佳明看板 · 设备配对</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
         background: #0f1115; color: #e8eaf0;
         font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", "Microsoft YaHei", sans-serif; }
  main { width: min(92vw, 26rem); padding: 2rem 1.5rem; text-align: center;
         background: #171a21; border: 1px solid #262b36; border-radius: 1rem; }
  h1 { font-size: 1.15rem; margin: 0 0 1rem; font-weight: 600; letter-spacing: .02em; }
  .lead { margin: 0 0 1.25rem; color: #b9c0cf; }
  .code { font: 700 2.5rem/1.2 ui-monospace, SFMono-Regular, Consolas, monospace;
          letter-spacing: .18em; padding: .75rem .5rem; margin: 0 0 1.25rem;
          background: #0b0d11; border: 1px dashed #2f3a4a; border-radius: .6rem;
          color: #7ee0a0; user-select: all; }
  .hint { margin: .35rem 0; color: #98a1b3; font-size: .9rem; }
  .hint.dim { color: #6d7686; }
  code { font-family: ui-monospace, SFMono-Regular, Consolas, monospace; background: #0b0d11;
         padding: .1rem .35rem; border-radius: .3rem; }
</style>
</head>
<body>
<main>
  <h1>佳明看板 · 设备配对</h1>${body}
  <p class="hint dim">此页面不包含任何账号凭据或设备密钥。</p>
</main>
</body>
</html>`
}

/** 极简 404/405 文本响应体。 */
export function textPage(message, status) {
  return { status, body: `${message}\n` }
}
