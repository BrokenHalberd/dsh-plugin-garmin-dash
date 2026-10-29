import { formBindingData, FormExtensionAbility, formProvider } from '@kit.FormKit';
import { CardSync } from '../service/CardSync';
import { Want } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { CardNet } from '../service/DeviceStore';
import { DeviceStore, CardExtra } from '../service/DeviceStore';

/**
 * 服务卡片入口
 * - onAddForm：首次添加时读缓存并注入 ✓
 * - onUpdateForm：到点自动刷新（updateDuration）时**重读缓存** ✓ ← 之前缺失 ✗
 * - onFormEvent：卡片上的「刷新」按钮（postCardAction message）✓
 */
export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    // 尽力记录 formId（不同版本参数键不同，逐个试，取到即记）
    try {
      const keys: string[] = ['ohos.extra.param.key.form_id', 'formId', 'ohos.extra.param.key.form_identity'];
      for (let i = 0; i < keys.length; i++) {
        const v = want.parameters === undefined ? undefined : want.parameters[keys[i]];
        if (typeof v === 'string' && v.length > 0) {
          CardSync.rememberFormId(this.context.filesDir, v as string);
          break;
        }
      }
    } catch (e) {
    }
    return CardSync.build(this.context.filesDir);
  }

  onUpdateForm(formId: string): void {
    CardSync.rememberFormId(this.context.filesDir, formId);
    const data = CardSync.build(this.context.filesDir);
    formProvider.updateForm(formId, data).catch(() => {
      // 忽略：卡片可能已被移除
    });
  }

  onFormEvent(formId: string, message: string): void {
    if (message.indexOf('refresh') < 0) {
      return;
    }
    const filesDir = this.context.filesDir;
    const c0 = DeviceStore.getCardCache(filesDir);
    const glyphs = ['\u27F3', '\u21BB', '\u27F2', '\u21BA'];
    let frame = 0;
    const pushSpin = (glyph: string): void => {
      const d = formBindingData.createFormBindingData({
        'tsb': c0.tsb, 'ctl': c0.ctl, 'atl': c0.atl, 'ride': c0.ride,
        'updated': c0.updated,
        'weekTss': c0.weekTss, 'steps': c0.steps, 'rhr': c0.rhr, 'bb': c0.bb, 'bbChg': c0.bbChg,
        'sleepDeep': c0.sleepDeep, 'sleepLight': c0.sleepLight,
        'sleepRem': c0.sleepRem, 'sleepAwake': c0.sleepAwake,
        'hrvNow': c0.hrvNow, 'hrvLow': c0.hrvLow, 'hrvB1': c0.hrvB1, 'hrvB2': c0.hrvB2,
        'spin': glyph
      });
      formProvider.updateForm(formId, d).catch(() => {
        // 卡片可能已移除
      });
    };
    // 动画帧：每 150ms 推一帧，看起来就是图标在转
    const timer = setInterval(() => {
      frame++;
      if (frame > 8) {
        clearInterval(timer);
        this.refreshFromServer(formId).then(() => {
          formProvider.updateForm(formId, CardSync.build(filesDir)).catch(() => {
            // 忽略
          });
        }).catch(() => {
          formProvider.updateForm(formId, CardSync.build(filesDir)).catch(() => {
            // 忽略
          });
        });
        return;
      }
      pushSpin(glyphs[frame % 4]);
    }, 150);
  }


  /** 真刷新：向宿主后端要一次最新趋势，写回缓存并更新卡片 */
  private async refreshFromServer(formId: string): Promise<boolean> {
    const filesDir = this.context.filesDir;
    const net: CardNet = DeviceStore.getCardNet(filesDir);
    if (net.base.length === 0) {
      return false;
    }
    const url = net.base + '/garmin-dash/api/trend?days=30';
    const req = http.createHttp();
    let body = '';
    try {
      const res = await req.request(url, {
        method: http.RequestMethod.GET,
        header: { 'X-Device-Key': net.key } as Record<string, string>,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 25000
      });
      body = typeof res.result === 'string' ? res.result : '';
      if (res.responseCode !== 200 || body.length === 0) {
        return false;
      }
    } catch (e) {
      return false;
    } finally {
      req.destroy();
    }
    try {
      const t = JSON.parse(body) as TrendResp;
      const pts = t.points;
      if (pts.length === 0) {
        return false;
      }
      const last = pts[pts.length - 1];
      let wt = 0;
      for (let i = Math.max(0, pts.length - 7); i < pts.length; i++) {
        const one = pts[i].tss;
        wt = wt + (one === null ? 0 : one);
      }
      const old = DeviceStore.getCardCache(filesDir);
      // 缓存里没有充放数据时，卡片进程自己向后退一次（保证大卡片也能显示 +74/-50）
      let bbChg: string | null = old.bbChg.length === 0 ? null : old.bbChg;
      if (bbChg === null) {
        try {
          const bres = await http.createHttp().request(
            net.base + '/garmin-dash/api/body-battery',
            {
              method: http.RequestMethod.GET,
              usingProtocol: http.HttpProtocol.HTTP1_1,
              header: { 'X-Device-Key': net.key } as Record<string, string>,
              connectTimeout: 8000,
              readTimeout: 15000,
              expectDataType: http.HttpDataType.STRING
            },
          );
          const btext = bres.result as string;
          if (bres.responseCode === 200 && btext.length > 0) {
            const bj = JSON.parse(btext) as BodyBatteryResp;
            const ch = bj.charged;
            const dr = bj.drained;
            const hasCh = ch !== null && ch !== undefined;
            const hasDr = dr !== null && dr !== undefined;
            if (hasCh || hasDr) {
              const plus = hasCh ? ('+' + ch) : '';
              const minus = hasDr ? ('-' + dr) : '';
              bbChg = plus + (plus.length > 0 && minus.length > 0 ? ' / ' : '') + minus;
            }
          }
        } catch (e) {
          bbChg = null;
        }
      }
      const extra: CardExtra = {
        weekTss: wt,
        steps: old.steps.length === 0 ? null : Number(old.steps),
        rhr: old.rhr.length === 0 ? null : Number(old.rhr),
        bb: old.bb.length === 0 ? null : Number(old.bb),
        bbChg: bbChg,
        sleepDeep: old.sleepDeep.length === 0 ? null : Number(old.sleepDeep),
        sleepLight: old.sleepLight.length === 0 ? null : Number(old.sleepLight),
        sleepRem: old.sleepRem.length === 0 ? null : Number(old.sleepRem),
        sleepAwake: old.sleepAwake.length === 0 ? null : Number(old.sleepAwake),
        hrvNow: old.hrvNow.length === 0 ? null : Number(old.hrvNow),
        hrvLow: old.hrvLow.length === 0 ? null : Number(old.hrvLow),
        hrvB1: old.hrvB1.length === 0 ? null : Number(old.hrvB1),
        hrvB2: old.hrvB2.length === 0 ? null : Number(old.hrvB2),
        calories: EntryFormAbility.numOf(old.calories),
        stress: EntryFormAbility.numOf(old.stress)
      };
      DeviceStore.setCardCache(filesDir, last.tsb, last.ctl, last.atl, '', extra);
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 字符串安全转数字（空/非法 → null ✓） */
  private static numOf(v: string): number | null {
    if (v === undefined || v === null || v.length === 0) {
      return null;
    }
    const x = Number(v);
    return Number.isFinite(x) ? x : null;
  }

  private static build(filesDir: string): formBindingData.FormBindingData {
    const c = DeviceStore.getCardCache(filesDir);
    return formBindingData.createFormBindingData({
      'tsb': c.tsb,
      'ctl': c.ctl,
      'atl': c.atl,
      'ride': c.ride,
      'updated': c.updated,
      'weekTss': c.weekTss,
      'steps': c.steps,
      'rhr': c.rhr,
      'bb': c.bb,
      'bbChg': c.bbChg,
      'sleepDeep': c.sleepDeep,
      'sleepLight': c.sleepLight,
      'sleepRem': c.sleepRem,
      'sleepAwake': c.sleepAwake,
      'hrvNow': c.hrvNow,
      'hrvLow': c.hrvLow,
      'hrvB1': c.hrvB1,
      'hrvB2': c.hrvB2,
      'spin': '\u27F3'
    });
  }
}

interface TrendPointResp {
  tsb: number | null;
  ctl: number | null;
  atl: number | null;
  tss: number | null;
  date: string;
}

interface BodyBatteryResp {
  charged?: number | null;
  drained?: number | null;
}

interface TrendResp {
  points: TrendPointResp[];
}
