/**
 * 后端接口客户端：/garmin-dash/api/*
 * 鉴权：除 health / pair 外，一律带 X-Device-Key 请求头（配对一次后长期有效）
 */
import { http } from '@kit.NetworkKit';
import { DeviceStore } from './DeviceStore';
import { GarminLocalSource, localDate } from './GarminLocalSource';
import { Summary, Activity, ActivityDetail, Trend, PairResult, DshLink, ChatReply , HrvInfo , HrvRange , CurveData , ActivitiesWindow , BodyBattery , RouteData } from '../model/Types';

export class ApiError extends Error {
  code: number;

  constructor(code: number, message: string) {
    super(message);
    this.code = code;
  }
}

interface ChatBody {
  text: string;
  sessionId: string;
}

interface PairBody {
  pairCode: string;
}

const TIMEOUT_MS: number = 20000;

export class ApiClient {
  /** GET 结果短期缓存：同一活动重复进入详情时秒开（TTL 120 秒） */
  private static getCache: Map<string, string> = new Map();
  private static getCacheAt: Map<string, number> = new Map();
  private static readonly GET_TTL_MS: number = 120000;
  /** 免鉴权的连通性检查（用于配对前验证地址） */
  static async health(baseUrl: string): Promise<string> {
    const url = ApiClient.normalize(baseUrl) + '/garmin-dash/api/health';
    const req = http.createHttp();
    try {
      const res = await req.request(url, {
        method: http.RequestMethod.GET,
        usingProtocol: http.HttpProtocol.HTTP1_1,
        connectTimeout: TIMEOUT_MS,
        readTimeout: TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      if (res.responseCode !== 200) {
        throw new ApiError(res.responseCode, 'HTTP ' + res.responseCode);
      }
      return res.result as string;
    } finally {
      req.destroy();
    }
  }

  /** 用一次性配对码换取长期设备密钥 */
  static async pair(baseUrl: string, pairCode: string): Promise<PairResult> {
    const url = ApiClient.normalize(baseUrl) + '/garmin-dash/api/pair';
    const req = http.createHttp();
    try {
      const header: Record<string, string> = { 'Content-Type': 'application/json' };
      const body: PairBody = { pairCode: pairCode };
      const res = await req.request(url, {
        method: http.RequestMethod.POST,
        usingProtocol: http.HttpProtocol.HTTP1_1,
        header: header,
        extraData: JSON.stringify(body),
        connectTimeout: TIMEOUT_MS,
        readTimeout: TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const text = res.result as string;
      if (res.responseCode !== 200) {
        throw new ApiError(res.responseCode, ApiClient.hint(res.responseCode, text));
      }
      return JSON.parse(text) as PairResult;
    } finally {
      req.destroy();
    }
  }

  static async getSummary(date: string): Promise<Summary> {
    const t = await ApiClient.authedGet('/garmin-dash/api/summary?date=' + date);
    return JSON.parse(t) as Summary;
  }

  static async getActivities(limit: number, offset: number): Promise<Activity[]> {
    const t = await ApiClient.authedGet('/garmin-dash/api/activities?limit=' + limit + '&offset=' + offset);
    return JSON.parse(t) as Activity[];
  }

  static async getActivityDetail(id: number): Promise<ActivityDetail> {
    const t = await ApiClient.authedGet('/garmin-dash/api/activity?id=' + id);
    return JSON.parse(t) as ActivityDetail;
  }

  /** 聚合接口：一次拿到 trend/summary/hrv/hrvRange/bodyBattery/activities ✓ */
  static async getBundle(days: number, date: string, parts: string): Promise<BundleResult> {
    const raw = await ApiClient.authedGet('/garmin-dash/api/bundle?days=' + days + '&date=' + date + '&parts=' + parts);
    return JSON.parse(raw) as BundleResult;
  }

  static async getTrend(days: number): Promise<Trend> {
    const t = await ApiClient.authedGet('/garmin-dash/api/trend?days=' + days);
    return JSON.parse(t) as Trend;
  }

  /** 取「DSH 对话」一次性配对链接（App 内直接打开即完成配对） */
  static async getDshLink(): Promise<DshLink> {
    const t = await ApiClient.authedGet('/garmin-dash/api/dsh-link');
    return JSON.parse(t) as DshLink;
  }
  /**
   * 内建聊天：把一条消息送进后端的固定持久会话，返回助手回复。
   * 后端保证工作区与权限档锁死，App 无法更改。
   */

  static async postChat(text: string, sessionId: string): Promise<ChatReply> {
    const t = await ApiClient.authedPost('/garmin-dash/api/chat', text, sessionId);
    return JSON.parse(t) as ChatReply;
  }
  private static async authedPost(path: string, text: string, sessionId: string): Promise<string> {
    const base = DeviceStore.getBaseUrl();
    if (base.length === 0) {
      throw new ApiError(0, '尚未配置服务器地址');
    }
    const key = DeviceStore.getDeviceKey();
    if (key.length === 0) {
      throw new ApiError(401, '尚未配对，请先在「我的」里配对');
    }
    const body: ChatBody = { text: text, sessionId: sessionId };
    const req = http.createHttp();
    try {
      const res = await req.request(base + path, {
        method: http.RequestMethod.POST,
        usingProtocol: http.HttpProtocol.HTTP1_1,
        header: { 'X-Device-Key': key, 'Content-Type': 'application/json' } as Record<string, string>,
        extraData: JSON.stringify(body),
        connectTimeout: TIMEOUT_MS,
        readTimeout: 240000,
        expectDataType: http.HttpDataType.STRING
      });
      const resText = res.result as string;
      if (res.responseCode !== 200) {
        throw new ApiError(res.responseCode, ApiClient.hint(res.responseCode, resText));
      }
      return resText;
    } finally {
      req.destroy();
    }
  }
  /** HRV（Garmin HRV Status）：单日 */
  static async getHrv(date: string): Promise<HrvInfo> {
    const txt = await ApiClient.authedGet('/garmin-dash/api/hrv?date=' + date);
    return JSON.parse(txt) as HrvInfo;
  }

  /** HRV（Garmin HRV Status）：最近 N 天，一次请求 */
  static async getHrvRange(days: number): Promise<HrvRange> {
    const txt = await ApiClient.authedGet('/garmin-dash/api/hrv-range?days=' + days);
    return JSON.parse(txt) as HrvRange;
  }

  /** 功率曲线聚合（后端算好）：一次请求 */
  static async getCurve(days: number): Promise<CurveData> {
    const txt = await ApiClient.authedGet('/garmin-dash/api/curve?days=' + days);
    return JSON.parse(txt) as CurveData;
  }

  /** 活动列表（按天窗口：近 N 天全部，不按条数截断） */
  static async getActivitiesDays(days: number): Promise<Activity[]> {
    const txt = await ApiClient.authedGet('/garmin-dash/api/activities?days=' + days);
    const obj = JSON.parse(txt) as ActivitiesWindow;
    return obj.activities;
  }

  /** 身体电量（当日最高/最低）：后端走直连端点，summary 里那个字段恒为 null */
  static async getBodyBattery(date: string): Promise<BodyBattery> {
    const txt = await ApiClient.authedGet('/garmin-dash/api/body-battery?date=' + date);
    return JSON.parse(txt) as BodyBattery;
  }

  /** 路线（后端抽稀后一次返回，缓存 6 小时） */
  /** 路线：失败自动重试（中继抖动时第二次基本都命中后端缓存） */
  static async getRouteRetry(id: number, points: number): Promise<RouteData> {
    let last: Error = new Error('路线加载失败');
    for (let i = 0; i < 3; i++) {
      try {
        return await ApiClient.getRoute(id, points);
      } catch (e) {
        last = e as Error;
        if (i < 2) {
          await new Promise<void>((resolve: () => void) => {
            setTimeout(() => { resolve(); }, 900);
          });
        }
      }
    }
    throw last;
  }

  static async getRoute(id: number, points: number): Promise<RouteData> {
    const txt = await ApiClient.authedGet('/garmin-dash/api/route?id=' + id + '&points=' + points);
    return JSON.parse(txt) as RouteData;
  }

  /**
   * 带鉴权的 GET。
   *
   * garminLocalFallback：正式版的**备用取数通道**——
   * 后端（公网中继/隧道）不通时，直接用手机内的 refresh_token 走佳明直连，
   * 结果序列化成同样的 JSON，因此所有视图无需任何改动。
   * 与本地版（com.atlas.garminlocal）共用同一套 GarminApi / GarminLocalSource。
   */
  private static async authedGet(path: string): Promise<string> {
    const cachedText = ApiClient.getCache.get(path);
    if (cachedText !== undefined) {
      const at = ApiClient.getCacheAt.get(path);
      if (at !== undefined && Date.now() - at < ApiClient.GET_TTL_MS) {
        return cachedText;
      }
    }
    const base = DeviceStore.getBaseUrl();
    const key = DeviceStore.getDeviceKey();
    if (base.length === 0 || key.length === 0) {
      const local = await ApiClient.tryLocal(path);
      if (local !== null) {
        ApiClient.getCache.set(path, local);
        ApiClient.getCacheAt.set(path, Date.now());
        return local;
      }
      if (base.length === 0) {
        throw new ApiError(0, '尚未配置服务器地址');
      }
      throw new ApiError(401, '尚未配对，请先在「我的」里配对');
    }
    const req = http.createHttp();
    try {
      const header: Record<string, string> = { 'Content-Type': 'application/json', 'X-Device-Key': key };
      const res = await req.request(base + path, {
        method: http.RequestMethod.GET,
        usingProtocol: http.HttpProtocol.HTTP1_1,
        header: header,
        connectTimeout: TIMEOUT_MS,
        readTimeout: TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const text = res.result as string;
      if (res.responseCode !== 200) {
        throw new ApiError(res.responseCode, ApiClient.hint(res.responseCode, text));
      }
      ApiClient.getCache.set(path, text);
      ApiClient.getCacheAt.set(path, Date.now());
      return text;
    } catch (e) {
      // 后端不通（隧道抖动 / PC 离线 / 中继 503）→ 直连佳明
      const local = await ApiClient.tryLocal(path);
      if (local !== null) {
        ApiClient.getCache.set(path, local);
        ApiClient.getCacheAt.set(path, Date.now());
        return local;
      }
      throw e as Error;
    } finally {
      req.destroy();
    }
  }

  /** 从查询串取参数 */
  private static queryValue(path: string, key: string): string {
    const q: number = path.indexOf('?');
    if (q < 0) {
      return '';
    }
    const parts: string[] = path.substring(q + 1).split('&');
    for (const part of parts) {
      const eq: number = part.indexOf('=');
      if (eq > 0 && part.substring(0, eq) === key) {
        return decodeURIComponent(part.substring(eq + 1));
      }
    }
    return '';
  }

  /**
   * 后端路径 → 直连佳明（备用取数通道）。返回 JSON 文本；无对应实现返回 null。
   * 内部异常一律吞掉返回 null，让调用方给出最终错误文案。
   */
  private static async tryLocal(path: string): Promise<string | null> {
    try {
      const prefix: string = '/garmin-dash/api/';
      if (!path.startsWith(prefix)) {
        return null;
      }
      const rest: string = path.substring(prefix.length);
      const name: string = rest.split('?')[0];
      if (name === 'summary') {
        const date: string = ApiClient.queryValue(path, 'date');
        const d: string = date.length > 0 ? date : localDate(new Date());
        return JSON.stringify(await GarminLocalSource.summary(d));
      }
      if (name === 'activities') {
        const days: string = ApiClient.queryValue(path, 'days');
        if (days.length > 0) {
          return JSON.stringify(await GarminLocalSource.activitiesDays(Number(days)));
        }
        const limit: number = Number(ApiClient.queryValue(path, 'limit'));
        const offset: number = Number(ApiClient.queryValue(path, 'offset'));
        return JSON.stringify(await GarminLocalSource.activities(
          limit > 0 ? limit : 20, offset > 0 ? offset : 0));
      }
      if (name === 'activity') {
        const id: number = Number(ApiClient.queryValue(path, 'id'));
        if (id <= 0) {
          return null;
        }
        const detail = await GarminLocalSource.activityDetail(id);
        const merged = JSON.parse(JSON.stringify(detail)) as Record<string, Object>;
        const curve = await GarminLocalSource.powerCurveRaw(id);
        const ck: string[] = Object.keys(curve);
        for (const k of ck) {
          merged[k] = curve[k];
        }
        return JSON.stringify(merged);
      }
      if (name === 'trend') {
        const days: number = Number(ApiClient.queryValue(path, 'days'));
        return JSON.stringify(await GarminLocalSource.trend(days > 0 ? days : 30));
      }
      if (name === 'curve') {
        const days: number = Number(ApiClient.queryValue(path, 'days'));
        return JSON.stringify(await GarminLocalSource.curve(days > 0 ? days : 90));
      }
      if (name === 'hrv') {
        const date: string = ApiClient.queryValue(path, 'date');
        const d: string = date.length > 0 ? date : localDate(new Date());
        return JSON.stringify(await GarminLocalSource.hrv(d));
      }
      if (name === 'hrv-range') {
        const days: number = Number(ApiClient.queryValue(path, 'days'));
        return JSON.stringify(await GarminLocalSource.hrvRange(days > 0 ? days : 14));
      }
      if (name === 'body-battery') {
        const date: string = ApiClient.queryValue(path, 'date');
        const d: string = date.length > 0 ? date : localDate(new Date());
        return JSON.stringify(await GarminLocalSource.bodyBattery(d));
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  static friendly(e: Object): string {
    const m = (e as Error).message ?? '';
    if (m.indexOf('HTTP2') >= 0 || m.indexOf('framing') >= 0) {
      return '网络协议协商失败（已自动改用 HTTP/1.1，请重装最新版 App）';
    }
    if (m.indexOf('timeout') >= 0 || m.indexOf('Timeout') >= 0) {
      return '网络超时：检查手机网络，或稍后重试';
    }
    if (m.indexOf('2300') >= 0 || m.indexOf('resolve') >= 0) {
      return '无法连接服务器：检查地址是否正确、电脑端分身是否在运行';
    }
    return '网络请求失败：' + m;
  }

  private static hint(code: number, body: string): string {
    if (code === 401) {
      return '未授权（设备密钥失效或未配对）';
    }
    if (code === 503) {
      return '上游（佳明）暂时不可用，稍后重试';
    }
    return 'HTTP ' + code + '：' + body;
  }

  private static normalize(url: string): string {
    let u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }
}


/** 聚合响应（各段可选，partial 标记失败的段） */
export interface RecoverySeries {
  days: string[];
  vals: number[];
}

export interface BundleResult {
  date: string;
  days: number;
  partial: string[];
  trend?: Trend;
  summary?: Summary;
  hrv?: HrvInfo;
  hrvRange?: HrvRange;
  curve?: CurveData;
  bodyBattery?: BodyBattery;
  activities?: Activity[];
  /** 近 N 天静息心率（后端 /api/bundle?parts=extra 一次性下发） */
  recovery?: RecoverySeries;
}
