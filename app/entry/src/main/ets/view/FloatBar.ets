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
        // ── 沉浸光感 · 真实毛玻璃材质 ──────────────────────────────────────────
        // 依据华为官方「沉浸光感」指南（developer.huawei.com → arkts-immersive-light-sense）
        // 的材质接口 backgroundBlurStyle（@since 11，本 SDK 已带，编译期可用）。
        // 作用：对胶囊下方透出的页面内容做真实高斯模糊，叠加 glass_fill_strong 半透明色后
        // 呈现真玻璃质感；此前仅靠半透明色模拟（无模糊）。
        // 影响面：纯视觉属性——不改布局尺寸、不改点击/切换/高亮逻辑，不消费任何事件。
        // 兼容性：不支持的机型由系统自动降级（表现为无模糊的普通半透明背景，即旧观感）。
        // 顺序要求：backgroundBlurStyle 必须在 backgroundColor 之前，玻璃色才叠在模糊层之上。
        .backgroundBlurStyle(BlurStyle.Thin)
        // 注意：不要把 lightUpEffect 叠加在这里。它按「照亮程度」整体渲染组件，
        // 0<value<1 会把胶囊连同图标文字一起压暗（实测 0.25/0.6 整条变黑），
        // 与玻璃观感相反。官方 6.x 的 lightUpEffect 适合图片/媒体内容；
        // 浮层玻璃的光感留给 7.x 的 effectStrategy(LIGHT_SENSING)（见 Index.ets 注释）。
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
