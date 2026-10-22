import { formBindingData, FormExtensionAbility, formProvider } from '@kit.FormKit';
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
    return EntryFormAbility.build(this.context.filesDir);
  }

  onUpdateForm(formId: string): void {
    const data = EntryFormAbility.build(this.context.filesDir);
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
        'weekTss': c0.weekTss, 'steps': c0.steps, 'rhr': c0.rhr, 'bb': c0.bb,
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
          formProvider.updateForm(formId, EntryFormAbility.build(filesDir)).catch(() => {
            // 忽略
          });
        }).catch(() => {
          formProvider.updateForm(formId, EntryFormAbility.build(filesDir)).catch(() => {
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
      const extra: CardExtra = {
        weekTss: wt,
        steps: old.steps.length === 0 ? null : Number(old.steps),
        rhr: old.rhr.length === 0 ? null : Number(old.rhr),
        bb: old.bb.length === 0 ? null : Number(old.bb),
        sleepDeep: old.sleepDeep.length === 0 ? null : Number(old.sleepDeep),
        sleepLight: old.sleepLight.length === 0 ? null : Number(old.sleepLight),
        sleepRem: old.sleepRem.length === 0 ? null : Number(old.sleepRem),
        sleepAwake: old.sleepAwake.length === 0 ? null : Number(old.sleepAwake),
        hrvNow: old.hrvNow.length === 0 ? null : Number(old.hrvNow),
        hrvLow: old.hrvLow.length === 0 ? null : Number(old.hrvLow),
        hrvB1: old.hrvB1.length === 0 ? null : Number(old.hrvB1),
        hrvB2: old.hrvB2.length === 0 ? null : Number(old.hrvB2)
      };
      DeviceStore.setCardCache(filesDir, last.tsb, last.ctl, last.atl, '', extra);
      return true;
    } catch (e) {
      return false;
    }
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

interface TrendResp {
  points: TrendPointResp[];
}
