/**
 * setup-page.mjs —— 部署引导页（`/garmin-dash/setup`）。
 *
 * 目标：别人装上这个插件后，打开一个页面就知道**缺什么、下一步做什么**。
 * 页面只在**本机回环**可达（配对码与路径信息不应外泄），因此由路由层做限制。
 *
 * 页面包含：依赖自检 / 手机配对二维码 / App 获取方式 / 公网中继引导 / 配置项说明。
 * 无任何外部资源（无 CDN、无字体、无脚本），可离线打开。
 */
import { escapeHtml } from './pages.mjs'
import { paths, dshHome } from './config.mjs'
import { qrAvailable } from './qr.mjs'

/** 一行自检结果 → HTML。 */
function checkRow(item) {
  const icon = item.level === 'ok' ? '✅' : (item.level === 'warn' ? '⚠️' : '❌')
  const detail = item.detail ? `<div class="dim">${escapeHtml(item.detail)}</div>` : ''
  return `<li class="${escapeHtml(item.level)}"><span class="ic">${icon}</span><div><b>${escapeHtml(item.label)}</b>${detail}</div></li>`
}

function steps(list) {
  return `<ol>${list.map((s) => `<li>${s}</li>`).join('')}</ol>`
}

/**
 * 组装引导页。
 * @param {object} args
 * @param {Array<{level:string,label:string,detail?:string}>} args.checks 自检结果
 * @param {string} args.version 插件版本
 * @param {boolean} args.qrReady 二维码渲染是否可用
 * @param {string} args.publicBase 公网基址（空 = 未启用中继）
 * @param {boolean} args.hasAppAsset 包内是否带 App 产物
 */
export function setupPageHtml({ checks, version, qrReady, publicBase, hasAppAsset }) {
  const okCount = checks.filter((c) => c.level === 'ok').length
  const badCount = checks.filter((c) => c.level === 'error').length
  const headline = badCount === 0
    ? `<span class="pill ok">就绪 ${okCount} 项</span>`
    : `<span class="pill bad">${badCount} 项待处理</span>`

  const relayBlock = publicBase
    ? `<p class="ok-line">已启用公网中继：<code>${escapeHtml(publicBase)}</code></p>
       <p class="dim">手机在任意网络下都能连（未配对设备一律 401）。</p>`
    : `<p class="warn-line">当前仅局域网可用。</p>
       ${steps([
    '安装中继插件 <code>@linxin666/dsh-remote-web-ui</code> 并在 profile 里启用',
    '在分身里启用中继（固定域名模式），重启分身',
    '回到本页刷新：上方会出现公网地址，复制它作为手机端「服务器地址」',
  ])}`

  const appBlock = hasAppAsset
    ? `<p>本插件包内含已构建的 <b>未签名 HAP</b> 与完整 HarmonyOS 工程源码。</p>
       <p><a class="btn" href="/garmin-dash/app/latest.hap" download>下载 HAP（未签名）</a></p>
       <p class="dim">华为要求应用必须签名后才能安装：用 DevEco Studio 打开工程 → 开启自动签名 → Run，或用自己的签名工具签名后再装。</p>`
    : `<p class="warn-line">本包未附带 App 产物（开发态安装）。</p>
       <p>请从仓库获取 <code>app/</code> 工程后用 DevEco Studio 构建。</p>`

  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>佳明看板 · 部署引导</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; padding: 2rem 1rem 4rem; background: #0f1115; color: #e8eaf0;
         font: 15px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", "Microsoft YaHei", sans-serif; }
  main { width: min(96vw, 46rem); margin: 0 auto; }
  h1 { font-size: 1.3rem; margin: 0 0 .35rem; }
  h2 { font-size: 1rem; margin: 2rem 0 .6rem; padding-bottom: .35rem; border-bottom: 1px solid #262b36; }
  .sub { color: #98a1b3; margin: 0 0 1rem; }
  .card { background: #171a21; border: 1px solid #262b36; border-radius: .8rem; padding: 1rem 1.1rem; }
  ul.checks { list-style: none; padding: 0; margin: 0; }
  ul.checks li { display: flex; gap: .6rem; padding: .45rem 0; border-bottom: 1px dashed #232833; }
  ul.checks li:last-child { border-bottom: 0; }
  .ic { width: 1.4rem; flex: none; }
  .dim { color: #79839a; font-size: .86rem; word-break: break-all; }
  code { font-family: ui-monospace, SFMono-Regular, Consolas, monospace; background: #0b0d11;
         padding: .1rem .35rem; border-radius: .3rem; color: #cfe3ff; }
  .pill { display: inline-block; padding: .15rem .6rem; border-radius: 1rem; font-size: .8rem; }
  .pill.ok { background: #12351f; color: #7ee0a0; }
  .pill.bad { background: #3a1d1d; color: #ff9c9c; }
  .ok-line { color: #7ee0a0; }
  .warn-line { color: #ffcf7a; }
  .qr { display: flex; gap: 1.2rem; align-items: center; flex-wrap: wrap; }
  .qr img { width: 220px; height: 220px; background: #fff; border-radius: .6rem; padding: .4rem; }
  .code { font: 700 1.6rem/1.2 ui-monospace, Consolas, monospace; letter-spacing: .16em; color: #7ee0a0; }
  .btn { display: inline-block; margin: .4rem 0; padding: .5rem 1rem; border-radius: .5rem;
         background: #1d4ed8; color: #fff; text-decoration: none; }
  ol, ul { padding-left: 1.3rem; }
  footer { margin-top: 2.5rem; color: #6d7686; font-size: .82rem; }
</style>
</head>
<body>
<main>
  <h1>佳明看板 · 部署引导 ${headline}</h1>
  <p class="sub">插件 <code>dsh-plugin-garmin-dash</code> v${escapeHtml(version)} · 本页仅本机可访问</p>

  <h2>① 依赖自检</h2>
  <div class="card"><ul class="checks">${checks.map(checkRow).join('')}</ul></div>

  <h2>② 手机配对</h2>
  <div class="card">
    <div class="qr">
      ${qrReady
    ? '<img src="/garmin-dash/pair-qr.png" alt="配对二维码">'
    : '<div class="dim">（未找到二维码渲染库，请使用下方链接或脚本生成）</div>'}
      <div>
        <p>用手机 App 扫描左侧二维码，或在「我的」里手动输入配对码。</p>
        <p class="dim">二维码内容即一次性配对链接，10 分钟内有效、只能使用一次。</p>
        ${qrReady ? '' : `<p class="dim">配对链接：<code>${escapeHtml(publicBase || 'http://<本机IP>:<端口>')}/garmin-dash/pair</code></p>`}
      </div>
    </div>
  </div>

  <h2>③ 手机 App</h2>
  <div class="card">${appBlock}</div>

  <h2>④ 公网访问（可选）</h2>
  <div class="card">${relayBlock}</div>

  <h2>⑤ 当前生效配置</h2>
  <div class="card">
    <p class="dim">优先级：插件配置 &gt; 环境变量 &gt; 历史路径（存在时） &gt; 可移植默认值。</p>
    <ul class="checks">
      <li><span class="ic">📁</span><div><b>数据目录 / 聊天工作区</b><div class="dim">${escapeHtml(paths.chatWorkspace)}</div></div></li>
      <li><span class="ic">🔑</span><div><b>设备库</b><div class="dim">${escapeHtml(paths.devicesFile)}</div></div></li>
      <li><span class="ic">⚙️</span><div><b>配置文件（在 profile 的插件配置里改）</b><div class="dim">dataRoot / devicesFile / accountsDir / garminPluginDir / publicBase / chat.{enabled,workspace,profile,dshExe,dshCli,timeoutMs}</div></div></li>
      <li><span class="ic">🏠</span><div><b>DSH 主目录</b><div class="dim">${escapeHtml(dshHome())}</div></div></li>
    </ul>
  </div>

  <footer>本页不包含账号凭据与设备密钥；配对码为一次性。刷新即可重新生成。</footer>
</main>
</body>
</html>`
}
