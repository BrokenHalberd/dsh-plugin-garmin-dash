/**
 * 悬浮玻璃底部栏（独立组件，对齐 ClashBox FloatBar）
 *
 * 为什么必须独立成组件：把栏放在 Index 的 @Builder 里、靠参数/父级 @State 刷新时，
 * ArkUI 对 @Builder 的渲染缓存会导致「点击能切页、高亮却不跟随」。
 * ClashBox 的做法是：Swiper 叠一个独立 FloatBar 组件，
 * 高亮状态用 @Provide/@Consume 跨组件传递——子组件在 @Consume 变化时可靠重渲染。
 */
import { LengthMetrics } from '@kit.ArkUI';
// HarmonyOS 7（API 26）官方「沉浸光感/沉浸材质」模块：@ohos.arkui.uiMaterial
// 官方文档：developer.huawei.com → arkts-immersive-light-sense（enable / constraints）
// 能力：ImmersiveMaterial（玻璃厚度/材质色/倒色/阴影/交互态/光感颜色）+ 组件级 systemMaterial
import uiMaterial from '@ohos.arkui.uiMaterial';

/** 设备是否支持沉浸系统材质（官方运行时判断，等价于指南里的能力判断；不支持则走旧样式降级） */
const IMMERSIVE_SUPPORTED: boolean = uiMaterial.isImmersiveMaterialSupported();

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

  /**
   * 选中态胶囊的沉浸材质（只在支持设备上创建；null = 不支持，走旧样式降级）。
   * · style: THIN —— 玻璃厚度档（ULTRA_THIN/THIN/REGULAR/THICK/ULTRA_THICK）
   * · materialColor: 复用现有玻璃色，保证与旧观感銜接
   * · lightEffect.color: 光感颜色（官方「沉浸光感」的着色光）
   * · interactive: 按下时的交互态反馈
   * · applyShadow: 材质自带阴影（系统材质会接管背景/模糊/阴影/Border）
   */
  private activeMaterial: uiMaterial.ImmersiveMaterial | null = IMMERSIVE_SUPPORTED
    ? new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN,
        materialColor: $r('app.color.glass_fill_strong'),
        colorInvert: false,
        applyShadow: true,
        interactive: true,
        lightEffect: { color: $r('app.color.accent') }
      })
    : null;

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
        // ── 沉浸光感 · HarmonyOS 7 官方沉浸材质（首选）────────────────────────
        // 官方模块 @ohos.arkui.uiMaterial（API 26）：组件级 systemMaterial 应用系统材质。
        // 仅在「选中态且设备支持」时生效（activeMaterial 为 null 时传 undefined = 不启用）；
        // 官方说明：材质启用后其观感优先于背景色/blur/阴影/Border，因此下一行的
        // backgroundBlurStyle 与 backgroundColor 在支持的设备上作为被接管的底色，
        // 在不支持的设备上则充当降级样式（旧观感），两条路都不改布局与交互逻辑。
        .systemMaterial(this.currentTab === t.idx && this.activeMaterial !== null ? this.activeMaterial : undefined)
        // ── 降级 / 兜底：真实毛玻璃材质 ──────────────────────────────────────
        // 依据官方「沉浸光感」指南中的材质接口 backgroundBlurStyle（@since 11）：
        // 对胶囊下方透出的页面内容做真实高斯模糊，叠加玻璃色呈现玻璃质感。
        // 影响面：纯视觉——不改布局尺寸、不改点击/切换/高亮逻辑，不消费任何事件。
        // 顺序要求：backgroundBlurStyle 必须在 backgroundColor 之前，玻璃色才叠在模糊层之上。
        .backgroundBlurStyle(BlurStyle.Thin)
        // 注意：不要把 lightUpEffect 叠加在这里。它按「照亮程度」整体渲染组件，
        // 0<value<1 会把胶囊连同图标文字一起压暗（实测 0.25/0.6 整条变黑），
        // 与玻璃观感相反；光感请用上面的 uiMaterial lightEffect。
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
