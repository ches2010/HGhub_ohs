import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { LocalServer } from '../core/LocalServer';
import { Bridge, setSharedBridge } from '../core/Bridge';
import { httpRequest } from '../core/Http';

const TAG: string = 'HGhubX';
const PORT: number = 17860;
/** 本地服务起来后多久还没 onPageEnd 就认为异常（毫秒） */
const LOAD_WATCHDOG_MS: number = 6000;

@Entry
@Component
struct Index {
  /** 固定为 about:blank；真实页面用 controller.loadUrl 显式加载，
   *  避免「改 @State 驱动 Web.src」在某些 ArkWeb 版本上不触发重新加载导致白屏。 */
  @State pageUrl: string = 'about:blank';
  @State targetUrl: string = '';
  @State bundleMissing: boolean = false;
  @State bootError: string = '';
  @State lastLoadError: string = '';
  @State pageLoaded: boolean = false;
  @State diagOpen: boolean = false;
  @State pingResult: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();
  private server: LocalServer | null = null;
  private bridge: Bridge | null = null;
  private registered: boolean = false;

  aboutToAppear(): void {
    const context = this.abilityContext();
    const bridge = new Bridge(context);
    bridge.attach(this.controller);
    this.bridge = bridge;
    setSharedBridge(bridge);

    const server = new LocalServer(context.resourceManager, PORT, () => {
      const b = this.bridge;
      return b === null ? 'https://huangguoai.com' : b.currentBase();
    });
    this.server = server;
    server.start().then(() => {
      const bundle = server.hasBundle();
      const url = server.pageUrl();
      hilog.info(0x0000, TAG, 'local server on %{public}s bundle=%{public}s', url, String(bundle));
      this.bundleMissing = !bundle;
      this.targetUrl = url;
      if (!bundle) {
        this.diagOpen = true;
        return;
      }
      this.loadTarget(url);
      // 看门狗：服务起来了但页面迟迟没有 onPageEnd，就把诊断面板顶出来
      setTimeout(() => {
        if (!this.pageLoaded) {
          hilog.error(0x0000, TAG, 'page not loaded in %{public}dms, running ping', LOAD_WATCHDOG_MS);
          this.diagOpen = true;
          this.runPing();
        }
      }, LOAD_WATCHDOG_MS);
    }).catch((err: Error) => {
      hilog.error(0x0000, TAG, 'local server failed: %{public}s', err.message);
      this.bootError = err.message;
      this.diagOpen = true;
    });
  }

  /** 显式 loadUrl；控制器还没 attach 时退回改 @State */
  private loadTarget(url: string): void {
    try {
      this.controller.loadUrl(url);
      hilog.info(0x0000, TAG, 'loadUrl %{public}s', url);
    } catch (e) {
      const message = e !== undefined && e !== null ? (e as Error).message : '';
      hilog.warn(0x0000, TAG, 'loadUrl failed (%{public}s), fallback to src', message);
      this.pageUrl = url;
    }
  }

  /** 用原生 http 打本地服务：能通 → 服务没问题，白屏在 WebView 侧；不通 → 服务/端口问题 */
  private runPing(): void {
    const url = `http://127.0.0.1:${PORT}/__ping`;
    httpRequest(url, 'GET', '{}', '', true, 4000).then((r) => {
      const text = new util.TextDecoder().decodeToString(new Uint8Array(r.bytes));
      this.pingResult = `HTTP ${r.status} · ${text}`;
      hilog.info(0x0000, TAG, 'ping ok: %{public}s', this.pingResult);
    }).catch((e: Error) => {
      this.pingResult = `失败：${e.message}`;
      hilog.error(0x0000, TAG, 'ping failed: %{public}s', e.message);
    });
  }

  private abilityContext(): common.UIAbilityContext {
    try {
      const host = this.getUIContext().getHostContext();
      if (host !== undefined) {
        return host as common.UIAbilityContext;
      }
    } catch (e) {
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

  private reload(): void {
    this.pageLoaded = false;
    this.lastLoadError = '';
    if (this.targetUrl.length > 0) {
      this.loadTarget(this.targetUrl);
    }
    this.diagOpen = false;
  }

  @Builder
  diagnosePanel() {
    Column({ space: 8 }) {
      Text(this.bundleMissing ? 'App 里没有前端页面' : (this.pageLoaded ? '页面已加载（面板可关闭）' : '页面没有加载出来'))
        .fontSize(17)
        .fontColor(this.bundleMissing || !this.pageLoaded ? '#ff8a80' : '#8fd694')
        .fontWeight(FontWeight.Bold)

      Text(`bundle=${this.bundleMissing ? 'missing' : 'ok'}  loaded=${this.pageLoaded ? 'yes' : 'no'}`)
        .fontSize(12).fontColor('#9e9e9e')

      if (this.targetUrl.length > 0) {
        Text(`目标：${this.targetUrl}`).fontSize(12).fontColor('#cccccc')
      }
      if (this.bootError.length > 0) {
        Text(`本地服务启动失败：${this.bootError}`).fontSize(12).fontColor('#eeeeee')
        Text(`端口 ${PORT} 可能被占用`).fontSize(11).fontColor('#999999')
      }
      if (this.bundleMissing) {
        Text('rawfile/www 里没有 index.html。修复：\n1) node harmony/patches/apply-patch.mjs .\n2) harmony/scripts/build-web.sh\n3) 重新 Build HAP\n（或用仓库自带的产物，重新解压 zip）')
          .fontSize(12).fontColor('#eeeeee')
      }
      if (this.lastLoadError.length > 0) {
        Text(`Web 加载错误：${this.lastLoadError}`).fontSize(12).fontColor('#ffcc80')
      }
      if (this.pingResult.length > 0) {
        Text(`本地服务自检：${this.pingResult}`).fontSize(12).fontColor('#90caf9')
      }
      if (this.pingResult.length === 0 && !this.bundleMissing) {
        Text('（6 秒内未加载完成会自动做一次本地服务自检）').fontSize(11).fontColor('#777777')
      }

      Row({ space: 10 }) {
        Button('重新加载').fontSize(13).height(32)
          .onClick(() => this.reload())
        Button('自检').fontSize(13).height(32)
          .onClick(() => this.runPing())
        Button('收起').fontSize(13).height(32)
          .onClick(() => { this.diagOpen = false; })
      }.margin({ top: 4 })

      Text('详细日志：hdc shell hilog | grep HGhubX').fontSize(11).fontColor('#777777')
    }
    .alignItems(HorizontalAlign.Start)
    .padding(18)
    .width('100%')
    .backgroundColor('#111111')
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
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
          // 服务可能已经起来了：attach 之后补一次加载
          if (this.targetUrl.length > 0 && !this.pageLoaded) {
            this.loadTarget(this.targetUrl);
          }
        })
        .onPageEnd(() => {
          this.pageLoaded = true;
          this.diagOpen = this.bundleMissing;
          hilog.info(0x0000, TAG, 'page loaded ok');
          const bridge = this.bridge;
          if (bridge !== null) {
            bridge.setPageReady();
          }
        })
        .onConsole((event): boolean => {
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
            this.lastLoadError = `${info} @ ${event.request.getRequestUrl()}`;
            if (!this.pageLoaded) {
              this.diagOpen = true;
              this.runPing();
            }
          }
        })
        .onHttpErrorReceive((event) => {
          if (event !== undefined && event !== null) {
            const code = event.response.getResponseCode();
            hilog.error(0x0000, TAG, 'http %{public}d url=%{public}s',
              code, event.request.getRequestUrl());
            this.lastLoadError = `HTTP ${code} @ ${event.request.getRequestUrl()}`;
            if (!this.pageLoaded) {
              this.diagOpen = true;
              this.runPing();
            }
          }
        })

      if (this.diagOpen || this.bundleMissing || this.bootError.length > 0) {
        this.diagnosePanel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
}
