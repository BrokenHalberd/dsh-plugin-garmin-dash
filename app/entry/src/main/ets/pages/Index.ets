import { common } from '@kit.AbilityKit';
import { router, display } from '@kit.ArkUI';
import { motion } from '@kit.MultimodalAwarenessKit';
import { DeviceStore } from '../service/DeviceStore';
import { StatusView } from '../view/StatusView';
import { ActivitiesView } from '../view/ActivitiesView';
import { TrendView } from '../view/TrendView';
import { MeView } from '../view/MeView';
import { ApiClient } from '../service/ApiClient';
import { TabItem, TabDef } from '../view/FloatBar';
// HarmonyOS 7 官方沉浸材质（API 26）：底部 TabBar 悬浮样式背板材质
import { uiMaterial } from '@kit.ArkUI';

/**
 * 主界面：Tabs 悬浮页签（官方沉浸光感材质）+ 圆形 DSH 对话键。
 *
 * ── 沉浸光感（Light Sense）接入状态 ──────────────────────────────
 * 官方文档：developer.huawei.com → 沉浸光感（arkts-immersive-light-sense）
 * + 沉浸光感常见问题（FAQ）+ @ohos.arkui.uiMaterial API 参考 + Tabs 文档。
 *
 * 【根因记录】旧方案（Swiper + Stack 里悬浮的普通 Row + systemMaterial）
 * 代码完全符合官方指南，但真机（Mate 80 Pro / HarmonyOS 7.0.0.111 / API 26）
 * hilog 抓到框架拒绝日志：
 *   W C03900/com.atlas.garmindash/Ace:
 *     Material inactive: out of scope. Use component in navigation title bar or Tabbar.
 * 即 ArkUI 把沉浸式系统材质限定在 Navigation 标题栏 / TabBar 作用域内激活，
 * 普通容器（Stack/Row/Column…）设置 systemMaterial 一律不生效——
 * 表现为「API 全对、按压零反馈、无折射流光」。
 *
 * 【现行方案】Tabs + barFloatingStyle（API 26 官方悬浮页签入口）：
 *   · Tabs({ barPosition: End }) + barOverlap(true) + vertical(false)
 *     是 barFloatingStyle 生效的三前置（官方 Tabs 文档约束）；
 *   · barFloatingStyle({ systemMaterial }) 把沉浸材质挂到真 TabBar 背板
 *     （TabBar 作用域 ✓），胶囊悬浮形态也由系统接管（对齐 AppGallery）；
 *   · 材质参数对齐官方示例 LightEffect.ets：ULTRA_THIN（悬浮栏推荐档）+
 *     interactive（按压弹性形变）+ lightEffect:{color:undefined}（默认白色流光）。
 *
 * 【材质门槛】（指南 + API 参考交叉确认）：
 *   MaterialState：DEFAULT(0) 下组件可主动设置材质；ENABLE(1) 全局默认开启；
 *   DISABLE(2) 下主动设置不生效。故门槛必须是 state !== DISABLE——
 *   写成 === ENABLE 会让未配置 ohos.arkui.UIMaterial.state 的普通应用
 *   （返回 DEFAULT）永远走降级，这是本项目踩过的坑。
 *
 * 【已废弃路线】（查证/实测后放弃，勿回退）：
 *   · Stack 悬浮 Row + systemMaterial：out of scope，见上 ✗
 *   · lightUpEffect（@since 12/18）：按「照亮程度」整体压暗组件，实测变黑 ✗
 *   · effectStrategy(LIGHT_SENSING)：SDK 26 中只是 SymbolEffectStrategy ✗
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
 * 底部 TabBar 背板的沉浸材质（HarmonyOS 7 官方 uiMaterial，API 26）。
 * 参数对齐官方示例 code/DocsSample/ArkUISample/ImmersiveLightSense：
 *   · LightEffect.ets：ULTRA_THIN + interactive + lightEffect:{color:undefined}
 *     （lightEffect 传有效对象即启用光感交互反馈，color:undefined 用默认白色流光）
 *   · 官方推荐悬浮按钮/轻量提示用 ULTRA_THIN 或 THIN 档。
 * 门槛：设备支持（isImmersiveMaterialSupported）且应用级配置非 DISABLE。
 * 不满足 = null → barFloatingStyle 不传 systemMaterial，走系统默认悬浮背板。
 */
const DOCK_MATERIAL_STATE: uiMaterial.MaterialState = uiMaterial.getMaterialInfo().state;
const DOCK_SUPPORTED: boolean = uiMaterial.isImmersiveMaterialSupported()
  && DOCK_MATERIAL_STATE !== uiMaterial.MaterialState.DISABLE;
const DOCK_MATERIAL: uiMaterial.ImmersiveMaterial | null = DOCK_SUPPORTED
  ? new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
      interactive: true,
      lightEffect: { color: undefined }
    })
  : null;

@Entry
@Component
struct Index {
  private context = getContext(this) as common.UIAbilityContext;
  /** Tabs 控制器：趋势页面板滑到头时由 onSwipeOut 驱动切大页 */
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

  /** 页签静态定义（标题/图标/索引；TabItem 消费，Tabs 原生处理点击切页） */
  private tabs(): TabDef[] {
    return [
      { title: '状态', icon: $r('sys.symbol.bolt_filled_on_circle'), idx: 0 },
      { title: '运动', icon: $r('sys.symbol.compass_circle'), idx: 1 },
      { title: '趋势', icon: $r('sys.symbol.rectangle_portrait_wave_2'), idx: 2 },
      { title: '我的', icon: $r('sys.symbol.person_crop_circle_fill_1'), idx: 3 }
    ];
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

  /**
   * TabBar 单页签：包一层 @Builder 以满足 tabBar(CustomBuilder) 签名。
   * 动态高亮由 TabItem 内部 @Consume('currentTab') 自管理——直接在 @Builder
   * 里写选中态样式会踩「切页不跟高亮」的渲染缓存坑（见 FloatBar.ets 注释）。
   */
  @Builder
  tabBarBuilder(t: TabDef) {
    TabItem({ itemDef: t })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // ── 主内容区：Tabs（barOverlap 让内容延伸到 TabBar 底下，配合悬浮胶囊）──
      Tabs({ barPosition: BarPosition.End, controller: this.controller }) {
        TabContent() {
          Column() {
            StatusView({ tick: this.tick })
          }
          .width('100%').height('100%')
          .padding({ top: this.topInset })
        }
        .tabBar(this.tabBarBuilder(this.tabs()[0]))

        TabContent() {
          Column() {
            ActivitiesView({ tick: this.tick })
          }
          .width('100%').height('100%')
          .padding({ top: this.topInset })
        }
        .tabBar(this.tabBarBuilder(this.tabs()[1]))

        TabContent() {
          Column() {
            TrendView({
              tick: this.tick,
              onSwipeOut: (delta: number) => {
                const t = this.currentTab + delta;
                if (t < 0 || t > 3) {
                  return;
                }
                // 先改 currentTab（高亮立即跟随 + 解除趋势页的滑动禁用），再驱动 Tabs。
                // changeIndex 是控制器调用，不受 swipeable(false) 影响，
                // 无需旧 Swiper 方案的 setTimeout(0) 补丁
                this.currentTab = t;
                this.tick = this.tick + 1;
                this.controller.changeIndex(t);
              }
            })
          }
          .width('100%').height('100%')
          .padding({ top: this.topInset })
        }
        .tabBar(this.tabBarBuilder(this.tabs()[2]))

        TabContent() {
          Column() {
            MeView({ onChanged: () => { this.tick = this.tick + 1; } })
          }
          .width('100%').height('100%')
          .padding({ top: this.topInset })
        }
        .tabBar(this.tabBarBuilder(this.tabs()[3]))
      }
      // 悬浮样式三前置（官方 Tabs 文档约束）：barOverlap=true + vertical=false + barPosition=End
      .barOverlap(true)
      .vertical(false)
      .barMode(BarMode.Fixed)
      // 趋势页(索引2)交给内层面板先滑（TrendView 的 PanGesture），到头由
      // onSwipeOut 回调切大页；其余页签由 Tabs 原生左右滑动切换
      // （对齐旧 Swiper disableSwipe(currentTab===2) 的行为；Tabs 的对应属性是 scrollable）
      .scrollable(this.currentTab !== 2)
      // 官方悬浮 TabBar 样式（API 26）：胶囊形态 + 背板沉浸材质。
      // 材质挂在 TabBar 作用域内才会被框架激活（旧 Stack+Row 方案 out of scope 的教训）
      .barFloatingStyle({
        // 12vp 视觉边距 + 底部安全区（窗口为全屏沉浸布局，见 EntryAbility），对齐旧 Dock 几何
        barBottomMargin: 12 + this.bottomInset,
        // 材质门槛见文件头：设备支持且非 DISABLE 才传，否则 undefined 走系统默认悬浮背板
        systemMaterial: DOCK_MATERIAL === null ? undefined : DOCK_MATERIAL
      })
      .onChange((index: number) => {
        this.currentTab = index;
        this.tick = this.tick + 1;
      })
      .width('100%')
      .height('100%')

      // ── DSH 圆键悬浮层（智感握持换边逻辑不变）──
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
