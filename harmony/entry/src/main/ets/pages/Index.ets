import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LocalServer } from '../core/LocalServer';
import { Bridge, setSharedBridge } from '../core/Bridge';

const TAG: string = 'HGhubX';
const PORT: number = 17860;

@Entry
@Component
struct Index {
  @State pageUrl: string = 'about:blank';
  private controller: webview.WebviewController = new webview.WebviewController();
  private server: LocalServer | null = null;
  private bridge: Bridge | null = null;
  private registered: boolean = false;

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const bridge = new Bridge(context);
    bridge.attach(this.controller);
    this.bridge = bridge;
    // 让 UIAbility.onBackPressed 能拿到同一个实例
    setSharedBridge(bridge);

    const server = new LocalServer(context.resourceManager, PORT, () => {
      const b = this.bridge;
      return b === null ? 'https://huangguoai.com' : b.currentBase();
    });
    this.server = server;
    server.start().then(() => {
      hilog.info(0x0000, TAG, 'local server on %{public}s', server.pageUrl());
      this.pageUrl = server.pageUrl();
    }).catch((err: Error) => {
      hilog.error(0x0000, TAG, 'local server failed: %{public}s', err.message);
      const html = `<html><body style="background:#111;color:#eee;font:16px sans-serif;padding:24px">
        <h3>本地服务启动失败</h3><p>${err.message}</p>
        <p>端口 ${PORT} 可能被占用，或缺少 ohos.permission.INTERNET。</p></body></html>`;
      this.pageUrl = `data:text/html;charset=utf-8,${encodeURIComponent(html)}`;
    });
  }

  aboutToDisappear(): void {
    const server = this.server;
    this.server = null;
    if (server !== null) {
      server.stop();
    }
  }

  build() {
    Column() {
      Web({ src: this.pageUrl, controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .databaseAccess(true)
        .mixedMode(MixedMode.All)
        .width('100%')
        .height('100%')
        .onControllerAttached(() => {
          if (this.registered) {
            return;
          }
          this.registered = true;
          const bridge = this.bridge;
          if (bridge === null) {
            return;
          }
          this.controller.registerJavaScriptProxy(
            bridge,
            'hghub',
            ['http', 'setBase', 'openUrl', 'setOrientation', 'log', 'clearCache', 'setBackEnabled', 'background', 'netInfo']
          );
          // registerJavaScriptProxy 在页面开始加载后注册需要刷新一次才生效
          this.controller.refresh();
        })
        .onPageEnd(() => {
          hilog.info(0x0000, TAG, 'page loaded');
          const bridge = this.bridge;
          if (bridge !== null) {
            bridge.setPageReady();
          }
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
}
