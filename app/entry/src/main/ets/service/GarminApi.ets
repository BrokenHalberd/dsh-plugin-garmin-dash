/**
 * Garmin 直连服务（手机侧）—— 由逆向 Node 依赖 garmin-connect 得到并实测验证。
 *
 * 来源与验证：
 *  · 端点表来自 garmin-connect/dist/garmin/UrlClass.js（REA 分析产物 + 直接读源交叉核对）；
 *  · 续期请求格式经 curl 实测通过（HTTP 200 + JSON，access/refresh 均返回）；
 *  · 续期后 refresh_token **会轮换**，所以必须回写本地存储，否则下次续期失效。
 *
 * 设计要点：
 *  1) 手机独立续期，不依赖 PC；只有当 refresh 也不可用时才回后端要一次（低频兜底）。
 *  2) access_token 寿命约 30 小时，refresh 约 30 天，故日常几乎不会碰网络续期。
 *  3) 401 自动续期并重试一次（与依赖里的行为一致）。
 */
import { http } from '@kit.NetworkKit';
import { DeviceStore } from './DeviceStore';

/** Garmin Connect 数据 API 域名 */
export const GC_API: string = 'https://connectapi.garmin.com';
/** 续期（DI OAuth2）域名与路径 */
export const GC_DIAUTH: string = 'https://diauth.garmin.com';
export const GC_TOKEN_PATH: string = '/di-oauth2-service/oauth/token';
/** 公共客户端 ID（依赖里是常量，非用户凭据） */
export const GC_CLIENT_ID: string = 'GARMIN_CONNECT_MOBILE_ANDROID_DI_2025Q2';

/** 续期结果 */
export interface GarminRefreshResult {
  ok: boolean;
  accessToken: string;
  refreshToken: string;
  accessExpiresAtMs: number;
  refreshExpiresAtMs: number;
  error: string;
}

/**
 * Garmin 原生客户端请求头。
 * 来源：garmin-connect 的 nativeHeaders()；缺这些头会被 diauth 直接返回登录页 HTML（实测）。
 */
export function garminNativeHeaders(): Record<string, string> {
  const h: Record<string, string> = {};
  h['Accept-Encoding'] = 'identity';
  h['Accept-Language'] = 'en-US,en;q=0.9';
  h['Cache-Control'] = 'no-cache';
  h['User-Agent'] = 'GCM-Android-5.23';
  h['X-App-Ver'] = '10861';
  h['X-Garmin-Client-Platform'] = 'Android';
  h['X-Garmin-Paired-App-Version'] = '10861';
  h['X-Garmin-User-Agent'] = 'com.garmin.android.apps.connectmobile';
  h['X-GCExperience'] = 'GC5';
  h['X-Lang'] = 'en';
  return h;
}

/** 把字符串转 base64（用于 Basic 认证头） */
function toBase64(input: string): string {
  const table: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let out: string = '';
  let i: number = 0;
  while (i < input.length) {
    const c1: number = input.charCodeAt(i);
    const c2: number = i + 1 < input.length ? input.charCodeAt(i + 1) : -1;
    const c3: number = i + 2 < input.length ? input.charCodeAt(i + 2) : -1;
    const e1: number = c1 >> 2;
    const e2: number = ((c1 & 3) << 4) | (c2 >= 0 ? c2 >> 4 : 0);
    const e3: number = c2 >= 0 ? (((c2 & 15) << 2) | (c3 >= 0 ? c3 >> 6 : 0)) : -1;
    const e4: number = c3 >= 0 ? (c3 & 63) : -1;
    out += table.charAt(e1);
    out += table.charAt(e2);
    out += e3 >= 0 ? table.charAt(e3) : '=';
    out += e4 >= 0 ? table.charAt(e4) : '=';
    i += 3;
  }
  return out;
}

/** x-www-form-urlencoded 编码（避免引入额外依赖） */
function formEncode(pairs: Map<string, string>): string {
  const parts: string[] = [];
  pairs.forEach((v: string, k: string) => {
    parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(v));
  });
  return parts.join('&');
}

/** 简单 JSON 取值（ArkTS 里直接访问动态字段不方便，这里集中处理） */
function jsonStr(obj: Object | null | undefined, key: string): string {
  if (obj === null || obj === undefined) {
    return '';
  }
  const rec = obj as Record<string, Object>;
  const v: Object | undefined = rec[key];
  return typeof v === 'string' ? v as string : '';
}

function jsonNum(obj: Object | null | undefined, key: string): number {
  if (obj === null || obj === undefined) {
    return 0;
  }
  const rec = obj as Record<string, Object>;
  const v: Object | undefined = rec[key];
  return typeof v === 'number' ? v as number : 0;
}

export class GarminApi {
  /** 并发上限：避免首页同时发出十几条请求把 Socket/内存打满 */
  private static inflight: number = 0;
  private static readonly MAX_INFLIGHT: number = 3;

  private static async acquire(): Promise<void> {
    for (let i = 0; i < 200; i++) {
      if (GarminApi.inflight < GarminApi.MAX_INFLIGHT) {
        GarminApi.inflight += 1;
        return;
      }
      await new Promise<void>((resolve) => setTimeout(() => resolve(), 50));
    }
    GarminApi.inflight += 1;
  }

  private static release(): void {
    GarminApi.inflight = GarminApi.inflight > 0 ? GarminApi.inflight - 1 : 0;
  }

  /** 内存里的 access_token（避免每次请求读 preferences） */
  private static access: string = '';
  private static accessExpMs: number = 0;

  /** 用 refresh_token 续期：POST diauth + Basic 认证 + 原生头 */
  static async refresh(): Promise<GarminRefreshResult> {
    const fail = (msg: string): GarminRefreshResult => {
      const r: GarminRefreshResult = {
        ok: false,
        accessToken: '',
        refreshToken: '',
        accessExpiresAtMs: 0,
        refreshExpiresAtMs: 0,
        error: msg
      };
      return r;
    };

    const rt: string = DeviceStore.getGarminRefreshToken();
    if (rt.length === 0) {
      return fail('没有 refresh_token，请先扫码配对一次');
    }
    const refreshExp: number = DeviceStore.getGarminRefreshExp();
    if (refreshExp > 0 && refreshExp <= Date.now()) {
      return fail('refresh_token 已过期，请重新配对');
    }

    const url: string = GC_DIAUTH + GC_TOKEN_PATH;
    const header = garminNativeHeaders();
    header['Accept'] = 'application/json';
    header['Authorization'] = 'Basic ' + toBase64(GC_CLIENT_ID + ':');
    header['Content-Type'] = 'application/x-www-form-urlencoded';

    const form = new Map<string, string>();
    form.set('grant_type', 'refresh_token');
    form.set('client_id', GC_CLIENT_ID);
    form.set('refresh_token', rt);

    const req = http.createHttp();
    let body: string = '';
    let code: number = 0;
    try {
      const res = await req.request(url, {
        method: http.RequestMethod.POST,
        header: header,
        extraData: formEncode(form),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 20000,
        readTimeout: 30000
      });
      code = res.responseCode;
      body = typeof res.result === 'string' ? res.result : '';
    } catch (e) {
      return fail('续期请求失败：' + (e as Error).message);
    } finally {
      req.destroy();
    }

    if (code !== 200) {
      return fail('续期 HTTP ' + code + '：' + (body.length > 120 ? body.substring(0, 120) : body));
    }

    let parsed: Object | null = null;
    try {
      parsed = JSON.parse(body) as Object;
    } catch (e) {
      return fail('续期响应不是 JSON（可能回到了登录页）');
    }

    const access: string = jsonStr(parsed, 'access_token');
    if (access.length === 0) {
      return fail('续期响应里没有 access_token');
    }
    // 轮换：服务端会返回新的 refresh_token，必须覆盖旧的
    const newRt: string = jsonStr(parsed, 'refresh_token');
    const expiresIn: number = jsonNum(parsed, 'expires_in');
    const refreshExpiresIn: number = jsonNum(parsed, 'refresh_token_expires_in');
    const now: number = Date.now();

    const accessExp: number = now + (expiresIn > 0 ? expiresIn * 1000 : 3600 * 1000);
    const refreshExpNew: number = refreshExpiresIn > 0 ? now + refreshExpiresIn * 1000 : refreshExp;

    GarminApi.access = access;
    GarminApi.accessExpMs = accessExp;
    DeviceStore.setGarminToken(access);
    DeviceStore.setGarminTokenExp(accessExp);
    if (newRt.length > 0) {
      DeviceStore.setGarminRefreshToken(newRt);
      DeviceStore.setGarminRefreshExp(refreshExpNew);
    }

    const ok: GarminRefreshResult = {
      ok: true,
      accessToken: access,
      refreshToken: newRt,
      accessExpiresAtMs: accessExp,
      refreshExpiresAtMs: refreshExpNew,
      error: ''
    };
    return ok;
  }

  /** 确保有一个可用的 access_token（快过期就续期；续不到再回后端要一次） */
  static async ensureAccess(): Promise<string> {
    const now: number = Date.now();
    if (GarminApi.access.length > 0 && GarminApi.accessExpMs > now + 60 * 1000) {
      return GarminApi.access;
    }
    const cached: string = DeviceStore.getGarminToken();
    const cachedExp: number = DeviceStore.getGarminTokenExp();
    if (cached.length > 0 && (cachedExp === 0 || cachedExp > now + 60 * 1000)) {
      GarminApi.access = cached;
      GarminApi.accessExpMs = cachedExp;
      return cached;
    }
    const r = await GarminApi.refresh();
    if (r.ok) {
      return r.accessToken;
    }
    // 兜底：后端仍然持有可用的佳明登录态
    const fromServer: string = await GarminApi.fetchTokenFromServer();
    if (fromServer.length > 0) {
      GarminApi.access = fromServer;
      return fromServer;
    }
    throw new Error('无法获取佳明 token：' + r.error);
  }

  /** 后端兜底取 token（低频，仅当本地续期失败；PC 不可达时返回空串） */
  static async fetchTokenFromServer(): Promise<string> {
    const base: string = DeviceStore.getBaseUrl();
    const key: string = DeviceStore.getDeviceKey();
    if (base.length === 0 || key.length === 0) {
      return '';
    }
    const url: string = base + '/garmin-dash/api/garmin-token';
    const req = http.createHttp();
    try {
      const res = await req.request(url, {
        method: http.RequestMethod.GET,
        header: { 'X-Device-Key': key } as Record<string, string>,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 8000,
        readTimeout: 12000
      });
      if (res.responseCode !== 200) {
        return '';
      }
      const body: string = typeof res.result === 'string' ? res.result : '';
      const obj = JSON.parse(body) as Object;
      const t: string = jsonStr(obj, 'access_token');
      const rt: string = jsonStr(obj, 'refresh_token');
      if (t.length > 0) {
        DeviceStore.setGarminToken(t);
      }
      if (rt.length > 0) {
        DeviceStore.setGarminRefreshToken(rt);
      }
      return t;
    } catch (e) {
      return '';
    } finally {
      req.destroy();
    }
  }

  /** 直连 GET：自动带 Bearer；401 续期后重试一次 */
  static async get(pathAndQuery: string): Promise<string> {
    let token: string = await GarminApi.ensureAccess();
    let res = await GarminApi.raw(token, pathAndQuery);
    if (res.code === 401) {
      const r = await GarminApi.refresh();
      if (r.ok) {
        token = r.accessToken;
        res = await GarminApi.raw(token, pathAndQuery);
      }
    }
    if (res.code < 200 || res.code >= 300) {
      throw new Error('Garmin HTTP ' + res.code + '：' + (res.body.length > 120 ? res.body.substring(0, 120) : res.body));
    }
    return res.body;
  }

  /** 单次原始请求 */
  private static async raw(token: string, pathAndQuery: string): Promise<GarminRawResponse> {
    const url: string = pathAndQuery.startsWith('http') ? pathAndQuery : (GC_API + pathAndQuery);
    await GarminApi.acquire();
    const header: Record<string, string> = {};
    header['Authorization'] = 'Bearer ' + token;
    header['Accept'] = 'application/json';
    header['User-Agent'] = 'GCM-Android-5.23';
    const req = http.createHttp();
    try {
      const res = await req.request(url, {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 8000,
        readTimeout: 15000
      });
      const body: string = typeof res.result === 'string' ? res.result : '';
      const out: GarminRawResponse = { code: res.responseCode, body: body };
      return out;
    } finally {
      GarminApi.release();
      req.destroy();
    }
  }

  // ── 数据端点（路径来自 garmin-connect 的 UrlClass + 后端实际调用）──────

  /** 当日汇总（步数/心率/睡眠等） */
  static async summaryRaw(date: string): Promise<string> {
    return GarminApi.get('/usersummary-service/usersummary/daily/?calendarDate=' + encodeURIComponent(date));
  }

  /** 活动列表 */
  static async activitiesRaw(limit: number, offset: number): Promise<string> {
    return GarminApi.get('/activitylist-service/activities/search/activities?start=' + String(offset)
      + '&limit=' + String(limit));
  }

  /** 活动详情 */
  static async activityRaw(id: number): Promise<string> {
    return GarminApi.get('/activity-service/activity/' + String(id));
  }

  /** HRV：按顺序尝试三个候选路径（与后端一致） */
  static async hrvRaw(date: string): Promise<string> {
    const paths: string[] = [
      '/hrv-service/hrv/' + date,
      '/hrv-service/hrv/daily/' + date,
      '/wellness-service/wellness/dailyHrv/' + date
    ];
    let lastErr: string = '';
    for (const p of paths) {
      try {
        return await GarminApi.get(p);
      } catch (e) {
        lastErr = (e as Error).message;
      }
    }
    throw new Error('HRV 三个候选路径都失败：' + lastErr);
  }

  /** 身体电量 */
  static async bodyBatteryRaw(date: string): Promise<string> {
    return GarminApi.get('/usersummary-service/stats/bodybattery/daily?calendarDate=' + encodeURIComponent(date));
  }
}

/** 原始响应包装 */
export interface GarminRawResponse {
  code: number;
  body: string;
}
