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

  /** 硬件返回键：页面栈/弹层能消费就返回 true，否则交回系统（退到后台） */
  onBackPressed(): boolean {
    const bridge = getSharedBridge();
    return bridge !== null ? bridge.handleBack() : false;
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {}

  onBackground(): void {}

  onDestroy(): void {}
}
