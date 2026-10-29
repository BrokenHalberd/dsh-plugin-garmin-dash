/**
 * GarminLocalSource.ets —— 手机端本地数据源（直连佳明，不经过 PC 后端）
 *
 * 目标：手机自己取数、自己续期，PC 只是首次登录的入口。
 *
 * 与后端的对应关系（语义必须一致，否则两端显示会不同）：
 *  · summary      ← /usersummary-service/usersummary/daily/{displayName}（步数/热卡/静息心率）
 *                   + /sleep-service/sleep/dailySleepData（睡眠 DTO，秒→分钟）
 *                   + /weight-service/weight/dayview（克→kg，失败不致命）
 *                   + /usersummary-service/stats/bodybattery/daily/{d}/{d}（当日高/低值）
 *  · hrv          ← /hrv-service/hrv/{date}，当日没有则**回溯最多 7 天**（佳明常次日出）
 *  · bodyBattery  ← stats/bodybattery/daily/{d}/{d}，取 values.highBodyBattery
 *  · curve        ← 活动列表项自带的 maxAvgPower_*（不可用 normalize 后的对象，字段会被裁掉）
 *  · trend        ← 活动 TSS + Coggan EMA（CTL τ=42 / ATL τ=7 / TSB=CTL_today−ATL_yesterday）
 *  · activities   ← /activitylist-service/activities/search/activities
 */
import { GarminApi } from './GarminApi';
import { Activity, ActivityDetail, BodyBattery, CurveData, HrvDay, HrvInfo, HrvRange, SleepInfo, Summary, Trend, TrendPoint, WeeklyTotal, WeightInfo } from '../model/Types';

const CTL_TAU: number = 42;
const ATL_TAU: number = 7;
const WARMUP_DAYS: number = 120;

// ── JSON 取值工具（ArkTS 里动态字段必须显式转换）────────────────────
function asObj(v: Object | null | undefined): Record<string, Object> | null {
  if (v === null || v === undefined) {
    return null;
  }
  return v as Record<string, Object>;
}

function str(o: Record<string, Object> | null, key: string): string {
  if (o === null) {
    return '';
  }
  const v: Object | undefined = o[key];
  return typeof v === 'string' ? v as string : '';
}

function numOrNull(o: Record<string, Object> | null, key: string): number | null {
  if (o === null) {
    return null;
  }
  const v: Object | undefined = o[key];
  if (typeof v === 'number') {
    const n: number = v as number;
    return Number.isFinite(n) ? n : null;
  }
  if (typeof v === 'string' && (v as string).length > 0) {
    const n: number = Number(v as string);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

function objAt(o: Record<string, Object> | null, key: string): Record<string, Object> | null {
  if (o === null) {
    return null;
  }
  return asObj(o[key]);
}

function arrOf(v: Object | null | undefined): Object[] {
  return Array.isArray(v) ? v as Object[] : [];
}

function round1(x: number): number {
  return Math.round(x * 10) / 10;
}

/** 本地时区 YYYY-MM-DD */
export function localDate(d: Date): string {
  const y: number = d.getFullYear();
  const m: number = d.getMonth() + 1;
  const dd: number = d.getDate();
  return `${y}-${m < 10 ? '0' : ''}${m}-${dd < 10 ? '0' : ''}${dd}`;
}

export function addDays(date: string, delta: number): string {
  const parts: string[] = date.split('-');
  const y: number = Number(parts[0]);
  const m: number = Number(parts[1]);
  const d: number = Number(parts[2]);
  const dt = new Date(y, m - 1, d);
  dt.setDate(dt.getDate() + delta);
  return localDate(dt);
}

/** ISO 周首日（周一） */
export function isoWeekStart(date: string): string {
  const parts: string[] = date.split('-');
  const dt = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
  const shift: number = (dt.getDay() + 6) % 7;
  return addDays(date, -shift);
}

function dateRange(start: string, end: string): string[] {
  const out: string[] = [];
  let cursor: string = start;
  for (let i = 0; i < 10000; i++) {
    out.push(cursor);
    if (cursor >= end) {
      break;
    }
    cursor = addDays(cursor, 1);
  }
  return out;
}

function toLocalDate(value: string): string {
  if (value.length < 10) {
    return '';
  }
  const head: string = value.substring(0, 10);
  return head;
}

export class GarminLocalSource {
  private static displayName: string = '';

  /** displayName：user-settings 稳定且快；socialProfile 会偶发挂 30 秒 */
  private static async resolveDisplayName(): Promise<string> {
    if (GarminLocalSource.displayName.length > 0) {
      return GarminLocalSource.displayName;
    }
    const paths: string[] = [
      '/userprofile-service/userprofile/user-settings',
      '/userprofile-service/socialProfile'
    ];
    for (const p of paths) {
      try {
        const j = JSON.parse(await GarminApi.get(p)) as Object;
        const name: string = str(asObj(j), 'displayName');
        if (name.length > 0) {
          GarminLocalSource.displayName = name;
          return name;
        }
      } catch (e) {
        // 换下一个候选
      }
    }
    throw new Error('取不到 displayName');
  }

  /** 当日概览（与后端 summary 契约一致） */
  static async summary(date: string): Promise<Summary> {
    let daily: Record<string, Object> | null = null;
    try {
      const dn: string = await GarminLocalSource.resolveDisplayName();
      const raw: string = await GarminApi.get(
        `/usersummary-service/usersummary/daily/${encodeURIComponent(dn)}?calendarDate=${date}`);
      daily = asObj(JSON.parse(raw) as Object);
    } catch (e) {
      daily = null;
    }

    let sleepInfo: SleepInfo | null = null;
    try {
      const raw: string = await GarminApi.get(`/sleep-service/sleep/dailySleepData?date=${date}`);
      const dto: Record<string, Object> | null = objAt(asObj(JSON.parse(raw) as Object), 'dailySleepDTO');
      if (dto !== null) {
        const secToMin = (v: number | null): number | null => v === null ? null : Math.round(v / 60);
        const scores: Record<string, Object> | null = objAt(dto, 'sleepScores');
        const overall: Record<string, Object> | null = objAt(scores, 'overall');
        const info: SleepInfo = {
          score: numOrNull(overall, 'value'),
          durationMinutes: secToMin(numOrNull(dto, 'sleepTimeSeconds')),
          deepMinutes: secToMin(numOrNull(dto, 'deepSleepSeconds')),
          lightMinutes: secToMin(numOrNull(dto, 'lightSleepSeconds')),
          remMinutes: secToMin(numOrNull(dto, 'remSleepSeconds')),
          awakeMinutes: secToMin(numOrNull(dto, 'awakeSleepSeconds'))
        };
        sleepInfo = info;
      }
    } catch (e) {
      sleepInfo = null;
    }

    let weight: WeightInfo | null = null;
    try {
      const raw: string = await GarminApi.get(`/weight-service/weight/dayview?date=${date}`);
      const total: Record<string, Object> | null = objAt(asObj(JSON.parse(raw) as Object), 'totalAverage');
      const grams: number | null = numOrNull(total, 'weight');
      if (grams !== null && grams > 0) {
        const info: WeightInfo = { date, kg: Math.round(grams / 100) / 10, bodyFatPercent: null, bmi: null };
        weight = info;
      }
    } catch (e) {
      weight = null;
    }

    let bb: number | null = null;
    try {
      const raw: string = await GarminApi.get(
        `/usersummary-service/stats/bodybattery/daily/${date}/${date}`);
      const arr: Object[] = arrOf(JSON.parse(raw) as Object);
      if (arr.length > 0) {
        const values: Record<string, Object> | null = objAt(asObj(arr[0]), 'values');
        bb = numOrNull(values, 'highBodyBattery');
        if (bb === null) {
          bb = numOrNull(values, 'lowBodyBattery');
        }
      }
    } catch (e) {
      bb = null;
    }

    const summary: Summary = {
      date,
      steps: numOrNull(daily, 'totalSteps'),
      restingHeartRate: numOrNull(daily, 'restingHeartRate'),
      sleep: sleepInfo,
      weight,
      bodyBattery: bb,
      calories: numOrNull(daily, 'totalKilocalories'),
      activeCalories: numOrNull(daily, 'activeKilocalories'),
      stress: numOrNull(daily, 'averageStressLevel'),
      maxStress: numOrNull(daily, 'maxStressLevel')
    };
    return summary;
  }

  /** 活动列表（原始 → App 契约） */
  static async activities(limit: number, offset: number): Promise<Activity[]> {
    const raw: string = await GarminApi.get(
      `/activitylist-service/activities/search/activities?start=${offset}&limit=${limit}`);
    return GarminLocalSource.mapActivities(arrOf(JSON.parse(raw) as Object));
  }

  /** 最近 N 天的活动 */
  static async activitiesDays(days: number): Promise<Activity[]> {
    const end: string = localDate(new Date());
    const start: string = addDays(end, -(Math.max(1, days) - 1));
    const out: Activity[] = [];
    for (let page = 0; page < 6; page++) {
      let arr: Object[] = [];
      try {
        const raw: string = await GarminApi.get(
          `/activitylist-service/activities/search/activities?start=${page * 50}&limit=50`);
        arr = arrOf(JSON.parse(raw) as Object);
      } catch (e) {
        break;
      }
      if (arr.length === 0) {
        break;
      }
      for (const item of arr) {
        const a: Record<string, Object> = asObj(item) as Record<string, Object>;
        const d: string = toLocalDate(str(a, 'startTimeLocal'));
        if (d.length === 0 || d < start) {
          continue;
        }
        if (d > end) {
          continue;
        }
        out.push(GarminLocalSource.mapActivity(a));
      }
      if (arr.length < 50) {
        break;
      }
    }
    return out;
  }

  private static mapActivities(items: Object[]): Activity[] {
    const out: Activity[] = [];
    for (const it of items) {
      const o: Record<string, Object> | null = asObj(it);
      if (o !== null) {
        out.push(GarminLocalSource.mapActivity(o));
      }
    }
    return out;
  }

  private static mapActivity(a: Record<string, Object>): Activity {
    const typeObj: Record<string, Object> | null = objAt(a, 'activityType');
    const act: Activity = {
      id: numOrNull(a, 'activityId') ?? 0,
      name: str(a, 'activityName'),
      type: str(typeObj, 'typeKey'),
      startTime: str(a, 'startTimeLocal'),
      distanceMeters: numOrNull(a, 'distance'),
      durationSeconds: numOrNull(a, 'duration'),
      averageHeartRate: numOrNull(a, 'averageHR'),
      maxHeartRate: numOrNull(a, 'maxHR'),
      elevationGainMeters: numOrNull(a, 'elevationGain'),
      avgPower: numOrNull(a, 'avgPower'),
      normPower: numOrNull(a, 'normPower'),
      intensityFactor: numOrNull(a, 'intensityFactor'),
      trainingStressScore: numOrNull(a, 'trainingStressScore'),
      averageCadence: numOrNull(a, 'averageBikingCadenceInRevPerMinute')
    };
    return act;
  }

  /** 单活动全程功率曲线原始对象（maxAvgPower_1..18000，供详情页曲线图） */
  static async powerCurveRaw(id: number): Promise<Record<string, Object>> {
    const out: Record<string, Object> = {};
    try {
      const raw: string = await GarminApi.get('/activity-service/activity/' + id + '/powerCurve');
      const j: Record<string, Object> | null = asObj(JSON.parse(raw) as Object);
      if (j !== null) {
        const keys: string[] = Object.keys(j);
        for (const k of keys) {
          if (k.startsWith('maxAvgPower_') || k === 'excludeFromPowerCurveReports') {
            out[k] = j[k];
          }
        }
      }
    } catch (e) {
      // 无曲线数据的活动直接返回空对象
    }
    return out;
  }

  /** 单活动详情 */
  static async activityDetail(id: number): Promise<ActivityDetail> {
    const raw: string = await GarminApi.get(`/activity-service/activity/${id}`);
    const a: Record<string, Object> | null = asObj(JSON.parse(raw) as Object);
    if (a === null) {
      throw new Error('活动详情为空');
    }
    // 佳明把真实数值放在 summaryDTO 里，顶层只有元信息（否则距离/时长/TSS 全为 null）
    const a2: Record<string, Object> | null = asObj(a['summaryDTO']);
    // 活动级没有 vO2MaxValue 时，用该日用户级 maxmet 兜底
    let vo2: number | null = null;
    try {
      const day: string = toLocalDate(str(a, 'startTimeLocal'));
      if (day.length === 10) {
        const mm: string = await GarminApi.get('/metrics-service/metrics/maxmet/daily/' + day + '/' + day);
        const one: Record<string, Object> | null = asObj(JSON.parse(mm) as Object);
        const cyc: Record<string, Object> | null = objAt(one, 'cycling');
        const gen: Record<string, Object> | null = objAt(one, 'generic');
        vo2 = numOrNull(cyc, 'vo2MaxValue') ?? numOrNull(gen, 'vo2MaxValue');
      }
    } catch (e) {
      vo2 = null;
    }
    const src: Record<string, Object> = a2 !== null ? a2 : a;
    const d: ActivityDetail = {
      activityId: numOrNull(src, 'activityId') ?? id,
      activityName: (str(src, 'activityName').length > 0 && str(src, 'activityName') !== 'Unnamed')
        ? str(src, 'activityName')
        : str(a, 'activityName'),
      startTimeLocal: str(src, 'startTimeLocal'),
      distance: numOrNull(src, 'distance'),
      duration: numOrNull(src, 'duration'),
      averageHR: numOrNull(src, 'averageHR'),
      maxHR: numOrNull(src, 'maxHR'),
      elevationGain: numOrNull(src, 'elevationGain'),
      avgPower: numOrNull(src, 'avgPower') ?? numOrNull(src, 'averagePower'),
      maxPower: numOrNull(src, 'maxPower'),
      normPower: numOrNull(src, 'normPower') ?? numOrNull(src, 'normalizedPower'),
      intensityFactor: numOrNull(src, 'intensityFactor'),
      trainingStressScore: numOrNull(src, 'trainingStressScore'),
      activityTrainingLoad: numOrNull(src, 'activityTrainingLoad'),
      avgLeftBalance: numOrNull(src, 'leftBalance') ?? numOrNull(src, 'avgLeftBalance'),
      averageBikingCadenceInRevPerMinute: numOrNull(src, 'averageBikeCadence') ?? numOrNull(src, 'averageBikingCadenceInRevPerMinute'),
      vO2MaxValue: numOrNull(src, 'vO2MaxValue') ?? vo2,
      differenceBodyBattery: numOrNull(src, 'differenceBodyBattery'),
      aerobicTrainingEffect: numOrNull(src, 'aerobicTrainingEffect') ?? numOrNull(src, 'trainingEffect'),
      anaerobicTrainingEffect: numOrNull(src, 'anaerobicTrainingEffect')
    };
    return d;
  }

  /** 单日 HRV（含 7 天回溯，与后端一致） */
  static async hrv(date: string): Promise<HrvInfo> {
    const paths: string[] = ['/hrv-service/hrv/', '/hrv-service/hrv/daily/',
      '/wellness-service/wellness/dailyHrv/'];
    const fetchOne = async (d: string): Promise<HrvInfo | null> => {
      for (const base of paths) {
        try {
          const raw: string = await GarminApi.get(base + d);
          const j: Record<string, Object> | null = asObj(JSON.parse(raw) as Object);
          const summary: Record<string, Object> | null = objAt(j, 'hrvSummary') ?? j;
          const lastNight: number | null = numOrNull(summary, 'lastNightAvg');
          if (lastNight !== null) {
            const baseline: Record<string, Object> | null = objAt(summary, 'baseline');
            const info: HrvInfo = {
              available: true,
              date: d,
              lastNightAvg: lastNight,
              weeklyAvg: numOrNull(summary, 'weeklyAvg'),
              status: str(summary, 'status').length > 0 ? str(summary, 'status') : null,
              baselineLow: numOrNull(baseline, 'lowUpper'),
              baselineBalancedLow: numOrNull(baseline, 'balancedLow'),
              baselineBalancedUpper: numOrNull(baseline, 'balancedUpper'),
              feedback: str(summary, 'feedbackPhrase').length > 0 ? str(summary, 'feedbackPhrase') : null,
              reason: null
            };
            return info;
          }
        } catch (e) {
          // 下一个候选
        }
      }
      return null;
    };

    const today: HrvInfo | null = await fetchOne(date);
    if (today !== null) {
      return today;
    }
    for (let i = 1; i <= 7; i++) {
      const got: HrvInfo | null = await fetchOne(addDays(date, -i));
      if (got !== null) {
        return got;
      }
    }
    const empty: HrvInfo = {
      available: false, date, lastNightAvg: null, weeklyAvg: null, status: null,
      baselineLow: null, baselineBalancedLow: null, baselineBalancedUpper: null,
      feedback: null, reason: 'no_data'
    };
    return empty;
  }

  /**
   * HRV 区间（最近 N 天）。
   *
   * 性能要点：原实现逐日调用 hrv()（内部 3 条路径 × 最多 8 天回溯），14 天最坏会发出
   * 三百多次串行请求，App 会卡死/被系统回收（表现为"用一会就闪退"）。
   * 这里改为**每天只打一次**主路径，失败就当这天没有数据，请求数上界 = N。
   */
  static async hrvRange(days: number): Promise<HrvRange> {
    const n: number = Math.max(1, Math.min(30, days));
    const out: HrvDay[] = [];
    let sum: number = 0;
    let count: number = 0;
    let min: number | null = null;
    let max: number | null = null;
    for (let i = 0; i < n; i++) {
      const d: string = addDays(localDate(new Date()), -i);
      let value: number | null = null;
      let status: string | null = null;
      let weekly: number | null = null;
      try {
        const raw: string = await GarminApi.get('/hrv-service/hrv/' + d);
        const j: Record<string, Object> | null = asObj(JSON.parse(raw) as Object);
        const summary: Record<string, Object> | null = objAt(j, 'hrvSummary') ?? j;
        value = numOrNull(summary, 'lastNightAvg');
        status = str(summary, 'status').length > 0 ? str(summary, 'status') : null;
        weekly = numOrNull(summary, 'weeklyAvg');
      } catch (e) {
        // 该日无数据（佳明常返回 403/404）→ 记为 null，不重试、不回溯
      }
      const day: HrvDay = { date: d, value, status, weeklyAvg: weekly };
      out.push(day);
      if (value !== null) {
        sum += value;
        count += 1;
        min = min === null || value < min ? value : min;
        max = max === null || value > max ? value : max;
      }
    }
    const range: HrvRange = {
      available: count > 0,
      days: out,
      count,
      avg: count > 0 ? round1(sum / count) : null,
      min,
      max,
      reason: count > 0 ? null : 'no_data'
    };
    return range;
  }

  /** 当日身体电量 */
  static async bodyBattery(date: string): Promise<BodyBattery> {
    try {
      const raw: string = await GarminApi.get(
        `/usersummary-service/stats/bodybattery/daily/${date}/${date}`);
      const arr: Object[] = arrOf(JSON.parse(raw) as Object);
      if (arr.length > 0) {
        const values: Record<string, Object> | null = objAt(asObj(arr[0]), 'values');
        const high: number | null = numOrNull(values, 'highBodyBattery');
        const low: number | null = numOrNull(values, 'lowBodyBattery');
        const out: BodyBattery = {
          available: high !== null, date, value: high ?? low, high, low, reason: null
        };
        return out;
      }
    } catch (e) {
      // 落到 no_data
    }
    const empty: BodyBattery = { available: false, date, value: null, high: null, low: null, reason: 'no_data' };
    return empty;
  }

  /** 功率曲线（用列表项自带 maxAvgPower_*，零额外请求） */
  static async curve(days: number): Promise<CurveData> {
    const span: number = Math.max(7, Math.min(365, days));
    const secs: number[] = [1, 2, 5, 10, 20, 30, 60, 120, 300, 600, 1200, 1800, 3600, 7200, 18000];
    const p42: number[] = secs.map((s: number): number => 0);
    const p90: number[] = secs.map((s: number): number => 0);
    const pall: number[] = secs.map((s: number): number => 0);
    const zones: number[] = [0, 0, 0, 0, 0, 0, 0];

    const now: Date = new Date();
    const c42: string = addDays(localDate(now), -42);
    const c90: string = addDays(localDate(now), -90);

    const picks: Record<string, Object>[] = [];
    let scanned: number = 0;
    for (let page = 0; page < 4; page++) {
      let arr: Object[] = [];
      try {
        const raw: string = await GarminApi.get(
          `/activitylist-service/activities/search/activities?start=${page * 100}&limit=100`);
        arr = arrOf(JSON.parse(raw) as Object);
      } catch (e) {
        break;
      }
      if (arr.length === 0) {
        break;
      }
      scanned += arr.length;
      for (const it of arr) {
        const o: Record<string, Object> | null = asObj(it);
        if (o === null) {
          continue;
        }
        if (numOrNull(o, 'normPower') !== null && numOrNull(o, 'avgPower') !== null) {
          picks.push(o);
        }
      }
      // 与后端 curveSummary 一致：用**累计**命中数判定（arr.filter(hasPower).length >= 100）
      if (picks.length >= 100 || arr.length < 100) {
        break;
      }
    }

    let used: number = 0;
    for (const p of picks.slice(0, 80)) {
      const date: string = toLocalDate(str(p, 'startTimeLocal'));
      if (date.length === 0) {
        continue;
      }
      // 与后端一致：没有 maxAvgPower_* 的活动不计入 count（后端在 used++ 前就 continue）
      const hasAnyCurve: boolean = secs.some((s: number): boolean => typeof p[`maxAvgPower_${s}`] === 'number');
      if (!hasAnyCurve) {
        continue;
      }
      used += 1;
      for (let k = 0; k < secs.length; k++) {
        const v: number | null = numOrNull(p, `maxAvgPower_${secs[k]}`);
        if (v === null || v <= 0) {
          continue;
        }
        if (date >= c42 && v > p42[k]) {
          p42[k] = v;
        }
        if (date >= c90 && v > p90[k]) {
          p90[k] = v;
        }
        if (v > pall[k]) {
          pall[k] = v;
        }
      }
      if (date >= c90) {
        for (let z = 1; z <= 7; z++) {
          const zv: number | null = numOrNull(p, `powerTimeInZone_${z}`);
          if (zv !== null && zv > 0) {
            zones[z - 1] += zv;
          }
        }
      }
    }

    const eftp = (arr: number[]): number | null => arr[10] > 0 ? Math.round(arr[10] * 0.95) : null;
    const data: CurveData = {
      days: span,
      count: used,
      scanned,
      p42,
      p90,
      pall,
      e42: eftp(p42),
      e90: eftp(p90),
      eall: eftp(pall),
      zones,
      updatedAt: new Date().toISOString()
    };
    return data;
  }

  private static tssOf(a: Record<string, Object> | null): number {
    let v: number | null = numOrNull(a, 'trainingStressScore');
    if (v === null) {
      v = numOrNull(a, 'activityTrainingLoad');
    }
    return v === null || v < 0 ? 0 : v;
  }

  /** 训练负荷趋势（EMA 与后端 trend.mjs 完全一致） */
  static async trend(days: number): Promise<Trend> {
    const span: number = Math.max(7, Math.min(365, days));
    const end: string = localDate(new Date());
    const start: string = addDays(end, -(span - 1));
    const warmupStart: string = addDays(start, -WARMUP_DAYS);

    // 取足够覆盖 warmup 的活动（TSS 按日聚合）
    const tssByDate = new Map<string, number>();
    const acts: Record<string, Object>[] = [];
    const neededStart: string = warmupStart;
    for (let page = 0; page < 5; page++) {
      let arr: Object[] = [];
      try {
        const raw: string = await GarminApi.get(
          `/activitylist-service/activities/search/activities?start=${page * 50}&limit=50`);
        arr = arrOf(JSON.parse(raw) as Object);
      } catch (e) {
        break;
      }
      if (arr.length === 0) {
        break;
      }
      let reachedEarlier: boolean = false;
      for (const it of arr) {
        const o: Record<string, Object> | null = asObj(it);
        if (o === null) {
          continue;
        }
        const d: string = toLocalDate(str(o, 'startTimeLocal'));
        if (d.length === 0) {
          continue;
        }
        if (d < neededStart) {
          reachedEarlier = true;
          continue;
        }
        if (d > end) {
          continue;
        }
        acts.push(o);
        const prev: number = tssByDate.get(d) ?? 0;
        tssByDate.set(d, prev + GarminLocalSource.tssOf(o));
      }
      if (acts.length >= 400) {
        break;
      }
      if (reachedEarlier || arr.length < 50) {
        break;
      }
    }

    // 活动契约（用于周汇总）
    const activities: Activity[] = GarminLocalSource.mapActivities(acts);

    // EMA
    const points: TrendPoint[] = [];
    let ctl: number = 0;
    let atl: number = 0;
    let atlPrev: number = 0;
    for (const date of dateRange(warmupStart, end)) {
      const tss: number = tssByDate.get(date) ?? 0;
      ctl = ctl + (tss - ctl) / CTL_TAU;
      atl = atl + (tss - atl) / ATL_TAU;
      if (date < start) {
        atlPrev = round1(atl);
        continue;
      }
      const p: TrendPoint = {
        date,
        tss: round1(tss),
        ctl: round1(ctl),
        atl: round1(atl),
        tsb: round1(round1(ctl) - atlPrev)
      };
      points.push(p);
      atlPrev = round1(atl);
    }

    // 周汇总（ISO 周，周一为首日）
    const weekMap = new Map<string, WeeklyTotal>();
    for (const a of activities) {
      const d: string = toLocalDate(a.startTime);
      if (d.length === 0) {
        continue;
      }
      const wk: string = isoWeekStart(d);
      let row: WeeklyTotal | undefined = weekMap.get(wk);
      if (row === undefined) {
        const fresh: WeeklyTotal = { weekStart: wk, distanceMeters: 0, durationSeconds: 0, tss: 0 };
        weekMap.set(wk, fresh);
        row = fresh;
      }
      row.distanceMeters += a.distanceMeters ?? 0;
      row.durationSeconds += a.durationSeconds ?? 0;
      row.tss += a.trainingStressScore ?? 0;
    }
    const weekly: WeeklyTotal[] = [];
    weekMap.forEach((v: WeeklyTotal) => {
      const row: WeeklyTotal = {
        weekStart: v.weekStart,
        distanceMeters: Math.round(v.distanceMeters * 100) / 100,
        durationSeconds: Math.round(v.durationSeconds),
        tss: round1(v.tss)
      };
      weekly.push(row);
    });
    weekly.sort((a: WeeklyTotal, b: WeeklyTotal): number => a.weekStart < b.weekStart ? -1 : 1);

    const trend: Trend = { days: span, points, weekly };
    return trend;
  }
}
