import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, display } from '@kit.ArkUI';

const TAG: string = 'GarminDash';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, 'onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(0x0000, TAG, 'loadContent ok');
    });

    // 全屏布局：让页面的渐变铺到状态栏后面（否则顶部会露出窗口底色，看起来像一片空白）。
    // 同时把安全区高度写进 AppStorage，页面据此给内容留出上/下边距——与同机 ClashBox 的
    // StatusBarUtils + topRectHeight 做法一致。
    try {
      const win = windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(true).then(() => {
        const top = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const bottom = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        AppStorage.setOrCreate('topRectHeight', top.topRect.height / display.getDefaultDisplaySync().densityPixels);
        AppStorage.setOrCreate('bottomRectHeight', bottom.bottomRect.height / display.getDefaultDisplaySync().densityPixels);
        hilog.info(0x0000, TAG, 'safe area stored');
      }).catch((e: Object) => {
        hilog.warn(0x0000, TAG, 'layout full screen failed: %{public}s', JSON.stringify(e));
      });
    } catch (e) {
      hilog.warn(0x0000, TAG, 'window setup failed');
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {}

  onBackground(): void {}

  onDestroy(): void {}
}
