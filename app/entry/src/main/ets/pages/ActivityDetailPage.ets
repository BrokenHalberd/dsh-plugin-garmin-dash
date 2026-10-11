import { router } from '@kit.ArkUI';
import { ApiClient } from '../service/ApiClient';
import { DeviceStore } from '../service/DeviceStore';
import { Activity, ActivityDetail } from '../model/Types';
import { Fmt } from '../util/Format';
import { Theme } from '../util/Theme';
import { common } from '@kit.AbilityKit';
/** 完整详情：基础字段 + 功率曲线（1s~5h）+ 功率/心率区间 */
interface DetailFull extends ActivityDetail {
  maxAvgPower_1?: number;
  maxAvgPower_2?: number;
  maxAvgPower_5?: number;
  maxAvgPower_10?: number;
  maxAvgPower_20?: number;
  maxAvgPower_30?: number;
  maxAvgPower_60?: number;
  maxAvgPower_120?: number;
  maxAvgPower_300?: number;
  maxAvgPower_600?: number;
  maxAvgPower_1200?: number;
  maxAvgPower_1800?: number;
  maxAvgPower_3600?: number;
  maxAvgPower_7200?: number;
  maxAvgPower_18000?: number;
  powerTimeInZone_1?: number;
  powerTimeInZone_2?: number;
  powerTimeInZone_3?: number;
  powerTimeInZone_4?: number;
  powerTimeInZone_5?: number;
  powerTimeInZone_6?: number;
  powerTimeInZone_7?: number;
  hrTimeInZone_1?: number;
  hrTimeInZone_2?: number;
  hrTimeInZone_3?: number;
  hrTimeInZone_4?: number;
  hrTimeInZone_5?: number;
  normPower: number | null;
  avgPower: number | null;
  trainingStressScore: number | null;
  durationSeconds: number | null;
}
/** 近 90 天最佳曲线（按本页曲线顺序点数） */
interface CurveBest {
  pts: number[];
  count: number;
  eftp: number | null;
}
@Entry
@Component
struct ActivityDetailPage {
  @State detail: DetailFull | null = null;
  @State loading: boolean = true;
  @State err: string = '';
  /** 系统深浅色：Canvas 取色用 */
  @State dark: boolean = false;
  @State staleNote: string = '';
  // ── 曲线对比与派生指标（Intervals.icu 风格）──
  @State bestCurve: number[] = [];
  @State cmpCount: number = 0;
  @State cmpLoading: boolean = false;
  @State cmpErr: string = '';
  @State cmpReady: boolean = false;
  @State eftpBest: number | null = null;
  private cmpSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private cmpCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.cmpSettings);
  @StorageProp('topRectHeight') topInset: number = 0;
  @StorageProp('bottomRectHeight') bottomInset: number = 0;
  private activityId: number = 0;

  /** 系统字体缩放（无障碍字号） */
  private fontScale: number = 1;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  aboutToAppear(): void {
    this.dark = Theme.isDark(getContext(this) as common.UIAbilityContext);
    // 跟随系统字体缩放（无障碍字号）：Canvas 文字不会自动继承，需手动读取
    try {
      const cfg = (getContext(this) as common.UIAbilityContext).config;
      this.fontScale = cfg.fontSizeScale !== undefined && cfg.fontSizeScale > 0 ? cfg.fontSizeScale : 1;
    } catch (e) {
      this.fontScale = 1;
    }
    const params = router.getParams() as Record<string, number>;
    if (params !== null && params !== undefined) {
      this.activityId = params.id as number;
    }
    this.load();
  }
  private load(): void {
    if (this.activityId === 0) {
      this.err = '缺少活动 ID';
      this.loading = false;
      return;
    }
    this.loading = true;
    const key = 'activity:' + this.activityId;
    ApiClient.getActivityDetail(this.activityId)
      .then((d: ActivityDetail) => {
        this.detail = d as DetailFull;
        this.loading = false;
        this.err = '';
        this.staleNote = '';
        DeviceStore.cachePut(key, JSON.stringify(d));
        this.drawCurve();
      })
      .catch((e: Object) => {
        this.loading = false;
        const cached = DeviceStore.cacheGet(key);
        if (cached.length > 0) {
          this.detail = JSON.parse(cached) as DetailFull;
          this.staleNote = '离线数据 · ' + Fmt.ago(DeviceStore.cacheAge(key));
          this.drawCurve();
        } else {
          this.err = ApiClient.friendly(e);
        }
      });
  }
  /** 功率曲线：横轴对数（1s → 5h） */
  private curvePoints(): number[] {
    const d = this.detail;
    if (d === null) {
      return [];
    }
    const keys: number[] = [1, 2, 5, 10, 20, 30, 60, 120, 300, 600, 1200, 1800, 3600, 7200, 18000];
    const vals: number[] = [];
    for (let i = 0; i < keys.length; i++) {
      vals.push(this.curveValue(keys[i]));
    }
    return vals;
  }
  private curveValue(sec: number): number {
    const d = this.detail;
    if (d === null) {
      return 0;
    }
    let v: number | undefined = undefined;
    if (sec === 1) { v = d.maxAvgPower_1; }
    else if (sec === 2) { v = d.maxAvgPower_2; }
    else if (sec === 5) { v = d.maxAvgPower_5; }
    else if (sec === 10) { v = d.maxAvgPower_10; }
    else if (sec === 20) { v = d.maxAvgPower_20; }
    else if (sec === 30) { v = d.maxAvgPower_30; }
    else if (sec === 60) { v = d.maxAvgPower_60; }
    else if (sec === 120) { v = d.maxAvgPower_120; }
    else if (sec === 300) { v = d.maxAvgPower_300; }
    else if (sec === 600) { v = d.maxAvgPower_600; }
    else if (sec === 1200) { v = d.maxAvgPower_1200; }
    else if (sec === 1800) { v = d.maxAvgPower_1800; }
    else if (sec === 3600) { v = d.maxAvgPower_3600; }
    else if (sec === 7200) { v = d.maxAvgPower_7200; }
    else { v = d.maxAvgPower_18000; }
    return v === undefined || v === null ? 0 : v;
  }
  private drawCurve(): void {
    const vals = this.curvePoints();
    if (vals.length === 0) {
      return;
    }
    const w = this.ctx.width;
    const h = this.ctx.height;
    const padL = Math.round(this.labelSize(w) * 2.6) + 4;
    const padR = 8;
    const padT = 12;
    const padB = this.labelSize(w) + 12;
    const plotW = w - padL - padR;
    const plotH = h - padT - padB;
    this.ctx.clearRect(0, 0, w, h);
    let max = 1;
    for (let i = 0; i < vals.length; i++) {
      if (vals[i] > max) {
        max = vals[i];
      }
    }
    max = max * 1.1;
    const secs: number[] = [1, 2, 5, 10, 20, 30, 60, 120, 300, 600, 1200, 1800, 3600, 7200, 18000];
    const logMin = Math.log(1);
    const logMax = Math.log(18000);
    const xOf = (sec: number): number => padL + ((Math.log(sec) - logMin) / (logMax - logMin)) * plotW;
    const yOf = (v: number): number => padT + plotH - (v / max) * plotH;
    // 网格 + y 刻度
    this.ctx.font = this.labelSize(this.ctx.width) + 'px sans-serif';
    for (let g = 0; g <= 4; g++) {
      const v = (max * g) / 4;
      const y = yOf(v);
      this.ctx.strokeStyle = Theme.grid(this.dark);
      this.ctx.lineWidth = 1;
      this.ctx.beginPath();
      this.ctx.moveTo(padL, y);
      this.ctx.lineTo(w - padR, y);
      this.ctx.stroke();
      this.ctx.fillStyle = Theme.axis(this.dark);
      this.ctx.fillText('' + Math.round(v), 2, y + 3);
    }
    // 曲线
    this.ctx.strokeStyle = Theme.ctl(this.dark);
    this.ctx.lineWidth = 2.2;
    this.ctx.beginPath();
    for (let i = 0; i < secs.length; i++) {
      const x = xOf(secs[i]);
      const y = yOf(vals[i]);
      if (i === 0) {
        this.ctx.moveTo(x, y);
      } else {
        this.ctx.lineTo(x, y);
      }
    }
    this.ctx.stroke();
    // 数据点
    for (let i = 0; i < secs.length; i++) {
      this.ctx.beginPath();
      this.ctx.arc(xOf(secs[i]), yOf(vals[i]), 2.4, 0, Math.PI * 2);
      this.ctx.fillStyle = Theme.ctl(this.dark);
      this.ctx.fill();
    }
    // x 轴标签：1s / 10s / 1m / 5m / 20m / 1h / 5h
    const marks: number[] = [1, 10, 60, 300, 1200, 3600, 18000];
    const labels: string[] = ['1s', '10s', '1m', '5m', '20m', '1h', '5h'];
    this.ctx.fillStyle = Theme.axis(this.dark);
    for (let i = 0; i < marks.length; i++) {
      this.ctx.fillText(labels[i], xOf(marks[i]) - 6, h - 6);
    }
    // 峰值标注
    let bestIdx = 0;
    for (let i = 0; i < vals.length; i++) {
      if (vals[i] === max / 1.1) {
        bestIdx = i;
        break;
      }
    }
    this.ctx.fillStyle = Theme.text(this.dark);
    this.ctx.font = '10px sans-serif';
    this.ctx.fillText('峰值 ' + Math.round(vals[bestIdx]) + ' W', padL + 2, padT + 10);
  }
  @Builder
  row(label: string, value: string) {
    Row() {
      Text(label).fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
      Text(value).fontSize(13).fontWeight(FontWeight.Medium)
    }
    .width('100%').padding({ top: 7, bottom: 7 })
  }
  @Builder
  zoneBar(label: string, seconds: number, maxSeconds: number, color: ResourceColor) {
    Row() {
      Text(label).fontSize(11).fontColor($r('app.color.text_secondary')).width(30)
      Stack({ alignContent: Alignment.Start }) {
        Row().width('100%').height(14).backgroundColor($r('app.color.chip_background')).borderRadius(7)
        Row().width((maxSeconds > 0 ? Math.max(2, (seconds / maxSeconds) * 100) : 2) + '%')
          .height(14).backgroundColor(color).borderRadius(7)
      }
      .layoutWeight(1)
      Text(Fmt.duration(seconds)).fontSize(11).fontColor($r('app.color.text_secondary')).width(56)
        .textAlign(TextAlign.End)
    }
    .width('100%').margin({ top: 5 })
  }
  private z(i: number): number {
    const d = this.detail;
    if (d === null) {
      return 0;
    }
    let v: number | undefined = undefined;
    if (i === 1) { v = d.powerTimeInZone_1; }
    else if (i === 2) { v = d.powerTimeInZone_2; }
    else if (i === 3) { v = d.powerTimeInZone_3; }
    else if (i === 4) { v = d.powerTimeInZone_4; }
    else if (i === 5) { v = d.powerTimeInZone_5; }
    else if (i === 6) { v = d.powerTimeInZone_6; }
    else { v = d.powerTimeInZone_7; }
    return v === undefined || v === null ? 0 : v;
  }
  private hz(i: number): number {
    const d = this.detail;
    if (d === null) {
      return 0;
    }
    let v: number | undefined = undefined;
    if (i === 1) { v = d.hrTimeInZone_1; }
    else if (i === 2) { v = d.hrTimeInZone_2; }
    else if (i === 3) { v = d.hrTimeInZone_3; }
    else if (i === 4) { v = d.hrTimeInZone_4; }
    else { v = d.hrTimeInZone_5; }
    return v === undefined || v === null ? 0 : v;
  }
  private zoneMax(power: boolean): number {
    let m = 1;
    const n = power ? 7 : 5;
    for (let i = 1; i <= n; i++) {
      const v = power ? this.z(i) : this.hz(i);
      if (v > m) {
        m = v;
      }
    }
    return m;
  }
  private hasPowerZones(): boolean {
    return this.zoneMax(true) > 1;
  }
  private hasHrZones(): boolean {
    return this.zoneMax(false) > 1;
  }
  private hasCurve(): boolean {
    const d = this.detail;
    if (d === null) {
      return false;
    }
    return d.maxAvgPower_60 !== undefined && d.maxAvgPower_60 !== null;
  }
// ── 派生指标（全部由现有详情数据现算）──

  /** 本次骑行的 20 分钟最佳功率推算 eFTP（单次只能给出下限） */
  private eftpFromRide(): number | null {
    const d = this.detail;
    if (d === null) return null;
    const v = d.maxAvgPower_1200;
    if (v === undefined || v === null || v <= 0) return null;
    return Math.round(v * 0.95);
  }

  /** 变异性指数 VI = NP / 平均功率（越接近 1 越平稳） */
  private vi(): number | null {
    const d = this.detail;
    if (d === null) return null;
    const np = d.normPower;
    const ap = d.avgPower;
    if (np === undefined || np === null || ap === undefined || ap === null || ap <= 0) return null;
    return Math.round((np / ap) * 100) / 100;
  }

  /** 训练密度 TSS/小时 */
  private tssPerHour(): number | null {
    const d = this.detail;
    if (d === null) return null;
    const tss = d.trainingStressScore;
    const sec = d.durationSeconds;
    if (tss === undefined || tss === null || sec === undefined || sec === null || sec <= 600) return null;
    return Math.round(tss / (sec / 3600));
  }

  /** 任意详情对象的曲线取值（键名形如 maxAvgPower_<秒>） */
  private curveValueOf(d: DetailFull, sec: number): number {
    let v: number | undefined;
    if (sec === 1) v = d.maxAvgPower_1;
    else if (sec === 2) v = d.maxAvgPower_2;
    else if (sec === 5) v = d.maxAvgPower_5;
    else if (sec === 10) v = d.maxAvgPower_10;
    else if (sec === 20) v = d.maxAvgPower_20;
    else if (sec === 30) v = d.maxAvgPower_30;
    else if (sec === 60) v = d.maxAvgPower_60;
    else if (sec === 120) v = d.maxAvgPower_120;
    else if (sec === 300) v = d.maxAvgPower_300;
    else if (sec === 600) v = d.maxAvgPower_600;
    else if (sec === 1200) v = d.maxAvgPower_1200;
    else if (sec === 1800) v = d.maxAvgPower_1800;
    else if (sec === 3600) v = d.maxAvgPower_3600;
    else if (sec === 7200) v = d.maxAvgPower_7200;
    else if (sec === 18000) v = d.maxAvgPower_18000;
    return v === undefined || v === null ? 0 : v;
  }

  /** 由某条曲线推算 eFTP（20 分钟 × 0.95） */
  private eftpOf(pts: number[]): number | null {
    const secs = this.curvePoints();
    for (let i = 0; i < secs.length; i++) {
      if (secs[i] === 1200 && i < pts.length && pts[i] > 0) {
        return Math.round(pts[i] * 0.95);
      }
    }
    return null;
  }

  /** 应用已缓存的对比结果 */
  private applyComparison(json: string): void {
    try {
      const cb = JSON.parse(json) as CurveBest;
      if (cb.pts.length > 0) {
        this.bestCurve = cb.pts;
        this.cmpCount = cb.count;
        this.eftpBest = cb.eftp;
        this.cmpReady = true;
      }
    } catch (e) {
      DeviceStore.cachePut('curveBest:90', '');
    }
  }

  /** 载入「近 90 天最佳曲线」（按钮触发；命中缓存则不请求） */
  private loadComparison(): void {
    if (this.cmpLoading) return;
    const key = 'curveBest:90';
    const cached = DeviceStore.cacheGet(key);
    if (cached.length > 10 && DeviceStore.cacheAge(key) < 86400000) {
      this.applyComparison(cached);
      return;
    }
    if (!DeviceStore.isPaired()) { this.cmpErr = '尚未配对'; return; }
    this.cmpLoading = true;
    this.cmpErr = '';
    const secs = this.curvePoints();
    const cutoff = Fmt.shiftDays(Fmt.today(), -90);
    ApiClient.getActivities(30, 0)
      .then((list: Activity[]) => {
        const picks: number[] = [];
        for (let i = 0; i < list.length && picks.length < 10; i++) {
          const a = list[i];
          const d10 = a.startTime.length >= 10 ? a.startTime.substring(0, 10) : '';
          if (d10 < cutoff) continue;
          if (a.normPower === null || a.avgPower === null) continue;
          picks.push(a.id);
        }
        if (picks.length === 0) {
          this.cmpLoading = false;
          this.cmpErr = '近 90 天没有带功率的活动';
          return;
        }
        const best: number[] = [];
        for (let k = 0; k < secs.length; k++) best.push(0);
        let idx = 0;
        const step = () => {
          if (idx >= picks.length) {
            const payload: CurveBest = { pts: best, count: picks.length, eftp: this.eftpOf(best) };
            DeviceStore.cachePut(key, JSON.stringify(payload));
            this.bestCurve = best;
            this.cmpCount = picks.length;
            this.eftpBest = payload.eftp;
            this.cmpReady = true;
            this.cmpLoading = false;
            this.drawComparison();
            return;
          }
          const id = picks[idx];
          idx++;
          ApiClient.getActivityDetail(id)
            .then((d: ActivityDetail) => {
              const full = d as DetailFull;
              for (let k = 0; k < secs.length; k++) {
                const v = this.curveValueOf(full, secs[k]);
                if (v > best[k]) best[k] = v;
              }
            })
            .catch(() => { })
            .then(() => { step(); });
        };
        step();
      })
      .catch((e: Object) => {
        this.cmpLoading = false;
        this.cmpErr = ApiClient.friendly(e);
      });
  }

  /** 画「本次 vs 近 90 天最佳」对比图 */
  private drawComparison(): void {
    const d = this.detail;
    if (d === null || this.bestCurve.length === 0) return;
    const w = this.cmpCtx.width;
    const h = this.cmpCtx.height;
    if (w <= 0 || h <= 0) return;
    const secs = this.curvePoints();
    const mine: number[] = [];
    let max = 10;
    for (let i = 0; i < secs.length; i++) {
      const v = this.curveValue(secs[i]);
      mine.push(v);
      if (v > max) max = v;
      if (i < this.bestCurve.length && this.bestCurve[i] > max) max = this.bestCurve[i];
    }
    const padL = Math.round(this.labelSize(w) * 2.6) + 4;
    const padR = 8;
    const padT = 12;
    const padB = this.labelSize(w) + 12;
    const iw = w - padL - padR;
    const ih = h - padT - padB;
    this.cmpCtx.clearRect(0, 0, w, h);
    // 网格 + y 轴
    this.cmpCtx.strokeStyle = Theme.grid(this.dark);
    this.cmpCtx.lineWidth = 1;
    this.cmpCtx.fillStyle = Theme.axis(this.dark);
    this.cmpCtx.font = this.labelSize(this.cmpCtx.width) + 'px sans-serif';
    for (let g = 0; g <= 2; g++) {
      const val = Math.round((max / 2) * g);
      const yy = padT + ih - (val / max) * ih;
      this.cmpCtx.beginPath();
      this.cmpCtx.moveTo(padL, yy);
      this.cmpCtx.lineTo(padL + iw, yy);
      this.cmpCtx.stroke();
      this.cmpCtx.fillText(String(val), 4, yy + 4);
    }
    // 对数横轴：1s → 5h
    const xOf = (i: number) => {
      const t = Math.log(secs[i]) / Math.log(18000);
      return padL + t * iw;
    };
    const yOf = (v: number) => padT + ih - (v / max) * ih;
    const path = (pts: number[], color: string, width: number) => {
      this.cmpCtx.strokeStyle = color;
      this.cmpCtx.lineWidth = width;
      this.cmpCtx.beginPath();
      for (let i = 0; i < secs.length && i < pts.length; i++) {
        if (pts[i] <= 0) continue;
        const px = xOf(i);
        const py = yOf(pts[i]);
        if (i === 0) this.cmpCtx.moveTo(px, py);
        else this.cmpCtx.lineTo(px, py);
      }
      this.cmpCtx.stroke();
    };
    path(this.bestCurve, '#8E5BD9', 1.6);
    path(mine, Theme.ctl(this.dark), 2.4);
    // x 轴标注
    this.cmpCtx.fillStyle = Theme.axis(this.dark);
    const marks = [60, 300, 1200, 3600];
    for (let i = 0; i < secs.length; i++) {
      for (let m = 0; m < marks.length; m++) {
        if (secs[i] === marks[m]) {
          const label = marks[m] >= 3600 ? (marks[m] / 3600) + 'h' : (marks[m] / 60) + 'm';
          this.cmpCtx.fillText(label, xOf(i) - 8, h - 7);
        }
      }
    }
  }
  /** 画布字号：以画布宽度为基准（图越大字越大），再乘系统字体缩放 */
  private labelSize(canvasW: number): number {
    let base = Math.round(canvasW / 26);
    if (base < 11) base = 11;
    if (base > 20) base = 20;
    const scaled = Math.round(base * this.fontScale);
    return scaled < 10 ? 10 : scaled;
  }

  build() {
    Column() {
      Row() {
        Button('‹ 返回').fontSize(13).height(32)
          .backgroundColor($r('app.color.chip_background')).fontColor(Theme.text(this.dark))
          .onClick(() => { router.back(); })
        Blank()
        if (this.detail !== null) {
          Text(Fmt.sportName(this.detail.activityName.length > 0 ? '' : '')).fontSize(0)
        }
      }
      .width('100%').padding({ top: 8 + this.topInset, bottom: 8 })
      if (this.loading) {
        Row() {
          LoadingProgress().width(22).height(22)
          Text('读取中…').fontSize(13).fontColor(Theme.tsb(this.dark)).margin({ left: 8 })
        }.padding(16)
      }
      if (this.err.length > 0) {
        Column() {
          Text(this.err).fontSize(13).fontColor($r('app.color.danger'))
          Button('重试').fontSize(13).margin({ top: 8 }).onClick(() => { this.load(); })
        }.padding(16)
      }
      if (this.detail !== null) {
        Scroll() {
          Column() {
            if (this.staleNote.length > 0) {
              Text(this.staleNote).fontSize(11).fontColor($r('app.color.banner_text'))
                .width('100%').padding(8).backgroundColor($r('app.color.banner_background')).borderRadius(8).margin({ bottom: 8 })
            }
            Text(this.detail.activityName).fontSize(19).fontWeight(FontWeight.Bold).width('100%')
            Text(Fmt.shortTime(this.detail.startTimeLocal)).fontSize(12).fontColor(Theme.tsb(this.dark))
              .width('100%').margin({ top: 2, bottom: 10 })
            Row() {
              Column() {
                Text(Fmt.km(this.detail.distance)).fontSize(24).fontWeight(FontWeight.Bold)
                Text('距离').fontSize(10).fontColor(Theme.tsb(this.dark))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Column() {
                Text(Fmt.duration(this.detail.duration)).fontSize(24).fontWeight(FontWeight.Bold)
                Text('时长').fontSize(10).fontColor(Theme.tsb(this.dark))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Column() {
                Text(Fmt.int(this.detail.trainingStressScore)).fontSize(24).fontWeight(FontWeight.Bold).fontColor(Theme.ctl(this.dark))
                Text('TSS').fontSize(10).fontColor(Theme.tsb(this.dark))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            }
            .width('100%').padding(14).backgroundColor($r('app.color.card_background_blur')).border({ width: 1, color: $r('app.color.card_border_highlight') }).borderRadius(14)
            if (this.hasCurve()) {
              Column() {
                Text('功率曲线（最佳平均功率）').fontSize(14).fontWeight(FontWeight.Medium).width('100%')
                Canvas(this.ctx)
                  .width('100%')
                  .height(180)
                  .margin({ top: 6 })
                  .onReady(() => { this.drawCurve(); })
              }
              .padding(14).width('100%').backgroundColor($r('app.color.card_background_blur')).border({ width: 1, color: $r('app.color.card_border_highlight') }).borderRadius(14).margin({ top: 12 })
            }
            Column() {
              this.row('平均功率', Fmt.num(this.detail.avgPower, ' W'))
              this.row('标准化功率 NP', Fmt.num(this.detail.normPower, ' W'))
              this.row('最大功率', Fmt.num(this.detail.maxPower, ' W'))
              this.row('强度因子 IF', this.detail.intensityFactor === null ? '--' : this.detail.intensityFactor.toFixed(3))
              this.row('训练负荷', Fmt.int(this.detail.activityTrainingLoad))
              this.row('平均心率', Fmt.num(this.detail.averageHR, ' bpm'))
              this.row('最大心率', Fmt.num(this.detail.maxHR, ' bpm'))
              this.row('左右平衡', this.detail.avgLeftBalance === null ? '--' : this.detail.avgLeftBalance.toFixed(1) + ' % 左')
              this.row('踏频', Fmt.num(this.detail.averageBikingCadenceInRevPerMinute, ' rpm'))
              this.row('爬升', Fmt.num(this.detail.elevationGain, ' m'))
              this.row('有氧/无氧效果', Fmt.num1(this.detail.aerobicTrainingEffect, '') + ' / ' + Fmt.num1(this.detail.anaerobicTrainingEffect, ''))
              this.row('Body Battery 变化', Fmt.int(this.detail.differenceBodyBattery))
              this.row('VO2max', Fmt.int(this.detail.vO2MaxValue))
            }
            .padding(14).width('100%').backgroundColor($r('app.color.card_background_blur')).border({ width: 1, color: $r('app.color.card_border_highlight') }).borderRadius(14).margin({ top: 12 })
            if (this.hasPowerZones()) {
              Column() {
                Text('功率区间时长').fontSize(14).fontWeight(FontWeight.Medium).width('100%')
                this.zoneBar('Z1', this.z(1), this.zoneMax(true), '#9DC3F5')
                this.zoneBar('Z2', this.z(2), this.zoneMax(true), '#6FA8EE')
                this.zoneBar('Z3', this.z(3), this.zoneMax(true), '#3D86E0')
                this.zoneBar('Z4', this.z(4), this.zoneMax(true), '#F2A93B')
                this.zoneBar('Z5', this.z(5), this.zoneMax(true), '#EE8B2E')
                this.zoneBar('Z6', this.z(6), this.zoneMax(true), '#E2603B')
                this.zoneBar('Z7', this.z(7), this.zoneMax(true), $r('app.color.danger'))
              }
              .padding(14).width('100%').backgroundColor($r('app.color.card_background_blur')).border({ width: 1, color: $r('app.color.card_border_highlight') }).borderRadius(14).margin({ top: 12 })
            }
            if (this.hasHrZones()) {
              Column() {
                Text('心率区间时长').fontSize(14).fontWeight(FontWeight.Medium).width('100%')
                this.zoneBar('Z1', this.hz(1), this.zoneMax(false), '#A8D5BA')
                this.zoneBar('Z2', this.hz(2), this.zoneMax(false), '#7BC49A')
                this.zoneBar('Z3', this.hz(3), this.zoneMax(false), '#F2C94C')
                this.zoneBar('Z4', this.hz(4), this.zoneMax(false), '#EE8B2E')
                this.zoneBar('Z5', this.hz(5), this.zoneMax(false), $r('app.color.danger'))
              }
              .padding(14).width('100%').backgroundColor($r('app.color.card_background_blur')).border({ width: 1, color: $r('app.color.card_border_highlight') }).borderRadius(14).margin({ top: 12 })
            }
// ── 分析：派生指标 + 曲线对比（Intervals.icu 风格）──
            if (this.detail !== null) {
              Column() {
                Row() {
                  Text('训练分析').fontSize(13).fontWeight(FontWeight.Medium)
                  Blank()
                  Text('由本次数据现算').fontSize(10).fontColor($r('app.color.text_hint'))
                }
                .width('100%')
                Row() {
                  Column() {
                    Text('eFTP(本次20min)').fontSize(10).fontColor($r('app.color.text_tertiary'))
                    Text(this.eftpFromRide() === null ? '--' : this.eftpFromRide() + ' W')
                      .fontSize(17).fontWeight(FontWeight.Bold)
                  }
                  .alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Column() {
                    Text('eFTP(90天最佳)').fontSize(10).fontColor($r('app.color.text_tertiary'))
                    Text(this.eftpBest === null ? '待加载' : this.eftpBest + ' W')
                      .fontSize(17).fontWeight(FontWeight.Bold).fontColor($r('app.color.accent'))
                  }
                  .alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Column() {
                    Text('变异性 VI').fontSize(10).fontColor($r('app.color.text_tertiary'))
                    Text(this.vi() === null ? '--' : '' + this.vi())
                      .fontSize(17).fontWeight(FontWeight.Bold)
                  }
                  .alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Column() {
                    Text('TSS/小时').fontSize(10).fontColor($r('app.color.text_tertiary'))
                    Text(this.tssPerHour() === null ? '--' : '' + this.tssPerHour())
                      .fontSize(17).fontWeight(FontWeight.Bold)
                  }
                  .alignItems(HorizontalAlign.Start).layoutWeight(1)
                }
                .width('100%').margin({ top: 8 })
                Text('VI = NP/平均功率：<1.05 平稳（计时/稳定输出），>1.10 起伏大（间歇/爬坡/团练）')
                  .fontSize(9).fontColor($r('app.color.text_hint')).width('100%').margin({ top: 6 })

                if (this.cmpReady) {
                  Canvas(this.cmpCtx)
                    .width('100%').height(150).margin({ top: 10 })
                    .onReady(() => { this.drawComparison(); })
                  Row({ space: 12 }) {
                    Row() {
                      Row().width(10).height(2).backgroundColor(Theme.ctl(this.dark))
                      Text(' 本次').fontSize(10).fontColor($r('app.color.text_tertiary'))
                    }
                    Row() {
                      Row().width(10).height(2).backgroundColor('#8E5BD9')
                      Text(' 近90天最佳（' + this.cmpCount + ' 次）').fontSize(10).fontColor($r('app.color.text_tertiary'))
                    }
                  }
                  .width('100%').margin({ top: 6 })
                } else {
                  Row() {
                    Text(this.cmpErr.length > 0 ? this.cmpErr : '对比近 90 天最佳曲线（最多取 10 次带功率的活动）')
                      .fontSize(11).fontColor($r('app.color.text_secondary')).layoutWeight(1)
                    Button(this.cmpLoading ? '加载中…' : '开始对比')
                      .fontSize(12).height(30)
                      .backgroundColor($r('app.color.accent')).fontColor($r('app.color.accent_on'))
                      .enabled(!this.cmpLoading)
                      .onClick(() => { this.loadComparison(); })
                  }
                  .width('100%').margin({ top: 10 })
                }
              }
              .padding(14).width('100%').margin({ top: 10 })
              .backgroundColor($r('app.color.card_background_blur'))
              .border({ width: 1, color: $r('app.color.card_border_highlight') })
              .borderRadius(14)
            }
            Row().height(96 + this.bottomInset)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.background'))
  }
}
