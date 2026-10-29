/**
 * 数据模型：与后端 /garmin-dash/api/* 的契约一一对应
 */

export interface SleepInfo {
  score: number | null;
  durationMinutes: number | null;
  deepMinutes: number | null;
  lightMinutes: number | null;
  remMinutes: number | null;
  awakeMinutes: number | null;
}

export interface WeightInfo {
  date: string;
  kg: number | null;
  bodyFatPercent: number | null;
  bmi: number | null;
}

export interface Summary {
  date: string;
  steps: number | null;
  restingHeartRate: number | null;
  sleep: SleepInfo | null;
  weight: WeightInfo | null;
  bodyBattery: number | null;
  calories?: number | null;
  activeCalories?: number | null;
  stress?: number | null;
  maxStress?: number | null;
}

export interface Activity {
  id: number;
  name: string;
  type: string;
  startTime: string;
  distanceMeters: number | null;
  durationSeconds: number | null;
  averageHeartRate: number | null;
  maxHeartRate: number | null;
  elevationGainMeters: number | null;
  avgPower: number | null;
  normPower: number | null;
  intensityFactor: number | null;
  trainingStressScore: number | null;
  averageCadence: number | null;
}

export interface TrendPoint {
  date: string;
  tss: number | null;
  ctl: number | null;
  atl: number | null;
  tsb: number | null;
}

export interface Trend {
  days: number;
  points: TrendPoint[];
  weekly: WeeklyTotal[];
}

export interface WeeklyTotal {
  weekStart: string;
  distanceMeters: number;
  durationSeconds: number;
  tss: number;
}

export interface PairResult {
  deviceKey: string;
  deviceId: string;
}

/** 单次活动完整详情（字段随上游返回，可能缺项） */
export interface ActivityDetail {
  activityId: number;
  activityName: string;
  startTimeLocal: string;
  distance: number | null;
  duration: number | null;
  averageHR: number | null;
  maxHR: number | null;
  elevationGain: number | null;
  avgPower: number | null;
  maxPower: number | null;
  normPower: number | null;
  intensityFactor: number | null;
  trainingStressScore: number | null;
  activityTrainingLoad: number | null;
  avgLeftBalance: number | null;
  averageBikingCadenceInRevPerMinute: number | null;
  vO2MaxValue: number | null;
  differenceBodyBattery: number | null;
  aerobicTrainingEffect: number | null;
  anaerobicTrainingEffect: number | null;
}

export interface DshLink {
  url: string;
  ttlSeconds: number;
}
/** App 内建聊天的一轮回复 */
export interface ChatReply {
  reply: string;
  sessionId: string;
  tools: string[];
}
/** Garmin HRV（HRV Status）：昨夜均值 / 7 天均值 / 状态与基线 */
export interface HrvInfo {
  available: boolean;
  date: string;
  lastNightAvg: number | null;
  weeklyAvg: number | null;
  status: string | null;
  baselineLow: number | null;
  baselineBalancedLow: number | null;
  baselineBalancedUpper: number | null;
  feedback: string | null;
  reason: string | null;
}
/** HRV 单日 */
export interface HrvDay {
  date: string;
  value: number | null;
  status: string | null;
  weeklyAvg: number | null;
}

/** HRV 区间（最近 N 天） */
export interface HrvRange {
  available: boolean;
  days: HrvDay[];
  count: number;
  avg: number | null;
  min: number | null;
  max: number | null;
  reason: string | null;
}

/** 后端聚合好的功率曲线（一次请求） */
export interface CurveData {
  days: number;
  count: number;
  scanned: number;
  p42: number[];
  p90: number[];
  pall: number[];
  e42: number | null;
  e90: number | null;
  eall: number | null;
  zones: number[];
  updatedAt: string;
  error?: string;
}

/** 按天窗口的活动列表返回体 */
export interface ActivitiesWindow {
  days: number;
  from: string;
  count: number;
  scanned: number;
  activities: Activity[];
}

/** 身体电量（当日高/低值） */
export interface BodyBattery {
  available: boolean;
  date: string;
  value: number | null;
  high: number | null;
  low: number | null;
  reason: string | null;
  /** 当日充入（+）/ 消耗（-）总量，Garmin 的 "+74 / -50" */
  charged?: number | null;
  drained?: number | null;
  atWake?: number | null;
  current?: number | null;
}

/** 轨迹点（抽稀后） */
export interface RoutePoint {
  lat: number;
  lon: number;
  speed: number | null;
  power: number | null;
  hr: number | null;
  elev: number | null;
  dist: number | null;
}

/** 路线数据 */
export interface RouteData {
  available: boolean;
  id: number;
  rawPoints: number;
  points: RoutePoint[];
  bounds: RouteBounds;
  stats: RouteStats;
  reason: string | null;
}

export interface RouteBounds {
  minLat: number;
  maxLat: number;
  minLon: number;
  maxLon: number;
}

export interface RouteStats {
  speedMin: number | null;
  speedMax: number | null;
  powerMin: number | null;
  powerMax: number | null;
  powerAvg: number | null;
}

/** 爬坡段（由轨迹海拔与累计距离推算） */
export interface ClimbSeg {
  startKm: number;
  lengthKm: number;
  ascent: number;
  grade: number;
  cat: string;
  /** 在轨迹点数组中的起止下标（画面积用） */
  i0: number;
  i1: number;
}
