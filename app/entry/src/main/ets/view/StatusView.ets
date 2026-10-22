import { ApiClient, BundleResult } from '../service/ApiClient';
import { DeviceStore, CardExtra } from '../service/DeviceStore';
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
  @State lastTrend: TrendPoint | null = null;
  @State weekTss: number = 0;

  aboutToAppear(): void {
    // 一次聚合请求拿全部（失败自动回退到分接口）
    this.loadAll();
  }

  onTick(): void {
    // 与首屏一致：一次聚合请求（失败自动回退）
    this.loadAll();
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
    this.loadAll();
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
    // Garmin 原始枚举 → 中文（BALANCED / UNBALANCED / LOW / HIGH）
    const raw = this.hrv === null || this.hrv.status === null ? '' : this.hrv.status.toUpperCase();
    if (raw === 'BALANCED') {
      return '平衡区';
    }
    if (raw === 'UNBALANCED') {
      return '偏离平衡区';
    }
    if (raw === 'LOW') {
      return '低于平衡区';
    }
    if (raw === 'HIGH') {
      return '高于平衡区';
    }
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
      return '低于平衡区';
    }
    if (h.status === 'HIGH') {
      return '高于平衡区';
    }
    if (h.status === 'BALANCED') {
      return '平衡区';
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
    if (h === null || h.status === null) {
      return 'HRV 暂无数据：确保夜间佩戴手表，并在手表上开启 HRV 状态记录';
    }
    const raw = h.status.toUpperCase();
    if (raw === 'BALANCED') {
      const t = this.tsb;
      const r = this.ramp;
      if (t !== null && t < -20) {
        return 'HRV 平衡，但疲劳偏高（TSB ' + Math.round(t) + '）：今天做轻松有氧，先别加量';
      }
      if (r !== null && r > 8) {
        return 'HRV 平衡，但周负荷增幅偏大（+' + Math.round(r) + '）：保持现状，别再往上加';
      }
      if (t !== null && t > 10) {
        return 'HRV 平衡且状态新鲜（TSB +' + Math.round(t) + '）：适合做质量课（阈值/间歇）';
      }
      return 'HRV 平衡：按计划推进，保持睡眠与恢复节奏';
    }
    if (raw === 'UNBALANCED') {
      return '略低于个人平衡区：今天避免阈值以上强度，优先睡眠，观察 2~3 天是否回升';
    }
    if (raw === 'LOW') {
      return '明显低于个人基线：主动减量 30~50%，睡够；连续 3 天以上注意是否感冒或过训';
    }
    if (raw === 'HIGH') {
      return '高于个人平衡区：恢复充分，可正常训练或略加量（+5~10%）';
    }
    return 'HRV 状态：' + h.status;
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


  /** HRV 条：低区宽度（按 baselineLow 真实数值 ✓） */
  private hrvWLow(): number {
    const h = this.hrv;
    if (h === null || h.baselineLow === null || h.baselineLow <= 0) {
      return 1;
    }
    return Math.max(1, h.baselineLow);
  }

  /** HRV 条：平衡区宽度（balancedLow → balancedUpper ✓） */
  private hrvWMid(): number {
    const h = this.hrv;
    if (h === null || h.baselineLow === null || h.baselineBalancedUpper === null) {
      return 1;
    }
    return Math.max(1, h.baselineBalancedUpper - h.baselineLow);
  }

  /** HRV 条：高区宽度（固定尾巴 20ms ✓） */
  private hrvWHigh(): number {
    return 20;
  }

  /** HRV 当前值在整条上的位置（0~100%）✓ */
  private hrvMarkerPct(): number {
    const h = this.hrv;
    if (h === null || h.lastNightAvg === null || h.baselineBalancedUpper === null) {
      return -1;
    }
    const total = h.baselineBalancedUpper + 20;
    if (total <= 0) {
      return -1;
    }
    let pct = (h.lastNightAvg / total) * 100;
    if (pct < 2) {
      pct = 2;
    }
    if (pct > 98) {
      pct = 98;
    }
    return Math.round(pct);
  }

  /** 区间文字（带数字 ✓） */
  private hrvRangeText(): string {
    const h = this.hrv;
    if (h === null || h.baselineLow === null || h.baselineBalancedUpper === null) {
      return '—';
    }
    return '低于 ' + h.baselineLow + ' / ' + h.baselineLow + '–' + h.baselineBalancedUpper + ' / 高于 ' + h.baselineBalancedUpper + ' ms';
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

      Stack({ alignContent: Alignment.Start }) {
        Row() {
          Row().layoutWeight(this.hrvWLow()).height('100%').backgroundColor(COLOR_DANGER)
          Row().layoutWeight(this.hrvWMid()).height('100%').backgroundColor(COLOR_ACCENT)
          Row().layoutWeight(this.hrvWHigh()).height('100%').backgroundColor(COLOR_WARN)
        }
        .width('100%').height('100%').borderRadius(5).clip(true)
        if (this.hrvMarkerPct() >= 0) {
          Column() {
            Row().width(3).height(14).backgroundColor('#FFFFFF').borderRadius(2)
          }
          .width('100%').height('100%').padding({ left: this.hrvMarkerPct() + '%' })
          .alignItems(HorizontalAlign.Start)
        }
      }
      .width('100%').height(10).margin({ top: 10 })
      Row() {
        Text(this.hrvRangeText()).fontSize(9).fontColor(COLOR_HINT)
        Blank()
        Text('白线=昨夜值').fontSize(9).fontColor(COLOR_HINT)
      }
      .width('100%').margin({ top: 4 })

      Text(this.hrvAdvice()).fontSize(11).fontColor(COLOR_SECONDARY).width('100%').margin({ top: 8 })
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

  /** 一次请求拿全部；任一段为空则回退到对应分接口 */
  private loadAll(): void {
    ApiClient.getBundle(30, this.date)
      .then((b: BundleResult) => {
        if (b.trend !== undefined) {
          this.applyTrend(JSON.stringify(b.trend));
        }
        if (b.summary !== undefined) {
          this.summary = b.summary;
          this.err = '';
          this.staleNote = '';
        }
        if (b.hrv !== undefined) {
          this.hrv = b.hrv;
          this.hrvErr = '';
        }
        if (b.bodyBattery !== undefined) {
          this.bb = b.bodyBattery;
        }
        this.loading = false;
        this.refreshing = false;
        if (b.partial.length > 0) {
          this.staleNote = '部分数据缺失：' + b.partial.join('、');
        }
        this.writeCardCache(b);
      })
      .catch((e: Object) => {
        // 回退：老的四路请求（保底可用 ✓）
        this.staleNote = '聚合失败，已回退：' + ApiClient.friendly(e);
        this.loadHrv(false);
        this.loadBb();
        this.load(false);
        this.loadForm();
      });
  }

  /**
   * 把当前已就绪的所有状态写入桌面卡片缓存。
   * 必须在 tsb/ctl/atl/summary/hrv/bb 全部赋值之后再调用（否则卡片拿到旧值或 null ✓）。
   */
  /** 安全数值：null/undefined/NaN 一律 null ✓ */
  private nz(v: number | null | undefined): number | null {
    if (v === null || v === undefined || Number.isNaN(v) || !Number.isFinite(v)) {
      return null;
    }
    return v;
  }

  /**
   * 把 bundle 里的数据直接写入卡片缓存（不依赖任何 this.* 状态 ✓ 彻底避免时序问题）。
   */
  private writeCardCache(b: BundleResult): void {
    const trend = b.trend;
    if (trend === undefined || trend.points.length === 0) {
      return;
    }
    const last = trend.points[trend.points.length - 1];
    let wt = 0;
    for (let j = Math.max(0, trend.points.length - 7); j < trend.points.length; j++) {
      const one = trend.points[j].tss;
      wt = wt + (one === null ? 0 : one);
    }
    const s = b.summary;
    const sl = (s === undefined || s === null) ? null : s.sleep;
    const h = b.hrv;
    const bv = b.bodyBattery;
    let bbValue: number | null = null;
    if (bv !== undefined && bv !== null && bv.available) {
      const cur = bv.value;
      bbValue = (cur === null || cur === undefined || Number.isNaN(cur)) ? null : cur;
    }
    const extra: CardExtra = {
      weekTss: this.nz(wt),
      steps: (s === undefined || s === null) ? null : this.nz(s.steps),
      rhr: (s === undefined || s === null) ? null : this.nz(s.restingHeartRate),
      bb: bbValue,
      sleepDeep: sl === null ? null : this.nz(sl.deepMinutes),
      sleepLight: sl === null ? null : this.nz(sl.lightMinutes),
      sleepRem: sl === null ? null : this.nz(sl.remMinutes),
      sleepAwake: sl === null ? null : this.nz(sl.awakeMinutes),
      hrvNow: (h === undefined || h === null) ? null : this.nz(h.lastNightAvg),
      hrvLow: (h === undefined || h === null) ? null : this.nz(h.baselineLow),
      hrvB1: (h === undefined || h === null) ? null : this.nz(h.baselineBalancedLow),
      hrvB2: (h === undefined || h === null) ? null : this.nz(h.baselineBalancedUpper)
    };
    DeviceStore.setCardNet(getContext(this).filesDir);
    DeviceStore.setCardCache(getContext(this).filesDir, last.tsb, last.ctl, last.atl, '', extra);
  }

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

      this.lastTrend = last;
      {
        let wt = 0;
        const pts = t.points;
        for (let i = Math.max(0, pts.length - 7); i < pts.length; i++) {
          const one = pts[i].tss;
          wt = wt + (one === null ? 0 : one);
        }
        this.weekTss = wt;
      }

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
              Button('重试').fontSize(13).margin({ top: 8 }).onClick(() => { this.loadAll(); })
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
