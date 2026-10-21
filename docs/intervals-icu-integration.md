# Intervals.icu 数据接入调研

> 调研日期：2026-10-21 · 目标：为「佳明仪表盘」增加 Intervals.icu（下称 ICU）数据接入
> 事实来源：ICU 官方 API 文档页 + 官方论坛 API 指南（david，平台作者）+ 社区 MCP 实现

## 一、结论先说（三条最重要的）

| # | 结论 | 影响 |
|---|---|---|
| 1 | **个人使用只需 API Key + Basic Auth**，无需 OAuth | ✅ 接入成本很低，一个设置项就够 |
| 2 | **athlete id 可以写 `0`**，表示"这个 key 所属的运动员" | ✅ 用户**不用去查自己的数字 id**，少一个配置项 |
| 3 | ⚠️ **ICU 明确说明：Strava 数据不通过 API 提供；且 2026-10-09 起 Garmin 条款变更，"很可能即将屏蔽 API 访问 Garmin 数据"** | ❌ 我们用户的 ICU 数据基本都来自 Garmin → **通过 ICU 拉训练数据可能随时失效** |

**因此建议定位**：ICU 作为**可选增强源**（wellness / 区间检测 / 计划课表），
**不作为**主数据源；主数据仍走我们已有的 Garmin Connect 直连。

---

## 二、认证

| 项 | 值 |
|---|---|
| 方式 | HTTP **Basic Auth** |
| 用户名 | 固定字符串 **`API_KEY`** |
| 密码 | 用户的 API Key（形如 `1l0nlqjq3j1obdhg08rz5rfhx`） |
| Key 获取 | ICU 网页 → `/settings` → 底部 **Developer Settings** → 生成 |
| 多用户应用 | 需改用 **OAuth + Bearer**（我们是单用户本地后端，**不需要**） |
| 示例 | `curl -u API_KEY:<key> https://intervals.icu/api/v1/athlete/0/activities.csv` |

## 三、限流（必须遵守，否则 429）

| 维度 | API Key 调用者 |
|---|---|
| 每日 | **5000 次**（UTC 零点重置） |
| 15 分钟滚动窗 | **2500 次** |
| 每秒（按 IP） | **10 次**（此项**不返回**限流头） |
| 响应头 | `X-RateLimit-Limit: <15m>,<daily>` · `X-RateLimit-Remaining: <15m>,<daily>` |
| 超限 | **429** + `Retry-After: <秒>` |

**实现要求**：
- 后端加一个**统一节流器**（令牌桶：≤10/s，≤2500/15min）
- 解析 `X-RateLimit-Remaining`，剩余低于阈值时降频
- 遇 429 → 按 `Retry-After` 退避重试（不要把用户的界面卡死）

## 四、Cloudflare 注意（容易踩的坑）

ICU 在 Cloudflare 后面，**部分客户端库的 User-Agent 会被判定可疑并被 challenge/拦截**。
→ 我们的后端必须设置**浏览器风格的 User-Agent**，例如：
`Mozilla/5.0 (Windows NT 10.0; Win64; x64) GarminDash/1.0`

## 五、可用端点（与我们 App 的映射）

| 端点 | 内容 | 能否替代/增强我们现有数据 |
|---|---|---|
| `GET /api/v1/athlete/{id}` | 运动员档案（体重、FTP、FTHR 等） | ✅ 交叉校验 FTP/体重（我们现在手填） |
| `GET /api/v1/athlete/{id}/activities` | 活动列表（`oldest`/`newest` 过滤） | ⚠️ 与 Garmin 直连重复，且**可能被屏蔽** ✗ |
| `GET /api/v1/activity/{id}?intervals=true` | 活动详情 + **自动检测的区间（intervals）** | ✅✅ **最有价值**：ICU 的区间检测比我们自己切更成熟 |
| `GET /api/v1/athlete/{id}/wellness` | 每日 wellness（HRV、静息心率、睡眠、主观感受等） | ✅ 补充我们缺的主观/睡眠维度 |
| `GET /api/v1/athlete/{id}/events`（需 `oldest`+`newest`） | 日历/计划课表 | ✅ 可做"今日课表" |
| `GET /api/v1/athlete/{id}/power-curves` | 功率曲线 | ⚠️ 我们已自算 15 档曲线，重复 |
| `POST /api/v1/athlete/{id}/events` | 创建计划课表 | ✅ 未来可双向写入（把我们的建议课表推到 ICU） |

## 六、建议的接入方案（三阶段）

### 阶段 1：最小可用（1 轮）
1. 「我的」页新增「Intervals.icu」设置项：**API Key** 输入框 + 「测试连接」按钮
2. 后端新增 `/api/icu/test`（用 `athlete/0` 拉档案验证 key 是否有效）
3. 成功后把 key 存到设备侧（**不落明文日志**），后端只透传

### 阶段 2：数据增强（2~3 轮）
1. `/api/icu/wellness?days=90` → **状态页**增加「睡眠 / 主观疲劳」卡片
2. `/api/icu/activity-intervals?id=xxx` → **详情页**增加「ICU 自动区间」卡（与我们的爬坡段并列）
3. 缓存：wellness 1 小时、interval 6 小时（ICU 数据变化不快）

### 阶段 3：双向（可选）
1. 把「训练建议」生成的结构化课表 `POST` 到 ICU 日历（用户可选择是否同步）
2. 从 ICU 拉计划课表 → 首页「今日课表」

## 七、风险与对策

| 风险 | 说明 | 对策 |
|---|---|---|
| **Garmin 数据屏蔽** ✗✗ | ICU 官方 2026-10-09 公告：很可能即将屏蔽 API 访问 Garmin 数据 | ① 一切 ICU 功能**必须失败可降级**（不阻塞主体功能）② 主数据永远走 Garmin 直连 ✓ ③ 在设置项里**明确写清**"ICU 数据可能因平台策略失效" |
| **Strava 数据不可用** | 官方明确 | 无需处理（我们不依赖 Strava） |
| **429 限流** | 见上表 | 节流 + 退避 + 缓存 |
| **Cloudflare 拦截** | 见上 | 浏览器 UA |
| **API Key 泄露** | key 等于账户数据访问权 | 设备侧加密存储（HarmonyOS `preferences` 非明文 ✓）；不上传日志；不写入仓库存档 |
| **体量** | 我们的 App 是本地优先 | ICU 数据**只读展示**，不并入库表，避免口径冲突 |

## 八、与现有架构的契合度

| 我们的机制 | ICU 接入如何复用 |
|---|---|
| 后端插件路由（`/garmin-dash/api/*` + 设备密钥鉴权） | 直接加 `/api/icu/*` 分支 ✓ |
| `TtlCache` 缓存 | wellness/interval 缓存直接复用 ✓ |
| 错误分类（`classifyError` → 503/404） | 429 单独映射为"ICU 限流，请稍后" ✓ |
| App `ApiClient` 统一封装 | 加 3 个方法（`icuTest/icuWellness/icuIntervals`）✓ |
| 我的页设置项（体重/等级表已在此） | API Key 输入放同一处 ✓ |

## 九、下一步

需要你决定：
1. **是否接入**（考虑到 Garmin 数据可能被屏蔽 ✗ 的价值判断）
2. 若接：**先做阶段 1（连通性 + 设置项）** 还是 **直接做阶段 2 的区间检测**（价值最大 ✓）
3. API Key 请你自己在 ICU 生成后填在 App 里（**不要贴到对话里** ✗）