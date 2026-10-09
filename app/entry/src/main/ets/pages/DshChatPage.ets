import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { ApiClient } from '../service/ApiClient';
import { DeviceStore } from '../service/DeviceStore';
import { ChatReply } from '../model/Types';
import { Fmt } from '../util/Format';
/** 一条聊天消息 */
interface ChatMsg {
  role: string;   // 'user' | 'assistant'
  text: string;
  tools: string;
}
const QUICK_PROMPTS: string[] = [
  '分析我最近 30 天的训练负荷，给三点建议',
  '按我现在的水平，排下周的骑行训练（含功率区间）',
  '我昨天睡得怎么样？和上周比呢',
  '这次骑行的功率曲线说明了什么'
];
/**
 * App 内建聊天（原生界面，非 WebView）。
 *
 * 重要约束（后端硬保证，App 侧无任何入口可改）：
 *   · 工作区固定 E:\GarminData —— 会话的 cwd 在后端启动进程时钉死，创建后不可变
 *   · 权限档固定 workspace-write —— headless profile 的 defaultPreset + 后端环境变量双保险
 * 会话是**持久会话**：每条消息只起一个短进程，但用同一个 session id 续接，
 * 因此拥有完整会话记忆，App/电脑重启后依旧连续。
 */
@Entry
@Component
struct DshChatPage {
  private scroller: Scroller = new Scroller();
  @State msgs: ChatMsg[] = [];
  @State input: string = '';
  @State sending: boolean = false;
  @State err: string = '';
  @State sessionId: string = '';
  @State dark: boolean = false;
  // 全屏布局下由 EntryAbility 写入的安全区高度（避免按钮被状态栏/手势条压住）
  @StorageProp('topRectHeight') topInset: number = 0;
  @StorageProp('bottomRectHeight') bottomInset: number = 0;
  aboutToAppear(): void {
    this.sessionId = DeviceStore.getChatSession();
    this.restoreLog();
  }

  /** 恢复上次的对话（界面历史；模型侧记忆由 sessionId 保证） */
  private restoreLog(): void {
    const raw = DeviceStore.getChatLog();
    if (raw.length < 3) {
      return;
    }
    try {
      const parsed = JSON.parse(raw) as ChatMsg[];
      if (parsed !== null && parsed.length > 0) {
        this.msgs = parsed;
        setTimeout(() => {
          this.scrollBottom();
        }, 60);
      }
    } catch (e) {
      // 记录损坏：清掉，避免每次打开都报错
      DeviceStore.setChatLog('[]');
    }
  }

  /** 落盘（只留最近 200 条，避免 preferences 无限增长） */
  private persistLog(): void {
    const all = this.msgs;
    const keep = all.length > 200 ? all.slice(all.length - 200) : all;
    DeviceStore.setChatLog(JSON.stringify(keep));
  }
  private scrollBottom(): void {
    try {
      this.scroller.scrollEdge(Edge.Bottom);
    } catch (e) {
      // 列表尚未布局完成时忽略
    }
  }
  private send(text0: string): void {
    const text = text0.trim();
    if (text.length === 0 || this.sending) {
      return;
    }
    const mine: ChatMsg = { role: 'user', text: text, tools: '' };
    this.msgs = this.msgs.concat([mine]);
    this.persistLog();
    this.input = '';
    this.sending = true;
    this.err = '';
    this.scrollBottom();
    ApiClient.postChat(text, this.sessionId)
      .then((r: ChatReply) => {
        if (r.sessionId !== undefined && r.sessionId.length > 0) {
          this.sessionId = r.sessionId;
          DeviceStore.setChatSession(r.sessionId);
        }
        const tools: string = r.tools === undefined || r.tools === null ? '' : r.tools.join(' · ');
        const reply: ChatMsg = { role: 'assistant', text: r.reply, tools: tools };
        this.msgs = this.msgs.concat([reply]);
        this.persistLog();
        this.sending = false;
        this.scrollBottom();
      })
      .catch((e: Object) => {
        this.sending = false;
        this.err = ApiClient.friendly(e);
      });
  }
  private newSession(): void {
    DeviceStore.clearChatSession();
    DeviceStore.setChatLog('[]');
    this.sessionId = '';
    this.msgs = [];
    this.err = '';
  }
  @Builder
  bubble(m: ChatMsg) {
    Row() {
      if (m.role === 'user') {
        Blank()
      }
      Column() {
        Text(m.text)
          .fontSize(15)
          .lineHeight(22)
          .fontColor(m.role === 'user' ? $r('app.color.accent_on') : $r('app.color.text_primary'))
          .textAlign(TextAlign.Start)
        if (m.tools.length > 0) {
          Text('调用：' + m.tools)
            .fontSize(10)
            .fontColor($r('app.color.text_hint'))
            .margin({ top: 6 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .constraintSize({ maxWidth: '82%' })
      .backgroundColor(m.role === 'user' ? $r('app.color.accent') : $r('app.color.card_background_blur'))
      .borderRadius(18)
      .border({
        width: m.role === 'user' ? 0 : 1,
        color: $r('app.color.card_border_highlight')
      })
      if (m.role !== 'user') {
        Blank()
      }
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }
  @Builder
  emptyState() {
    Column() {
      Text('DSH 助手')
        .fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
      Text('能查你的佳明数据、分析训练负荷、排课程、也能读写 E:\\GarminData 里的文件')
        .fontSize(12).fontColor($r('app.color.text_tertiary'))
        .textAlign(TextAlign.Center).margin({ top: 6, bottom: 18 })
      ForEach(QUICK_PROMPTS, (q: string) => {
        Text(q)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .width('100%')
          .backgroundColor($r('app.color.card_background_blur'))
          .borderRadius(14)
          .border({ width: 1, color: $r('app.color.card_border_highlight') })
          .margin({ bottom: 8 })
          .onClick(() => { this.send(q); })
      }, (q: string) => q)
    }
    .width('100%')
    .padding({ top: 30, bottom: 20 })
  }
  @Builder
  thinking() {
    Row() {
      Row({ space: 8 }) {
        LoadingProgress().width(16).height(16)
        Text('DSH 正在思考…').fontSize(13).fontColor($r('app.color.text_tertiary'))
      }
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .backgroundColor($r('app.color.card_background_blur'))
      .borderRadius(18)
      Blank()
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }
  build() {
    Column() {
      // 顶部栏
      Row() {
        Button('‹ 返回').fontSize(13).height(32)
          .backgroundColor($r('app.color.chip_background')).fontColor($r('app.color.text_primary'))
          .onClick(() => { router.back(); })
        Column() {
          Text('DSH 对话').fontSize(16).fontWeight(FontWeight.Bold)
          Text(this.sessionId.length > 0 ? '会话续接中 · 工作区 E:\\GarminData' : '新会话 · 工作区 E:\\GarminData')
            .fontSize(10).fontColor($r('app.color.text_hint'))
        }
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })
        .layoutWeight(1)
        Button('新会话').fontSize(12).height(30)
          .backgroundColor($r('app.color.chip_background')).fontColor($r('app.color.text_secondary'))
          .onClick(() => { this.newSession(); })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8 + this.topInset, bottom: 8 })
      .backgroundColor($r('app.color.tab_background_blur'))
      // 消息区
      List({ scroller: this.scroller, space: 2 }) {
        if (this.msgs.length === 0 && !this.sending) {
          ListItem() {
            this.emptyState()
          }
        }
        ForEach(this.msgs, (m: ChatMsg) => {
          ListItem() {
            this.bubble(m)
          }
        }, (m: ChatMsg) => m.role + m.text.length + m.text.substring(0, 12))
        if (this.sending) {
          ListItem() {
            this.thinking()
          }
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 12, right: 12 })
      .scrollBar(BarState.Off)
      if (this.err.length > 0) {
        Row() {
          Text(this.err).fontSize(12).fontColor($r('app.color.danger')).layoutWeight(1)
          Button('重试').fontSize(12).height(28)
            .backgroundColor($r('app.color.chip_background')).fontColor($r('app.color.text_primary'))
            .onClick(() => { this.send('继续'); })
        }
        .width('100%').padding({ left: 14, right: 14, top: 8, bottom: 8 })
      }
      // 输入区
      Row({ space: 8 }) {
        TextArea({ text: this.input, placeholder: '说点什么…（回车换行，点右侧发送）' })
          .fontSize(14)
          .layoutWeight(1)
          .height(44)
          .backgroundColor($r('app.color.card_background_blur'))
          .borderRadius(22)
          .border({ width: 1, color: $r('app.color.card_border_highlight') })
          .onChange((v: string) => { this.input = v; })
        Column() {
          SymbolGlyph($r('sys.symbol.arrow_up'))
            .fontSize(20)
            .fontColor([$r('app.color.accent_on')])
        }
        .width(44).height(44).borderRadius(22)
        .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        .backgroundColor(this.sending ? $r('app.color.chip_background') : $r('app.color.accent'))
        .clickEffect({ level: ClickEffectLevel.MIDDLE, scale: 0.9 })
        .onClick(() => { this.send(this.input); })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 10 + this.bottomInset })
      .backgroundColor($r('app.color.tab_background_blur'))
    }
    .width('100%')
    .height('100%')
    .linearGradient({
      angle: 165,
      colors: [
        [$r('app.color.gradient_start'), 0.0],
        [$r('app.color.gradient_mid'), 0.5],
        [$r('app.color.gradient_end'), 1.0]
      ]
    })
  }
}
