# dsh-plugin-garmin-dash · 佳明看板

把 **Garmin Connect** 数据变成自己手机上的原生仪表盘：DSH 插件做后端（复用佳明登录态、不消耗大模型），附一套 **鸿蒙（HarmonyOS / ArkTS）原生 App** 工程与已构建产物。

> 适合：已经有 DSH + [`dsh-plugin-garmin-connect`](https://github.com/Likenttt/garmin-connect-plugin-for-dsh)（已登录佳明），想要一个"自己的数据看板"的人。

---

## 特性

| 能力 | 说明 |
|---|---|
| **数据接口** | `/garmin-dash/api/{summary,activities,activity,trend}`：身体状态、活动列表、单次详情（功率曲线 / 功率区间 / 心率区间 / 左右平衡）、训练负荷（CTL/ATL/TSB + 周汇总） |
| **部署引导页** | `/garmin-dash/setup`：依赖自检 + 配对二维码 + App 下载 + 公网中继引导（**仅本机回环可访问**） |
| **安全配对** | 8 位一次性配对码（10 分钟）；设备密钥仅在服务端存 **SHA-256 哈希**；未配对一律 401 |
| **App 内建对话** | App 里直接和 DSH 对话（原生界面）：**完整会话记忆**（持久会话续接），**工作区与权限档由后端锁死** |
| **随包分发 App** | `assets/` 内含未签名 HAP，`app/` 内是完整鸿蒙工程源码 |
| **可移植配置** | 代码里没有任何具体机器路径；路径全部可从 profile 配置或环境变量覆盖 |

---

## 快速开始

```bash
# 1) 装插件（二选一）
#    a. 从 npm（如已发布）
npm i dsh-plugin-garmin-dash
#    b. 直接从源码（本仓库）
npm i github:BrokenHalberd/dsh-plugin-garmin-dash
```

2) 确认已安装并登录 `dsh-plugin-garmin-connect`（本插件复用它的登录态）
3) 打开引导页：`http://127.0.0.1:<webServer端口>/garmin-dash/setup`
4) 用手机 App 扫码配对（App 从引导页下载 HAP，**用 DevEco Studio 自动签名后安装**）

> App 必须签名才能装（华为要求）。仓库提供的是**未签名 HAP**，请用 DevEco 打开 `app/` 开启自动签名，或用自家签名工具处理。

---

## 配置（写在 profile 的插件配置里）

优先级：**插件配置 > 环境变量 > 历史路径（存在时） > 可移植默认值**

```yaml
plugins:
  garmin-dash:
    dataRoot: 'D:\GarminData'            # 快照落盘 + 聊天工作区
    publicBase: 'https://xxxx.dsh-market.com'   # 可选：手机端使用的公网地址
    chat:
      enabled: true
      profile: headless
```

完整配置项（含环境变量对照）见 [PUBLISH.md](./PUBLISH.md)。

---

## 目录结构

```
lib/        插件实现（ESM）：路由、配置解析、数据层、配对库、快照、趋势、引导页、二维码
bin/        命令行工具（生成配对码）
assets/     App 产物（未签名 HAP）
app/        鸿蒙工程源码（ArkTS / DevEco Studio）
test/       测试套件（夹具为脱敏样本：已移除活动 ID、精确时间戳与地点名）
cordis.patch.yml   bundle 补丁（挂载路由）
PUBLISH.md   发布与部署说明（npm 发布、市场收录、配置表、已知限制）
```

---

## 测试

```bash
node test/run-all.mjs            # 4 个套件
```

- `config-resolution` / `data-layer` / `trend-unit`：纯离线，任何机器可跑
- `plugin-entry` / `integration`：用**真实的** `@deepseek-ai/cordis` 等宿主模块装载插件并打 HTTP，因此需要一个 DSH 安装：

```bash
# 指向 DSH 应用内的 @deepseek-ai 目录；未设置且自动探测失败时，该套件会 SKIP（不影响整体绿灯）
export DSH_APP_DIR=/path/to/DSH/resources/app/node_modules/@deepseek-ai
```

自动探测顺序：`DSH_APP_DIR` → `$DSH_HOME/profiles/*/node_modules/@deepseek-ai` → 常见安装位置。

---

## 安全设计

- 配对码一次性、10 分钟有效；设备库只存密钥哈希
- 除 `health` / `pair` 外所有数据端点要求 `X-Device-Key`
- 引导页 / 自检 / 二维码 / App 下载**仅限本机回环**（非回环 403）
- 内建对话的工作区即会话 cwd（创建后不可变），权限档由 profile + 环境变量双重限定
- 默认不暴露公网；外网访问需显式启用中继插件

---

## 已知限制

- App 必须自行签名（华为要求，无法绕过）
- 依赖 `dsh-plugin-garmin-connect` 的佳明登录态；本插件不接触账号密码
- App 内建对话依赖**本机** DSH 子进程（跨机器不可用，设计如此）
- 佳明未提供的指标（如部分账号的体重 / Body Battery）显示 `--`，不做估算

---

## License

[MIT](./LICENSE) © BrokenHalberd


