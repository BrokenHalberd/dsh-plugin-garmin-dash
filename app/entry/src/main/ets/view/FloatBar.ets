/**
 * 底部页签项（Tabs 自定义 TabBar 的单个页签，对齐 AppGallery 系统 Dock 观感）。
 *
 * ── 架构变迁：Swiper+FloatBar 整条 Dock → Tabs+barFloatingStyle ─────────────
 * 旧方案把 Dock 做成 Stack 里悬浮的普通 Row 并直接挂 systemMaterial，
 * 代码完全符合官方指南，但真机 hilog 证实被框架拒绝激活：
 *   `W C03900/.../Ace: Material inactive: out of scope.
 *    Use component in navigation title bar or Tabbar.`
 * 即 ArkUI（HarmonyOS 7.0）把沉浸式系统材质限定在 Navigation 标题栏 /
 * TabBar 作用域内，普通容器（Stack/Row/Column…）一律不激活——这是
 * 「代码全对但真机无光感」的根因。
 * 新方案由 pages/Index.ets 的 Tabs + barFloatingStyle（API 26）承载悬浮
 * 胶囊形态与背板沉浸材质（TabBar 作用域 ✓），本组件退化为「单个页签项」：
 *   · 选中态：accent 图标/文字 + 浅色内嵌胶囊（#2EFFFFFF ≈ 18% 白）；
 *   · 点击切页由 Tabs 原生处理（tabBar 位置点击即切对应 TabContent），
 *     不再自写 onClick / changeIndex；
 *   · 高亮刷新沿用 @Consume('currentTab') 跨组件传递——@Builder 渲染缓存
 *     会导致「点击能切页、高亮不跟随」（旧方案踩坑），独立组件 + @Consume 可靠。
 */
import { LengthMetrics } from '@kit.ArkUI';

export interface TabDef {
  title: string;
  icon: Resource;
  idx: number;
}

@Component
export struct TabItem {
  /** 页签静态定义（标题/图标/索引），由 Index 的 tabs() 传入，构造后不变 */
  itemDef: TabDef = { title: '', icon: $r('sys.symbol.bolt_filled_on_circle'), idx: 0 };
  /** 当前选中页签（Index @Provide），变化时本组件可靠重渲染 */
  @Consume('currentTab') currentTab: number;

  build() {
    Flex({
      direction: FlexDirection.Column,
      justifyContent: FlexAlign.Center,
      alignItems: ItemAlign.Center,
      space: { main: LengthMetrics.vp(3) }
    }) {
      SymbolGlyph(this.itemDef.icon)
        .fontSize(21)
        .fontColor([this.currentTab === this.itemDef.idx ? $r('app.color.accent') : $r('app.color.text_tertiary')])
        .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_OPACITY)
        .scale({ x: this.currentTab === this.itemDef.idx ? 1.12 : 1, y: this.currentTab === this.itemDef.idx ? 1.12 : 1 })
        .translate({ y: this.currentTab === this.itemDef.idx ? -1 : 0 })
        .animation({ duration: 320, curve: Curve.Friction })

      Text(this.itemDef.title)
        .fontSize(10)
        .fontColor(this.currentTab === this.itemDef.idx ? $r('app.color.accent') : $r('app.color.text_tertiary'))
        .fontWeight(this.currentTab === this.itemDef.idx ? FontWeight.Medium : FontWeight.Normal)
    }
    .height(52)
    .margin({ left: 4, right: 4, top: 6, bottom: 6 })
    .borderRadius(100)
    // 选中高亮胶囊：半透明白叠在系统材质背板上形成内嵌胶囊；未选中透明。
    // 纯视觉属性，不影响点击/切换（切换由 Tabs 原生 tabBar 点击处理）。
    .backgroundColor(this.currentTab === this.itemDef.idx ? '#2EFFFFFF' : Color.Transparent)
    .animation({ duration: 320, curve: Curve.Friction })
  }
}
