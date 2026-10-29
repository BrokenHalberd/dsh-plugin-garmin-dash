import { common } from '@kit.AbilityKit';
import { router, LengthMetrics, curves, display } from '@kit.ArkUI';
import { motion } from '@kit.MultimodalAwarenessKit';
import { DeviceStore } from '../service/DeviceStore';
import { StatusView } from '../view/StatusView';
import { ActivitiesView } from '../view/ActivitiesView';
import { TrendView } from '../view/TrendView';
import { MeView } from '../view/MeView';

/**
 * 主界面：液态玻璃选项栏 + 圆形 DSH 对话键。
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

/** 底部选项栏 + 安全区：滚到底时避开遮挡 */
const BOTTOM_BAR_PAD: number = 104;

@Entry
@Component
struct Index {
  private context = getContext(this) as common.UIAbilityContext;
  private controller: TabsController = new TabsController();
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
  @State currentTab: number = 0;
  @State tick: number = 0;
  @State handLeft: boolean = false;
  @State fabVisible: boolean = true;

  aboutToAppear(): void {
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

  private switchTo(idx: number): void {
    this.currentTab = idx;
    this.controller.changeIndex(idx);
    this.tick = this.tick + 1;
  }

  @Builder
  tabItem(title: string, icon: Resource, idx: number) {
    Flex({
      direction: FlexDirection.Column,
      justifyContent: FlexAlign.Center,
      alignItems: ItemAlign.Center,
      space: { main: LengthMetrics.vp(3) }
    }) {
      SymbolGlyph(icon)
        .fontSize(21)
        .fontColor([this.currentTab === idx ? $r('app.color.accent') : $r('app.color.text_tertiary')])
        .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_OPACITY)
        .scale({ x: this.currentTab === idx ? 1.12 : 1, y: this.currentTab === idx ? 1.12 : 1 })
        .translate({ y: this.currentTab === idx ? -1 : 0 })
        .animation({ duration: 320, curve: Curve.Friction })

      Text(title)
        .fontSize(10)
        .fontColor(this.currentTab === idx ? $r('app.color.accent') : $r('app.color.text_tertiary'))
        .fontWeight(this.currentTab === idx ? FontWeight.Medium : FontWeight.Normal)
    }
    .layoutWeight(1)
    .height(52)
    .margin({ left: 4, right: 4, top: 6, bottom: 6 })
    .borderRadius(100)
    .backgroundColor(this.currentTab === idx ? $r('app.color.glass_fill_strong') : Color.Transparent)
    .animation({ duration: 320, curve: Curve.Friction })
    .onClick(() => { this.switchTo(idx); })
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
      Tabs({ barPosition: BarPosition.End, controller: this.controller }) {
        TabContent() {
          Column() {
            StatusView({ tick: this.tick })
          }
          .width('100%').height('100%')
        }
        .tabBar(this.tabItem('状态', $r('sys.symbol.bolt_filled_on_circle'), 0))

        TabContent() {
          Column() {
            ActivitiesView({ tick: this.tick })
          }
          .width('100%').height('100%')
        }
        .tabBar(this.tabItem('运动', $r('sys.symbol.compass_circle'), 1))

        TabContent() {
          Column() {
            TrendView({
            tick: this.tick,
            onSwipeOut: (delta: number) => {
              const t = this.currentTab + delta;
              if (t < 0 || t > 3) {
                return;
              }
              // 关键顺序：先改 currentTab，让 disableSwipe(this.currentTab === 2) 立刻解除禁用，
              // 下一帧再 changeIndex(t) 才能真正带上翻页动画（禁用状态下是瞬跳）
              this.currentTab = t;
              this.tick = this.tick + 1;
              setTimeout(() => {
                try {
                  this.controller.changeIndex(t);
                } catch (eC) {
                }
              }, 0);
            }
          })
          }
          .width('100%').height('100%')
        }
        .tabBar(this.tabItem('趋势', $r('sys.symbol.rectangle_portrait_wave_2'), 2))

        TabContent() {
          Column() {
            MeView({ onChanged: () => { this.tick = this.tick + 1; } })
          }
          .width('100%').height('100%')
        }
        .tabBar(this.tabItem('我的', $r('sys.symbol.person_crop_circle_fill_1'), 3))
      }
      // 趋势页(索引2)交给内层面板先滑，到头由 onSwipeOut 回调切大页（对齐 ClashBox）
      .scrollable(this.currentTab !== 2)
      // 对齐 ClashBox ProxyPage：内层 Scroll 先处理纵向，Swiper 只接横向
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

      // 悬浮玻璃选项栏（全项目唯一一处真模糊，与 ClashBox 的 FloatBar 一致）

      .height(64)
      .margin({ bottom: 12 + this.bottomInset })
      .backgroundBlurStyle(BlurStyle.Thin)
      .backgroundColor($r('app.color.glass_fill_subtle'))
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
