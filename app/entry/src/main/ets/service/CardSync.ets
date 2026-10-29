import { formBindingData, formProvider } from '@kit.FormKit';
import { fileIo } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { DeviceStore } from './DeviceStore';

/**
 * 卡片绑定数据与同步推送（App 侧与 FormExtensionAbility 侧共用 ✓）
 * 目的：App 刷新完数据后主动推给桌面卡片，实现"App 与卡片同步更新" ✓
 */
export class CardSync {
  /** 生成卡片绑定数据（键必须与卡片 @LocalStorageProp 一致 ✓） */
  static build(filesDir: string): formBindingData.FormBindingData {
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
      'calories': c.calories,
      'stress': c.stress,
      'spin': '\u27F3'
    });
  }

  /** 记录一个卡片实例 id（去重） */
  static rememberFormId(filesDir: string, formId: string): void {
    try {
      if (formId === undefined || formId === null || formId.length === 0) {
        return;
      }
      const ids = CardSync.readFormIds(filesDir);
      let found = false;
      for (let i = 0; i < ids.length; i++) {
        if (ids[i] === formId) {
          found = true;
          break;
        }
      }
      if (!found) {
        ids.push(formId);
        const f = fileIo.openSync(filesDir + '/card_form_ids.json',
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(f.fd, JSON.stringify(ids));
        fileIo.closeSync(f);
      }
    } catch (e) {
    }
  }

  /** 读出已记录的卡片实例 id */
  static readFormIds(filesDir: string): string[] {
    try {
      const path = filesDir + '/card_form_ids.json';
      const st = fileIo.statSync(path);
      if (st.size <= 2) {
        return [];
      }
      const rf = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(st.size);
      fileIo.readSync(rf.fd, buf);
      fileIo.closeSync(rf);
      const arr = JSON.parse(buffer.from(buf).toString('utf-8')) as string[];
      return arr === null || arr === undefined ? [] : arr;
    } catch (e) {
      return [];
    }
  }

  /** 主动推送给所有已知卡片（App 刷新完数据后调用 ✓） */
  static async pushToCards(filesDir: string): Promise<void> {
    try {
      const ids = CardSync.readFormIds(filesDir);
      if (ids.length === 0) {
        return;
      }
      const data = CardSync.build(filesDir);
      for (let i = 0; i < ids.length; i++) {
        try {
          await formProvider.updateForm(ids[i], data);
        } catch (e) {
          // 单个失败（卡片已删）不影响其它
        }
      }
    } catch (e) {
    }
  }
}
