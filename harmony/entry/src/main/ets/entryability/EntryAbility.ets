import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
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
      }
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
