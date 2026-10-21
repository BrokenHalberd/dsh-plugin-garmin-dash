# 小艺（Celia）接入调研：用意图框架把「佳明本地版」接进系统助手

> 调研日期：2026-10-21 · 依据：本机 SDK 实测 + 华为官方 Intents Kit 文档
> SDK：`E:\DevEcoStudio\sdk\default`（openharmony + hms）

## 一、结论

**可行 ✓**，而且比预想的近：本机 SDK **已经带完整的意图框架（Intents Kit）**，
不需要额外 SDK 包 ✓。可以做三件事：

| 能力 | 效果 | 难度 |
|---|---|---|
| **功能意图（Function Intent）** | 对小艺说「问问佳明我最近骑了几次」，**小艺直接播报我们的结果** | ★★ |
| **UI 意图（UI Extension）** | 小艺里弹出**我们 App 的卡片/页面**（趋势图、骑行列表） | ★★★ |
| **入口/页面意图** | 语音「打开佳明本地版的训练趋势」→ 直接跳到对应页面 | ★★ |

## 二、本机 SDK 证据（实测，非推测）

| 模块 | 路径 | 说明 |
|---|---|---|
| `@kit.IntentsKit` | `hms/ets/kits/@kit.IntentsKit.d.ts` | 导出 `insightIntent`、`InsightIntentUIExtensionAbility` |
| `@hms.ai.insightIntent` | `hms/ets/api/` | HM 侧意图 API |
| `InsightIntentUIExtensionAbility` | `hms/ets/api/@hms.ai.insightIntent.InsightIntentUIExtensionAbility.d.ts` | **继承 `UIExtensionAbility`** → 小艺可渲染我们的 UI ✓ |
| `@ohos.app.ability.insightIntent` | `openharmony/ets/api/` | 核心类型：`IntentEntity`、`IntentResult<T>`、`ExecuteMode`、`ReturnMode`、`ExecuteResult` |
| `InsightIntentDecorator` | `openharmony/ets/api/@ohos.app.ability.InsightIntentDecorator.d.ts` | **声明式装饰器**（见下） |
| `InsightIntentContext` / `Provider` / `EntryExecutor` | 同目录 | 执行上下文、意图提供、入口执行器 |

**可用的装饰器（声明式意图）**：

```typescript
@InsightIntentLink(intentInfo)          // 链接类意图
@InsightIntentPage(intentInfo)          // 页面类意图（跳转到某页）
@InsightIntentFunction(intentInfo)      // 函数类意图（无 UI，直接返回结果）
@InsightIntentFunctionMethod(intentInfo)// 标在方法上，指定意图执行方法
@InsightIntentEntry(intentInfo)         // 入口类意图
@InsightIntentForm(intentInfo)          // 卡片类意图
@InsightIntentEntity(intentEntityInfo)  // 参数/结果实体（结构化 schema）
```

执行模式与返回：
- `enum ExecuteMode`（前台/后台执行）
- `enum ReturnMode`（返回方式）
- `interface ExecuteResult` / `interface IntentResult<T>`（结果封装）

## 三、建议暴露的 4 个意图（结合我们的数据能力）

| 意图名（建议） | 用户怎么说 | 实现 |
|---|---|---|
| `getRecentRides` | 「我最近骑了几次车？」 | 调 `ApiClient.getActivitiesDays(30)` → 返回 {次数, 最近3次: 日期/距离/TSS} |
| `getTrainingStatus` | 「我现在的训练负荷/状态怎么样？」 | 调 `ApiClient.getTrend(90)` → 返回 {CTL, ATL, TSB, 一句判读} |
| `getRecovery` | 「我恢复得怎么样？」 | `getHrvRange(14)` + `getBodyBattery(今天)` → {HRV状态, 电量高/低} |
| `openTrendPage` | 「打开佳明本地版的训练趋势」 | 跳转 App 内「趋势/数据中心」页 |

> 进阶：意图处理器内部**直接调用我们的 `LocalAgent`** ✓ → 小艺一句话 → 本地大模型 → 组织人话回答 ✓✓（这是我们独有的优势：数据 + 解释都在本机 ✓）

## 四、接入步骤（建议）

1. **声明意图**：按 SDK 的装饰器写法，在入口 Ability 上加 `@InsightIntentFunction` / `@InsightIntentPage`，参数用 `@InsightIntentEntity` 描述 schema
2. **实现处理器**：函数体内调数据层（`ApiClient` 或未来的设备直连）→ 组装 `IntentResult<T>`
3. **模块配置**：`module.json5` 里按官方要求声明意图（**具体字段需以官方文档为准** ⚠️ 我尚未在 SDK 中找到 `insight_intent` 配置项的确切 schema，需查官方文档确认）
4. **AGC 侧开通**：意图框架/技能调用能力通常需要在 **AGC 开通并配置**（且可能要求应用已上架）⚠️ **需确认**
5. **真机验证**：小艺版本需支持；用语音真的说一遍才算通过

## 五、风险与前置条件（必须先确认 ✗）

| # | 风险 | 说明 | 对策 |
|---|---|---|---|
| **1** | **可能需要上架 + AGC 开通** | 意图框架属"AI 能力"，一般有资质/白名单要求 ⚠️ | 先查官方「申请开通」流程；若要求上架，则**先解决发布证书 + 上架** |
| **2** | **意图 schema 配置位置未确认** | 我在 SDK 里只看到装饰器 ✓，**没找到** module.json5 的 `insight_intent` 字段定义 ✗ | 查官方"功能搜索方案/技能调用方案"文档确认 |
| **3** | **小艺侧识别率** | 语音说法多样，意图匹配由系统做 | 多写几个说法示例（utterances）；提供兜底回答 |
| **4** | **调试困难** | 语音链路没法在模拟器里完整复现 | 需要真机 + 小艺；先做函数意图（无 UI）最容易验证 |
| **5** | **隐私** | 小艺是系统级入口，会把用户话语交给系统处理 | 我们只接收**结构化参数**（不接收原始语音）✓；敏感数据不返回 |

## 六、与现有路线的关系

| 路线 | 关系 |
|---|---|
| **本地版 App（已可用）** ✓ | 意图处理器 = 复用它的数据层与 Agent ✓ |
| **远程后端（正式版）** ✓ | 若上架要求登录/风控，可继续用后端 ✓ |
| **小艺** ✓ | **是"入口"**，不是替代 ✓ —— 用户从系统助手直接唤起我们的能力 ✓ |

## 七、建议的推进顺序（低风险 → 高价值）

1. **先做 1 个函数意图**（`getTrainingStatus`）✓ —— 无 UI ✓ 最容易验证 ✓ 收益明确 ✓
2. 验证通过后再加 `getRecentRides` / `getRecovery` ✓
3. 最后做 **UI 意图**（小艺里显示趋势卡 ✓ 工作量大 ⚠️）
4. 若上架是前置条件 → **优先解决发布证书 + 上架** ✓

## 八、待你决定

1. 是否推进小艺接入（我建议 **先做 1 个函数意图试水** ✓）
2. 是否愿意为此走上架流程（可能为前置条件 ⚠️）
3. 你先在 AGC 看一眼「意图框架 / Intents Kit」是否有开通入口（截个图我就能判断可行性）

---

## 九、实测结论（2026-10-21 更新）

**AGC「开放能力管理」实测：只有「AI 问答联网增强服务」，没有「意图框架 / Intents Kit / AI 技能」入口。**

→ 结论：**小艺（意图框架）接入目前对该账号/该应用不开放** ❌
（推测原因：需上架后开放 / 白名单 / 特定资质；SDK 里的 API 存在 ≠ 线上可开通）

### 因此的现实选择

| 方案 | 是否可行 | 说明 |
|---|---|---|
| 小艺意图框架 | ❌ 暂不可用 | 等上架或 AGC 开放后再试 |
| **服务卡片（Service Widget）** | ✅ **可行，零资质** | 桌面小卡片显示"今日表单 / CTL·ATL·TSB / HRV / 最近骑行"，点击进入 App；SDK 标准能力（`@ohos.app.form.*`） |
| 应用内快捷指令（App 内语音/文字快捷） | ✅ 可行 | 已在本地版 Agent 里具备（自然语言即可） |
| 桌面图标长按快捷方式（shortcuts） | ⚠️ 需确认 | `module.json5` 的 shortcuts 配置，标准能力，但入口深度不同 |

**建议**：改为做**服务卡片**（一眼看到今日状态 ✓ 点击进 App ✓ 无需任何资质 ✓）。