# 首页统计卡片布局规范（LAW）

> 本文件是**约束性规范**，不是说明。改动 `view/StatusView.ets` 的卡片区之前**必须**读完，
> 改完必须运行 `node scripts/check-layout.mjs` 且 PASS。
>
> 背景：这套布局被反复改坏过 6 次（写死高度、Grid 撑爆、漏改 bbCard、百分比不生效…）。
> 下面的每条规则都对应一次真实事故，**不是理论**。

---

## 1. 容器：必须是 Flex(wrap + SpaceBetween)（3.87.0 起验证过的写法）

首页 6 张统计卡片的容器**只有一个正确写法**：

```ts
Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
  // 6 张卡片，顺序 = 显示顺序（左、右、左、右…）
}
.width('100%')
```

**这条规则解决什么**：`ItemAlign.Stretch` 让**同一行**的两张卡片取**较高者**的高度，
较矮那张自动拉伸对齐 —— 这就是产品要求的"根据相邻高度取更高者对齐"。

### 禁止（都试过，都错）

| 写法 | 后果 |
| --- | --- |
| `Flex` + `ItemAlign.Stretch` | **换行场景下不生效**，矮卡不会被拉伸（实测：睡眠高、BB 矮） |
| 卡片里写 `height('100%')` | 参照 Grid 剩余空间 → **卡片超长** |
| `Column` + 多个 `Row` | `Row` 高度由子项决定，`height('100%')` 无参照 → **不生效** |
| `Flex` + `.rowGap(10)` | **Flex 没有 rowGap**，编译报错 |
| 卡片上写 `height(104)` | 内容多一行就撑破；数据/字号一变就错位 |

---

## 2. 卡片规则：只有两种尺寸（大卡 / 小卡）

**这是唯一的尺寸规则，新增卡片只需选一种，不要引入第三种宽度。**

| 类型 | 宽度 | 效果 | 写法 |
| --- | --- | --- | --- |
| **大卡片** | `100%` | 独占一整行 | `this.card({ title:'…', value:…, unit:'…', sub:'…', big: true })` |
| **小卡片** | `48%` | 两两成行，Flex 自动配对 | `this.card({ … })`（省略 big 或 big:false）|

卡片根容器的**固定属性链**（不要增删）：

```ts
.alignItems(HorizontalAlign.Start)
.justifyContent(FlexAlign.Start)
.padding(14)
.width(cfg.big === true ? '100%' : '48%')   // ← 尺寸只由 big 决定
.margin({ bottom: CARD_GAP })               // ← 间距只由常量决定
.backgroundColor($r('app.color.card_background_blur'))
.border({ width: 1, color: $r('app.color.card_border_highlight') })
.borderRadius(14)
```

`bbCard()`（Body Battery 专用）固定为**小卡片**：`.width('48%')` + `.margin({ bottom: CARD_GAP })`。

### 为什么 `margin(bottom)` 绝对不能删

它**同时承担三件事**：
1. 小卡片两行之间、大卡与小卡之间的**行距**
2. 卡片区与**上一段（HRV）** 的段距
3. 卡片区与**下一段（睡眠阶段条）** 的段距

删掉 → 整页所有间隙消失（真实事故：3.98.0 / 3.98.1 连续两版）。

### 禁止

- ❌ 任何 `height(...)` / `constraintSize({minHeight})`（写死必错）
- ❌ 第三种宽度（如 60%、'auto'）
- ❌ 用 `Grid` 做卡片网格（会吞掉段落间距）
- ❌ 把间距写成数字字面量（必须用 `CARD_GAP`）
- ❌ 给内容 Column 加 `space`（曾误加到错误重试框，造成"改了没效果"）

### 已知限制（诚实记录）

`Flex` 换行 + `ItemAlign.Stretch` **不能让矮卡拉伸到行高**（API 24 实测 2 次）。
`Grid` + `GridItemAlignment.STRETCH` 能等高，但会吞掉段落间距。
**所以当前"同一行两小卡等高"尚未实现**，需要运行时测量（`onAreaChange` 记录高度 → 每行取 max → 回写 height）。
在实现之前：同一行两卡内容行数不同时，底边**不会**齐平。

## 3. 两套 Builder 必须同步：`card()` 与 `bbCard()`

首页有两种卡片构建器：

| Builder | 用途 | 参数 |
| --- | --- | --- |
| `card(cfg: StatCardCfg)` | 5 张普通卡（步数/心率/睡眠/热量/压力） | **按值传参** |
| `bbCard()` | Body Battery 专用卡 | 无参 |

**它们都必须满足第 2 节的全部属性**，而且**属性链顺序可能不同**（这点坑过一次）：

```
card():   .padding(14) → .width('48%') → .margin({bottom:10}) → .backgroundColor
bbCard(): .width('48%') → .margin({bottom:10}) → .padding(14) → .backgroundColor
```

> **批量替换脚本必须逐个核对两处，不能只按相邻字符串匹配。**
> 事故：给 `card()` 加 `48%` 时 `bbCard()` 因顺序不同被漏掉 → BB 卡 100% 宽独占一行。

---

## 4. `@Builder` 严禁按值传"要显示的数据"

`@Builder` 的**参数在首次构建时被捕获**，之后状态更新**不会**刷新它。

```ts
// ❌ 错：数值永远不会更新
@Builder card(cfg: StatCardCfg) {
  Text(cfg.value)          // cfg.value 被冻结在第一次的值
}

// ✅ 对：Builder 内部直接读 this
@Builder metricSteps() {
  Text(this.st(this.steps))   // this.steps 变就跟着变
}
```

`card(cfg)` 目前只传**标题/单位/副标题**这类**稳定文案**是正确的；
但**凡是会变的数值，必须由 Builder 内部读 `this.xxx`**。

事故：大卡 `rightItem('步数', this.steps)` 按值传参 → 数字永远空 → 排查了 5 个版本。

---

## 5. 插入卡片的最短路径（中间插、后面加都一样）

```ts
// 在 Flex 里任意位置加一行即可，布局自动重排：
this.card({ title: '新指标', value: '--', unit: '', sub: '', big: true })  // 大卡（整行）
this.card({ title: '新指标', value: '--', unit: '', sub: '' })              // 小卡（自动两两成行）
```

不需要关心顺序、不需要手动配对、不需要改任何间距 —— `Flex` 的 `wrap` + `SpaceBetween` 会处理。

## 6. 新增 / 删除一张卡片的检查清单

1. 卡片数量保持**偶数**（两列）；若必须奇数，最后一张需单独占位设计，不能留半格空洞。
2. 新卡片必须写到 `Flex` 内、**按显示顺序**插入（左、右、左、右…）。
3. 新卡片的宽度/margin/无 height 三点必须符合第 2 节。
4. 若新卡片需要**独立 Builder**（像 `bbCard()`），必须同样满足第 2 节，且**不接收可变数值参数**。
5. 运行 `node scripts/check-layout.mjs`，必须 PASS。
6. 装到设备上看三种数据状态：① 全有数据 ② 某项缺失（显示 `--`） ③ 副标题为空 —— 三种都要**左右底边齐平**。

---

## 6. 当前卡片顺序（2026-10-23）

| 行 | 左 | 右 |
| --- | --- | --- |
| 1 | 步数 | 静息心率 |
| 2 | 睡眠（含评分副标题） | Body Battery |
| 3 | 热量 | 压力（含档位副标题） |

改顺序时同步改本表，并重跑检查脚本。
