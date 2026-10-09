/**
 * 显示格式化工具
 */

export class Fmt {
  /** 米 → 公里，保留一位小数 */
  static km(meters: number | null): string {
    if (meters === null || meters === undefined) {
      return '--';
    }
    return (meters / 1000).toFixed(1) + ' km';
  }

  /** 秒 → h:mm 或 mm:ss */
  static duration(seconds: number | null): string {
    if (seconds === null || seconds === undefined) {
      return '--';
    }
    const s = Math.round(seconds);
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = s % 60;
    if (h > 0) {
      return h + ':' + Fmt.pad(m) + ':' + Fmt.pad(sec);
    }
    return m + ':' + Fmt.pad(sec);
  }

  /** 秒 → 1h23m */
  static durationShort(seconds: number | null): string {
    if (seconds === null || seconds === undefined) {
      return '--';
    }
    const s = Math.round(seconds);
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    if (h > 0) {
      return h + 'h' + m + 'm';
    }
    return m + 'm';
  }

  static num(v: number | null, unit: string): string {
    if (v === null || v === undefined) {
      return '--';
    }
    return Math.round(v) + unit;
  }

  static num1(v: number | null, unit: string): string {
    if (v === null || v === undefined) {
      return '--';
    }
    return v.toFixed(1) + unit;
  }

  static int(v: number | null): string {
    if (v === null || v === undefined) {
      return '--';
    }
    return '' + Math.round(v);
  }

  /** 2026-10-07 08:23:34 → 10-07 08:23 */
  static shortTime(iso: string): string {
    if (!iso || iso.length < 16) {
      return iso;
    }
    return iso.substring(5, 16).replace('T', ' ');
  }

  /** 运动类型 → 中文 */
  static sportName(type: string): string {
    if (type === 'cycling') {
      return '骑行';
    }
    if (type === 'running') {
      return '跑步';
    }
    if (type === 'swimming') {
      return '游泳';
    }
    if (type === 'walking') {
      return '步行';
    }
    if (type === 'hiking') {
      return '徒步';
    }
    return type;
  }

  static today(): string {
    const d = new Date();
    return d.getFullYear() + '-' + Fmt.pad(d.getMonth() + 1) + '-' + Fmt.pad(d.getDate());
  }

  static pad(n: number): string {
    return n < 10 ? '0' + n : '' + n;
  }

  /** 秒 → 分（睡眠用） */
  static minutes(seconds: number | null): string {
    if (seconds === null || seconds === undefined) {
      return '--';
    }
    return Math.round(seconds / 60) + ' 分';
  }
  /** 毫秒差 → 人类可读（刚刚 / 5 分钟前 / 2 小时前 / 3 天前） */
  static ago(ms: number): string {
    if (ms < 0) {
      return '未知时间';
    }
    const min = Math.floor(ms / 60000);
    if (min < 1) {
      return '刚刚';
    }
    if (min < 60) {
      return min + ' 分钟前';
    }
    const hr = Math.floor(min / 60);
    if (hr < 24) {
      return hr + ' 小时前';
    }
    return Math.floor(hr / 24) + ' 天前';
  }

  /** 分钟 → 1h45m */
  static minutesShort(minutes: number | null): string {
    if (minutes === null || minutes === undefined) {
      return '--';
    }
    const h = Math.floor(minutes / 60);
    const m = Math.round(minutes % 60);
    if (h > 0) {
      return h + 'h' + m + 'm';
    }
    return m + 'm';
  }
  /** 该日期所在 ISO 周的周一（YYYY-MM-DD） */
  static weekStart(date: string): string {
    const p = date.split('-');
    const d = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]));
    const shift = (d.getDay() + 6) % 7;
    d.setDate(d.getDate() - shift);
    return d.getFullYear() + '-' + Fmt.pad(d.getMonth() + 1) + '-' + Fmt.pad(d.getDate());
  }

  /** 在 YYYY-MM-DD 上加减天数 */
  static shiftDays(date: string, delta: number): string {
    const p = date.split('-');
    const d = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]));
    d.setDate(d.getDate() + delta);
    return d.getFullYear() + '-' + Fmt.pad(d.getMonth() + 1) + '-' + Fmt.pad(d.getDate());
  }

  /** 8/17 形式 */
  static monthDay(date: string): string {
    const p = date.split('-');
    if (p.length < 3) {
      return date;
    }
    return Number(p[1]) + '/' + Number(p[2]);
  }
}