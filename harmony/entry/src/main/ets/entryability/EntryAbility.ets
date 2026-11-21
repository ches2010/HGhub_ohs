import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { getSharedBridge } from '../core/Bridge';

const TAG: string = 'HGhubX';

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
      this.setupImmersiveWindow(windowStage);
    });
  }

  /**
   * 全面屏适配：让 ArkWeb 延伸到状态栏/导航条区域，并保持系统栏透明。
   * 前端已有 viewport-fit=cover + safe-area 避让，页面控件不会切入系统栏。
   */
  private setupImmersiveWindow(windowStage: window.WindowStage): void {
    windowStage.getMainWindow().then((mainWindow: window.Window) => {
      // 窗口背景跟随应用暗色底，避免页面首帧或透明系统栏后露出白底。
      mainWindow.setWindowBackgroundColor('#071218');
      mainWindow.setWindowLayoutFullScreen(true).then(() => {
        const systemBarProperties: window.SystemBarProperties = {
          statusBarColor: '#00000000',
          statusBarContentColor: '#FFFFFF',
          navigationBarColor: '#00000000',
          navigationBarContentColor: '#FFFFFF'
        };
        return mainWindow.setWindowSystemBarProperties(systemBarProperties);
      }).then(() => {
        hilog.info(0x0000, TAG, 'immersive window enabled');
      }).catch((err: BusinessError) => {
        hilog.warn(0x0000, TAG, 'immersive window setup failed: %{public}d %{public}s',
          err.code, err.message);
      });
    }).catch((err: BusinessError) => {
      hilog.warn(0x0000, TAG, 'getMainWindow failed: %{public}d %{public}s',
        err.code, err.message);
    });
  }

  /** 硬件返回键：未由页面消费时也返回 true，让系统退到后台而不是销毁 Ability。 */
  onBackPressed(): boolean {
    const bridge = getSharedBridge();
    return bridge !== null ? bridge.handleBack() : true;
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {}

  onBackground(): void {}

  onDestroy(): void {}
}
