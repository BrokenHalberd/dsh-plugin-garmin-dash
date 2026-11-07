import { common } from '@kit.AbilityKit';
import { router, LengthMetrics, curves, display } from '@kit.ArkUI';
import { motion } from '@kit.MultimodalAwarenessKit';
import { DeviceStore } from '../service/DeviceStore';
import { StatusView } from '../view/StatusView';
import { ActivitiesView } from '../view/ActivitiesView';
import { TrendView } from '../view/TrendView';
import { MeView } from '../view/MeView';
import { ApiClient } from '../service/ApiClient';
import { FloatBar, TabDef } from '../view/FloatBar';
// HarmonyOS 7 官方沉浸材质（API 26）：底部 Dock 用整条系统玻璃材质
// 官方示例的导入写法是 kit 聚合入口（@kit.ArkUI 再导出 uiMaterial）
import { uiMaterial } from '@kit.ArkUI';

/**
 * 主界面：液态玻璃选项栏 + 圆形 DSH 对话键。
 *
 * ── 沉浸光感（Light Sense）接入状态 ──────────────────────────────
 * 官方指南：developer.huawei.com → arkts-immersive-light-sense（含 enable / constraints 两篇）。
 * 已启用（DevEco 26.0.0 + SDK HarmonyOS 26.0.0 / API 26，工程 compileSdk 26.0.0(26)）：
 *   ① view/FloatBar.ets：@ohos.arkui.uiMaterial 的 ImmersiveMaterial + 组件级 systemMaterial
 *      （选中胶囊：ImmersiveStyle.THIN + materialColor + lightEffect 光感着色 + interactive），
 *      用 uiMaterial.isImmersiveMaterialSupported() 做运行时能力判断，不支持则降级。
 *   ② 降级样式：backgroundBlurStyle(BlurStyle.Thin) + glass_fill_strong 半透明玻璃色。
 * 已废弃路线（查证/实测后放弃）：
 *   · lightUpEffect（@since 12/18）：按「照亮程度」整体压暗组件，实测让整条胶囊变黑 ✗
 *   · effectStrategy(LIGHT_SENSING)：SDK 26 中仍只是 SymbolEffectStrategy（符号动效），
 *     真正的 7.x 沉浸材质入口是上面的 @ohos.arkui.uiMaterial ✗
 * 功耗注意：官方约束文档要求光感仅在常驻浮层/卡片开启，避免全页面常开。
 * ─────────────────────────────────────────────────────────────────────
 *
 * ── 适人握持：完全照 ClashBox 的 HoldingHandleUtil 逻辑 ──────────────
 * 1) **只订阅 `holdingHandChanged`（握持手）**，绝不同时轮询"操作手"——
 *    两个信号会互相打架，按钮会来回跳（之前"不稳定"的真正原因）。
 * 2) `canIUse` 先验系统能力，不支持就不订阅。
 * 3) 只认 LEFT/RIGHT；`NOT_HELD` / `BOTH_HANDS_HELD` 保持现状。
 * 4) **1.5s 防抖锁**：old/new 双状态 + 定时复检，期间新事件只记录不执行。
 * 5) 换边方式与 ClashBox 一致：**先隐藏按钮 → 500ms 后换边 → 再显示**，
 *    避免按钮横穿屏幕时被误触。
 * 6) 有开关（默认开），存本地；关闭即退订。
 */
const HAND_DEBOUNCE_MS: number = 1500;
const HAND_HIDE_MS: number = 500;

/**
 * 底部 Dock 的沉浸材质（HarmonyOS 7 官方 uiMaterial，API 26）。
 * 对齐官方示例 code/DocsSample/ArkUISample/ImmersiveLightSense：
 *   · pages/immersiveLightSense/LightEffect.ets：
 *       new uiMaterial.ImmersiveMaterial({ style: ULTRA_THIN, interactive: true,
 *                                        lightEffect: { color: undefined } })
 *     —— interactive=按压弹性形变；lightEffect.color=undefined 用【系统默认光感】，
 *        自定义颜色会让光感变弱/失效（我们之前传 accent 就是这个坑）。
 *   · pages/immersiveLightSense/GamePage.ets / ExploreHomePage.ets：
 *     材质元素的 backgroundColor 必须是 Transparent，且不要再叠自绘 blur/border/shadow，
 *     否则那些自绘层会盖住系统材质的折射/光感（看起来就只剩"纯透玻璃"）。
 * 生效前置（官方示例 pages/immersiveLightSense/MaterialInfo.ets）：
 *   只有 uiMaterial.getMaterialInfo().state === MaterialState.ENABLE 时材质才真正渲染；
 *   DEFAULT/DISABLE 时 systemMaterial 不生效——此时必须保留自绘的模糊+玻璃色兜底，
 *   否则界面就是“纯透明”（我们踩过这个坑）。
 * 不支持/未开启 = null → 不套材质，自动走 backgroundBlurStyle + 玻璃色的降级样式。
 */
const DOCK_MATERIAL_STATE: uiMaterial.MaterialState = uiMaterial.getMaterialInfo().state;
const DOCK_SUPPORTED: boolean = uiMaterial.isImmersiveMaterialSupported()
  && DOCK_MATERIAL_STATE === uiMaterial.MaterialState.ENABLE;
const DOCK_MATERIAL: uiMaterial.ImmersiveMaterial | null = DOCK_SUPPORTED
  ? new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
      interactive: true,
      lightEffect: { color: undefined }
    })
  : null;

/** 底部选项栏 + 安全区：滚到底时避开遮挡 */
const BOTTOM_BAR_PAD: number = 104;

@Entry
@Component
struct Index {
  private context = getContext(this) as common.UIAbilityContext;
  private controller: SwiperController = new SwiperController();
  /** 右手时圆键需要向右平移的距离（vp） */
  private shiftX: number = 0;
  /** 上一次已生效的握持手：0 未知 / 1 左手 / 2 右手 */
  private oldHand: number = 0;
  /** 最新一次收到的握持手（防抖比较用） */
  private newHand: number = 0;
  /** 防抖锁：true 可响应新事件，false 表示正在防抖中 */
  private handUnlocked: boolean = true;
  private watchingHand: boolean = false;

  @StorageProp('topRectHeight') topInset: number = 0;
  @StorageProp('bottomRectHeight') bottomInset: number = 0;
  @StorageLink('handFollow') @Watch('onHandFollowChanged') handFollow: boolean = true;
  @Provide('currentTab') currentTab: number = 0;
  @State tick: number = 0;
  @State handLeft: boolean = false;
  @State fabVisible: boolean = true;

  aboutToAppear(): void {
    ApiClient.setCacheDir(this.context.filesDir);
    DeviceStore.init(this.context);
    try {
      const screenW = px2vp(display.getDefaultDisplaySync().width);
      // 左右各 20 的边距 + 58 的按钮宽度
      this.shiftX = screenW - 98;
    } catch (e) {
      this.shiftX = 300;
    }
    // 开关初值来自本地设置
    this.handFollow = DeviceStore.getHandFollow();
    this.startHandWatch();
  }

  aboutToDisappear(): void {
    this.stopHandWatch();
  }

  onHandFollowChanged(): void {
    DeviceStore.setHandFollow(this.handFollow);
    if (this.handFollow) {
      this.startHandWatch();
    } else {
      this.stopHandWatch();
    }
  }

  private startHandWatch(): void {
    if (this.watchingHand || !this.handFollow) {
      return;
    }
    try {
      if (!canIUse('SystemCapability.MultimodalAwareness.Motion')) {
        return;
      }
    } catch (e) {
      return;
    }
    try {
      motion.on('holdingHandChanged', (status: motion.HoldingHandStatus) => {
        this.onHandStatus(status);
      });
      this.watchingHand = true;
      // 取一次当前状态作为基准，避免首次事件就误判为"变化"
      try {
        const now = motion.getRecentOperatingHandStatus();
        this.oldHand = now === motion.OperatingHandStatus.LEFT_HAND_OPERATED ? 1 : 0;
      } catch (e) {
      }
    } catch (e) {
      this.watchingHand = false;
    }
  }

  private stopHandWatch(): void {
    if (!this.watchingHand) {
      return;
    }
    try {
      motion.off('holdingHandChanged');
    } catch (e) {
    }
    this.watchingHand = false;
  }

  /** 只认左右手；未握持/双手保持现状（与 ClashBox 一致） */
  private onHandStatus(status: motion.HoldingHandStatus): void {
    if (status !== motion.HoldingHandStatus.LEFT_HAND_HELD &&
      status !== motion.HoldingHandStatus.RIGHT_HAND_HELD) {
      return;
    }
    const code = status === motion.HoldingHandStatus.LEFT_HAND_HELD ? 1 : 2;
    if (this.oldHand === code) {
      return;
    }
    this.newHand = code;
    if (!this.handUnlocked) {
      return; // 防抖中：只记录，等复检
    }
    this.handUnlocked = false;
    this.oldHand = code;
    this.applyHand(code);
  }

  /** ClashBox 的做法：先隐藏 → 500ms 后换边 → 再显示；随后 1.5s 复检 */
  private applyHand(code: number): void {
    animateTo({ duration: 160, curve: Curve.EaseOut }, () => {
      this.fabVisible = false;
    });
    setTimeout(() => {
      // 换边必须瞬时完成（此刻按钮不可见），动画只作用于"淡入"
      this.handLeft = code === 1;
      animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
        this.fabVisible = true;
      });
      setTimeout(() => {
        if (this.newHand !== this.oldHand) {
          this.oldHand = this.newHand;
          this.applyHand(this.newHand);
        } else {
          this.handUnlocked = true;
        }
      }, HAND_DEBOUNCE_MS);
    }, HAND_HIDE_MS);
  }

  /** 页签静态定义（ClashBox 的 tabList 同款） */
  private tabs(): TabDef[] {
    return [
      { title: '状态', icon: $r('sys.symbol.bolt_filled_on_circle'), idx: 0 },
      { title: '运动', icon: $r('sys.symbol.compass_circle'), idx: 1 },
      { title: '趋势', icon: $r('sys.symbol.rectangle_portrait_wave_2'), idx: 2 },
      { title: '我的', icon: $r('sys.symbol.person_crop_circle_fill_1'), idx: 3 }
    ];
  }

  private switchTo(idx: number): void {
    this.currentTab = idx;
    this.controller.changeIndex(idx, true);
    this.tick = this.tick + 1;
  }


  /** 圆形主按钮（ClashBox 启动键形态）→ DSH 对话触发键 */
  @Builder
  dshButton() {
    Column() {
      SymbolGlyph($r('sys.symbol.ellipsis_message_fill'))
        .fontSize(25)
        .fontColor([$r('app.color.accent')])
    }
    .width(60)
    .height(60)
    .borderRadius(30)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    // 液态玻璃：模糊底 + 半透明填充 + 1px 高光边 + 柔和外影（不是实色填充）
    .backgroundBlurStyle(BlurStyle.Thin)
    .backgroundColor($r('app.color.glass_fill_subtle'))
    .border({ width: 0.5, color: $r('app.color.glass_border_highlight') })
    .shadow({ radius: 18, color: $r('app.color.glass_shadow'), offsetY: 8, type: ShadowType.BLUR })
    .clickEffect({ level: ClickEffectLevel.MIDDLE, scale: 0.92 })
    .onClick(() => {
      router.pushUrl({ url: 'pages/DshChatPage' });
    })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Swiper(this.controller) {
        Column() {
          StatusView({ tick: this.tick })
        }
        .width('100%').height('100%')

        Column() {
          ActivitiesView({ tick: this.tick })
        }
        .width('100%').height('100%')

        Column() {
          TrendView({
            tick: this.tick,
            onSwipeOut: (delta: number) => {
              const t = this.currentTab + delta;
              if (t < 0 || t > 3) {
                return;
              }
              // 关键顺序：先改 currentTab，让 disableSwipe(this.currentTab === 2) 立刻解除禁用，
              // 下一帧再 changeIndex(t, true) 才能真正带上翻页动画（禁用状态下是瞬跳）
              this.currentTab = t;
              this.tick = this.tick + 1;
              setTimeout(() => {
                try {
                  this.controller.changeIndex(t, true);
                } catch (eC) {
                }
              }, 0);
            }
          })
        }
        .width('100%').height('100%')

        Column() {
          MeView({ onChanged: () => { this.tick = this.tick + 1; } })
        }
        .width('100%').height('100%')
      }
      .loop(false)
      // 趋势页(索引2)交给内层面板先滑，到头由 onSwipeOut 回调切大页（对齐 ClashBox）
      .disableSwipe(this.currentTab === 2)
      // 对齐 ClashBox ProxyPage：内层 Scroll 先处理纵向，Swiper 只接横向
      .nestedScroll(SwiperNestedScrollMode.SELF_FIRST)
      .cachedCount(0)
      .indicator(false)
      .duration(280)
      .curve(Curve.Friction)
      .effectMode(EdgeEffect.None)
      .itemSpace(0)
      .onAnimationStart((startIndex: number, targetIndex: number) => {
        this.currentTab = targetIndex;
      })
      .onChange((index: number) => {
        this.currentTab = index;
        this.tick = this.tick + 1;
      })
      .width('100%')
      .height('100%')
      .padding({ top: this.topInset })

      Row() {
        this.dshButton()
        Blank()
      }
      .width('100%')
      .padding({ left: 20, right: 20 })
      .margin({ bottom: 84 + this.bottomInset })
      .opacity(this.fabVisible ? 1 : 0)
      .animation({ duration: 180, curve: Curve.EaseOut })
      // translate 必须声明在 animation 之后：否则换边会变成"横穿屏幕"的补间
      .translate({ x: this.handLeft ? 0 : this.shiftX })

      // 悬浮玻璃 Dock：对齐系统 AppGallery —— 整条套官方沉浸材质（systemMaterial），
      // 选中项的高亮由 FloatBar 内部的浅色胶囊承担；不支持设备自动降级为
      // backgroundBlurStyle + glass_fill_subtle 的旧玻璃样式（两条路都不改布局与交互）。
      Row() {
        FloatBar({ tabList: this.tabs(), swiperController: this.controller })
      }
      .width('93%')
      .height(64)
      .margin({ bottom: 12 + this.bottomInset })
      .systemMaterial(DOCK_MATERIAL === null ? undefined : DOCK_MATERIAL)
      // 系统材质生效时：底色与自绘模糊让位（盖住会削弱材质折射/光感）；
      // 但【描边 + 投影要保留】——实测去掉后玻璃条在深色背景上没有边界、与页面糊在一起，
      // 与 AppGallery 的 Dock 形态不符。描边/投影只勾勒轮廓，不影响材质内部的折射。
      .backgroundBlurStyle(DOCK_MATERIAL === null ? BlurStyle.Thin : BlurStyle.NONE)
      .backgroundColor(DOCK_MATERIAL === null ? $r('app.color.glass_fill_subtle') : Color.Transparent)
      .borderRadius(32)
      .border({ width: 0.5, color: $r('app.color.glass_border_highlight') })
      .shadow({ radius: 26, color: $r('app.color.glass_shadow'), offsetY: 12, type: ShadowType.BLUR })
    }
    .width('100%')
    .height('100%')
    .linearGradient({
      angle: 165,
      colors: [
        [$r('app.color.gradient_start'), 0.0],
        [$r('app.color.gradient_mid'), 0.45],
        [$r('app.color.gradient_end'), 1.0]
      ]
    })
  }
}
