import FormExtensionAbility from '@ohos.app.form.FormExtensionAbility';
import formBindingData from '@ohos.app.form.formBindingData';
import { DeviceStore } from '../service/DeviceStore';

/** 服务卡片数据源：读 App 写入的缓存（App 打开时刷新 ✓） */
export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Object): Object {
    const c = DeviceStore.getCardCache();
    const data: Record<string, string> = {
      'tsb': c.tsb,
      'ctl': c.ctl,
      'atl': c.atl,
      'ride': c.ride,
      'updated': c.updated
    };
    return formBindingData.createFormBindingData(data);
  }

  onFormEvent(formId: string, message: string): void {
    // 卡片内事件（当前无交互按钮，保留扩展点）
  }
}