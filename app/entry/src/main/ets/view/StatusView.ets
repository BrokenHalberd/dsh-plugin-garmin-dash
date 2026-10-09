import { ApiClient } from '../service/ApiClient';
import { DeviceStore } from '../service/DeviceStore';
import { Summary } from '../model/Types';
import { Fmt } from '../util/Format';

/**
 * 状态卡配置。
 *
 * 为什么用一个对象而不是四个字符串参数：ArkUI 的 @Builder **按值传递参数时，
 * 参数变化不会刷新 builder 内部的 UI**（曾经导致"翻日期只有睡眠条变、其余不动"）。
 * 按引用（对象）传递才会随状态更新，所以这里统一走对象。
 */
interface StatCardCfg {
  title: string;
  value: string;
  unit: string;
  sub: string;
}

@Component
export struct StatusView {
  @Prop @Watch('onTick') tick: number = 0;
  @State summary: Summary | null = null;
  @State loading: boolean = false;
  @State refreshing: boolean = false;
  @State err: string = '';
  @State staleNote: string = '';
  @State date: string = Fmt.today();

  aboutToAppear(): void {
    this.load(false);
  }

  onTick(): void {
    this.load(false);
  }

  private isToday(): boolean {
    return this.date === Fmt.today();
  }

  private shiftDate(delta: number): void {
    const p = this.date.split('-');
    const d = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]));
    d.setDate(d.getDate() + delta);
    const next = d.getFullYear() + '-' + Fmt.pad(d.getMonth() + 1) + '-' + Fmt.pad(d.getDate());
    if (next > Fmt.today()) {
      return;
    }
    this.date = next;
    this.load(false);
  }

  private load(fromPull: boolean): void {
    if (!DeviceStore.isPaired()) {
      this.err = '尚未配对：请到「我的」里完成配对';
      return;
    }
    const key = 'summary:' + this.date;

    // ① 先立刻显示缓存：翻日期不再等网络（有缓存就是 0 延迟）
    const cachedFirst = DeviceStore.cacheGet(key);
    let showedCache = false;
    if (cachedFirst.length > 0) {
      this.summary = JSON.parse(cachedFirst) as Summary;
      this.staleNote = '缓存 · ' + Fmt.ago(DeviceStore.cacheAge(key)) + ' · 正在刷新…';
      showedCache = true;
    }

    // ② 再拉最新（有缓存时不再显示整页转圈）
    if (!fromPull && !showedCache) {
      this.loading = true;
    }
    this.err = '';
    ApiClient.getSummary(this.date)
      .then((s: Summary) => {
        this.summary = s;
        this.staleNote = '';
        this.err = '';
        this.loading = false;
        this.refreshing = false;
        DeviceStore.cachePut(key, JSON.stringify(s));
      })
      .catch((e: Object) => {
        this.loading = false;
        this.refreshing = false;
        const cached = DeviceStore.cacheGet(key);
        if (cached.length > 0) {
          this.summary = JSON.parse(cached) as Summary;
          this.staleNote = '离线数据 · ' + Fmt.ago(DeviceStore.cacheAge(key)) + '（' + ApiClient.friendly(e) + '）';
        } else {
          this.err = ApiClient.friendly(e);
        }
      });
  }

  // ── 卡片文案（每次都从当前 summary 现算，保证翻日期立刻跟着变）──

  private stepsText(): string {
    const s = this.summary;
    return s === null ? '--' : Fmt.int(s.steps);
  }

  private rhrText(): string {
    const s = this.summary;
    return s === null ? '--' : Fmt.int(s.restingHeartRate);
  }

  private sleepText(): string {
    const s = this.summary;
    if (s === null || s.sleep === null) {
      return '--';
    }
    const raw = s.sleep.durationMinutes;
    if (raw === null || raw === undefined) {
      return '--';
    }
    const minutes = raw > 1440 ? raw / 60 : raw;
    return Math.floor(minutes / 60) + ' 小时 ' + Math.round(minutes % 60) + ' 分';
  }

  private sleepScoreText(): string {
    const s = this.summary;
    if (s === null || s.sleep === null || s.sleep.score === null) {
      return '';
    }
    return '评分 ' + s.sleep.score;
  }

  private weightText(): string {
    const s = this.summary;
    if (s === null || s.weight === null || s.weight.kg === null) {
      return '--';
    }
    return Fmt.num1(s.weight.kg, '');
  }

  private weightSubText(): string {
    const s = this.summary;
    if (s === null || s.weight === null) {
      return '无记录';
    }
    return s.weight.date;
  }

  private bbText(): string {
    const s = this.summary;
    return s === null ? '--' : Fmt.int(s.bodyBattery);
  }

  private stageRaw(kind: string): number | null {
    const s = this.summary;
    if (s === null || s.sleep === null) {
      return null;
    }
    if (kind === 'deep') {
      return s.sleep.deepMinutes;
    }
    if (kind === 'light') {
      return s.sleep.lightMinutes;
    }
    if (kind === 'rem') {
      return s.sleep.remMinutes;
    }
    return s.sleep.awakeMinutes;
  }

  private stageWeight(kind: string): number {
    const v = this.stageRaw(kind);
    if (v === null || v <= 0) {
      return 0.01;
    }
    return v;
  }

  /** 状态卡：按引用传对象，状态变化才会刷新内部 UI */
  @Builder
  card(cfg: StatCardCfg) {
    Column() {
      Text(cfg.title).fontSize(12).fontColor($r('app.color.text_tertiary'))
      Row() {
        Text(cfg.value).fontSize(26).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        if (cfg.unit.length > 0) {
          Text(cfg.unit).fontSize(12).fontColor($r('app.color.text_tertiary')).margin({ left: 3, bottom: 4 })
        }
      }
      .alignItems(VerticalAlign.Bottom)
      if (cfg.sub.length > 0) {
        Text(cfg.sub).fontSize(11).fontColor($r('app.color.text_tertiary')).margin({ top: 2 })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .width('48%')
    .backgroundColor($r('app.color.card_background_blur'))
    .border({ width: 1, color: $r('app.color.card_border_highlight') })
    .borderRadius(14)
    .margin({ bottom: 10 })
  }

  /** 日期左右切换：无参构建器，状态在内部读（值参不刷新，血泪教训） */
  @Builder
  navBack() {
    Column() {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(18)
        .fontColor([$r('app.color.text_primary')])
        .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_OPACITY)
    }
    .width(46)
    .height(38)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.chip_background'))
    .borderRadius(19)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
    .onClick(() => {
      this.shiftDate(-1);
    })
  }

  @Builder
  navForward() {
    Column() {
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18)
        .fontColor([this.isToday() ? $r('app.color.text_hint') : $r('app.color.text_primary')])
        .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_OPACITY)
    }
    .width(46)
    .height(38)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.chip_background'))
    .borderRadius(19)
    .opacity(this.isToday() ? 0.45 : 1)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
    .onClick(() => {
      if (!this.isToday()) {
        this.shiftDate(1);
      }
    })
  }

  @Builder
  legend(color: ResourceColor, label: string, kind: string) {
    Row() {
      Row().width(8).height(8).borderRadius(4).backgroundColor(color)
      Text(' ' + label + ' ' + Fmt.minutesShort(this.stageRaw(kind)))
        .fontSize(10).fontColor($r('app.color.text_tertiary'))
    }
  }

  @Builder
  sleepStages() {
    Column() {
      Row() {
        Row().layoutWeight(this.stageWeight('deep')).height(10).backgroundColor($r('app.color.sleep_deep'))
        Row().layoutWeight(this.stageWeight('light')).height(10).backgroundColor($r('app.color.sleep_light'))
        Row().layoutWeight(this.stageWeight('rem')).height(10).backgroundColor($r('app.color.sleep_rem'))
        Row().layoutWeight(this.stageWeight('awake')).height(10).backgroundColor($r('app.color.sleep_awake'))
      }
      .width('100%')
      .borderRadius(5)
      .clip(true)

      Row({ space: 12 }) {
        this.legend($r('app.color.sleep_deep'), '深睡', 'deep')
        this.legend($r('app.color.sleep_light'), '浅睡', 'light')
        this.legend($r('app.color.sleep_rem'), 'REM', 'rem')
        this.legend($r('app.color.sleep_awake'), '清醒', 'awake')
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .padding(14)
    .width('100%')
    .backgroundColor($r('app.color.card_background_blur'))
    .border({ width: 1, color: $r('app.color.card_border_highlight') })
    .borderRadius(14)
    .margin({ bottom: 10 })
  }

  build() {
    Refresh({ refreshing: $$this.refreshing }) {
      Scroll() {
        Column() {
          Row({ space: 8 }) {
            this.navBack()
            Column() {
              Text(this.isToday() ? '今天' : this.date).fontSize(17).fontWeight(FontWeight.Bold)
              Text(this.date).fontSize(10).fontColor($r('app.color.text_tertiary'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Center)
            this.navForward()
          }
          .width('100%')
          .padding({ top: 10, bottom: 10 })

          if (this.staleNote.length > 0) {
            Text(this.staleNote).fontSize(11).fontColor($r('app.color.banner_text'))
              .width('100%').padding(8)
              .backgroundColor($r('app.color.banner_background')).borderRadius(8).margin({ bottom: 8 })
          }

          if (this.err.length > 0) {
            Column() {
              Text(this.err).fontSize(13).fontColor($r('app.color.danger'))
              Button('重试').fontSize(13).margin({ top: 8 }).onClick(() => { this.load(false); })
            }
            .padding(16).width('100%').backgroundColor($r('app.color.card_background_blur'))
            .border({ width: 1, color: $r('app.color.card_border_highlight') }).borderRadius(14)
          }

          if (this.loading && this.summary === null) {
            Row() {
              LoadingProgress().width(22).height(22)
              Text('读取中…').fontSize(13).fontColor($r('app.color.text_tertiary')).margin({ left: 8 })
            }
            .padding(16)
          }

          if (this.summary !== null) {
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
              this.card({ title: '步数', value: this.stepsText(), unit: '步', sub: '' })
              this.card({ title: '静息心率', value: this.rhrText(), unit: 'bpm', sub: '' })
              this.card({ title: '睡眠', value: this.sleepText(), unit: '', sub: this.sleepScoreText() })
              this.card({ title: '体重', value: this.weightText(), unit: 'kg', sub: this.weightSubText() })
              this.card({ title: 'Body Battery', value: this.bbText(), unit: '', sub: '' })
            }
            .width('100%')

            if (this.summary.sleep !== null) {
              this.sleepStages()
            }

            Text('下拉刷新 · 切换标签页自动刷新')
              .fontSize(11).fontColor($r('app.color.text_hint')).width('100%').margin({ top: 4, bottom: 96 })
          }
        }
        .width('100%')
        .constraintSize({ minHeight: '100%' })
        .justifyContent(FlexAlign.Start)
        .padding({ left: 12, right: 12 })
        .alignItems(HorizontalAlign.Start)
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
    }
    .onRefreshing(() => {
      this.load(true);
    })
    .width('100%')
    .height('100%')
  }
}
