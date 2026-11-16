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
  /** rawfile/www 里没有前端产物：用 ArkUI 直接盖一层说明，不依赖 Web 能渲染出来 */
  @State bundleMissing: boolean = false;
  @State bootError: string = '';
  @State lastLoadError: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();
  private server: LocalServer | null = null;
  private bridge: Bridge | null = null;
  private registered: boolean = false;

  aboutToAppear(): void {
    const context = this.abilityContext();
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
      hilog.info(0x0000, TAG, 'local server on %{public}s, bundle=%{public}s',
        server.pageUrl(), String(server.hasBundle()));
      this.bundleMissing = !server.hasBundle();
      this.pageUrl = server.pageUrl();
    }).catch((err: Error) => {
      hilog.error(0x0000, TAG, 'local server failed: %{public}s', err.message);
      this.bootError = err.message;
      const html = `<html><body style="background:#111;color:#eee;font:16px sans-serif;padding:24px">`
        + `<h3>本地服务启动失败</h3><p>${err.message}</p>`
        + `<p>端口 ${PORT} 可能被占用，或缺少 ohos.permission.INTERNET。</p></body></html>`;
      this.pageUrl = `data:text/html;charset=utf-8,${encodeURIComponent(html)}`;
    });
  }

  /** 取 UIAbilityContext：优先新写法，取不到再退回已废弃的 getContext */
  private abilityContext(): common.UIAbilityContext {
    try {
      const host = this.getUIContext().getHostContext();
      if (host !== undefined) {
        return host as common.UIAbilityContext;
      }
    } catch (e) {
      // 低版本 SDK 没有 getUIContext()，走下面的兜底
    }
    return getContext(this) as common.UIAbilityContext;
  }

  aboutToDisappear(): void {
    const server = this.server;
    this.server = null;
    if (server !== null) {
      server.stop();
    }
  }

  @Builder
  diagnosePanel() {
    Column({ space: 10 }) {
      Text(this.bundleMissing ? 'App 里没有前端页面（这就是白屏原因）' : '加载失败')
        .fontSize(18)
        .fontColor('#ff8a80')
        .fontWeight(FontWeight.Bold)
      if (this.bundleMissing) {
        Text('entry/src/main/resources/rawfile/www/ 是空的（只有 README.txt），LocalServer 取不到 index.html。')
          .fontSize(13)
          .fontColor('#cccccc')
        Text('修复（在仓库根执行）：\n1) node harmony/patches/apply-patch.mjs .\n2) harmony/scripts/build-web.sh\n3) 重新 Build HAP')
          .fontSize(13)
          .fontColor('#eeeeee')
      }
      if (this.bootError.length > 0) {
        Text(`本地服务启动失败：${this.bootError}`)
          .fontSize(13)
          .fontColor('#eeeeee')
        Text(`端口 ${PORT} 可能被占用`).fontSize(12).fontColor('#999999')
      }
      if (this.lastLoadError.length > 0) {
        Text(`最近一次加载错误：${this.lastLoadError}`)
          .fontSize(12)
          .fontColor('#aaaaaa')
      }
      Text('完整日志：hdc shell hilog | grep HGhubX')
        .fontSize(12)
        .fontColor('#888888')
    }
    .padding(20)
    .width('100%')
    .backgroundColor('#111111')
  }

  build() {
    Stack() {
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
          hilog.info(0x0000, TAG, 'page loaded: %{public}s', this.pageUrl);
          const bridge = this.bridge;
          if (bridge !== null) {
            bridge.setPageReady();
          }
        })
        .onConsole((event): boolean => {
          // 前端的 console 直接进 hilog：白屏时第一时间就能看到 JS 报错。
          // 注意：ArkWeb 的 onConsole 签名是 Callback<OnConsoleEvent, boolean>，
          // 返回 true = 该条消息已由我们处理，不再交给系统默认打印。
          if (event !== undefined && event !== null) {
            hilog.info(0x0000, TAG, 'web console: %{public}s', event.message.getMessage());
          }
          return true;
        })
        .onErrorReceive((event) => {
          if (event !== undefined && event !== null) {
            const info = event.error.getErrorInfo();
            hilog.error(0x0000, TAG, 'load error: %{public}s url=%{public}s',
              info, event.request.getRequestUrl());
            this.lastLoadError = info;
          }
        })
        .onHttpErrorReceive((event) => {
          if (event !== undefined && event !== null) {
            const code = event.response.getResponseCode();
            hilog.error(0x0000, TAG, 'http %{public}d url=%{public}s',
              code, event.request.getRequestUrl());
            this.lastLoadError = `HTTP ${code} @ ${event.request.getRequestUrl()}`;
          }
        })

      if (this.bundleMissing || this.bootError.length > 0) {
        this.diagnosePanel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
}
