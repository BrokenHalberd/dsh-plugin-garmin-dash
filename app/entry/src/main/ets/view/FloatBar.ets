/**
 * 悬浮玻璃底部栏（独立组件，对齐 ClashBox FloatBar）
 *
 * 为什么必须独立成组件：把栏放在 Index 的 @Builder 里、靠参数/父级 @State 刷新时，
 * ArkUI 对 @Builder 的渲染缓存会导致「点击能切页、高亮却不跟随」。
 * ClashBox 的做法是：Swiper 叠一个独立 FloatBar 组件，
 * 高亮状态用 @Provide/@Consume 跨组件传递——子组件在 @Consume 变化时可靠重渲染。
 */
import { LengthMetrics } from '@kit.ArkUI';

export interface TabDef {
  title: string;
  icon: Resource;
  idx: number;
}

@Component
export struct FloatBar {
  @Require tabList: TabDef[] = [];
  @Require swiperController: SwiperController;
  @Consume('currentTab') currentTab: number;

  build() {
    Row() {
      ForEach(this.tabList, (t: TabDef, i: number) => {
        Flex({
          direction: FlexDirection.Column,
          justifyContent: FlexAlign.Center,
          alignItems: ItemAlign.Center,
          space: { main: LengthMetrics.vp(3) }
        }) {
          SymbolGlyph(t.icon)
            .fontSize(21)
            .fontColor([this.currentTab === t.idx ? $r('app.color.accent') : $r('app.color.text_tertiary')])
            .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_OPACITY)
            .scale({ x: this.currentTab === t.idx ? 1.12 : 1, y: this.currentTab === t.idx ? 1.12 : 1 })
            .translate({ y: this.currentTab === t.idx ? -1 : 0 })
            .animation({ duration: 320, curve: Curve.Friction })

          Text(t.title)
            .fontSize(10)
            .fontColor(this.currentTab === t.idx ? $r('app.color.accent') : $r('app.color.text_tertiary'))
            .fontWeight(this.currentTab === t.idx ? FontWeight.Medium : FontWeight.Normal)
        }
        .layoutWeight(1)
        .height(52)
        .margin({ left: 4, right: 4, top: 6, bottom: 6 })
        .borderRadius(100)
        .backgroundColor(this.currentTab === t.idx ? $r('app.color.glass_fill_strong') : Color.Transparent)
        .animation({ duration: 320, curve: Curve.Friction })
        .onClick(() => {
          // 关键顺序：先改状态（高亮立即生效，并解除 disableSwipe 约束），再驱动 Swiper
          this.currentTab = t.idx;
          try {
            this.swiperController.changeIndex(t.idx, true);
          } catch (e) {
          }
        })
      }, (t: TabDef) => String(t.idx))
    }
    .width('100%')
  }
}
