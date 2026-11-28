/**
 * JS 桥：注入到页面的 `window.hghub`。
 *
 * 设计原则——ArkTS 侧只做「哑传输 + 平台能力」，业务逻辑全部留在前端 TypeScript：
 *   http()           HTTP 请求（原生侧没有 CORS 限制，等价于 Rust 的 reqwest）
 *   setBase()        记录当前线路，供媒体代理拼 Referer
 *   openUrl()        系统浏览器/其他应用打开链接
 *   setOrientation() 竖屏/横屏锁定
 *   log()            写日志
 *   clearCache()     清 Web 缓存
 */
import { webview } from '@kit.ArkWeb';
import { common, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { connection } from '@kit.NetworkKit';
import { httpRequest } from './Http';
import { PlaybackLog } from './PlaybackLog';
import { SourceManager } from './SourceManager';

const TAG: string = 'HGhubX';

interface SourceTestReply {
  id: string;
  result: string;
}

interface NetInfoSnapshot {
  online: boolean;
  bearerTypes: string[];
  dnses: string[];
  linkAddresses: string[];
  mtu: number;
}
const DEFAULT_BASE: string = 'https://huangguoai.com';

/** 供 UIAbility 拿到同一个 Bridge 实例（返回键走 onBackPressed） */
let sharedBridge: Bridge | null = null;

export function setSharedBridge(bridge: Bridge): void {
  sharedBridge = bridge;
}

export function getSharedBridge(): Bridge | null {
  return sharedBridge;
}

export class Bridge {
  private controller: webview.WebviewController | null = null;
  private context: common.UIAbilityContext;
  private base: string = DEFAULT_BASE;
  /** 前端是否注册了返回监听（App.tsx 的 app/back-button） */
  private backEnabled: boolean = false;
  /** 页面是否已加载完成，未完成时不要吞返回键 */
  private pageReady: boolean = false;
  private playbackLog: PlaybackLog;
  private sourceManager: SourceManager;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.playbackLog = new PlaybackLog(context.filesDir);
    this.sourceManager = new SourceManager(context);
  }

  attach(controller: webview.WebviewController): void {
    this.controller = controller;
  }

  currentBase(): string {
    return this.base;
  }

  private reply(reqId: string, ok: boolean, payload: string): void {
    const controller = this.controller;
    if (controller === null) {
      return;
    }
    const flag = ok ? 'true' : 'false';
    const script =
      `window.__hgResolve && window.__hgResolve(${JSON.stringify(reqId)}, ${flag}, ${JSON.stringify(payload)})`;
    controller.runJavaScript(script).catch((err: BusinessError) => {
      hilog.warn(0x0000, TAG, 'runJavaScript failed: %{public}s', err.message);
    });
  }

  /**
   * 唯一的网络入口。返回 { status, b64 }，由前端自己解 base64 → 文本/JSON。
   * 这样 ArkTS 侧完全不用碰业务 JSON 结构（避开 ArkTS 的强类型限制）。
   */
  http(reqId: string, url: string, method: string, headersJson: string, body: string, timeoutMs: number): void {
    const timeout = timeoutMs > 0 ? timeoutMs : 30000;
    httpRequest(url, method, headersJson, body, false, timeout)
      .then((result) => {
        const b64 = new util.Base64Helper().encodeToStringSync(new Uint8Array(result.bytes));
        this.reply(reqId, true, JSON.stringify({ status: result.status, b64: b64 }));
      })
      .catch((err: Error) => {
        this.reply(reqId, false, err.message.length > 0 ? err.message : '网络请求失败');
      });
  }

  setBase(base: string): void {
    if (base.length > 0) {
      this.base = base;
    }
  }

  openUrl(url: string): void {
    const want: Want = { action: 'ohos.want.action.viewData', uri: url };
    this.context.startAbility(want).catch((err: BusinessError) => {
      hilog.warn(0x0000, TAG, 'startAbility failed: %{public}s', err.message);
    });
  }

  setOrientation(landscape: boolean): void {
    window.getLastWindow(this.context).then((win: window.Window) => {
      const orientation = landscape ? window.Orientation.LANDSCAPE : window.Orientation.PORTRAIT;
      win.setPreferredOrientation(orientation);
    }).catch((err: BusinessError) => {
      hilog.warn(0x0000, TAG, 'setPreferredOrientation failed: %{public}s', err.message);
    });
  }

  private redactText(msg: string): string {
    return msg
      .replace(/(authorization|cookie|set-cookie)\s*:\s*[^\r\n;]+/gi, '$1: [redacted]')
      .replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/gi, 'Bearer [redacted]')
      .replace(/(token|password|secret|access_key|refresh_token)\s*=\s*[^&\s]+/gi, '$1=[redacted]');
  }

  log(msg: string): void {
    hilog.info(0x0000, TAG, '%{public}s', this.redactText(msg));
  }

  playbackLogStatus(reqId: string): void {
    this.reply(reqId, true, JSON.stringify(this.playbackLog.status()));
  }

  playbackLogSet(reqId: string, enabled: boolean): void {
    this.reply(reqId, true, JSON.stringify(this.playbackLog.setEnabled(enabled)));
  }

  playbackLogAppend(reqId: string, linesJson: string): void {
    this.playbackLog.appendLines(linesJson);
    this.reply(reqId, true, 'null');
  }

  playbackLogRead(reqId: string): void {
    const text = this.playbackLog.export(this.currentBase());
    this.reply(reqId, true, JSON.stringify(text));
  }

  setBackEnabled(enabled: boolean): void {
    this.backEnabled = enabled;
  }

  setPageReady(): void {
    this.pageReady = true;
  }

  /**
   * UIAbility.onBackPressed 调用。
   * 返回 true = 本次返回键由 Web 层消费（页面栈/弹层/全屏）；false = 交给系统（退到后台）。
   * 判断是同步的（backEnabled/pageReady 由前端提前同步过来），实际处理在 Web 侧异步完成。
   */
  handleBack(): boolean {
    const controller = this.controller;
    if (controller === null || !this.pageReady || !this.backEnabled) {
      // Returning true lets the system move the UIAbility to background instead of destroying it.
      return true;
    }
    controller.runJavaScript('window.__hgBackEvent && window.__hgBackEvent()').catch((err: BusinessError) => {
      hilog.warn(0x0000, TAG, 'back event failed: %{public}s', err.message);
    });
    return true;
  }

  /**
   * 前端返回链末端调用：已无栈可退时**退到后台**（不是杀进程）。
   * 对应 UIAbilityContext.moveAbilityToBackground()（API 12+，仅手机/平板支持）。
   * 万一不被支持，兜底才 terminateSelf，避免用户按返回毫无反应。
   */
  background(): void {
    this.context.moveAbilityToBackground().catch((err: BusinessError) => {
      hilog.error(0x0000, TAG, 'moveAbilityToBackground failed: %{public}s (code=%{public}d)',
        err.message, err.code);
      this.context.terminateSelf().catch((e: BusinessError) => {
        hilog.error(0x0000, TAG, 'terminateSelf failed: %{public}s', e.message);
      });
    });
  }

  sourceState(reqId: string): void {
    try {
      this.reply(reqId, true, JSON.stringify(this.sourceManager.state()));
    } catch (err) {
      this.reply(reqId, false, (err as Error).message);
    }
  }

  sourceImportDemo(reqId: string): void {
    this.sourceManager.importDemo()
      .then(() => {
        this.reply(reqId, true, JSON.stringify(this.sourceManager.state()));
      })
      .catch((err: Error) => {
        this.reply(reqId, false, err.message);
      });
  }

  sourceTest(reqId: string, id: string): void {
    this.sourceManager.test(id)
      .then((result: string) => {
        const reply: SourceTestReply = { id: id, result: result };
      this.reply(reqId, true, JSON.stringify(reply));
      })
      .catch((err: Error) => {
        this.reply(reqId, false, err.message);
      });
  }

  sourceActivate(reqId: string, id: string): void {
    try {
      this.reply(reqId, true, JSON.stringify(this.sourceManager.activate(id)));
    } catch (err) {
      this.reply(reqId, false, (err as Error).message);
    }
  }

  sourceRollback(reqId: string): void {
    try {
      this.reply(reqId, true, JSON.stringify(this.sourceManager.rollback()));
    } catch (err) {
      this.reply(reqId, false, (err as Error).message);
    }
  }

  sourceRemove(reqId: string, id: string): void {
    try {
      this.reply(reqId, true, JSON.stringify(this.sourceManager.remove(id)));
    } catch (err) {
      this.reply(reqId, false, (err as Error).message);
    }
  }

  sourceImport(reqId: string, input: string, activate: boolean): void {
    this.sourceManager.importInput(input, activate)
      .then((descriptor) => {
        this.reply(reqId, true, JSON.stringify(descriptor));
      })
      .catch((err: Error) => {
        this.reply(reqId, false, err.message);
      });
  }

  sourceExportShareCode(reqId: string, id: string): void {
    this.sourceManager.exportShareCode(id)
      .then((shareCode: string) => {
        this.reply(reqId, true, JSON.stringify(shareCode));
      })
      .catch((err: Error) => {
        this.reply(reqId, false, err.message);
      });
  }

  sourceSetAllowUntrusted(reqId: string, allow: boolean): void {
    try {
      this.reply(reqId, true, JSON.stringify(this.sourceManager.setAllowUntrusted(allow)));
    } catch (err) {
      this.reply(reqId, false, (err as Error).message);
    }
  }

  sourceCheckUpdate(reqId: string, id: string): void {
    this.sourceManager.checkUpdate(id)
      .then((result) => {
        this.reply(reqId, true, JSON.stringify(result));
      })
      .catch((err: Error) => {
        this.reply(reqId, false, err.message);
      });
  }

  /** 网络快照：给前端 net_diag 用（默认网络、承载类型、DNS、链路地址） */
  netInfo(reqId: string): void {
    this.collectNetInfo().then((snapshot: NetInfoSnapshot) => {
      this.reply(reqId, true, JSON.stringify(snapshot));
    }).catch((err: Error) => {
      this.reply(reqId, false, err.message.length > 0 ? err.message : '读取网络信息失败');
    });
  }

  private async collectNetInfo(): Promise<NetInfoSnapshot> {
    const snapshot: NetInfoSnapshot = {
      online: false,
      bearerTypes: [] as string[],
      dnses: [] as string[],
      linkAddresses: [] as string[],
      mtu: 0
    };
    let net: connection.NetHandle;
    try {
      net = await connection.getDefaultNet();
    } catch (e) {
      return snapshot;
    }
    if (net.netId === 0) {
      return snapshot;
    }
    snapshot.online = true;
    try {
      const caps = await connection.getNetCapabilities(net);
      const bearers: string[] = [];
      const types = caps.bearerTypes;
      if (types !== undefined) {
        for (const type of types) {
          bearers.push(String(type));
        }
      }
      snapshot.bearerTypes = bearers;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'getNetCapabilities failed');
    }
    try {
      const props = await connection.getConnectionProperties(net);
      const dnses: string[] = [];
      const dnsList = props.dnses;
      if (dnsList !== undefined) {
        for (const dns of dnsList) {
          dnses.push(dns.address);
        }
      }
      snapshot.dnses = dnses;
      const links: string[] = [];
      const linkList = props.linkAddresses;
      if (linkList !== undefined) {
        for (const link of linkList) {
          links.push(link.address.address);
        }
      }
      snapshot.linkAddresses = links;
      snapshot.mtu = props.mtu !== undefined ? props.mtu : 0;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'getConnectionProperties failed');
    }
    return snapshot;
  }

  /**
   * 前端「清除缓存」。
   *
   * 这里刻意**不做** `WebStorage.deleteAllData()`：那会顺带清掉 localStorage 里的
   * 登录态、线路选择与观看记录，而 Rust 版清的是内存里的封面/播放列表缓存。
   * 移植版的媒体代理（LocalServer）本身不做内容缓存，静态资源由
   * `Cache-Control: no-cache` 控制，所以最贴近原语义的是「无可清理 + 记一条日志」。
   */
  clearCache(): void {
    hilog.info(0x0000, TAG, 'cache_clear requested (no in-memory cache in HarmonyOS port)');
  }
}
