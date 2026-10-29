# 发布与部署说明（dsh-plugin-garmin-dash）

> 目标：让别人拿到这个包后，**装插件 → 开引导页 → 扫码配对 → 装 App** 四步跑通。

---

## 一、包内有什么

```
dsh-plugin-garmin-dash/
├─ lib/                    插件实现（Node ESM）
│  ├─ index.js             插件入口（inject: webServer + loader）
│  ├─ routes.mjs           /garmin-dash 全部路由
│  ├─ config.mjs           配置与路径解析（★ 可分享的关键）
│  ├─ setup-page.mjs       部署引导页 HTML
│  ├─ qr.mjs               二维码 PNG（按需解析宿主的 qrcode）
│  ├─ garmin-service.mjs    数据聚合（summary/趋势/曲线/HRV/轨迹）
│  ├─ garmin-direct.mjs     ★ 佳明直连客户端（自建，不依赖 garmin-connect 插件）
│  └─ …                   配对库、快照、趋势等
├─ bin/                    命令行工具（mint-pair-code）
├─ assets/                 ★ 鸿蒙 App 产物（未签名 HAP）
├─ app/                    ★ 鸿蒙工程源码（ArkTS / DevEco）
├─ cordis.patch.yml        bundle 补丁（webServer 端口等）
└─ PUBLISH.md              本文件
```

`package.json` 的 `dsh` 字段声明了 bundle 补丁，DSH 安装后自动挂载路由：

```json
"dsh": { "bundle": { "patch": "./cordis.patch.yml" } }
```

---

## 二、发布前需要你决定的三件事

| # | 事项 | 说明 |
|---|---|---|
| 1 | **npm 包名** | 现名 `dsh-plugin-garmin-dash`（未占用则直接发；若已被占用，改用 `@<你的scope>/dsh-plugin-garmin-dash`） |
| 2 | ~~**许可证**~~ | ✅ 已定为 **MIT**（`LICENSE` + `package.json` 的 `license` 字段均已就位） |
| 3 | **仓库地址** | `package.json` 暂未写 `repository`。填上 GitHub 地址后，市场收录与源码分发都靠它 |

---

## 三、发布步骤（本地验证 → 发包 → 收录）

```bash
# 1) 本地验证包内容（不发布）
cd <backend 目录>
npm pack --dry-run          # 看清单与体积
npm pack                    # 生成 .tgz，可先发给别人试装

# 2) 发布（需 npm 账号）
npm login
npm publish --access public # 若用 scope 包，必须带 --access public

# 3) 让 DSH 装上（两种方式）
#    a. DSH 桌面端 → 插件市场 → 搜索包名安装（推荐，会自动写进 profile 依赖）
#    b. 手工：在 profile 的 package.json dependencies 里加 "dsh-plugin-garmin-dash": "^0.2.0"
#       然后在该 profile 目录执行安装并重启 DSH
```

### 收录到插件市场（三选一或都提）

| 市场 | 地址 |
|---|---|
| 官方社区市场 | https://github.com/anywhere-labs/deepseek-harness-desktop/tree/master/dsh-community-market |
| Awesome 列表 | https://github.com/awesome-dsh-plugin/awesome-dsh-plugin |
| 第三方市场 | https://github.com/dsh-market/dsh-market |

提交内容通常只需：**包名 + 一句话描述 + 仓库地址**（各市场 README 有模板）。

---

## 四、别人怎么用（装好插件之后）

1. 确认依赖：`dsh-plugin-garmin-connect`（本插件复用它的佳明登录态；没装/没登录 → 数据端点 503，引导页会明确提示）
2. **打开引导页**：`http://127.0.0.1:<webServer端口>/garmin-dash/setup`
   （仅本机回环可访问；页面含依赖自检、配对二维码、App 下载、中继引导、当前配置）
3. 手机 App：从引导页下载包内 HAP，**用 DevEco Studio 自动签名后安装**（华为要求签名，无法绕过），或用仓库里的 `app/` 源码自行构建
4. 手机与电脑同网段即可用；想要外网访问 → 引导页第 ④ 节有中继启用步骤

---

## 五、配置项（写在 profile 的插件配置里，也可用环境变量）

优先级：**插件配置 > 环境变量 > 历史路径（存在时） > 可移植默认值**

| 配置键 | 环境变量 | 默认 | 说明 |
|---|---|---|---|
| `dataRoot` | `GARMIN_DASH_DATA_ROOT` | `$DSH_HOME/garmin-dash/data` | 快照与报告落盘目录 |
| `devicesFile` | `GARMIN_DASH_DEVICES` | `$DSH_HOME/garmin-dash-devices.json` | 配对设备库（只存密钥哈希） |
| `accountsDir` | `GARMIN_DASH_ACCOUNTS_DIR` | `%LOCALAPPDATA%/dsh-plugin-garmin-connect/accounts` | garmin-connect 账号绑定 |
| `garminPluginDir` | `GARMIN_PLUGIN_DIR` | `$DSH_HOME/profiles/*/node_modules/dsh-plugin-garmin-connect` | 裸包名解析失败时的回退 |
| `publicBase` | `GARMIN_DASH_PUBLIC_BASE` | 空（自动从中继注册表推断） | 手机端使用的公网地址 |
| `relayRegistryFile` | — | `$DSH_HOME/remote-web-ui-registry/*.json` | 中继域名注册表 |
| `chat.enabled` | — | `true` | App 内建 DSH 对话 |
| `chat.workspace` | `GARMIN_CHAT_WORKSPACE` | 跟随 `dataRoot` | 聊天会话工作区（同时是权限边界） |
| `chat.profile` | `GARMIN_CHAT_PROFILE` | `headless` | 聊天子进程使用的 profile |
| `chat.dshExe` | `DSH_DESKTOP_EXE` | 自动探测 | DSH Desktop 可执行文件 |
| `chat.dshCli` | `DSH_DESKTOP_CLI` | 自动探测 | DSH CLI 入口 |
| `chat.timeoutMs` | — | `240000` | 单条消息超时 |

配置示例（profile 的 cordis patch）：

```yaml
plugins:
  garmin-dash:
    dataRoot: 'D:\GarminData'
    publicBase: 'https://xxxxxxxx.dsh-market.com'
    chat:
      enabled: true
      profile: headless
```

---

## 六、已知限制（如实告知使用者）

| 限制 | 说明 |
|---|---|
| **App 必须自行签名** | 华为要求；包内 HAP 是**未签名**的，需 DevEco 自动签名（需华为账号）或用自家签名工具 |
| **依赖佳明账号** | 通过 `dsh-plugin-garmin-connect` 登录；本插件不碰账号密码，也不存凭据 |
| **聊天依赖本机 DSH** | App 内建对话是本机 DSH 的子进程；跨机器无法工作（设计如此） |
| **部分指标可能为空** | 佳明未提供的数据（如体重、Body Battery 某些账号）会显示 `--`，不做估算 |
| **平台** | 后端为 Node（跨平台）；`chat` 路径探测目前按 Windows 习惯（`DSH Desktop.exe`），其他平台请显式配置 `chat.dshExe` / `chat.dshCli` |

---

## 七、安全设计（可写进市场描述）

- 设备密钥只在服务端存 **SHA-256 哈希**；配对码 8 位、一次性、10 分钟有效
- 除 `health` / `pair` 外所有数据端点要求 `X-Device-Key`，未配对一律 401
- 引导页、自检、二维码、App 下载**仅限本机回环**（非回环 403）
- 内建聊天的**工作区与权限档由后端锁定**（工作区即会话 cwd，权限档 `workspace-write` + profile `defaultPreset` 双保险）
- 默认不开启任何公网暴露；公网访问需显式启用中继插件
