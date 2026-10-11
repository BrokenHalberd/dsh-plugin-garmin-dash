import { common } from '@kit.AbilityKit';
import { inputMethod } from '@kit.IMEKit';
import { ApiClient } from '../service/ApiClient';
import { DeviceStore } from '../service/DeviceStore';
import { Activity, ActivityDetail, Summary, Trend, TrendPoint, WeeklyTotal , HrvRange , HrvDay , CurveData } from '../model/Types';
import { Fmt } from '../util/Format';
import { Theme } from '../util/Theme';

/** 带功率曲线的详情（上游返回 maxAvgPower_<秒>，基础接口未声明） */
interface CurveDetail extends ActivityDetail {
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
}

/** 近 90 天最佳曲线缓存体 */
interface CurveBest {
  windowFrom?: string;
  windowTo?: string;
  updatedAt?: string;
  p42: number[];
  p90: number[];
  pall: number[];
  e42: number | null;
  e90: number | null;
  eall: number | null;
  count: number;
  zones: number[];
}

/** 指标卡（按引用传对象 —— 值参不会刷新 @Builder 内部 UI） */
interface MetricCfg {
  label: string;
  value: string;
  hint: string;
  tone: string;
}

/** 面板定义 */
interface PanelDef {
  key: string;
  label: string;
}

/** 恢复缓存体 */
interface RecoveryCache {
  days: string[];
  vals: number[];
}

/** 近 6 周表格行 */
interface WeekRow {
  label: string;
  tss: number;
  ctl: number;
  atl: number;
  tsb: number;
}

const DUR_SECS: number[] = [1, 2, 5, 10, 20, 30, 60, 120, 300, 600, 1200, 1800, 3600, 7200, 18000];
const CURVE_NAMES: string[] = ['5s', '1m', '5m', '20m', '1h'];
const TABLE_IDX: number[] = [2, 6, 8, 10, 12];
const DUR_LABELS: string[] = ['1s', '2s', '5s', '10s', '20s', '30s', '1m', '2m', '5m', '10m', '20m', '30m', '1h', '2h', '5h'];
const ZONE_NAMES: string[] = ['Z1 主动恢复', 'Z2 耐力', 'Z3 节奏', 'Z4 阈值', 'Z5 VO2max', 'Z6 无氧', 'Z7 神经'];
const ZONE_COLORS: string[] = ['#8A93A5', '#2FA36B', '#2E9BB5', '#E0A33E', '#D9534F', '#8E5BD9', '#B0476B'];

/** Coggan 功率形态参考（W/kg）：列 = 5秒 / 1分钟 / 5分钟 / FTP */
/** 判定用时长在 15 档曲线中的下标：5s / 1min / 5min / 20min / 60min */
const DUR_IDX_W: number[] = [2, 6, 8, 10, 12];
const DUR_NAMES_W: string[] = ['5s', '1min', '5min', '20min', '60min'];
/** 综合等级权重：20min / 60min / eFTP = 3，5min = 2，1min / 5s = 1 */
const DUR_WEIGHTS_W: number[] = [1, 1, 2, 3, 3];
const EFTP_WEIGHT: number = 3;

const COGGAN_LEVELS: string[] = ['世界级', '专业', 'Cat 1', 'Cat 2', 'Cat 3', 'Cat 4', 'Cat 5', '未训练'];
const COGGAN_WKG: number[][] = [
  [23.5, 11.5, 7.6, 6.4],
  [20.8, 9.7, 6.3, 5.6],
  [18.4, 8.3, 5.7, 5.1],
  [16.6, 7.5, 5.1, 4.6],
  [15.3, 6.9, 4.7, 4.2],
  [13.9, 6.5, 4.3, 3.9],
  [12.4, 5.9, 3.9, 3.6],
  [9.7, 4.7, 3.1, 2.8]
];

const PANELS: PanelDef[] = [
  { key: 'overview', label: '总览' },
  { key: 'curve', label: '功率曲线' },
  { key: 'shape', label: '功率形态' },
  { key: 'fatigue', label: '疲劳形态' },
  { key: 'status', label: '状态管理' },
  { key: 'recovery', label: '健康恢复' },
  { key: 'predict', label: '表现预测器' }
];

/**
 * 数据中心 —— 把趋势页升级为多面板分析中心（对齐 Intervals.icu / BT300 的信息架构）。
 *
 * 数据全部来自现有接口：
 *   · `/trend?days=90`  → CTL/ATL/TSB 序列 + 周汇总
 *   · `/activities`     → 近 90 天带功率的活动清单
 *   · `/activity?id=`   → 逐条取功率曲线（最多 10 条，用于「最佳曲线/功率形态」）
 * 曲线聚合结果缓存 24 小时，避免重复请求。
 */
const COLOR_ACCENT: ResourceColor = $r('app.color.accent');
const COLOR_WARN: ResourceColor = $r('app.color.warn');
const COLOR_DANGER: ResourceColor = $r('app.color.danger');
const COLOR_TERTIARY: ResourceColor = $r('app.color.text_tertiary');
const COLOR_SECONDARY: ResourceColor = $r('app.color.text_secondary');
const COLOR_HINT: ResourceColor = $r('app.color.text_hint');
const COLOR_CHIP: ResourceColor = $r('app.color.chip_background');
const COLOR_CARD_BG: ResourceColor = $r('app.color.card_background_blur');
const COLOR_CARD_BORDER: ResourceColor = $r('app.color.card_border_highlight');
/** 底部选项栏 + 安全区高度：滚到底时用来避开遮挡 */
const BOTTOM_BAR_PAD: number = 104;

@Component
export struct TrendView {
  @Prop @Watch('onTick') tick: number = 0;
  @State trend: Trend | null = null;
  @State panel: string = 'overview';
  @State loading: boolean = false;
  @State refreshing: boolean = false;
  @State err: string = '';
  @State staleNote: string = '';
  @State dark: boolean = false;

  // ── 健康恢复（逐日静息心率；HRV 接口不可用）──
  @State rhrDays: string[] = [];
  @State rhrValues: number[] = [];
  @State rhrLoading: boolean = false;
  @State rhrErr: string = '';
  @State rhrReady: boolean = false;
  @State hrvRange: HrvRange | null = null;
  @State hrvLoading: boolean = false;

  // ── 表现预测器输入（持久化到本地）──
  @State pDistance: string = '80';
  @State pClimb: string = '500';
  @State pWeight: string = '75';
  @State pBike: string = '12';
  @State pCda: string = '0.30';
  @State pCrr: string = '0.005';
  @State pPower: string = '180';
  /** 传动效率（%）：默认 97，链条传动典型 95~98 */
  @State pEff: string = DeviceStore.getPredictEff().length > 0 ? DeviceStore.getPredictEff() : '97';
  /** 负荷明细表显示天数（10 ↔ 30 切换） */
  @State loadDays: number = 10;
  @State predReady: boolean = false;
  @State predSpeed: number = 0;
  @State predSeconds: number = 0;
  @State predTss: number = 0;
  @State predAnaerobic: number = 0;
  @State predThreshold: number = 0;
  @State predAerobic: number = 0;

  // 曲线聚合
  @State p42: number[] = [];
  @State p90: number[] = [];
  @State pall: number[] = [];
  @State e42: number | null = null;
  @State e90: number | null = null;
  @State eall: number | null = null;
  @State bestPts: number[] = [];
  @State bestCount: number = 0;
  @State eftp: number | null = null;
  @State curveLoading: boolean = false;
  @State curveErr: string = '';
  @State curveReady: boolean = false;
  @State curveUpdated: string = '';
  @State curveWindow: string = '';
  @State zones: number[] = [];

  /** 系统字体缩放（无障碍字号） */
  private fontScale: number = 1;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private curveSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private curveCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.curveSettings);

  aboutToAppear(): void {
    this.dark = Theme.isDark(getContext(this) as common.UIAbilityContext);
    try {
      const cfg = (getContext(this) as common.UIAbilityContext).config;
      this.fontScale = cfg.fontSizeScale !== undefined && cfg.fontSizeScale > 0 ? cfg.fontSizeScale : 1;
    } catch (e) {
      this.fontScale = 1;
    }
    this.load(false);
  }

  onTick(): void {
    this.load(false);
  }

  /** 画布字号：以画布宽度为基准，再乘系统字体缩放 */
  private labelSize(canvasW: number): number {
    let base = Math.round(canvasW / 26);
    if (base < 11) base = 11;
    if (base > 20) base = 20;
    const scaled = Math.round(base * this.fontScale);
    return scaled < 10 ? 10 : scaled;
  }

  // ── 载入趋势 ──

  private load(fromPull: boolean): void {
    if (!DeviceStore.isPaired()) {
      this.err = '尚未配对：请到「我的」里完成配对';
      return;
    }
    const key = 'trend:90';
    const cached = DeviceStore.cacheGet(key);
    let showed = false;
    if (cached.length > 10) {
      this.trend = JSON.parse(cached) as Trend;
      this.staleNote = '缓存 · ' + Fmt.ago(DeviceStore.cacheAge(key)) + ' · 正在刷新…';
      showed = true;
    }
    if (!fromPull && !showed) {
      this.loading = true;
    }
    this.err = '';
    ApiClient.getTrend(90)
      .then((t: Trend) => {
        this.trend = t;
        this.staleNote = '';
        this.loading = false;
        this.refreshing = false;
        DeviceStore.cachePut(key, JSON.stringify(t));
        this.drawPmc();
      })
      .catch((e: Object) => {
        this.loading = false;
        this.refreshing = false;
        if (!showed) {
          this.err = ApiClient.friendly(e);
        }
      });
  }

  // ── 载入曲线聚合（按钮触发；命中缓存则不请求）──

  private loadCurve(): void {
    if (this.curveLoading) {
      return;
    }
    const key = 'curve:v3';
    const cached = DeviceStore.cacheGet(key);
    if (cached.length > 10 && DeviceStore.cacheAge(key) < 3600000) {
      this.applyCurve(cached);
      return;
    }
    if (!DeviceStore.isPaired()) {
      this.curveErr = '尚未配对';
      return;
    }
    this.curveLoading = true;
    this.curveErr = '';
    ApiClient.getCurve(90)
      .then((c: CurveData) => {
        const json = JSON.stringify(c);
        DeviceStore.cachePut(key, json);
        this.applyCurve(json);
        this.curveLoading = false;
      })
      .catch((er: Object) => {
        this.curveLoading = false;
        this.curveErr = ApiClient.friendly(er);
      });
  }

  /** 20 分钟（数组下标 10）× 0.95 */
  private eftp20(arr: number[]): number | null {
    return arr.length >= 15 && arr[10] > 0 ? Math.round(arr[10] * 0.95) : null;
  }

  private applyCurve(json: string): void {
    try {
      const cb = JSON.parse(json) as CurveBest;
      if (cb.p90 !== undefined && cb.p90.length === 15 && cb.zones !== undefined && cb.zones.length === 7) {
        this.p42 = cb.p42;
        this.p90 = cb.p90;
        this.pall = cb.pall;
        this.e42 = cb.e42;
        this.e90 = cb.e90;
        this.eall = cb.eall;
        this.bestPts = cb.p90;
        this.eftp = cb.e90;
        this.bestCount = cb.count;
        this.zones = cb.zones;

        this.curveUpdated = cb.updatedAt === undefined ? '' : cb.updatedAt;

        this.curveWindow = (cb.windowFrom === undefined ? '' : cb.windowFrom) + ' ~ ' + (cb.windowTo === undefined ? '' : cb.windowTo);
        this.curveReady = true;
      }
    } catch (e) {
      DeviceStore.cachePut('curveBest:90', '');
    }
  }

  // ── 派生指标 ──

  private last(): TrendPoint | null {
    const t = this.trend;
    if (t === null || t.points.length === 0) {
      return null;
    }
    return t.points[t.points.length - 1];
  }

  private ctlNow(): number | null {
    const p = this.last();
    return p === null ? null : p.ctl;
  }

  private atlNow(): number | null {
    const p = this.last();
    return p === null ? null : p.atl;
  }

  private tsbNow(): number | null {
    const p = this.last();
    return p === null ? null : p.tsb;
  }

  private ramp(): number | null {
    const t = this.trend;
    if (t === null || t.points.length < 8) {
      return null;
    }
    const now = t.points[t.points.length - 1].ctl;
    const before = t.points[t.points.length - 8].ctl;
    if (now === null || before === null) {
      return null;
    }
    return Math.round((now - before) * 10) / 10;
  }

  /** 建议周 TSS：维持 = CTL×7；爬升目标 = (CTL+4)×7 */
  private suggestTss(): string {
    const ctl = this.ctlNow();
    if (ctl === null) {
      return '--';
    }
    const keep = Math.round(ctl * 7);
    const build = Math.round((ctl + 4) * 7);
    return keep + ' ~ ' + build;
  }

  /** 近 7 天单调性（Foster）：日均 TSS / 标准差 */
  private monotony(): number | null {
    const t = this.trend;
    if (t === null || t.points.length < 7) {
      return null;
    }
    const vals: number[] = [];
    for (let i = t.points.length - 7; i < t.points.length; i++) {
      const tv = t.points[i].tss;
      vals.push(tv === null ? 0 : tv);
    }
    let sum = 0;
    for (let i = 0; i < vals.length; i++) {
      sum += vals[i];
    }
    const mean = sum / vals.length;
    let sq = 0;
    for (let i = 0; i < vals.length; i++) {
      sq += (vals[i] - mean) * (vals[i] - mean);
    }
    const sd = Math.sqrt(sq / vals.length);
    if (sd < 0.01) {
      return null;
    }
    return Math.round((mean / sd) * 100) / 100;
  }

  /** 应变 Strain = 周 TSS × 单调性 */
  private strain(): number | null {
    const m = this.monotony();
    const t = this.trend;
    if (m === null || t === null || t.points.length < 7) {
      return null;
    }
    let sum = 0;
    for (let i = t.points.length - 7; i < t.points.length; i++) {
      const tv = t.points[i].tss;
      sum += tv === null ? 0 : tv;
    }
    return Math.round(sum * m);
  }

  private weekRows(n: number): WeekRow[] {
    const t = this.trend;
    if (t === null || t.points.length === 0) {
      return [];
    }
    const out: WeekRow[] = [];
    const thisWeek = Fmt.weekStart(Fmt.today());
    for (let w = 0; w < n; w++) {
      const ws = Fmt.shiftDays(thisWeek, -7 * w);
      const we = Fmt.shiftDays(ws, 6);
      let tss = 0;
      let ctl: number | null = null;
      let atl: number | null = null;
      let tsb: number | null = null;
      for (let i = 0; i < t.points.length; i++) {
        const p = t.points[i];
        if (p.date >= ws && p.date <= we) {
          tss += p.tss === null ? 0 : p.tss;
          ctl = p.ctl;
          atl = p.atl;
          tsb = p.tsb;
        }
      }
      const label = w === 0 ? '本周' : (w === 1 ? '上周' : Fmt.monthDay(ws) + ' 那周');
      out.push({ label: label, tss: Math.round(tss), ctl: ctl === null ? 0 : ctl, atl: atl === null ? 0 : atl, tsb: tsb === null ? 0 : tsb });
    }
    return out;
  }

  private weeklyDesc(): WeeklyTotal[] {
    const t = this.trend;
    if (t === null) {
      return [];
    }
    const out: WeeklyTotal[] = [];
    for (let i = t.weekly.length - 1; i >= 0; i--) {
      out.push(t.weekly[i]);
    }
    return out.slice(0, 8);
  }

  private weekMaxTss(): number {
    const list = this.weeklyDesc();
    let max = 1;
    for (let i = 0; i < list.length; i++) {
      if (list[i].tss > max) {
        max = list[i].tss;
      }
    }
    return max;
  }

  private formTitle(): string {
    const t = this.tsbNow();
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
    const t = this.tsbNow();
    if (t === null) {
      return '先骑一次带功率的车，就能算出体能/疲劳/表单';
    }
    if (t > 5) {
      return '状态好：适合比赛、FTP 测试或高强度间歇';
    }
    if (t >= -10) {
      return '负荷与恢复平衡：可按建议周 TSS 推进';
    }
    if (t >= -30) {
      return '训练期常态：保证睡眠与补给，避免叠加质量课';
    }
    return '建议减量 2~3 天（轻松骑/休息），避免受伤与免疫下降';
  }

  private formColor(): ResourceColor {
    const t = this.tsbNow();
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

  /** 功率形态判读：短时相对强 → 冲刺/无氧；长时相对强 → 计时/耐力 */
  private shapeVerdict(): string {
    const ef = this.eftp;
    if (!this.curveReady || ef === null || ef <= 0) {
      return '需要先加载功率曲线';
    }
    const p5 = this.bestPts[1] / ef;
    const p60 = this.bestPts[2] / ef;
    const p1200 = this.bestPts[4] / ef;
    if (p5 >= 3.0 && p1200 < 1.0) {
      return '偏向冲刺/无氧型：短时爆发强，长时相对偏弱';
    }
    if (p1200 >= 1.0 && p5 < 2.5) {
      return '偏向计时/耐力型：长时保持好，短时爆发相对平';
    }
    if (p60 >= 1.15) {
      return '综合型偏节奏：1 分钟级输出突出，适合节奏与爬坡';
    }
    return '综合型：各时长较均衡';
  }

  private shapeRatio(i: number): number {
    const ef = this.eftp;
    if (!this.curveReady || ef === null || ef <= 0 || i >= this.bestPts.length) {
      return 0;
    }
    return Math.round((this.bestPts[i] / ef) * 100);
  }

  // ── Canvas：PMC ──

  private drawPmc(): void {
    const t = this.trend;
    if (t === null || t.points.length < 2) {
      return;
    }
    const w = this.ctx.width;
    const h = this.ctx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    const font = this.labelSize(w);
    const padL = Math.round(font * 2.6) + 4;
    const padR = 8;
    const padT = 12;
    const padB = font + 12;
    const iw = w - padL - padR;
    const ih = h - padT - padB;
    const pts = t.points;
    let min = 0;
    let max = 10;
    for (let i = 0; i < pts.length; i++) {
      const p = pts[i];
      const vals: (number | null)[] = [p.ctl, p.atl, p.tsb];
      for (let k = 0; k < vals.length; k++) {
        const v = vals[k];
        if (v !== null) {
          if (v < min) min = v;
          if (v > max) max = v;
        }
      }
    }
    min = Math.min(min, -32);
    max = Math.max(max, 8);
    const span = max - min;
    const y = (v: number) => padT + ih - ((v - min) / span) * ih;
    const x = (i: number) => padL + (i / (pts.length - 1)) * iw;
    this.ctx.clearRect(0, 0, w, h);
    // 表单区间带
    this.ctx.globalAlpha = 0.12;
    this.ctx.fillStyle = '#2FA36B';
    this.ctx.fillRect(padL, y(max), iw, y(5) - y(max));
    this.ctx.fillStyle = '#8A93A5';
    this.ctx.fillRect(padL, y(5), iw, y(-10) - y(5));
    this.ctx.fillStyle = '#E0A33E';
    this.ctx.fillRect(padL, y(-10), iw, y(-30) - y(-10));
    this.ctx.fillStyle = '#D9534F';
    this.ctx.fillRect(padL, y(-30), iw, y(min) - y(-30));
    this.ctx.globalAlpha = 1;
    // 网格与 y 轴
    this.ctx.strokeStyle = Theme.grid(this.dark);
    this.ctx.lineWidth = 1;
    this.ctx.fillStyle = Theme.axis(this.dark);
    this.ctx.font = font + 'px sans-serif';
    const ticks: number[] = [max, (max + min) / 2, min];
    for (let i = 0; i < ticks.length; i++) {
      const v = Math.round(ticks[i]);
      const yy = y(ticks[i]);
      this.ctx.beginPath();
      this.ctx.moveTo(padL, yy);
      this.ctx.lineTo(padL + iw, yy);
      this.ctx.stroke();
      this.ctx.fillText(String(v), Math.round(font * 0.4), yy + Math.round(font * 0.35));
    }
    this.ctx.strokeStyle = Theme.zeroLine(this.dark);
    this.ctx.beginPath();
    this.ctx.moveTo(padL, y(0));
    this.ctx.lineTo(padL + iw, y(0));
    this.ctx.stroke();
    const line = (pick: (p: TrendPoint) => number | null, color: string, width: number) => {
      this.ctx.strokeStyle = color;
      this.ctx.lineWidth = width;
      this.ctx.beginPath();
      let started = false;
      for (let i = 0; i < pts.length; i++) {
        const v = pick(pts[i]);
        if (v === null) {
          continue;
        }
        const px = x(i);
        const py = y(v);
        if (!started) {
          this.ctx.moveTo(px, py);
          started = true;
        } else {
          this.ctx.lineTo(px, py);
        }
      }
      this.ctx.stroke();
    };
    line((p: TrendPoint) => p.tsb, Theme.tsb(this.dark), 1.4);
    line((p: TrendPoint) => p.atl, Theme.atl(this.dark), 1.8);
    line((p: TrendPoint) => p.ctl, Theme.ctl(this.dark), 2.4);
    this.ctx.fillStyle = Theme.axis(this.dark);
    const idxs: number[] = [0, Math.floor((pts.length - 1) / 2), pts.length - 1];
    for (let i = 0; i < idxs.length; i++) {
      const label = Fmt.monthDay(pts[idxs[i]].date);
      const px = x(idxs[i]);
      this.ctx.fillText(label, Math.max(padL, Math.min(px - font, padL + iw - font * 2.2)), h - 7);
    }
  }

  // ── Canvas：功率曲线（对数横轴，可切形态百分比）──

  private drawCurveChart(): void {
    if (!this.curveReady || this.p90.length < 15) {
      return;
    }
    const w = this.curveCtx.width;
    const h = this.curveCtx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    const font = this.labelSize(w);
    const padL = Math.round(font * 2.8) + 4;
    const padR = 8;
    const padT = 12;
    const padB = font + 12;
    const iw = w - padL - padR;
    const ih = h - padT - padB;
    const asPercent = this.panel === 'shape';
    const ef0 = this.e90;
    const base = ef0 !== null && ef0 > 0 ? ef0 : 1;
    let max = 10;
    if (asPercent) {
      for (let k = 0; k < 15; k++) {
        const v = this.p90[k] / base * 100;
        if (v > max) max = v;
      }
    } else {
      for (let k = 0; k < 15; k++) {
        if (this.p42[k] > max) max = this.p42[k];
        if (this.p90[k] > max) max = this.p90[k];
        if (this.pall[k] > max) max = this.pall[k];
      }
    }
    max = Math.round(max * 1.1);
    this.curveCtx.clearRect(0, 0, w, h);
    this.curveCtx.strokeStyle = Theme.grid(this.dark);
    this.curveCtx.lineWidth = 1;
    this.curveCtx.fillStyle = Theme.axis(this.dark);
    this.curveCtx.font = font + 'px sans-serif';
    for (let g = 0; g <= 2; g++) {
      const val = Math.round((max / 2) * g);
      const yy = padT + ih - (val / max) * ih;
      this.curveCtx.beginPath();
      this.curveCtx.moveTo(padL, yy);
      this.curveCtx.lineTo(padL + iw, yy);
      this.curveCtx.stroke();
      this.curveCtx.fillText(String(val), Math.round(font * 0.4), yy + Math.round(font * 0.35));
    }
    const xOf = (k: number) => padL + (Math.log(DUR_SECS[k]) / Math.log(18000)) * iw;
    const yOf = (v: number) => padT + ih - (v / max) * ih;
    const path = (arr: number[], color: string, width: number, percent: boolean) => {
      this.curveCtx.strokeStyle = color;
      this.curveCtx.lineWidth = width;
      this.curveCtx.beginPath();
      for (let k = 0; k < 15; k++) {
        const raw = arr[k];
        if (raw <= 0) {
          continue;
        }
        const v = percent ? raw / base * 100 : raw;
        const px = xOf(k);
        const py = yOf(v);
        if (k === 0) {
          this.curveCtx.moveTo(px, py);
        } else {
          this.curveCtx.lineTo(px, py);
        }
      }
      this.curveCtx.stroke();
    };
    if (asPercent) {
      path(this.p90, Theme.ctl(this.dark), 2.4, true);
    } else {
      path(this.pall, '#8A93A5', 1.4, false);
      path(this.p42, Theme.ctl(this.dark), 2.2, false);
      path(this.p90, '#E0A33E', 2.2, false);
    }
    // 时长刻度
    this.curveCtx.fillStyle = Theme.axis(this.dark);
    const marks: number[] = [60, 300, 1200, 3600];
    for (let k = 0; k < 15; k++) {
      for (let m = 0; m < marks.length; m++) {
        if (DUR_SECS[k] === marks[m]) {
          const lbl = marks[m] >= 3600 ? (marks[m] / 3600) + 'h' : (marks[m] / 60) + 'm';
          this.curveCtx.fillText(lbl, Math.max(padL, xOf(k) - font), h - 6);
        }
      }
    }
  }

  // ── @Builder ──

  @Builder
  panelChip(def: PanelDef) {
    Text(def.label)
      .fontSize(12)
      .fontColor(this.panel === def.key ? $r('app.color.accent_on') : $r('app.color.text_secondary'))
      .backgroundColor(this.panel === def.key ? $r('app.color.accent') : $r('app.color.chip_background'))
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(14)
      .onClick(() => {
        this.panel = def.key;
        if (def.key === 'curve' || def.key === 'shape') {
          if (!this.curveReady) {
            this.loadCurve();
          } else {
            this.drawCurveChart();
          }
        }
      })
  }

  @Builder
  metric(cfg: MetricCfg) {
    Column() {
      Text(cfg.label).fontSize(11).fontColor($r('app.color.text_tertiary'))
      Text(cfg.value).fontSize(19).fontWeight(FontWeight.Bold)
        .fontColor(cfg.tone === 'ctl' ? $r('app.color.accent')
          : (cfg.tone === 'atl' ? $r('app.color.danger') : $r('app.color.text_primary')))
      Text(cfg.hint).fontSize(9).fontColor($r('app.color.text_hint'))
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  @Builder
  overviewPanel() {
    Column() {
      Row() {
        this.metric({ label: '体能 CTL', value: Fmt.num1(this.ctlNow(), ''), hint: '42 天', tone: 'ctl' })
        this.metric({ label: '疲劳 ATL', value: Fmt.num1(this.atlNow(), ''), hint: '7 天', tone: 'atl' })
        this.metric({ label: '表单 TSB', value: Fmt.num1(this.tsbNow(), ''), hint: 'CTL−昨日ATL', tone: 'tsb' })
        this.metric({ label: 'Ramp', value: Fmt.num1(this.ramp(), ''), hint: '点/周', tone: 'ramp' })
      }
      .width('100%')

      Canvas(this.ctx)
        .width('100%').height(180).margin({ top: 10 })
        .onReady(() => { this.drawPmc(); })
        .backgroundColor($r('app.color.card_background_blur'))
        .borderRadius(12)

      Row({ space: 12 }) {
        Row() {
          Row().width(10).height(2).backgroundColor(Theme.ctl(this.dark))
          Text(' 体能').fontSize(10).fontColor($r('app.color.text_tertiary'))
        }
        Row() {
          Row().width(10).height(2).backgroundColor(Theme.atl(this.dark))
          Text(' 疲劳').fontSize(10).fontColor($r('app.color.text_tertiary'))
        }
        Row() {
          Row().width(10).height(2).backgroundColor(Theme.tsb(this.dark))
          Text(' 表单').fontSize(10).fontColor($r('app.color.text_tertiary'))
        }
      }
      .width('100%').margin({ top: 6 })

      Column() {
        Row() {
          Text('表单').fontSize(12).fontColor($r('app.color.text_tertiary'))
          Blank()
          Text(this.formTitle()).fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.formColor())
        }
        .width('100%')
        Text(this.formAdvice()).fontSize(11).fontColor($r('app.color.text_secondary'))
          .width('100%').margin({ top: 4 })
      }
      .padding(14).width('100%').margin({ top: 10 })
      .backgroundColor($r('app.color.card_background_blur'))
      .border({ width: 1, color: $r('app.color.card_border_highlight') })
      .borderRadius(14)

      Column() {
        Text('每周训练负荷').fontSize(13).fontWeight(FontWeight.Medium).width('100%')
        ForEach(this.weeklyDesc(), (wk: WeeklyTotal) => {
          Row() {
            Text(Fmt.monthDay(wk.weekStart)).fontSize(11).fontColor($r('app.color.text_secondary')).width(52)
            Row() {
                Row()
                  .width(Math.min(100, Math.max(1, (wk.tss / this.weekMaxTss()) * 100)) + '%')
                  .height(8).borderRadius(4).backgroundColor($r('app.color.accent'))
              }
              .layoutWeight(1)
              .height(8).borderRadius(4).backgroundColor($r('app.color.chip_background'))
            Text('TSS ' + Math.round(wk.tss)).fontSize(11).fontColor($r('app.color.accent')).width(62)
              .textAlign(TextAlign.End)
          }
          .width('100%').padding({ top: 5, bottom: 5 })
        }, (wk: WeeklyTotal) => wk.weekStart)
      }
      .padding(14).width('100%').margin({ top: 10 })
      .backgroundColor($r('app.color.card_background_blur'))
      .border({ width: 1, color: $r('app.color.card_border_highlight') })
      .borderRadius(14)
    }
    .width('100%')
  }

  @Builder
  curvePanel() {
    Column() {
      if (!this.curveReady) {
        Row() {
          Text(this.curveErr.length > 0 ? this.curveErr : '聚合带功率活动的功率曲线（最多 15 次，按 42 天 / 90 天 / 全部 三档统计）')
            .fontSize(11).fontColor($r('app.color.text_secondary')).layoutWeight(1)
          Button(this.curveLoading ? '加载中…' : '开始聚合')
            .fontSize(12).height(30)
            .backgroundColor($r('app.color.accent')).fontColor($r('app.color.accent_on'))
            .enabled(!this.curveLoading)
            .onClick(() => { this.loadCurve(); })
        }
        .width('100%').padding(14)
        .backgroundColor($r('app.color.card_background_blur'))
        .border({ width: 1, color: $r('app.color.card_border_highlight') })
        .borderRadius(14)
      } else {
        Canvas(this.curveCtx)
          .width('100%').height(210)
          .onReady(() => { this.drawCurveChart(); })
          .backgroundColor($r('app.color.card_background_blur'))
          .borderRadius(12)
        Row({ space: 14 }) {
          Row() {
            Row().width(10).height(2).backgroundColor(Theme.ctl(this.dark))
            Text(' 42 天').fontSize(10).fontColor($r('app.color.text_tertiary'))
          }
          Row() {
            Row().width(10).height(2).backgroundColor('#E0A33E')
            Text(' 90 天').fontSize(10).fontColor($r('app.color.text_tertiary'))
          }
          Row() {
            Row().width(10).height(2).backgroundColor('#8A93A5')
            Text(' 全部').fontSize(10).fontColor($r('app.color.text_tertiary'))
          }
        }
        .width('100%').margin({ top: 6 })

        Column() {
          Row() {
            Text('时长').fontSize(11).fontColor($r('app.color.text_tertiary')).width(52)
            Text('42 天').fontSize(11).fontColor($r('app.color.text_tertiary')).layoutWeight(1).textAlign(TextAlign.End)
            Text('90 天').fontSize(11).fontColor($r('app.color.text_tertiary')).layoutWeight(1).textAlign(TextAlign.End)
            Text('全部').fontSize(11).fontColor($r('app.color.text_tertiary')).layoutWeight(1).textAlign(TextAlign.End)
          }
          .width('100%').padding({ bottom: 6 })
          ForEach(CURVE_NAMES, (nm: string, i: number) => {
            Row() {
              Text(nm).fontSize(12).width(52)
              Text(this.w(this.p42[TABLE_IDX[i]])).fontSize(12).layoutWeight(1).textAlign(TextAlign.End)
              Text(this.w(this.p90[TABLE_IDX[i]])).fontSize(13).fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.accent')).layoutWeight(1).textAlign(TextAlign.End)
              Text(this.w(this.pall[TABLE_IDX[i]])).fontSize(12).layoutWeight(1).textAlign(TextAlign.End)
            }
            .width('100%').padding({ top: 5, bottom: 5 })
          }, (nm: string) => nm)
          Divider().color($r('app.color.divider')).margin({ top: 4, bottom: 4 })
          Row() {
            Text('eFTP').fontSize(11).fontColor($r('app.color.text_tertiary')).width(52)
            Text(this.ef(this.e42)).fontSize(12).layoutWeight(1).textAlign(TextAlign.End)
            Text(this.ef(this.e90)).fontSize(13).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.accent')).layoutWeight(1).textAlign(TextAlign.End)
            Text(this.ef(this.eall)).fontSize(12).layoutWeight(1).textAlign(TextAlign.End)
          }
          .width('100%').padding({ top: 4 })
          Text('数据窗口 ' + this.curveWindow + '（' + this.bestCount + ' 次骑行）；聚合于 ' + this.curveUpdated.substring(11, 16) + '，10 分钟内复用缓存')
            .fontSize(9).fontColor($r('app.color.text_hint')).width('100%').margin({ top: 6 })
        }
        .padding(14).width('100%').margin({ top: 10 })
        .backgroundColor($r('app.color.card_background_blur'))
        .border({ width: 1, color: $r('app.color.card_border_highlight') })
        .borderRadius(14)
      }
    }
    .width('100%')
  }

  private w(v: number): string {
    return v > 0 ? v + ' W' : '--';
  }

  private ef(v: number | null): string {
    return v === null ? '--' : v + ' W';
  }


  /** 体重（kg，来自表现预测器输入） */
  private massKg(): number {
    // 优先用「我的 → 个人设置」里的全局体重；未设置时退回卡片内的输入
    const g = Number.parseFloat(DeviceStore.getBodyWeight());
    if (Number.isFinite(g) && g > 20) {
      return g;
    }
    const w = Number.parseFloat(this.pWeight);
    return Number.isFinite(w) && w > 20 ? w : 0;
  }

  /** 某时长（列 0=5s 1=1min 2=5min 3=FTP）的 W/kg */
  private wkgOf(col: number): number {
    const m = this.massKg();
    if (m <= 0 || !this.curveReady) {
      return 0;
    }
    let watts = 0;
    if (col === 0) watts = this.pall[2];
    else if (col === 1) watts = this.pall[6];
    else if (col === 2) watts = this.pall[8];
    else {
      const e = this.eall;
      watts = e === null ? 0 : e;
    }
    return watts > 0 ? Math.round((watts / m) * 100) / 100 : 0;
  }

  private cogganLabel(col: number): string {
    const v = this.wkgOf(col);
    if (v <= 0) {
      return '--';
    }
    for (let i = 0; i < COGGAN_LEVELS.length; i++) {
      if (v >= COGGAN_WKG[i][col]) {
        return COGGAN_LEVELS[i];
      }
    }
    return '未训练';
  }

  /** 某时长的 W/kg（列 0..4 = 5s/1min/5min/20min/60min，5 = eFTP） */
  private wkgW(i: number): number {
    const m = this.massKg();
    if (m <= 0 || !this.curveReady) {
      return 0;
    }
    let w = 0;
    if (i === 5) {
      const e = this.eall;
      w = e === null ? 0 : e;
    } else {
      w = this.pall[DUR_IDX_W[i]];
    }
    return w > 0 ? Math.round((w / m) * 100) / 100 : 0;
  }

  /**
   * 某时长对应最接近的 Coggan 等级下标（0=世界级 … 7=未训练；-1=无数据）。
   * FTP 列阈值用于 eFTP 与 60min；20min 按 FTP×1.05 折算。
   */
  private levelOfDur(i: number): number {
    const v = this.wkgW(i);
    if (v <= 0) {
      return -1;
    }
    let col = 3;
    let scale = 1;
    if (i === 0) {
      col = 0;
    } else if (i === 1) {
      col = 1;
    } else if (i === 2) {
      col = 2;
    } else if (i === 3) {
      scale = 1.05;
    }
    for (let k = 0; k < COGGAN_LEVELS.length; k++) {
      if (v >= COGGAN_WKG[k][col] * scale) {
        return k;
      }
    }
    return COGGAN_LEVELS.length - 1;
  }

  /** 综合等级：逐时长等级下标的加权平均（取整） */
  private compositeLevel(): number {
    let sum = 0;
    let wsum = 0;
    for (let i = 0; i < 5; i++) {
      const lv = this.levelOfDur(i);
      if (lv < 0) {
        continue;
      }
      sum += lv * DUR_WEIGHTS_W[i];
      wsum += DUR_WEIGHTS_W[i];
    }
    const lvE = this.levelOfDur(5);
    if (lvE >= 0) {
      sum += lvE * EFTP_WEIGHT;
      wsum += EFTP_WEIGHT;
    }
    if (wsum === 0) {
      return -1;
    }
    return Math.round(sum / wsum);
  }

  private levelName(lv: number): string {
    if (lv < 0 || lv >= COGGAN_LEVELS.length) {
      return '--';
    }
    return COGGAN_LEVELS[lv];
  }

  /** 比值 r1=1min/5s、r2=5min/1min、r3=20min/5min */
  private ratioW(i: number): number {
    const a = this.wkgW(i + 1);
    const b = this.wkgW(i);
    if (a <= 0 || b <= 0) {
      return 0;
    }
    return Math.round((a / b) * 1000) / 1000;
  }

  /**
   * 车手类型（riduck.com 分类，按用户给定顺序逐条判定）。
   * 以 W/kg 绝对值为主 —— 因为曲线由多次骑行「取各时长最大」聚合，衰减比会偏高。
   */
  private riderType(): string {
    const w5 = this.wkgW(0);
    const w1 = this.wkgW(1);
    const w5m = this.wkgW(2);
    const w20 = this.wkgW(3);
    if (w5 <= 0 || w20 <= 0) {
      return '需先聚合曲线并填写体重';
    }
    const r1 = this.ratioW(0);
    const r2 = this.ratioW(1);
    const r3 = this.ratioW(2);
    if (w20 >= 4.5) {
      return '爬坡手';
    }
    if (w5 >= 14 && r1 < 0.40) {
      return '冲刺手';
    }
    if (w5m >= 4.5 && r2 > r3 * 1.05) {
      return '陡坡冲刺型';
    }
    if (r3 > 0.92) {
      return '计时赛手';
    }
    if (w20 >= 3.5 && w5 >= 12) {
      return '全能型';
    }
    if (w20 >= 3.0) {
      return '副将';
    }
    if (w20 >= 2.5) {
      return '耐力型';
    }
    if (w20 >= 2.0) {
      return '基础型';
    }
    return '未定级';
  }

  private riderTypeHint(): string {
    const w5 = this.wkgW(0);
    const w5m = this.wkgW(2);
    const w20 = this.wkgW(3);
    if (w5 <= 0 || w20 <= 0) {
      return '';
    }
    const r1 = this.ratioW(0);
    const r2 = this.ratioW(1);
    const r3 = this.ratioW(2);
    return '判定依据：20min ' + w20 + ' · 5min ' + w5m + ' · 5s ' + w5
      + ' W/kg；r1=' + r1 + ' r2=' + r2 + ' r3=' + r3;
  }

  @Builder
  cogganCard() {
    Column() {
      Row() {
        Text('Coggan 功率形态等级（W/kg）').fontSize(13).fontWeight(FontWeight.Medium)
        Blank()
        Text(this.massKg() > 0 ? '按体重 ' + this.massKg() + ' kg' : '需填体重')
          .fontSize(10).fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      Row() {
        Text('体重').fontSize(11).fontColor($r('app.color.text_secondary')).width(52)
        TextInput({ text: this.pWeight })
          .fontSize(13).type(InputType.Normal).layoutWeight(1).height(32)
          .backgroundColor($r('app.color.chip_background')).borderRadius(8)
          .onChange((v: string) => {
            this.pWeight = v;
            DeviceStore.setBodyWeight(v);
          })
        Text('kg').fontSize(10).fontColor($r('app.color.text_hint')).width(26).textAlign(TextAlign.End)
      }
      .width('100%').margin({ top: 8 })

      Row() {
        Text('时长').fontSize(11).fontColor($r('app.color.text_tertiary')).width(52)
        Text('你的 W/kg').fontSize(11).fontColor($r('app.color.text_tertiary')).layoutWeight(1).textAlign(TextAlign.End)
        Text('对应等级').fontSize(11).fontColor($r('app.color.text_tertiary')).layoutWeight(1).textAlign(TextAlign.End)
      }
      .width('100%').padding({ top: 10, bottom: 4 })
      ForEach(['5s', '1min', '5min', 'FTP'], (nm: string, i: number) => {
        Row() {
          Text(nm).fontSize(12).width(52)
          Text(this.wkgOf(i) > 0 ? '' + this.wkgOf(i) : '--').fontSize(12).layoutWeight(1).textAlign(TextAlign.End)
          Text(this.cogganLabel(i)).fontSize(12).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.accent')).layoutWeight(1).textAlign(TextAlign.End)
        }
        .width('100%').padding({ top: 4, bottom: 4 })
      }, (nm: string) => nm)
      Text('基于历史最佳功率（5 秒 / 1 分钟 / 5 分钟 / FTP=20 分钟最佳×0.95）与体重换算，'
        + '等级阈值采用 Coggan 功率形态表；体重只存本地。')
        .fontSize(9).fontColor($r('app.color.text_hint')).width('100%').margin({ top: 6 })
    }
    .padding(14).width('100%').margin({ top: 10 })
    .backgroundColor($r('app.color.card_background_blur'))
    .border({ width: 1, color: $r('app.color.card_border_highlight') })
    .borderRadius(14)
  }

  @Builder
  riderTypeCard() {
    Column() {
      Row() {
        Column() {
          Text('综合等级').fontSize(10).fontColor(COLOR_TERTIARY)
          Text(this.levelName(this.compositeLevel())).fontSize(22).fontWeight(FontWeight.Bold)
            .fontColor(COLOR_ACCENT)
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)
        Column() {
          Text('车手类型').fontSize(10).fontColor(COLOR_TERTIARY)
          Text(this.riderType()).fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(COLOR_DANGER)
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)
      }
      .width('100%')

      Row() {
        Text('体重').fontSize(11).fontColor(COLOR_SECONDARY).width(52)
        TextInput({ text: this.pWeight })
          .fontSize(13).type(InputType.Normal).layoutWeight(1).height(32)
          .backgroundColor(COLOR_CHIP).borderRadius(8)
          .onChange((v: string) => { this.pWeight = v; })
        Text('kg').fontSize(10).fontColor(COLOR_HINT).width(26).textAlign(TextAlign.End)
      }
      .width('100%').margin({ top: 10 })

      Row() {
        Text('时长').fontSize(11).fontColor(COLOR_TERTIARY).width(56)
        Text('W/kg').fontSize(11).fontColor(COLOR_TERTIARY).layoutWeight(1).textAlign(TextAlign.End)
        Text('等级').fontSize(11).fontColor(COLOR_TERTIARY).layoutWeight(1).textAlign(TextAlign.End)
        Text('权重').fontSize(11).fontColor(COLOR_TERTIARY).width(40).textAlign(TextAlign.End)
      }
      .width('100%').padding({ top: 10, bottom: 4 })
      ForEach(DUR_NAMES_W, (nm: string, i: number) => {
        Row() {
          Text(nm).fontSize(12).width(56)
          Text(this.wkgW(i) > 0 ? '' + this.wkgW(i) : '--').fontSize(12).layoutWeight(1).textAlign(TextAlign.End)
          Text(this.levelName(this.levelOfDur(i))).fontSize(12).fontWeight(FontWeight.Medium)
            .fontColor(COLOR_ACCENT).layoutWeight(1).textAlign(TextAlign.End)
          Text('x' + DUR_WEIGHTS_W[i]).fontSize(11).fontColor(COLOR_HINT).width(40).textAlign(TextAlign.End)
        }
        .width('100%').padding({ top: 4, bottom: 4 })
      }, (nm: string) => nm)
      Row() {
        Text('eFTP').fontSize(12).width(56)
        Text(this.wkgW(5) > 0 ? '' + this.wkgW(5) : '--').fontSize(12).layoutWeight(1).textAlign(TextAlign.End)
        Text(this.levelName(this.levelOfDur(5))).fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor(COLOR_ACCENT).layoutWeight(1).textAlign(TextAlign.End)
        Text('x' + EFTP_WEIGHT).fontSize(11).fontColor(COLOR_HINT).width(40).textAlign(TextAlign.End)
      }
      .width('100%').padding({ top: 4, bottom: 4 })

      Text(this.riderTypeHint()).fontSize(9).fontColor(COLOR_HINT).width('100%').margin({ top: 8 })
      Text('综合等级 = 各时长等级的加权平均（20min/60min/eFTP 权重 3，5min 权重 2，1min/5s 权重 1），'
        + '因此 FTP 与有氧耐力影响最大；车手类型按 riduck 分类规则逐条判定，以 W/kg 绝对值为主'
        + '（曲线为多次骑行取各时长最大，衰减比会偏高）。体重只存本地。')
        .fontSize(9).fontColor(COLOR_HINT).width('100%').margin({ top: 4 })
    }
    .padding(14).width('100%').margin({ top: 10 })
    .backgroundColor(COLOR_CARD_BG)
    .border({ width: 1, color: COLOR_CARD_BORDER })
    .borderRadius(14)
  }

  @Builder
  shapePanel() {
    Column() {
      if (!this.curveReady) {
        Row() {
          Text('需要先聚合功率曲线')
            .fontSize(11).fontColor($r('app.color.text_secondary')).layoutWeight(1)
          Button(this.curveLoading ? '加载中…' : '开始聚合')
            .fontSize(12).height(30)
            .backgroundColor($r('app.color.accent')).fontColor($r('app.color.accent_on'))
            .enabled(!this.curveLoading)
            .onClick(() => { this.loadCurve(); })
        }
        .width('100%').padding(14)
        .backgroundColor($r('app.color.card_background_blur'))
        .border({ width: 1, color: $r('app.color.card_border_highlight') })
        .borderRadius(14)
      } else {
        Canvas(this.curveCtx)
          .width('100%').height(200)
          .onReady(() => { this.drawCurveChart(); })
          .backgroundColor($r('app.color.card_background_blur'))
          .borderRadius(12)
        Column() {
          Text('形态判读').fontSize(13).fontWeight(FontWeight.Medium).width('100%')
          Text(this.shapeVerdict()).fontSize(12).fontColor($r('app.color.text_secondary'))
            .width('100%').margin({ top: 6 })
          Text('纵轴为「该时长最佳功率 ÷ eFTP」的百分比：短时（5 秒/1 分钟）越高越偏无氧爆发，'
            + '长时（20 分钟/1 小时）越接近 100% 越偏耐力/计时。')
            .fontSize(10).fontColor($r('app.color.text_hint')).width('100%').margin({ top: 8 })
        }
        .padding(14).width('100%').margin({ top: 10 })
        .backgroundColor($r('app.color.card_background_blur'))
        .border({ width: 1, color: $r('app.color.card_border_highlight') })
        .borderRadius(14)
      }
      if (this.curveReady) {
        this.riderTypeCard()
      }
    }
    .width('100%')
  }


  /** 功率区间时间占比（近 N 次活动的累计） */
  private zoneTotal(): number {
    let sum = 0;
    for (let i = 0; i < this.zones.length; i++) {
      sum += this.zones[i];
    }
    return sum;
  }

  private zonePct(i: number): number {
    const total = this.zoneTotal();
    if (total <= 0 || i >= this.zones.length) {
      return 0;
    }
    return Math.round((this.zones[i] / total) * 1000) / 10;
  }

  @Builder
  zoneDist() {
    Column() {
      Row() {
        Text('功率区间负荷分布').fontSize(13).fontWeight(FontWeight.Medium)
        Blank()
        Text('累计 ' + Math.round(this.zoneTotal() / 3600) + ' 小时 · ' + this.bestCount + ' 次')
          .fontSize(10).fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      ForEach(ZONE_NAMES, (nm: string, i: number) => {
        Row() {
          Text(nm).fontSize(10).fontColor($r('app.color.text_secondary')).width(96)
          Row() {
              Row()
                .width(Math.min(100, Math.max(1, this.zonePct(i))) + '%')
                .height(10).borderRadius(5).backgroundColor(ZONE_COLORS[i])
            }
            .layoutWeight(1)
            .height(10).borderRadius(5).backgroundColor($r('app.color.chip_background'))
          Text(this.zonePct(i) + '%').fontSize(10).fontColor($r('app.color.text_secondary')).width(46)
            .textAlign(TextAlign.End)
        }
        .width('100%').padding({ top: 4, bottom: 4 })
      }, (nm: string) => nm)
      Text('区间按佳明功率分区（Z1 主动恢复 → Z7 神经肌肉）；训练应尽量让 Z1/Z2 占大头，'
        + 'Z4 以上合计控制在 20% 以内，否则容易累积疲劳。')
        .fontSize(9).fontColor($r('app.color.text_hint')).width('100%').margin({ top: 6 })
    }
    .padding(14).width('100%').margin({ top: 10 })
    .backgroundColor($r('app.color.card_background_blur'))
    .border({ width: 1, color: $r('app.color.card_border_highlight') })
    .borderRadius(14)
  }


  /** 达成率：42 天最佳 ÷ 历史最佳（%） */
  private achieve(i: number): number {
    const a = this.p42[TABLE_IDX[i]];
    const b = this.pall[TABLE_IDX[i]];
    if (b <= 0 || a <= 0) {
      return 0;
    }
    return Math.round((a / b) * 1000) / 10;
  }

  private achieveColor(v: number): string {
    if (v >= 100) return '#2FA36B';
    if (v >= 95) return '#2E9BB5';
    if (v >= 85) return '#E0A33E';
    return '#D9534F';
  }

  @Builder
  relativeFatigue() {
    Column() {
      Row() {
        Text('相对疲劳（42 天达成率）').fontSize(13).fontWeight(FontWeight.Medium)
        Blank()
        Text('42 天最佳 ÷ 历史最佳').fontSize(10).fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      Row() {
        Text('时长').fontSize(11).fontColor($r('app.color.text_tertiary')).width(52)
        Text('42 天最佳').fontSize(11).fontColor($r('app.color.text_tertiary')).layoutWeight(1).textAlign(TextAlign.End)
        Text('历史最佳').fontSize(11).fontColor($r('app.color.text_tertiary')).layoutWeight(1).textAlign(TextAlign.End)
        Text('达成率').fontSize(11).fontColor($r('app.color.text_tertiary')).width(62).textAlign(TextAlign.End)
      }
      .width('100%').padding({ top: 8, bottom: 6 })
      ForEach(CURVE_NAMES, (nm: string, i: number) => {
        Row() {
          Text(nm).fontSize(12).width(52)
          Text(this.w(this.p42[TABLE_IDX[i]])).fontSize(12).layoutWeight(1).textAlign(TextAlign.End)
          Text(this.w(this.pall[TABLE_IDX[i]])).fontSize(12).layoutWeight(1).textAlign(TextAlign.End)
          Text(this.achieve(i) + '%').fontSize(12).fontWeight(FontWeight.Medium)
            .fontColor(this.achieveColor(this.achieve(i))).width(62).textAlign(TextAlign.End)
        }
        .width('100%').padding({ top: 5, bottom: 5 })
      }, (nm: string) => nm)
      Text('达成率越高说明该时长最近状态越接近你的历史最好水平；'
        + '若长时长达成率高、短时长偏低 → 近期偏耐力训练；反之偏短时强度。')
        .fontSize(9).fontColor($r('app.color.text_hint')).width('100%').margin({ top: 6 })
    }
    .padding(14).width('100%').margin({ top: 10 })
    .backgroundColor($r('app.color.card_background_blur'))
    .border({ width: 1, color: $r('app.color.card_border_highlight') })
    .borderRadius(14)
  }

  @Builder
  fatiguePanel() {
    Column() {
      Row() {
        this.metric({ label: '疲劳 ATL', value: Fmt.num1(this.atlNow(), ''), hint: '7 天负荷', tone: 'atl' })
        this.metric({ label: 'Ramp', value: Fmt.num1(this.ramp(), ''), hint: '点/周', tone: 'ramp' })
        this.metric({ label: '单调性', value: Fmt.num1(this.monotony(), ''), hint: '<2 较好', tone: 'ctl' })
        this.metric({ label: '应变', value: this.strain() === null ? '--' : '' + this.strain(), hint: '周TSS×单调', tone: 'tsb' })
      }
      .width('100%')

      Column() {
        Text('读法').fontSize(13).fontWeight(FontWeight.Medium).width('100%')
        Text('· 单调性 = 近 7 天日均 TSS ÷ 标准差：长期 >2.0 表示训练过于单一（每天都在练、强度雷同），受伤与疲劳风险上升')
          .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%').margin({ top: 6 })
        Text('· 应变 = 周 TSS × 单调性：一般控制在 4000 以内较稳妥，超过 6000 需明显减量')
          .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%').margin({ top: 4 })
        Text('· Ramp 建议：每周 CTL 增长 3~5 点为安全区，>7~8 点风险明显上升')
          .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%').margin({ top: 4 })
      }
      .padding(14).width('100%').margin({ top: 10 })
      .backgroundColor($r('app.color.card_background_blur'))
      .border({ width: 1, color: $r('app.color.card_border_highlight') })
      .borderRadius(14)

      if (this.curveReady) {
        this.relativeFatigue()
      }

      Column() {
        Text('近 8 周负荷').fontSize(13).fontWeight(FontWeight.Medium).width('100%')
        ForEach(this.weeklyDesc(), (wk: WeeklyTotal) => {
          Row() {
            Text(Fmt.monthDay(wk.weekStart)).fontSize(11).fontColor($r('app.color.text_secondary')).width(52)
            Row() {
                Row()
                  .width(Math.min(100, Math.max(1, (wk.tss / this.weekMaxTss()) * 100)) + '%')
                  .height(8).borderRadius(4).backgroundColor($r('app.color.danger'))
              }
              .layoutWeight(1)
              .height(8).borderRadius(4).backgroundColor($r('app.color.chip_background'))
            Text('TSS ' + Math.round(wk.tss)).fontSize(11).fontColor($r('app.color.text_secondary')).width(62)
              .textAlign(TextAlign.End)
          }
          .width('100%').padding({ top: 5, bottom: 5 })
        }, (wk: WeeklyTotal) => wk.weekStart)
      }
      .padding(14).width('100%').margin({ top: 10 })
      .backgroundColor($r('app.color.card_background_blur'))
      .border({ width: 1, color: $r('app.color.card_border_highlight') })
      .borderRadius(14)
    }
    .width('100%')
      if (this.zones.length === 7) {
        this.zoneDist()
      }
  }


  /** 数值输入解析（非法值回退默认） */
  private numOf(v: string, fallback: number): number {
    const n = Number.parseFloat(v);
    return Number.isFinite(n) && n >= 0 ? n : fallback;
  }

  /**
   * 功率 → 速度（稳态物理模型）：
   *   P = (Crr·m·g·cosθ + m·g·sinθ + 0.5·ρ·CdA·v²) · v
   * 用二分法解 v。假设匀速（忽略起步/减速，实际用时通常略长）。
   */
  private solveSpeed(power: number, mass: number, gradePct: number, cda: number, crr: number): number {
    const g = 9.80665;
    const rho = 1.225;
    const theta = Math.atan(gradePct / 100);
    const roll = crr * mass * g * Math.cos(theta);
    const grav = mass * g * Math.sin(theta);
    let lo = 0.5;
    let hi = 30;
    for (let i = 0; i < 40; i++) {
      const v = (lo + hi) / 2;
      const need = (roll + grav + 0.5 * rho * cda * v * v) * v;
      if (need > power) {
        hi = v;
      } else {
        lo = v;
      }
    }
    return (lo + hi) / 2;
  }

  private saveWeight(): void {
    DeviceStore.setPredictInputs(0, 0, this.numOf(this.pWeight, 75), 0, 0, 0, 0);
  }

  /** 夹紧到合理区间（越界说明输入有误，例如 CdA 输成 30） */
  private clampOf(v: number, lo: number, hi: number): number {
    if (!Number.isFinite(v)) {
      return lo;
    }
    if (v < lo) {
      return lo;
    }
    if (v > hi) {
      return hi;
    }
    return v;
  }

  /** 预测器输入的合理区间（用于提示） */
  private predOutOfRange(): string {
    const cda = this.clampOf(this.numOf(this.pCda, 0.30), 0.15, 0.70);
    const crr = this.clampOf(this.numOf(this.pCrr, 0.005), 0.002, 0.020);
    const w = this.numOf(this.pWeight, 75);
    const out: string[] = [];
    if (cda < 0.15 || cda > 0.70) {
      out.push('风阻 CdA 应在 0.15~0.70（公路车≈0.30）');
    }
    if (crr < 0.002 || crr > 0.020) {
      out.push('滚阻 Crr 应在 0.002~0.020（柏油≈0.005）');
    }
    if (w < 30 || w > 200) {
      out.push('体重应在 30~200 kg');
    }
    return out.join('；');
  }

  /** 传动效率（0.80~1.00） */
  private effOf(): number {
    const e = this.clampOf(this.numOf(this.pEff, 97), 80, 100) / 100;
    return e;
  }

  private runPredict(): void {
    const distKm = this.clampOf(this.numOf(this.pDistance, 80), 1, 1000);
    const climb = this.numOf(this.pClimb, 0);
    const mass = this.clampOf(this.numOf(this.pWeight, 75), 30, 200) + this.clampOf(this.numOf(this.pBike, 12), 5, 25);
    const cda = this.numOf(this.pCda, 0.30);
    const crr = this.numOf(this.pCrr, 0.005);
    const power = this.clampOf(this.numOf(this.pPower, 180), 50, 1500);
    if (distKm <= 0 || power <= 0) {
      this.predReady = false;
      return;
    }
    const grade = distKm > 0 ? (climb / (distKm * 1000)) * 100 : 0;
    // 输入功率要扣掉传动损耗，才是真正推动车的轮上功率
    const v = this.solveSpeed(power * this.effOf(), mass, grade, cda, crr);
    this.predSpeed = Math.round(v * 3.6 * 10) / 10;
    this.predSeconds = Math.round((distKm * 1000) / v);
    // TSS 估算：IF = P / FTP，TSS = 秒 × P × IF / (FTP × 3600) × 100
    const ftp = this.e90 !== null && this.e90 > 0 ? this.e90 : 0;
    if (ftp > 0) {
      const ifv = power / ftp;
      this.predTss = Math.round((this.predSeconds * power * ifv) / (ftp * 3600) * 100);
    } else {
      this.predTss = 0;
    }
    // 功率分解（按 %FTP 的比例估算，非生理测量）
    if (ftp > 0) {
      const ratio = power / ftp;
      let ana = 0;
      if (ratio > 1.0) {
        ana = Math.min(40, Math.round((ratio - 1.0) * 100));
      }
      const thr = Math.min(100 - ana, Math.round(ratio * 55));
      this.predAnaerobic = ana;
      this.predThreshold = Math.max(0, thr);
      this.predAerobic = Math.max(0, 100 - ana - Math.max(0, thr));
    }
    // 持久化输入，下次打开还在
    DeviceStore.setPredictInputs(distKm, climb, this.numOf(this.pWeight, 75), this.numOf(this.pBike, 12), cda, crr, power);
    this.predReady = true;
  }

  private fmtDuration(sec: number): string {
    const h = Math.floor(sec / 3600);
    const m = Math.floor((sec % 3600) / 60);
    const s = sec % 60;
    return h + ' 小时 ' + m + ' 分 ' + s + ' 秒';
  }

  @Builder
  inputRow(label: string, value: string, unit: string, key: string) {
    Row() {
      Text(label).fontSize(11).fontColor($r('app.color.text_secondary')).width(88)
      TextInput({ text: value })
        .fontSize(13).type(InputType.Normal).layoutWeight(1).height(34)
        .backgroundColor($r('app.color.chip_background')).borderRadius(8)
        .onSubmit(() => {
          try {
            inputMethod.getController().stopInputSession();
          } catch (e) {
          }
        })
        .onChange((v: string) => {
          if (key === 'dist') { this.pDistance = v; }
          else if (key === 'climb') { this.pClimb = v; }
          else if (key === 'weight') { this.pWeight = v; }
          else if (key === 'bike') { this.pBike = v; }
          else if (key === 'cda') { this.pCda = v; }
          else if (key === 'crr') { this.pCrr = v; }
          else if (key === 'power') { this.pPower = v; }
          else {
            this.pEff = v;
            DeviceStore.setPredictEff(v);
          }
        })
      Text(unit).fontSize(10).fontColor($r('app.color.text_hint')).width(34).textAlign(TextAlign.End)
    }
    .width('100%').padding({ top: 4, bottom: 4 })
  }


  /** 载入最近 14 天 HRV（1 小时缓存） */
  private loadHrvRange(): void {
    if (this.hrvLoading) {
      return;
    }
    const key = 'hrvRange:14';
    const cached = DeviceStore.cacheGet(key);
    if (cached.length > 10 && DeviceStore.cacheAge(key) < 3600000) {
      this.hrvRange = JSON.parse(cached) as HrvRange;
      return;
    }
    if (!DeviceStore.isPaired()) {
      return;
    }
    this.hrvLoading = true;
    ApiClient.getHrvRange(14)
      .then((r: HrvRange) => {
        this.hrvRange = r;
        this.hrvLoading = false;
        DeviceStore.cachePut(key, JSON.stringify(r));
      })
      .catch((e: Object) => {
        this.hrvLoading = false;
      });
  }

  private hrvRangeText(v: number | null): string {
    return v === null ? '--' : '' + v;
  }

  private hrvColorOf(v: number | null): ResourceColor {
    const r = this.hrvRange;
    if (v === null || r === null || r.min === null || r.max === null || r.max <= r.min) {
      return $r('app.color.text_secondary');
    }
    const rel = (v - r.min) / (r.max - r.min);
    if (rel >= 0.66) {
      return $r('app.color.accent');
    }
    if (rel <= 0.33) {
      return $r('app.color.warn');
    }
    return $r('app.color.text_secondary');
  }

  @Builder
  hrvRangeCard() {
    Column() {
      Row() {
        Text('HRV（近 14 天）').fontSize(13).fontWeight(FontWeight.Medium)
        Blank()
        Button(this.hrvLoading ? '读取中…' : (this.hrvRange === null ? '读取' : '刷新'))
          .fontSize(11).height(28)
          .backgroundColor($r('app.color.chip_background')).fontColor($r('app.color.text_secondary'))
          .enabled(!this.hrvLoading)
          .onClick(() => { this.loadHrvRange(); })
      }
      .width('100%')

      if (this.hrvRange !== null) {
        if (!this.hrvRange.available) {
          Text('该账号近 14 天没有 HRV 数据（需要手表支持 HRV Status 且佩戴过夜）')
            .fontSize(11).fontColor($r('app.color.text_hint')).width('100%').margin({ top: 8 })
        } else {
          Row() {
            Column() {
              Text('均值').fontSize(10).fontColor($r('app.color.text_tertiary'))
              Text(this.hrvRangeText(this.hrvRange.avg) + ' ms').fontSize(13).fontWeight(FontWeight.Medium)
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1)
            Column() {
              Text('区间').fontSize(10).fontColor($r('app.color.text_tertiary'))
              Text(this.hrvRangeText(this.hrvRange.min) + ' ~ ' + this.hrvRangeText(this.hrvRange.max))
                .fontSize(13).fontWeight(FontWeight.Medium)
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1)
            Column() {
              Text('有效天数').fontSize(10).fontColor($r('app.color.text_tertiary'))
              Text(this.hrvRange.count + ' / 14').fontSize(13).fontWeight(FontWeight.Medium)
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1)
          }
          .width('100%').margin({ top: 10 })

          Column() {
            ForEach(this.hrvRange.days, (d: HrvDay) => {
              Row() {
                Text(d.date.substring(5)).fontSize(11).fontColor($r('app.color.text_secondary')).width(46)
                Text(this.hrvRangeText(d.value)).fontSize(12).fontWeight(FontWeight.Medium)
                  .fontColor(this.hrvColorOf(d.value)).width(40)
                Text(d.status === null ? '' : this.hrvStatusCn(d.status)).fontSize(10)
                  .fontColor($r('app.color.text_tertiary')).layoutWeight(1).textAlign(TextAlign.End)
              }
              .width('100%').padding({ top: 4, bottom: 4 })
            }, (d: HrvDay) => d.date)
          }
          .width('100%').margin({ top: 6 })

          Text('状态按佳明 HRV Status 判定；颜色表示该日在你近 14 天区间中的相对位置')
            .fontSize(9).fontColor($r('app.color.text_hint')).width('100%').margin({ top: 6 })
        }
      } else {
        Text('点击「读取」拉取近 14 天 HRV（一次请求，缓存 1 小时）')
          .fontSize(11).fontColor($r('app.color.text_hint')).width('100%').margin({ top: 8 })
      }
    }
    .padding(14).width('100%').margin({ top: 10 })
    .backgroundColor($r('app.color.card_background_blur'))
    .border({ width: 1, color: $r('app.color.card_border_highlight') })
    .borderRadius(14)
  }

  private hrvStatusCn(s: string): string {
    if (s === 'LOW') {
      return '偏低';
    }
    if (s === 'HIGH') {
      return '偏高';
    }
    if (s === 'BALANCED') {
      return '平衡';
    }
    return s;
  }

  /** 载入近 14 天静息心率（逐日 /summary；命中缓存则不请求） */
  private loadRecovery(): void {
    this.loadHrvRange();
    if (this.rhrLoading) {
      return;
    }
    const key = 'recovery:14';
    const cached = DeviceStore.cacheGet(key);
    if (cached.length > 10 && DeviceStore.cacheAge(key) < 3600000) {
      this.applyRecovery(cached);
      return;
    }
    if (!DeviceStore.isPaired()) {
      this.rhrErr = '尚未配对';
      return;
    }
    this.rhrLoading = true;
    this.rhrErr = '';
    const days: string[] = [];
    const vals: number[] = [];
    let idx = 0;
    const step = () => {
      if (idx >= 14) {
        const payload = JSON.stringify({ days: days, vals: vals });
        DeviceStore.cachePut(key, payload);
        this.rhrDays = days;
        this.rhrValues = vals;
        this.rhrReady = true;
        this.rhrLoading = false;
        return;
      }
      const date = Fmt.shiftDays(Fmt.today(), -idx);
      idx++;
      ApiClient.getSummary(date)
        .then((s: Summary) => {
          const r = s.restingHeartRate;
          if (r !== null && r > 20) {
            days.push(date.substring(5));
            vals.push(r);
          }
        })
        .catch((e: Object) => { })
        .then(() => { step(); });
    };
    step();
  }

  private applyRecovery(json: string): void {
    try {
      const o = JSON.parse(json) as RecoveryCache;
      if (o.days.length > 0) {
        this.rhrDays = o.days;
        this.rhrValues = o.vals;
        this.rhrReady = true;
      }
    } catch (e) {
      DeviceStore.cachePut('recovery:14', '');
    }
  }

  private rhrMin(): number {
    let m = 999;
    for (let i = 0; i < this.rhrValues.length; i++) {
      if (this.rhrValues[i] < m) m = this.rhrValues[i];
    }
    return m === 999 ? 0 : m;
  }

  private rhrMax(): number {
    let m = 0;
    for (let i = 0; i < this.rhrValues.length; i++) {
      if (this.rhrValues[i] > m) m = this.rhrValues[i];
    }
    return m;
  }

  private rhrAvg(): number {
    if (this.rhrValues.length === 0) {
      return 0;
    }
    let s = 0;
    for (let i = 0; i < this.rhrValues.length; i++) {
      s += this.rhrValues[i];
    }
    return Math.round((s / this.rhrValues.length) * 10) / 10;
  }

  private rhrWidth(v: number): string {
    const lo = this.rhrMin();
    const hi = this.rhrMax();
    if (hi <= lo) {
      return '50%';
    }
    const pct = 20 + ((v - lo) / (hi - lo)) * 80;
    return Math.round(pct) + '%';
  }

  @Builder
  recoveryPanel() {
    Column() {
      if (!this.rhrReady) {
        Row() {
          Text(this.rhrErr.length > 0 ? this.rhrErr : '逐日读取近 14 天静息心率（14 次请求，结果缓存 1 小时）')
            .fontSize(11).fontColor($r('app.color.text_secondary')).layoutWeight(1)
          Button(this.rhrLoading ? '读取中…' : '开始读取')
            .fontSize(12).height(30)
            .backgroundColor($r('app.color.accent')).fontColor($r('app.color.accent_on'))
            .enabled(!this.rhrLoading)
            .onClick(() => { this.loadRecovery(); })
        }
        .width('100%').padding(14)
        .backgroundColor($r('app.color.card_background_blur'))
        .border({ width: 1, color: $r('app.color.card_border_highlight') })
        .borderRadius(14)
      } else {
        Column() {
          Row() {
            Column() {
              Text('静息心率').fontSize(11).fontColor($r('app.color.text_tertiary'))
              Text(this.rhrAvg() + ' bpm').fontSize(20).fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.accent'))
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1)
            Column() {
              Text('区间').fontSize(10).fontColor($r('app.color.text_tertiary'))
              Text(this.rhrMin() + ' ~ ' + this.rhrMax()).fontSize(13).fontWeight(FontWeight.Medium)
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1)
            Column() {
              Text('样本').fontSize(10).fontColor($r('app.color.text_tertiary'))
              Text(this.rhrValues.length + ' 天').fontSize(13).fontWeight(FontWeight.Medium)
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1)
          }
          .width('100%')

          Column() {
            ForEach(this.rhrDays, (d: string, i: number) => {
              Row() {
                Text(d).fontSize(11).fontColor($r('app.color.text_secondary')).width(46)
                Row() {
                    Row()
                      .width(this.rhrWidth(this.rhrValues[i]))
                      .height(10).borderRadius(5).backgroundColor($r('app.color.danger'))
                  }
                  .layoutWeight(1)
                  .height(10).borderRadius(5).backgroundColor($r('app.color.chip_background'))
                Text('' + this.rhrValues[i]).fontSize(11).width(34).textAlign(TextAlign.End)
              }
              .width('100%').padding({ top: 4, bottom: 4 })
            }, (d: string) => d)
          }
          .width('100%').margin({ top: 10 })

          this.hrvRangeCard()

          Text('读法：静息心率低于个人基线（约低于 7 天均值 3 bpm 以上）通常表示恢复良好；'
            + '连续 2~3 天高于基线 5 bpm 以上，常见于疲劳累积、睡眠不足或身体不适，建议降低强度。')
            .fontSize(9).fontColor($r('app.color.text_hint')).width('100%').margin({ top: 6 })
        }
        .padding(14).width('100%')
        .backgroundColor($r('app.color.card_background_blur'))
        .border({ width: 1, color: $r('app.color.card_border_highlight') })
        .borderRadius(14)
      }
    }
    .width('100%')
    
  }

  @Builder
  predictPanel() {
    Column() {
      Column() {
        Text('环境与目标参数').fontSize(13).fontWeight(FontWeight.Medium).width('100%')
        this.inputRow('目标距离', this.pDistance, 'km', 'dist')
        this.inputRow('总爬升', this.pClimb, 'm', 'climb')
        this.inputRow('体重', this.pWeight, 'kg', 'weight')
        this.inputRow('车重', this.pBike, 'kg', 'bike')
        this.inputRow('风阻 CdA', this.pCda, 'm²', 'cda')
        this.inputRow('滚阻 Crr', this.pCrr, '', 'crr')
        this.inputRow('目标功率', this.pPower, 'W', 'power')
        this.inputRow('传动效率', this.pEff, '%', 'eff')
        Row() {
          Button('计算').fontSize(13).height(36).layoutWeight(1)
            .backgroundColor($r('app.color.accent')).fontColor($r('app.color.accent_on'))
            .onClick(() => {
              this.runPredict();
              // 收起输入法：计算完成后键盘不再占屏，方便看结果
              try {
                inputMethod.getController().stopInputSession();
              } catch (e) {
              }
            })
        }
        .width('100%').margin({ top: 8 })
      }
      .padding(14).width('100%')
      .backgroundColor($r('app.color.card_background_blur'))
      .border({ width: 1, color: $r('app.color.card_border_highlight') })
      .borderRadius(14)

      if (this.predReady) {
        Column() {
          Row() {
            Column() {
              Text('预计均速').fontSize(10).fontColor($r('app.color.text_tertiary'))
              Text(this.predSpeed + ' km/h').fontSize(20).fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.accent'))
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1)
            Column() {
              Text('预计用时').fontSize(10).fontColor($r('app.color.text_tertiary'))
              Text(this.fmtDuration(this.predSeconds)).fontSize(16).fontWeight(FontWeight.Bold)
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1)
            Column() {
              Text('TSS 估算').fontSize(10).fontColor($r('app.color.text_tertiary'))
              Text('' + this.predTss).fontSize(20).fontWeight(FontWeight.Bold)
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1)
          }
          .width('100%')

          Text('功率分解（按 %FTP 估算，非生理测量）').fontSize(11)
            .fontColor($r('app.color.text_tertiary')).width('100%').margin({ top: 10 })
          Row() {
            if (this.predAnaerobic > 0) {
              Row().width(this.predAnaerobic + '%').height(12).backgroundColor('#D9534F')
            }
            Row().width(this.predThreshold + '%').height(12).backgroundColor('#E0A33E')
            Row().width(this.predAerobic + '%').height(12).backgroundColor('#2FA36B')
          }
          .width('100%').borderRadius(6).clip(true).margin({ top: 4 })
          Row() {
            Text('无氧 ' + this.predAnaerobic + '%').fontSize(10).fontColor('#D9534F').layoutWeight(1)
            Text('阈值 ' + this.predThreshold + '%').fontSize(10).fontColor('#E0A33E').layoutWeight(1).textAlign(TextAlign.Center)
            Text('有氧 ' + this.predAerobic + '%').fontSize(10).fontColor('#2FA36B').layoutWeight(1).textAlign(TextAlign.End)
          }
          .width('100%').margin({ top: 4 })

          Text('实际采用：CdA ' + this.clampOf(this.numOf(this.pCda, 0.30), 0.15, 0.70)
            + ' · Crr ' + this.clampOf(this.numOf(this.pCrr, 0.005), 0.002, 0.020)
            + ' · 总重 ' + (this.clampOf(this.numOf(this.pWeight, 75), 30, 200) + this.clampOf(this.numOf(this.pBike, 12), 5, 25)) + ' kg'
            + ' · 传动效率 ' + Math.round(this.effOf() * 100) + '%'
            + '　' + this.predOutOfRange())
            .fontSize(9).fontColor(COLOR_HINT).width('100%').margin({ top: 6 })
          Text('模型：P·η = (Crr·m·g·cosθ + m·g·sinθ + ½·ρ·CdA·v²)·v，ρ 取 1.225，η 为传动效率；'
            + '二分法解均速，假设全程匀速（起步与减速会使实际用时略长）。'
            + (this.e90 === null ? ' FTP 未取得则不做 TSS/分解。' : ' eFTP 取 ' + this.e90 + ' W。'))
            .fontSize(9).fontColor($r('app.color.text_hint')).width('100%').margin({ top: 8 })
        }
        .padding(14).width('100%').margin({ top: 10 })
        .backgroundColor($r('app.color.card_background_blur'))
        .border({ width: 1, color: $r('app.color.card_border_highlight') })
        .borderRadius(14)
      }
    }
    .width('100%')
  }


  @Builder
  tsbLegend() {
    Column() {
      Text('TSB 状态区间').fontSize(12).fontColor($r('app.color.text_tertiary')).width('100%')
      Row() {
        Row().width('25%').height(10).backgroundColor('#D9534F')
        Row().width('25%').height(10).backgroundColor('#E0A33E')
        Row().width('25%').height(10).backgroundColor('#8A93A5')
        Row().width('25%').height(10).backgroundColor('#2FA36B')
      }
      .width('100%').borderRadius(5).clip(true).margin({ top: 6 })
      Row() {
        Text('< −30 过度').fontSize(9).fontColor('#D9534F').layoutWeight(1)
        Text('−30~−10 有负荷').fontSize(9).fontColor('#E0A33E').layoutWeight(1).textAlign(TextAlign.Center)
        Text('−10~+5 正常').fontSize(9).fontColor('#8A93A5').layoutWeight(1).textAlign(TextAlign.Center)
        Text('>+5 新鲜').fontSize(9).fontColor('#2FA36B').layoutWeight(1).textAlign(TextAlign.End)
      }
      .width('100%').margin({ top: 4 })
    }
    .padding(14).width('100%').margin({ top: 10 })
    .backgroundColor($r('app.color.card_background_blur'))
    .border({ width: 1, color: $r('app.color.card_border_highlight') })
    .borderRadius(14)
  }

  @Builder
  loadRow(p: TrendPoint) {
    Row() {
      Text(p.date.substring(5)).fontSize(11).width(54)
      Text(p.tss === null ? '--' : '' + Math.round(p.tss)).fontSize(11).layoutWeight(1).textAlign(TextAlign.End)
      Text(p.ctl === null ? '--' : '' + p.ctl).fontSize(11).width(46).textAlign(TextAlign.End)
      Text(p.atl === null ? '--' : '' + p.atl).fontSize(11).width(46).textAlign(TextAlign.End)
        .fontColor($r('app.color.danger'))
      Text(p.tsb === null ? '--' : '' + p.tsb).fontSize(11).width(46).textAlign(TextAlign.End)
        .fontColor(p.tsb !== null && p.tsb >= -10 ? $r('app.color.accent') : $r('app.color.warn'))
    }
    .width('100%').padding({ top: 4, bottom: 4 })
  }

  /** 最近 N 天明细（倒序） */
  private recentDays(n: number): TrendPoint[] {
    const t = this.trend;
    if (t === null) {
      return [];
    }
    const out: TrendPoint[] = [];
    for (let i = t.points.length - 1; i >= 0 && out.length < n; i--) {
      out.push(t.points[i]);
    }
    return out;
  }

  @Builder
  loadTable() {
    Column() {
      Row() {
        Text('训练负荷明细').fontSize(13).fontWeight(FontWeight.Medium)
        Blank()
        Text('近 ' + this.loadDays + ' 天').fontSize(10).fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      Row() {
        Text('日期').fontSize(11).fontColor($r('app.color.text_tertiary')).width(54)
        Text('TSS').fontSize(11).fontColor($r('app.color.text_tertiary')).layoutWeight(1).textAlign(TextAlign.End)
        Text('CTL').fontSize(11).fontColor($r('app.color.text_tertiary')).width(46).textAlign(TextAlign.End)
        Text('ATL').fontSize(11).fontColor($r('app.color.text_tertiary')).width(46).textAlign(TextAlign.End)
        Text('TSB').fontSize(11).fontColor($r('app.color.text_tertiary')).width(46).textAlign(TextAlign.End)
      }
      .width('100%').padding({ top: 8, bottom: 4 })
      ForEach(this.recentDays(this.loadDays), (p: TrendPoint) => {
        this.loadRow(p)
      }, (p: TrendPoint) => p.date)
      Row() {
        Blank()
        Button(this.loadDays >= 30 ? '收起' : '显示更多')
          .fontSize(11).height(28)
          .backgroundColor($r('app.color.chip_background')).fontColor($r('app.color.text_secondary'))
          .onClick(() => { this.loadDays = this.loadDays >= 30 ? 10 : 30; })
      }
      .width('100%').margin({ top: 6 })
    }
    .padding(14).width('100%').margin({ top: 10 })
    .backgroundColor($r('app.color.card_background_blur'))
    .border({ width: 1, color: $r('app.color.card_border_highlight') })
    .borderRadius(14)
  }

  @Builder
  statusPanel() {
    Column() {
      Column() {
        Row() {
          Column() {
            Text('今日表单 TSB').fontSize(11).fontColor($r('app.color.text_tertiary'))
            Text(Fmt.num1(this.tsbNow(), '')).fontSize(26).fontWeight(FontWeight.Bold).fontColor(this.formColor())
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
          Column() {
            Text(this.formTitle()).fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.formColor())
            Text('建议周 TSS ' + this.suggestTss()).fontSize(10).fontColor($r('app.color.text_tertiary')).margin({ top: 3 })
          }
          .alignItems(HorizontalAlign.End)
        }
        .width('100%')
        Text(this.formAdvice()).fontSize(11).fontColor($r('app.color.text_secondary')).width('100%').margin({ top: 6 })
        Text('建议周 TSS：维持 = CTL×7，进阶 = (CTL+4)×7 —— 即每周 CTL 涨 4 点左右（安全区 3~5）')
          .fontSize(9).fontColor($r('app.color.text_hint')).width('100%').margin({ top: 6 })
      }
      .padding(14).width('100%')
      .backgroundColor($r('app.color.card_background_blur'))
      .border({ width: 1, color: $r('app.color.card_border_highlight') })
      .borderRadius(14)

      Column() {
        Row() {
          Text('周次').fontSize(11).fontColor($r('app.color.text_tertiary')).width(70)
          Text('TSS').fontSize(11).fontColor($r('app.color.text_tertiary')).layoutWeight(1).textAlign(TextAlign.End)
          Text('CTL').fontSize(11).fontColor($r('app.color.text_tertiary')).width(52).textAlign(TextAlign.End)
          Text('ATL').fontSize(11).fontColor($r('app.color.text_tertiary')).width(52).textAlign(TextAlign.End)
          Text('TSB').fontSize(11).fontColor($r('app.color.text_tertiary')).width(52).textAlign(TextAlign.End)
        }
        .width('100%').padding({ bottom: 6 })
        ForEach(this.weekRows(6), (w: WeekRow) => {
          Row() {
            Text(w.label).fontSize(12).width(70)
            Text('' + w.tss).fontSize(12).layoutWeight(1).textAlign(TextAlign.End)
            Text('' + w.ctl).fontSize(12).width(52).textAlign(TextAlign.End)
            Text('' + w.atl).fontSize(12).width(52).textAlign(TextAlign.End).fontColor($r('app.color.danger'))
            Text('' + w.tsb).fontSize(12).width(52).textAlign(TextAlign.End)
              .fontColor(w.tsb >= -10 ? $r('app.color.accent') : $r('app.color.warn'))
          }
          .width('100%').padding({ top: 5, bottom: 5 })
        }, (w: WeekRow) => w.label)
      }
      .padding(14).width('100%').margin({ top: 10 })
      .backgroundColor($r('app.color.card_background_blur'))
      .border({ width: 1, color: $r('app.color.card_border_highlight') })
      .borderRadius(14)
    }
    .width('100%')
  }

  build() {
    Refresh({ refreshing: $$this.refreshing }) {
      Scroll() {
        Column() {
          Row() {
            Text('数据中心').fontSize(16).fontWeight(FontWeight.Bold)
            Blank()
            Text(this.trend === null ? '' : '近 ' + this.trend.days + ' 天').fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%').padding({ bottom: 8 })

          Scroll() {
            Row({ space: 8 }) {
              ForEach(PANELS, (p: PanelDef) => {
                this.panelChip(p)
              }, (p: PanelDef) => p.key)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .padding({ bottom: 10 })

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
          if (this.loading && this.trend === null) {
            Row() {
              LoadingProgress().width(22).height(22)
              Text('读取中…').fontSize(13).fontColor($r('app.color.text_tertiary')).margin({ left: 8 })
            }
            .padding(16)
          }

          if (this.trend !== null) {
            if (this.panel === 'overview') {
              this.overviewPanel()
            } else if (this.panel === 'curve') {
              this.curvePanel()
            } else if (this.panel === 'shape') {
              this.shapePanel()
            } else if (this.panel === 'fatigue') {
              this.fatiguePanel()
            } else if (this.panel === 'predict') {
              this.predictPanel()
            } else if (this.panel === 'recovery') {
              this.recoveryPanel()
            } else {
              this.statusPanel()
            }
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
