import { formBindingData, FormExtensionAbility, formInfo } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { DeviceStore } from '../service/DeviceStore';

export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want) {
    const c = DeviceStore.getCardCache(this.context.filesDir);
    let formData = '';
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
      'hrvB2': c.hrvB2
    });
  }

  onCastToNormalForm(formId: string) {
  }

  onUpdateForm(formId: string) {
  }

  onChangeFormVisibility(newStatus: Record<string, number>) {
  }

  onFormEvent(formId: string, message: string) {
  }

  onRemoveForm(formId: string) {
  }

  onAcquireFormState(want: Want) {
    return formInfo.FormState.READY;
  }
};