import { common , errorManager } from '@kit.AbilityKit';
import { CardSync } from '../service/CardSync';
import { ApiClient, BundleResult } from '../service/ApiClient';
import { StatCard, StatCardSize, CARD_GAP } from '../components/StatCard';
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
  @State crashText: string = '';
  @State lastCardUpdated: string = '';

  aboutToAppear(): void {
    // 读上次崩溃日志；有则显示在首页顶部（红色）
    try {
      const old = DeviceStore.readCrash(getContext(this).filesDir);
      if (old.length > 0) {
        // 只有真正的 JS 崩溃（[CRASH]）才显示；纯 [STEP] 面包屑属于被强杀，不算报错 ✓
        const ci = old.indexOf('[CRASH]');
        if (ci >= 0) {
          this.crashText = old.substring(ci);
          setTimeout(() => {
            try {
              this.crashText = '';
            } catch (e0) {
            }
          }, 12000);
        }
        // 无论显示与否都清空（不再积累 ✓ 不用手点 ✓）
        DeviceStore.clearCrash(getContext(this).filesDir);
      }
    } catch (e0) {
    }
    // 全局 JS 崩溃钩子：把栈写进文件，下次打开能看到
    try {
      errorManager.on('globalErrorOccurred', (err: errorManager.GlobalError) => {
        try {
          DeviceStore.logCrash(getContext(this).filesDir,
            '[CRASH] ' + err.message);
        } catch (e9) {
        }
      });
    } catch (e8) {
    }
    // 先应用卡片侧可能更新的数据（反向同步 ✓）
    this.syncFromCard();
    // 一次聚合请求拿全部（失败自动回退到分接口）
    this.loadAll();
  }

  onTick(): void {
    // 先看卡片是否已刷新过（反向同步 ✓），再拉一次最新
    this.syncFromCard();
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

  private calText(): string {
    const s0 = this.summary;
    return s0 === null || s0.calories === undefined ? '--' : Fmt.int(s0.calories);
  }

  private stressText(): string {
    const s0 = this.summary;
    return s0 === null || s0.stress === undefined ? '--' : Fmt.int(s0.stress);
  }

  private stressTextSub(): string {
    const s0 = this.summary;
    if (s0 === null || s0.stress === undefined || s0.stress === null) {
      return '';
    }
    const v = s0.stress;
    if (v < 26) {
      return '放松';
    }
    if (v < 51) {
      return '偏低';
    }
    if (v < 76) {
      return '中等';
    }
    return '偏高';
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
      }
    .padding(14)
    .width('100%')
    .backgroundColor($r('app.color.card_background_blur'))
    .border({ width: 1, color: $r('app.color.card_border_highlight') })
    .borderRadius(14)
  }

  /** 载入今日表单：优先复用趋势页缓存，其次拉 30 天窗口 */

  /** 载入今日 HRV（1 小时缓存） */
  /** 载入当日身体电量（后端直连端点，缓存 1 小时） */
  /** 身体电量副标题：显示当日最低值 */
  /** 卡片用：电量充放字符串（+74/-50）；无数据显示空串 */
  private bbChgPlain(): string {
    const b0 = this.bb;
    if (b0 === null || b0 === undefined) {
      return '';
    }
    const ch = b0.charged;
    const dr = b0.drained;
    if ((ch === null || ch === undefined) && (dr === null || dr === undefined)) {
      return '';
    }
    const plus = (ch === null || ch === undefined) ? '' : ('+' + ch);
    const minus = (dr === null || dr === undefined) ? '' : ('-' + dr);
    return plus + (plus.length > 0 && minus.length > 0 ? ' / ' : '') + minus;
  }

  private bbSubText(): string {
    // 电量变化（Garmin 风格）：+74 / -50
    const b0 = this.bb;
    if (b0 !== null && b0 !== undefined) {
      const ch = b0.charged;
      const dr = b0.drained;
      if (ch !== undefined && dr !== undefined && (ch !== null || dr !== null)) {
        const plus = ch === null || ch === undefined ? '--' : ('+' + ch);
        const minus = dr === null || dr === undefined ? '--' : ('-' + dr);
        return plus + ' / ' + minus;
      }
    }
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
    const st1: string | null | undefined = this.hrv === null ? null : this.hrv.status;
    const raw = (st1 === null || st1 === undefined) ? '' : st1.toUpperCase();
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
    const st2: string | null | undefined = h.status;
    const raw = (st2 === null || st2 === undefined) ? '' : st2.toUpperCase();
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
    .margin({ bottom: CARD_GAP })
    .backgroundColor(COLOR_CARD_BG)
    .border({ width: 1, color: COLOR_CARD_BORDER })
    .borderRadius(14)
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
  /**
   * 一次请求拿全部。任何异常都不允许冒泡（会闪退 ✗），一律回退到分接口。
   */
  /**
   * 两段式加载：
   * 第一段 parts=home（trend/summary/hrv/bodyBattery，约 3.5s）→ 立刻渲染首页 ✓
   * 第二段 parts=extra（curve/hrvRange/activities，约 8s）→ 后台补齐并并入缓存 ✓ 不挡首屏
   */
  private watchdogSeq: number = 0;

  /**
   * 反向同步：卡片自己刷新过（写了 card_cache.json ✓），App 这边也跟上 ✓
   * 只更新卡片覆盖到的字段，不覆盖 App 独有的数据 ✓
   */
  private syncFromCard(): void {
    try {
      const c = DeviceStore.getCardCache(getContext(this).filesDir);
      if (c.updated === undefined || c.updated === null || c.updated.length === 0) {
        return;
      }
      if (c.updated === this.lastCardUpdated) {
        return;
      }
      const n1 = (v: string): number | null => {
        if (v === undefined || v === null || v.length === 0) {
          return null;
        }
        const x = Number(v);
        return Number.isFinite(x) ? x : null;
      };
      const tsb = n1(c.tsb);
      const ctl = n1(c.ctl);
      const atl = n1(c.atl);
      if (tsb !== null) {
        this.tsb = tsb;
      }
      if (ctl !== null) {
        this.ctl = ctl;
      }
      if (atl !== null) {
        this.atl = atl;
      }
      this.lastCardUpdated = c.updated;
    } catch (e) {
    }
  }

  private loadAll(): void {
    try {
      this.loading = true;
      this.refreshing = false;
      // 看门狗：25 秒内无论成功失败，必须结束转圈（绝不无限卡 ✓）
      this.watchdogSeq = this.watchdogSeq + 1;
      const mySeq = this.watchdogSeq;
      setTimeout(() => {
        try {
          if (mySeq === this.watchdogSeq && (this.loading || this.refreshing)) {
            this.loading = false;
            this.refreshing = false;
            this.staleNote = '刷新超时（25 秒），请下拉重试';
          }
        } catch (eW) {
        }
      }, 25000);
      try {
        DeviceStore.logCrash(getContext(this).filesDir, '[STEP] loadAll start date=' + this.date);
      } catch (e00) {
      }
      ApiClient.getBundle(30, this.date, 'home')
        .then((b: BundleResult) => {
          try {
            try {
              DeviceStore.logCrash(getContext(this).filesDir, '[STEP] home arrived');
            } catch (e01) {
            }
            this.applyBundleHome(b);
            // ★ 兜底：home 段没带 summary（后端降级/字段缺失/部分返回）时会静默跳过，
            //   导致卡片区一直转圈且不触发任何回退 —— 此时立刻补走四路老接口
            if (this.summary === null) {
              try {
                DeviceStore.logCrash(getContext(this).filesDir, '[STEP] home 缺少 summary，回退四路老接口');
              } catch (eS) {
              }
              this.fallbackLoad();
            }
            // 首页数据先落缓存（此时只有 home 段）
            try {
              DeviceStore.cachePut('bundle:all', JSON.stringify(b));
            } catch (e0) {
            }
            try {
              this.writeCardCache(b);
            } catch (e2) {
              this.staleNote = '卡片缓存写入失败';
            }
          } catch (e1) {
            this.loading = false;
            this.refreshing = false;
            this.fallbackLoad();
          }
          // 第二段：不等待，后台补慢数据
          this.loadExtra(30, this.date);
        })
        .catch((e: Object) => {
          this.staleNote = '聚合失败，已回退：' + ApiClient.friendly(e);
          this.loading = false;
          this.refreshing = false;
          this.fallbackLoad();
          // 首页失败也尝试后台补（可能只是首页那段超时）
          this.loadExtra(30, this.date);
        });
    } catch (e) {
      this.loading = false;
      this.refreshing = false;
      this.fallbackLoad();
    }
  }

  /** 把 home 段应用到界面 */
  private applyBundleHome(b: BundleResult): void {
    // ★ 关键顺序：summary 必须最先落（卡片区靠它渲染）。
    //   之前 applyTrend 在它前面，趋势一抛异常整段跳过 → summary 永远 null → 卡片不出现。
    if (b.summary !== undefined && b.summary !== null) {
      this.summary = b.summary;
      this.err = '';
      this.staleNote = '';
    }
    // 以下每一项独立 try —— 任何一段失败都不能连累其它段
    try {
      if (b.trend !== undefined && b.trend !== null && b.trend.points !== undefined
        && b.trend.points.length > 0) {
        this.applyTrend(JSON.stringify(b.trend));
      }
    } catch (eT) {
    }
    try {
      if (b.hrv !== undefined && b.hrv !== null) {
        this.hrv = b.hrv;
        this.hrvErr = '';
      }
    } catch (eH) {
    }
    try {
      if (b.bodyBattery !== undefined && b.bodyBattery !== null) {
        this.bb = b.bodyBattery;
      }
    } catch (eB) {
    }
    this.loading = false;
    this.refreshing = false;
    const miss = (b.partial === undefined || b.partial === null) ? 0 : b.partial.length;
    if (miss > 0) {
      this.staleNote = '部分数据缺失：' + b.partial.join('、');
    }
  }

  /** 后台补 slow 段（curve/hrvRange/activities），并入 bundle:all 缓存供其它页秒开 */
  private loadExtra(days: number, date: string): void {
    try {
      try {
        DeviceStore.logCrash(getContext(this).filesDir, '[STEP] loadExtra start');
      } catch (e02) {
      }
      ApiClient.getBundle(90, date, 'extra')
        .then((x: BundleResult) => {
          try {
            const cached = DeviceStore.cacheGet('bundle:all');
            let merged: BundleResult = x;
            if (cached.length > 10) {
              try {
                merged = JSON.parse(cached) as BundleResult;
              } catch (e7) {
              }
            }
            if (x.curve !== undefined) {
              merged.curve = x.curve;
            }
            if (x.hrvRange !== undefined) {
              merged.hrvRange = x.hrvRange;
            }
            if (x.activities !== undefined) {
              merged.activities = x.activities;
            }
            DeviceStore.cachePut('bundle:all', JSON.stringify(merged));
          } catch (e6) {
          }
        })
        .catch((e: Object) => {
        });
    } catch (e) {
    }
  }



  /** 回退到四路老接口（每一步都自带异常保护） */
  private fallbackLoad(): void {
    try {
      this.loadHrv(false);
    } catch (e) {
    }
    try {
      this.loadBb();
    } catch (e) {
    }
    try {
      this.load(false);
    } catch (e) {
    }
    try {
      this.loadForm();
    } catch (e) {
    }
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
    try {
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
      bbChg: this.bbChgPlain(),
      steps: (s === undefined || s === null) ? null : this.nz(s.steps),
      calories: (s === undefined || s === null) ? null : this.nz(s.calories),
      stress: (s === undefined || s === null) ? null : this.nz(s.stress),
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
    // 主动推给桌面卡片：App 刷新完，卡片立刻跟着变 ✓
    try {
      CardSync.pushToCards(getContext(this).filesDir);
    } catch (ePush) {
    }
      } catch (e) {
      // 卡片缓存写入失败绝不影响 App
    }
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
    .margin({ bottom: CARD_GAP })

    .backgroundColor($r('app.color.card_background_blur'))

    .border({ width: 1, color: $r('app.color.card_border_highlight') })

    .borderRadius(14)


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

          if (this.crashText.length > 0) {
            Column() {
              Text('⚠ 上次崩溃日志（点此清空）').fontSize(10).fontColor('#FFFFFF')
              Text(this.crashText).fontSize(8).fontColor('#FFE0E0').maxLines(14)
            }
            .width('100%').padding(8).backgroundColor('#B3261E').borderRadius(6).margin({ bottom: 6 })
            .onClick(() => {
              try {
                DeviceStore.clearCrash(getContext(this).filesDir);
              } catch (e) {
              }
              this.crashText = '';
            })
          }
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
            .padding(16).width('100%')
            .backgroundColor($r('app.color.card_background_blur'))
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
            Grid() {
              GridItem() {
                StatCard({ title: '步数', value: this.stepsText(), unit: '步' })
              }
              GridItem() {
                StatCard({ title: '静息心率', value: this.rhrText(), unit: 'bpm' })
              }
              GridItem() {
                StatCard({ title: '睡眠', value: this.sleepText(), sub: this.sleepScoreText() })
              }
              GridItem() {
                StatCard({
                  title: 'Body Battery',
                  value: this.bbText(),
                  suffix: ' 最高',
                  accent: true,
                  sub: this.bbSubText()
                })
              }
              GridItem() {
                StatCard({ title: '热量', value: this.calText(), unit: 'kcal' })
              }
              GridItem() {
                StatCard({ title: '压力', value: this.stressText(), sub: this.stressTextSub() })
              }
            }
            .columnsTemplate('1fr 1fr')
            .columnsGap(CARD_GAP)
            .rowsGap(CARD_GAP)
            .alignItems(GridItemAlignment.STRETCH)
            .margin({ bottom: CARD_GAP })
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
        .padding({ left: 12, right: 12, bottom: 96 })
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
