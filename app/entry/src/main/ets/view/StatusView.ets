import { ApiClient } from '../service/ApiClient';
import { DeviceStore } from '../service/DeviceStore';
import { Summary, Trend, TrendPoint , HrvInfo , BodyBattery } from '../model/Types';
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

const COLOR_ACCENT: ResourceColor = $r('app.color.accent');
const COLOR_WARN: ResourceColor = $r('app.color.warn');
const COLOR_DANGER: ResourceColor = $r('app.color.danger');
const COLOR_TERTIARY: ResourceColor = $r('app.color.text_tertiary');
const COLOR_SECONDARY: ResourceColor = $r('app.color.text_secondary');
const COLOR_HINT: ResourceColor = $r('app.color.text_hint');
const COLOR_CARD_BG: ResourceColor = $r('app.color.card_background_blur');
const COLOR_CARD_BORDER: ResourceColor = $r('app.color.card_border_highlight');

/** 底部选项栏 + 安全区高度：滚到底时用来避开遮挡 */
const BOTTOM_BAR_PAD: number = 104;

@Component
export struct StatusView {
  @Prop @Watch('onTick') tick: number = 0;
  @State summary: Summary | null = null;
  @State loading: boolean = false;
  @State refreshing: boolean = false;
  @State err: string = '';
  @State staleNote: string = '';
  @State date: string = Fmt.today();
  // ── 今日表单（复用 /trend；概念来自 Intervals.icu 的 TSB）──
  @State tsb: number | null = null;
  @State ctl: number | null = null;
  @State atl: number | null = null;
  @State ramp: number | null = null;
  @State formErr: string = '';
  @State hrv: HrvInfo | null = null;
  @State hrvErr: string = '';
  @State bb: BodyBattery | null = null;

  aboutToAppear(): void {
    this.loadHrv(false);
    this.loadBb();
    this.load(false);
  }

  onTick(): void {
    this.load(false);
    this.loadForm();
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
    const bb = this.bb;
    if (bb !== null && bb.available && bb.high !== null) {
      return '' + bb.high;
    }
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

  /** 载入今日表单：优先复用趋势页缓存，其次拉 30 天窗口 */

  /** 载入今日 HRV（1 小时缓存） */
  /** 载入当日身体电量（后端直连端点，缓存 1 小时） */
  /** 身体电量副标题：显示当日最低值 */
  private bbSubText(): string {
    const bb = this.bb;
    if (bb !== null && bb.available && bb.low !== null) {
      return '当日最低 ' + bb.low;
    }
    return '当日最高值';
  }

  private loadBb(): void {
    if (!DeviceStore.isPaired()) {
      return;
    }
    const key = 'bb:today';
    const cached = DeviceStore.cacheGet(key);
    if (cached.length > 10 && DeviceStore.cacheAge(key) < 3600000) {
      this.bb = JSON.parse(cached) as BodyBattery;
      return;
    }
    ApiClient.getBodyBattery(this.date)
      .then((b: BodyBattery) => {
        this.bb = b;
        if (b.available) {
          DeviceStore.cachePut(key, JSON.stringify(b));
        }
      })
      .catch((e: Object) => { });
  }

  private loadHrv(force: boolean): void {
    this.hrvErr = '';
    if (!DeviceStore.isPaired()) {
      this.hrvErr = '尚未配对（请到「我的」完成配对）';
      return;
    }
    const key = 'hrv:today';
    if (!force) {
      const cached = DeviceStore.cacheGet(key);
      if (cached.length > 10 && DeviceStore.cacheAge(key) < 3600000) {
        try {
          this.hrv = JSON.parse(cached) as HrvInfo;
          return;
        } catch (e) {
          this.hrvErr = '本地缓存损坏，正在重取';
        }
      }
    }
    ApiClient.getHrv(this.date)
      .then((h: HrvInfo) => {
        this.hrv = h;
        this.hrvErr = '';
        DeviceStore.cachePut(key, JSON.stringify(h));
      })
      .catch((e: Object) => {
        this.hrvErr = ApiClient.friendly(e);
      });
  }

  private hrvText(): string {
    const h = this.hrv;
    return h === null || h.lastNightAvg === null ? '--' : '' + h.lastNightAvg;
  }

  private hrvStatusText(): string {
    const h = this.hrv;
    if (this.hrvErr.length > 0) {
      return '读取失败';
    }
    if (h === null) {
      return '读取中';
    }
    if (h.status === null) {
      return h.available ? '--' : '无数据';
    }
    if (h.status === 'LOW') {
      return '偏低';
    }
    if (h.status === 'HIGH') {
      return '偏高';
    }
    if (h.status === 'BALANCED') {
      return '平衡';
    }
    return h.status;
  }

  private hrvColor(): ResourceColor {
    const h = this.hrv;
    if (h === null || h.status === null) {
      return COLOR_TERTIARY;
    }
    if (h.status === 'LOW') {
      return COLOR_WARN;
    }
    if (h.status === 'HIGH') {
      return COLOR_DANGER;
    }
    return COLOR_ACCENT;
  }

  private hrvAdvice(): string {
    const h = this.hrv;
    if (this.hrvErr.length > 0) {
      return 'HRV 读取失败：' + this.hrvErr + '　（点右上角「刷新」重试）';
    }
    if (h === null) {
      return '正在读取佳明 HRV Status…';
    }
    if (!h.available) {
      return '该日期没有 HRV 数据（需要手表支持 HRV Status 且佩戴过夜）';
    }
    if (h.status === 'LOW') {
      return 'HRV 偏低：优先睡眠与恢复，今天避免阈值以上高强度';
    }
    if (h.status === 'HIGH') {
      return 'HRV 偏高：恢复良好，可正常或略加量';
    }
    return 'HRV 平衡：按计划推进即可';
  }

  private hrvBarPct(kind: string): string {
    const h = this.hrv;
    if (h === null || h.baselineLow === null || h.baselineBalancedLow === null || h.baselineBalancedUpper === null) {
      return '33%';
    }
    const lo = h.baselineLow;
    const b1 = h.baselineBalancedLow;
    const b2 = h.baselineBalancedUpper;
    const v = h.lastNightAvg === null ? b2 : h.lastNightAvg;
    const hi = Math.max(b2 * 1.25, v * 1.15);
    const span = hi - lo;
    if (span <= 0) {
      return '33%';
    }
    if (kind === 'low') {
      return Math.round(((b1 - lo) / span) * 100) + '%';
    }
    if (kind === 'mid') {
      return Math.round(((b2 - b1) / span) * 100) + '%';
    }
    return Math.round(((hi - b2) / span) * 100) + '%';
  }

  /** 身体电量卡：必须是无参 @Builder —— 按值传参的 builder 不会随状态刷新 */
  @Builder
  bbCard() {
    Column() {
      Text('Body Battery').fontSize(11).fontColor($r('app.color.text_tertiary'))
      Row() {
        Text(this.bbText()).fontSize(26).fontWeight(FontWeight.Bold).fontColor($r('app.color.accent'))
        Text(' 最高').fontSize(10).fontColor($r('app.color.text_tertiary')).margin({ bottom: 4 })
      }
      .alignItems(VerticalAlign.Bottom)
      Text(this.bbSubText()).fontSize(9).fontColor($r('app.color.text_hint'))
    }
    .alignItems(HorizontalAlign.Start)
    .width('48%')
    .padding(14)
    .backgroundColor($r('app.color.card_background_blur'))
    .border({ width: 1, color: $r('app.color.card_border_highlight') })
    .borderRadius(14)
  }

  @Builder
  hrvCard() {
    Column() {
      Row() {
        Column() {
          Row() {

            Text('HRV（昨夜）').fontSize(11).fontColor($r('app.color.text_tertiary'))

            Blank()

            Text('刷新HRV').fontSize(10).fontColor($r('app.color.accent'))

              .onClick(() => { this.hrv = null; this.loadHrv(true); })

          }

          .width('100%')
          Text(this.hrvText() + ' ms').fontSize(24).fontWeight(FontWeight.Bold).fontColor(this.hrvColor())
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Column() {
          Text(this.hrvStatusText()).fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.hrvColor())
          Text('7 天均值 ' + this.hrvWeeklyText()).fontSize(10).fontColor(COLOR_TERTIARY)
            .margin({ top: 3 })
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')

      Row() {
        Row().width(this.hrvBarPct('low')).height(10).backgroundColor(COLOR_DANGER)
        Row().width(this.hrvBarPct('mid')).height(10).backgroundColor(COLOR_ACCENT)
        Row().width(this.hrvBarPct('high')).height(10).backgroundColor(COLOR_WARN)
      }
      .width('100%').borderRadius(5).clip(true).margin({ top: 10 })
      Row() {
        Text('低').fontSize(9).fontColor(COLOR_HINT).layoutWeight(1)
        Text('平衡').fontSize(9).fontColor(COLOR_HINT).layoutWeight(1).textAlign(TextAlign.Center)
        Text('高').fontSize(9).fontColor(COLOR_HINT).layoutWeight(1).textAlign(TextAlign.End)
      }
      .width('100%').margin({ top: 2 })

      Text(this.hrvAdvice()).fontSize(11).fontColor(COLOR_SECONDARY).width('100%').margin({ top: 8 })
      Text('数据来源：佳明 HRV Status（基线区间分低/平衡/高三段）')
        .fontSize(9).fontColor(COLOR_HINT).width('100%').margin({ top: 4 })
    }
    .padding(14).width('100%')
    .backgroundColor(COLOR_CARD_BG)
    .border({ width: 1, color: COLOR_CARD_BORDER })
    .borderRadius(14)
    .margin({ bottom: 10 })
  }

  private hrvWeeklyText(): string {
    const h = this.hrv;
    return h === null || h.weeklyAvg === null ? '--' : h.weeklyAvg + ' ms';
  }

  private loadForm(): void {

    const cached = DeviceStore.cacheGet('trend:90');

    if (cached.length > 10) {

      this.applyTrend(cached);

      return;

    }

    if (!DeviceStore.isPaired()) {

      return;

    }

    ApiClient.getTrend(30)

      .then((t: Trend) => {

        const json = JSON.stringify(t);

        DeviceStore.cachePut('trend:30', json);

        this.applyTrend(json);

      })

      .catch((e: Object) => {
        this.formErr = ApiClient.friendly(e);
      });

  }

  /** 从趋势数据里取最后一点的 CTL/ATL/TSB，并算 7 天 ramp */

  private applyTrend(json: string): void {

    try {

      const t = JSON.parse(json) as Trend;

      if (t.points.length === 0) {

        return;

      }

      const last: TrendPoint = t.points[t.points.length - 1];

      this.tsb = last.tsb;

      this.ctl = last.ctl;

      this.atl = last.atl;

      if (t.points.length >= 8) {

        const before = t.points[t.points.length - 8].ctl;

        if (before !== null && last.ctl !== null) {

          this.ramp = Math.round((last.ctl - before) * 10) / 10;

        }

      }

    } catch (e) {

      DeviceStore.cachePut('trend:30', '');

    }

  }

  private formTitle(): string {

    const t = this.tsb;

    if (t === null) {

      return '等待数据';

    }

    if (t > 5) {

      return '新鲜';

    }

    if (t >= -10) {

      return '正常训练';

    }

    if (t >= -30) {

      return '有负荷';

    }

    return '过度疲劳';

  }

  private formAdvice(): string {

    const t = this.tsb;

    if (t === null) {

      return '先骑一次带功率的车，就能算出你的体能/疲劳/表单';

    }

    if (t > 5) {

      return '状态好：适合比赛、FTP 测试或高强度间歇';

    }

    if (t >= -10) {

      return '负荷与恢复平衡：按计划推进即可';

    }

    if (t >= -30) {

      return '训练期常态：保证睡眠与补给，别再叠加质量课';

    }

    return '建议减量 2~3 天（轻松骑或休息），避免受伤与免疫下降';

  }

  private formColor(): ResourceColor {

    const t = this.tsb;

    if (t === null) {

      return $r('app.color.text_tertiary');

    }

    if (t >= -10) {

      return $r('app.color.accent');

    }

    if (t >= -30) {

      return $r('app.color.warn');

    }

    return $r('app.color.danger');

  }

  @Builder

  formCard() {

    Column() {

      Row() {

        Column() {

          Text('今日表单 TSB').fontSize(11).fontColor($r('app.color.text_tertiary'))

          Text(this.tsb === null ? '--' : '' + this.tsb)

            .fontSize(26).fontWeight(FontWeight.Bold).fontColor(this.formColor())

        }

        .alignItems(HorizontalAlign.Start)

        .layoutWeight(1)

        Column() {

          Text(this.formTitle()).fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.formColor())

          Text('体能 ' + (this.ctl === null ? '--' : '' + this.ctl)

            + ' · 疲劳 ' + (this.atl === null ? '--' : '' + this.atl)

            + ' · Ramp ' + (this.ramp === null ? '--' : '' + this.ramp))

            .fontSize(10).fontColor($r('app.color.text_tertiary')).margin({ top: 3 })

        }

        .alignItems(HorizontalAlign.End)

      }

      .width('100%')

      Text(this.formAdvice()).fontSize(11).fontColor($r('app.color.text_secondary'))

        .width('100%').margin({ top: 6 })

    }

    .padding(14).width('100%')

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

          this.formCard()
          this.hrvCard()

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
              this.bbCard()
            }
            .width('100%')

            if (this.summary.sleep !== null) {
              this.sleepStages()
            }

            Text('下拉刷新 · 切换标签页自动刷新')
              .fontSize(11).fontColor($r('app.color.text_hint')).width('100%').margin({ top: 4 })
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
