import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { getSharedBridge } from '../core/Bridge';
import quickjsSpike from 'libquickjs_spike.so';
import { SourceManager, DEMO_ID } from '../core/SourceManager';

const TAG: string = 'HGhubX';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, 'onCreate');
    hilog.info(0x0000, TAG, 'quickjs test begin');
    try {
      const result: string = quickjsSpike.evaluate('1 + 1');
      hilog.info(0x0000, TAG, 'quickjs eval: %{public}s', result);
    } catch (err) {
      const message: string = err instanceof Error ? err.message : String(err);
      hilog.error(0x0000, TAG, 'quickjs eval failed: %{public}s', message);
    }
    this.runSourcePilotTest();
  }

  private runSourcePilotTest(): void {
    const manager = new SourceManager(this.context);
    manager.importDemo()
      .then(() => {
        hilog.info(0x0000, TAG, 'source pilot state: %{public}s', JSON.stringify(manager.state()));
        return manager.test(DEMO_ID);
      })
      .then((result: string) => {
        const head: string = result.length > 160 ? result.substring(0, 160) : result;
        hilog.info(0x0000, TAG, 'source pilot test: %{public}s', head);
        manager.activate(DEMO_ID);
        hilog.info(0x0000, TAG, 'source pilot active: %{public}s', JSON.stringify(manager.state()));
        return manager.hostPilotCheck();
      })
      .then((hostResult: string) => {
        const head: string = hostResult.length > 240 ? hostResult.substring(0, 240) : hostResult;
        hilog.info(0x0000, TAG, 'source host pilot: %{public}s', head);
      })
      .catch((err: Error) => {
        hilog.error(0x0000, TAG, 'source pilot failed: %{public}s', err.message);
      });
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
      hilog.warn(0x0000, TAG, 'getMainWindow failed: %{public}d %{public}s', err.code, err.message);
    });
  }

  /** Ability 级兜底：页面级 onBackPress 未命中时也不销毁 Ability。 */
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
