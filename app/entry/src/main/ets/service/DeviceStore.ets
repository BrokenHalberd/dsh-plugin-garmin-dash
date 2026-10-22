/**
 * 本地存储：公网入口地址 + 设备密钥（配对一次，之后免扫）
 * 使用 preferences 持久化；deviceKey 只在首次配对时写入。
 */
import { fileIo } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/** 安全数值格式化：null / undefined / NaN / Infinity 一律空串（防止卡片显示 NaN ✓） */
function safeRound(v: number | null | undefined, digits: number): string {
  if (v === null || v === undefined || !Number.isFinite(v)) {
    return '';
  }
  if (digits > 0) {
    const f = Math.pow(10, digits);
    return String(Math.round(v * f) / f);
  }
  return String(Math.round(v));
}

/** 卡片进程用的网络配置 */
export interface CardNet {
  base: string;
  key: string;
}

/** 服务卡片附加数据（睡眠/HRV） */
export interface CardExtra {
  weekTss: number | null;
  steps: number | null;
  rhr: number | null;
  bb: number | null;
  sleepDeep: number | null;
  sleepLight: number | null;
  sleepRem: number | null;
  sleepAwake: number | null;
  hrvNow: number | null;
  hrvLow: number | null;
  hrvB1: number | null;
  hrvB2: number | null;
}

/** 服务卡片展示用的缓存（由状态页刷新时写入） */
export interface CardCache {
  tsb: string;
  ctl: string;
  atl: string;
  ride: string;
  updated: string;
  weekTss: string;
  steps: string;
  rhr: string;
  bb: string;
  sleepDeep: string;
  sleepLight: string;
  sleepRem: string;
  sleepAwake: string;
  hrvNow: string;
  hrvLow: string;
  hrvB1: string;
  hrvB2: string;
}

const STORE_NAME: string = 'garmin_dash';
const KEY_BASE_URL: string = 'baseUrl';
const KEY_DEVICE_KEY: string = 'deviceKey';
const KEY_DEVICE_ID: string = 'deviceId';

export class DeviceStore {
  private static store: preferences.Preferences | null = null;

  static init(context: common.UIAbilityContext): void {
    if (DeviceStore.store === null) {
      DeviceStore.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
    }
  }

  private static ensure(): preferences.Preferences {
    if (DeviceStore.store === null) {
      throw new Error('DeviceStore.init(context) 必须先调用');
    }
    return DeviceStore.store;
  }


  /** 写卡片缓存到文件（卡片进程跨进程可读 ✓） */

  /** 卡片网络配置（卡片在独立进程，读不到 preferences，所以落盘 ✓） */
  static setCardNet(filesDir: string): void {
    const base = DeviceStore.getBaseUrl();
    const key = DeviceStore.getDeviceKey();
    if (base.length === 0 || key.length === 0) {
      return;
    }
    try {
      const f = fileIo.openSync(filesDir + '/card_net.json', fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, JSON.stringify({ base: base, key: key }));
      fileIo.closeSync(f);
    } catch (e) {
      // 忽略
    }
  }

  static getCardNet(filesDir: string): CardNet {
    try {
      const f = fileIo.openSync(filesDir + '/card_net.json', fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(filesDir + '/card_net.json');
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
      const txt = buffer.from(buf).toString('utf-8');
      const o = JSON.parse(txt) as CardNet;
      if (o.base === undefined || o.key === undefined) {
        return { base: '', key: '' };
      }
      return o;
    } catch (e) {
      return { base: '', key: '' };
    }
  }

  static setCardCache(filesDir: string, tsb: number | null, ctl: number | null, atl: number | null, ride: string, x: CardExtra): void {
    const dd = new Date();
    const hh = dd.getHours() < 10 ? '0' + dd.getHours() : '' + dd.getHours();
    const mm = dd.getMinutes() < 10 ? '0' + dd.getMinutes() : '' + dd.getMinutes();
    const o: CardCache = {
      tsb: safeRound(tsb, 1),
      ctl: safeRound(ctl, 1),
      atl: safeRound(atl, 1),
      ride: ride,
      updated: hh + ':' + mm,
      weekTss: safeRound(x.weekTss, 0),
      steps: safeRound(x.steps, 0),
      rhr: safeRound(x.rhr, 0),
      bb: safeRound(x.bb, 0),
      sleepDeep: safeRound(x.sleepDeep, 0),
      sleepLight: safeRound(x.sleepLight, 0),
      sleepRem: safeRound(x.sleepRem, 0),
      sleepAwake: safeRound(x.sleepAwake, 0),
      hrvNow: safeRound(x.hrvNow, 0),
      hrvLow: safeRound(x.hrvLow, 0),
      hrvB1: safeRound(x.hrvB1, 0),
      hrvB2: safeRound(x.hrvB2, 0)
    };
    try {
      const f = fileIo.openSync(filesDir + '/card_cache.json',
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(f.fd, JSON.stringify(o));
      } finally {
        fileIo.closeSync(f);
      }
    } catch (e) {
      // 写失败不影响主流程
    }
  }

  /** 从文件读卡片缓存（卡片 onAddForm 调用 ✓ 不用 preferences ✓） */
  static getCardCache(filesDir: string): CardCache {
    const fallback: CardCache = {
      tsb: '', ctl: '', atl: '', ride: '打开 App 同步数据', updated: '', weekTss: '',
      steps: '', rhr: '', bb: '', sleepDeep: '', sleepLight: '', sleepRem: '', sleepAwake: '',
      hrvNow: '', hrvLow: '', hrvB1: '', hrvB2: ''
    };
    try {
      const path = filesDir + '/card_cache.json';
      const f = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        const st = fileIo.statSync(f.fd);
        if (st.size <= 0) {
          return fallback;
        }
        const buf = new ArrayBuffer(st.size);
        fileIo.readSync(f.fd, buf);
        const txt = buffer.from(buf).toString('utf-8');
        const o = JSON.parse(txt) as CardCache;
        return o;
      } finally {
        fileIo.closeSync(f);
      }
    } catch (e) {
      return fallback;
    }
  }

  static getBaseUrl(): string {
    const v = DeviceStore.ensure().getSync(KEY_BASE_URL, '') as string;
    return v;
  }

  static setBaseUrl(url: string): void {
    let u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    DeviceStore.ensure().putSync(KEY_BASE_URL, u);
    DeviceStore.ensure().flush();
  }

  static getDeviceKey(): string {
    return DeviceStore.ensure().getSync(KEY_DEVICE_KEY, '') as string;
  }

  static getDeviceId(): string {
    return DeviceStore.ensure().getSync(KEY_DEVICE_ID, '') as string;
  }

  static savePair(deviceKey: string, deviceId: string): void {
    const s = DeviceStore.ensure();
    s.putSync(KEY_DEVICE_KEY, deviceKey);
    s.putSync(KEY_DEVICE_ID, deviceId);
    s.flush();
  }

  static clearPair(): void {
    const s = DeviceStore.ensure();
    s.putSync(KEY_DEVICE_KEY, '');
    s.putSync(KEY_DEVICE_ID, '');
    s.flush();
  }

  static isPaired(): boolean {
    return DeviceStore.getDeviceKey().length > 0 && DeviceStore.getBaseUrl().length > 0;
  }

  // ── 离线缓存：网络失败时展示上次成功的数据，并标注时间 ──────────────
  static cachePut(key: string, json: string): void {
    const s = DeviceStore.ensure();
    s.putSync('cache:' + key, json);
    s.putSync('cacheAt:' + key, Date.now());
    s.flush();
  }

  static cacheGet(key: string): string {
    return DeviceStore.ensure().getSync('cache:' + key, '') as string;
  }

  /** 距上次成功缓存的毫秒数；无缓存返回 -1 */
  static cacheAge(key: string): number {
    const at = DeviceStore.ensure().getSync('cacheAt:' + key, 0) as number;
    if (at <= 0) {
      return -1;
    }
    return Date.now() - at;
  }
  // ── 内建聊天的会话 id：持久化，App 重启后继续同一个会话（完整记忆）──
  static getChatSession(): string {
    return DeviceStore.ensure().getSync('chatSession', '') as string;
  }

  static setChatSession(id: string): void {
    if (id.length === 0) {
      return;
    }
    const s = DeviceStore.ensure();
    s.putSync('chatSession', id);
    s.flush();
  }

  static clearChatSession(): void {
    const s = DeviceStore.ensure();
    s.putSync('chatSession', '');
    s.flush();
  }
  // ── 适人握持开关（默认开）──
  static getHandFollow(): boolean {
    return DeviceStore.ensure().getSync('handFollow', true) as boolean;
  }

  static setHandFollow(on: boolean): void {
    const s = DeviceStore.ensure();
    s.putSync('handFollow', on);
    s.flush();
  }
  // ── 聊天界面历史（本地持久化，最多 200 条）──
  // 说明：模型侧的会话记忆由 sessionId 保证（后端持久会话）；这里保存的是
  // **界面要显示的历史**，两者独立，互不依赖 DSH 的内部存储格式。
  static getChatLog(): string {
    return DeviceStore.ensure().getSync('chatLog', '[]') as string;
  }

  static setChatLog(json: string): void {
    const s = DeviceStore.ensure();
    s.putSync('chatLog', json);
    s.flush();
  }
  // ── 表现预测器输入（持久化）──
  static setPredictInputs(distKm: number, climb: number, weight: number, bike: number, cda: number, crr: number, power: number): void {
    const s = DeviceStore.ensure();
    s.putSync('predInputs', JSON.stringify({
      distKm: distKm, climb: climb, weight: weight, bike: bike, cda: cda, crr: crr, power: power
    }));
    s.flush();
  }

  static getPredictInputs(): string {
    return DeviceStore.ensure().getSync('predInputs', '') as string;
  }
  // ── 全局个人设置：体重（kg，字符串保存，空=未设置）──
  static getBodyWeight(): string {
    return DeviceStore.ensure().getSync('bodyWeight', '') as string;
  }

  static setBodyWeight(v: string): void {
    const s = DeviceStore.ensure();
    s.putSync('bodyWeight', v);
    s.flush();
  }
  // ── 表现预测器：传动效率（%，字符串保存）──
  static getPredictEff(): string {
    return DeviceStore.ensure().getSync('predictEff', '') as string;
  }

  static setPredictEff(v: string): void {
    const s = DeviceStore.ensure();
    s.putSync('predictEff', v);
    s.flush();
  }
  // ── 等级阈值表（JSON：{names,wkg}；空 = 用内置表）──
  static getLevelTable(): string {
    return DeviceStore.ensure().getSync('levelTable', '') as string;
  }

  static setLevelTable(v: string): void {
    const s = DeviceStore.ensure();
    s.putSync('levelTable', v);
    s.flush();
  }
}
