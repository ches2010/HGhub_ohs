/**
 * 本地 HTTP 服务（loopback）：把「静态前端 + 媒体代理」都放在同一个 origin 上。
 *
 * 为什么必须自己起服务，而不是用 Web 组件的 onInterceptRequest：
 *   onInterceptRequest 是同步回调，拿不到异步网络结果；/hls /seg /img 都要现拉上游，
 *   同步返回空响应等于播放全挂。HGhub 的 Linux 桌面版也是同样原因才起 loopback 代理
 *   （见 src-tauri/src/linux_http.rs），这里沿用同一套思路。
 *
 * 端点：
 *   GET /                      → rawfile/www/index.html
 *   GET /assets/*              → rawfile/www 下的静态资源
 *   GET /hls?u=<upstream m3u8> → 拉取并改写分片/key 地址
 *   GET /seg?u=<upstream seg>  → 分片/key 透传（含 Range），内层 m3u8 继续改写
 *   GET /img?u=<upstream img>  → 封面拉取 + AES-128-CBC 解密
 */
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { resourceManager } from '@kit.LocalizationKit';
import { httpRequest } from './Http';
import {
  aesCbcDecrypt,
  decodeText,
  encodeText,
  imageKind,
  looksLikePlaylist,
  rewritePlaylist,
  stripPadding
} from './Media';

function concatBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
  if (a.byteLength === 0) {
    return b;
  }
  if (b.byteLength === 0) {
    return a;
  }
  const out = new Uint8Array(a.byteLength + b.byteLength);
  out.set(a, 0);
  out.set(b, a.byteLength);
  return out;
}

function toArrayBuffer(view: Uint8Array): ArrayBuffer {
  const out = new ArrayBuffer(view.byteLength);
  new Uint8Array(out).set(view);
  return out;
}

function findHeaderEnd(buf: Uint8Array): number {
  for (let i = 0; i + 3 < buf.byteLength; i++) {
    if (buf[i] === 13 && buf[i + 1] === 10 && buf[i + 2] === 13 && buf[i + 3] === 10) {
      return i;
    }
  }
  return -1;
}

function param(query: string, name: string): string {
  if (query.length === 0) {
    return '';
  }
  const parts = query.split('&');
  for (const part of parts) {
    const eq = part.indexOf('=');
    if (eq > 0 && part.substring(0, eq) === name) {
      try {
        return decodeURIComponent(part.substring(eq + 1));
      } catch (e) {
        return part.substring(eq + 1);
      }
    }
  }
  return '';
}

function mimeOf(path: string): string {
  const lower = path.toLowerCase();
  const dot = lower.lastIndexOf('.');
  const ext = dot < 0 ? '' : lower.substring(dot);
  if (ext === '.html' || ext === '.htm') return 'text/html; charset=utf-8';
  if (ext === '.js' || ext === '.mjs') return 'text/javascript; charset=utf-8';
  if (ext === '.css') return 'text/css; charset=utf-8';
  if (ext === '.json') return 'application/json; charset=utf-8';
  if (ext === '.svg') return 'image/svg+xml';
  if (ext === '.png') return 'image/png';
  if (ext === '.jpg' || ext === '.jpeg') return 'image/jpeg';
  if (ext === '.webp') return 'image/webp';
  if (ext === '.gif') return 'image/gif';
  if (ext === '.ico') return 'image/x-icon';
  if (ext === '.woff') return 'font/woff';
  if (ext === '.woff2') return 'font/woff2';
  if (ext === '.ttf') return 'font/ttf';
  if (ext === '.m3u8') return 'application/vnd.apple.mpegurl';
  if (ext === '.ts') return 'video/mp2t';
  if (ext === '.m4s' || ext === '.mp4') return 'video/mp4';
  return 'application/octet-stream';
}

function sniffMedia(path: string, bytes: Uint8Array): string {
  const byExt = mimeOf(path);
  if (byExt !== 'application/octet-stream') {
    return byExt;
  }
  const image = imageKind(bytes);
  if (image.length > 0) {
    return image;
  }
  return byExt;
}

function ipv4ToInt(value: string): number | null {
  const parts = value.split('.');
  if (parts.length !== 4) return null;
  let out = 0;
  for (const part of parts) {
    if (!/^\d+$/.test(part)) return null;
    const n = Number(part);
    if (n > 255) return null;
    out = out * 256 + n;
  }
  return out;
}

function ipv4InCidr(value: string, cidr: string): boolean {
  const parts = cidr.split('/');
  const valueInt = ipv4ToInt(value);
  const baseInt = ipv4ToInt(parts[0]);
  const prefix = Number(parts[1]);
  if (valueInt === null || baseInt === null || !Number.isInteger(prefix) || prefix < 0 || prefix > 32) return false;
  const mask = prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0;
  return ((valueInt & mask) >>> 0) === ((baseInt & mask) >>> 0);
}

function isForbiddenIpv4(value: string): boolean {
  const ranges = [
    '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
    '169.254.0.0/16', '172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24',
    '192.168.0.0/16', '198.51.100.0/24', '203.0.113.0/24',
    '224.0.0.0/4', '240.0.0.0/4'
  ];
  return ranges.some((cidr: string) => ipv4InCidr(value, cidr));
}

function ipv6Groups(value: string): number[] | null {
  const text = value.toLowerCase().split('%')[0];
  let head = text;
  let tail = '';
  let compressed = false;
  if (text.includes('::')) {
    const parts = text.split('::');
    if (parts.length !== 2) return null;
    compressed = true;
    head = parts[0];
    tail = parts[1];
  }
  const headGroups = head.length === 0 ? [] as string[] : head.split(':');
  const tailGroups = tail.length === 0 ? [] as string[] : tail.split(':');
  const missing = 8 - headGroups.length - tailGroups.length;
  if (missing < 0 || (!compressed && missing !== 0)) return null;
  const tokens = headGroups.concat(new Array(compressed ? missing : 0).fill('0'), tailGroups);
  const groups: number[] = [];
  for (const token of tokens) {
    if (!/^[0-9a-f]{1,4}$/.test(token)) return null;
    groups.push(parseInt(token, 16));
  }
  return groups;
}

function isForbiddenIpv6(value: string): boolean {
  const groups = ipv6Groups(value);
  if (groups === null) return true;
  if (groups.every((group: number) => group === 0)) return true;
  if (groups[0] >= 0xfc00 && groups[0] <= 0xfdff) return true;
  if (groups[0] >= 0xfe80 && groups[0] <= 0xfebf) return true;
  if (groups[0] >= 0xfec0 && groups[0] <= 0xfeef) return true;
  if (groups[0] >= 0xff00) return true;
  if (groups[0] === 0x2001 && groups[1] === 0x0db8) return true;
  if (groups.slice(0, 5).every((group: number) => group === 0) && (groups[5] === 0 || groups[5] === 0xffff)) {
    const low = groups[6] * 65536 + groups[7];
    const ipv4 = `${Math.floor(low / 16777216) % 256}.${Math.floor(low / 65536) % 256}.${Math.floor(low / 256) % 256}.${low % 256}`;
    return isForbiddenIpv4(ipv4);
  }
  return false;
}

function isForbiddenUpstreamHost(host: string): boolean {
  const value = host.trim().replace(/^\[/, '').replace(/\]$/, '').toLowerCase();
  if (value.length === 0) return true;
  if (/(^|\.)localhost$/.test(value) || /(^|\.)local$/.test(value) || /(^|\.)internal$/.test(value) || /(^|\.)home\.arpa$/.test(value)) return true;
  if (value.includes(':')) return isForbiddenIpv6(value);
  if (/^\d+\.\d+\.\d+\.\d+$/.test(value)) return isForbiddenIpv4(value);
  return !value.includes('.');
}

interface ParsedHttpsUrl {
  host: string;
  port: string;
}

function parseHttpsUrl(value: string): ParsedHttpsUrl | null {
  const text = value.trim();
  if (!text.startsWith('https://')) return null;
  const rest = text.substring(8);
  if (rest.length === 0 || /\s/.test(rest)) return null;

  let end = rest.length;
  for (let i = 0; i < rest.length; i++) {
    const ch = rest.charAt(i);
    if (ch === '/' || ch === '?' || ch === '#') {
      end = i;
      break;
    }
  }
  const authority = rest.substring(0, end);
  if (authority.length === 0 || authority.indexOf('@') >= 0) return null;

  let host = '';
  let port = '';
  if (authority.startsWith('[')) {
    const close = authority.indexOf(']');
    if (close < 0) return null;
    host = authority.substring(1, close);
    const suffix = authority.substring(close + 1);
    if (suffix.length === 0) {
      port = '';
    } else if (suffix.startsWith(':')) {
      port = suffix.substring(1);
    } else {
      return null;
    }
  } else {
    const colon = authority.lastIndexOf(':');
    if (colon < 0) {
      host = authority;
    } else {
      host = authority.substring(0, colon);
      port = authority.substring(colon + 1);
    }
  }

  host = host.toLowerCase();
  if (host.length === 0) return null;
  if (port.length > 0 && (!/^\d{1,5}$/.test(port) || Number(port) > 65535)) return null;
  if (isForbiddenUpstreamHost(host)) return null;
  return { host: host, port: port };
}

function isAllowedUpstreamUrl(value: string): boolean {
  if (value.length === 0 || value.length > 2048) return false;
  return parseHttpsUrl(value) !== null;
}

export class LocalServer {
  private port: number;
  private mgr: resourceManager.ResourceManager;
  private baseProvider: () => string;
  private server: socket.TCPSocketServer | null = null;
  private running: boolean = false;
  /** rawfile/www 里是否存在前端产物（index.html）。缺了就只能白屏，必须让界面能说出来。 */
  private bundleReady: boolean = false;

  constructor(mgr: resourceManager.ResourceManager, port: number, baseProvider: () => string) {
    this.mgr = mgr;
    this.port = port;
    this.baseProvider = baseProvider;
  }

  origin(): string {
    return `http://127.0.0.1:${this.port}`;
  }

  pageUrl(): string {
    return `${this.origin()}/index.html`;
  }

  async start(): Promise<void> {
    if (this.running) {
      return;
    }
    let server: socket.TCPSocketServer;
    try {
      server = socket.constructTCPSocketServerInstance();
      await server.listen({ address: '127.0.0.1', port: this.port, family: 1 });
    } catch (e) {
      const message = e !== undefined && e !== null ? (e as Error).message : '';
      throw new Error(`本地服务无法监听 127.0.0.1:${this.port}（${message}）`);
    }
    server.on('connect', (client: socket.TCPSocketConnection) => {
      this.accept(client);
    });
    this.server = server;
    this.running = true;
    this.bundleReady = this.readRaw('www/index.html') !== null;
  }

  /** 前端产物是否已同步进 rawfile（构造并 start() 之后才有效） */
  hasBundle(): boolean {
    return this.bundleReady;
  }

  async stop(): Promise<void> {
    const server = this.server;
    this.server = null;
    this.running = false;
    if (server !== null) {
      try {
        await server.close();
      } catch (e) {
        // 关闭失败不影响退出
      }
    }
  }

  private accept(client: socket.TCPSocketConnection): void {
    let acc = new Uint8Array(0);
    let busy = false;
    client.on('message', (info: socket.SocketMessageInfo) => {
      if (busy) {
        return;
      }
      acc = concatBytes(acc, new Uint8Array(info.message));
      const end = findHeaderEnd(acc);
      if (end < 0) {
        if (acc.byteLength > 65536) {
          try {
            client.close();
          } catch (e) {
          }
        }
        return;
      }
      busy = true;
      const head = decodeText(acc.subarray(0, end));
      this.handle(client, head).catch((err: Error) => {
        this.send(client, 500, 'Internal Server Error', 'text/plain; charset=utf-8',
          encodeText(`server error: ${err.message}`), []).catch(() => {
        });
      });
    });
    client.on('close', () => {
      acc = new Uint8Array(0);
    });
  }

  private async handle(client: socket.TCPSocketConnection, head: string): Promise<void> {
    const lines = head.split('\r\n');
    if (lines.length === 0) {
      return;
    }
    const requestLine = lines[0].split(' ');
    if (requestLine.length < 2) {
      await this.send(client, 400, 'Bad Request', 'text/plain', encodeText('bad request'), []);
      return;
    }
    const method = requestLine[0].toUpperCase();
    const target = requestLine[1];
    if (method !== 'GET' && method !== 'HEAD') {
      await this.send(client, 405, 'Method Not Allowed', 'text/plain', encodeText('method not allowed'), []);
      return;
    }
    let range = '';
    let rangeCount = 0;
    let hasIfRange = false;
    let host = '';
    let hostCount = 0;
    const origins: string[] = [];
    for (let i = 1; i < lines.length; i++) {
      const colon = lines[i].indexOf(':');
      if (colon <= 0) continue;
      const name = lines[i].substring(0, colon).trim().toLowerCase();
      const value = lines[i].substring(colon + 1).trim();
      if (name === 'range') {
        rangeCount++;
        range = value;
      } else if (name === 'if-range' && value.length > 0) {
        hasIfRange = true;
      } else if (name === 'host') {
        hostCount++;
        host = value;
      } else if (name === 'origin') {
        origins.push(value);
      }
    }
    if (hostCount !== 1 || host !== `127.0.0.1:${this.port}`) {
      await this.send(client, 400, 'Bad Request', 'text/plain', encodeText('bad host'), []);
      return;
    }
    if (origins.length > 1 || (origins.length === 1 && origins[0] !== this.origin())) {
      await this.send(client, 403, 'Forbidden', 'text/plain', encodeText('bad origin'), []);
      return;
    }
    const rangeHeader = rangeCount === 1 && !hasIfRange ? range : '';
    const q = target.indexOf('?');
    const path = q < 0 ? target : target.substring(0, q);
    const query = q < 0 ? '' : target.substring(q + 1);
    const upstream = param(query, 'u');

    // 自检端点：用原生 http 打一下这里，就能区分「服务没起来」还是「WebView 加载被拦」
    if (path === '/__ping') {
      const body = `pong bundle=${this.bundleReady ? '1' : '0'} port=${this.port}`;
      await this.send(client, 200, 'OK', 'text/plain; charset=utf-8', encodeText(body), []);
      return;
    }
    if (path === '/hls') {
      await this.servePlaylist(client, upstream);
      return;
    }
    if (path === '/seg') {
      await this.serveSegment(client, upstream, rangeHeader, method === 'HEAD');
      return;
    }
    if (path === '/img') {
      await this.serveImage(client, upstream);
      return;
    }
    await this.serveStatic(client, path, method === 'HEAD');
  }

  private async fetchUpstream(url: string): Promise<Uint8Array> {
    if (!isAllowedUpstreamUrl(url)) {
      throw new Error('不支持的媒体地址');
    }
    const base = this.baseProvider();
    const headers = JSON.stringify({ 'Referer': `${base}/`, 'Accept': '*/*' });
    const resp = await httpRequest(url, 'GET', headers, '', false, 20000);
    if (resp.status < 200 || resp.status >= 300) {
      throw new Error(`上游返回 HTTP ${resp.status}`);
    }
    return new Uint8Array(resp.bytes);
  }

  private async servePlaylist(client: socket.TCPSocketConnection, url: string): Promise<void> {
    if (url.length === 0) {
      await this.send(client, 400, 'Bad Request', 'text/plain', encodeText('missing u'), []);
      return;
    }
    try {
      const bytes = await this.fetchUpstream(url);
      if (!looksLikePlaylist(bytes)) {
        await this.send(client, 502, 'Bad Gateway', 'text/plain', encodeText('not a playlist'), []);
        return;
      }
      const rewritten = rewritePlaylist(this.origin(), url, decodeText(bytes));
      await this.send(client, 200, 'OK', 'application/vnd.apple.mpegurl', encodeText(rewritten), [
        'Cache-Control: no-store'
      ]);
    } catch (e) {
      const msg = (e as Error).message;
      await this.send(client, 502, 'Bad Gateway', 'text/plain', encodeText(msg), []);
    }
  }

  private async serveSegment(
    client: socket.TCPSocketConnection,
    url: string,
    range: string,
    headOnly: boolean
  ): Promise<void> {
    if (url.length === 0) {
      await this.send(client, 400, 'Bad Request', 'text/plain', encodeText('missing u'), []);
      return;
    }
    try {
      let bytes = await this.fetchUpstream(url);
      // 内层清单（EXT-X-STREAM-INF 指向的子 m3u8）同样要改写
      if (looksLikePlaylist(bytes)) {
        const rewritten = rewritePlaylist(this.origin(), url, decodeText(bytes));
        await this.send(client, 200, 'OK', 'application/vnd.apple.mpegurl', encodeText(rewritten), [
          'Cache-Control: no-store'
        ]);
        return;
      }
      const contentType = sniffMedia(url.split('?')[0], bytes);
      const total = bytes.byteLength;
      let status = 200;
      let statusText = 'OK';
      const extra: string[] = ['Cache-Control: public, max-age=60', 'Accept-Ranges: bytes'];
      const spec = range.startsWith('bytes=') ? range.substring(6).trim() : '';
      if (spec.length > 0 && !spec.includes(',')) {
        const dash = spec.indexOf('-');
        const startText = dash < 0 ? spec : spec.substring(0, dash);
        const endText = dash < 0 ? '' : spec.substring(dash + 1);
        const hasStart = startText.length > 0;
        const hasEnd = endText.length > 0;
        const start = hasStart ? Number(startText) : 0;
        let end = hasEnd ? Number(endText) : total - 1;
        const valid = (!hasStart || (/^\d+$/.test(startText) && Number.isSafeInteger(start) && start >= 0))
          && (!hasEnd || (/^\d+$/.test(endText) && Number.isSafeInteger(end) && end >= 0));
        // HTTP suffix ranges (`bytes=-500`) mean the final 500 bytes, not the first 500.
        if (valid && !hasStart && hasEnd) {
          const suffix = Number(endText);
          if (suffix === 0) {
            await this.send(client, 416, 'Range Not Satisfiable', 'text/plain', encodeText('range'), [
              `Content-Range: bytes */${total}`
            ]);
            return;
          }
          start = suffix >= total ? 0 : total - suffix;
          end = total - 1;
        }
        if (valid && hasStart && start >= total) {
          await this.send(client, 416, 'Range Not Satisfiable', 'text/plain', encodeText('range'), [
            `Content-Range: bytes */${total}`
          ]);
          return;
        }
        if (valid && start <= end && start < total) {
          const clippedEnd = Math.min(end, total - 1);
          bytes = bytes.subarray(start, clippedEnd + 1);
          status = 206;
          statusText = 'Partial Content';
          extra.push(`Content-Range: bytes ${start}-${clippedEnd}/${total}`);
        }
        // Invalid or unsatisfiable-but-not-beyond-EOF ranges intentionally fall back to a full 200 response.
      }
      const body = headOnly ? new Uint8Array(0) : bytes;
      await this.send(client, status, statusText, contentType, body, extra, headOnly ? bytes.byteLength : undefined);
    } catch (e) {
      const msg = (e as Error).message;
      await this.send(client, 502, 'Bad Gateway', 'text/plain', encodeText(msg), []);
    }
  }

  private async serveImage(client: socket.TCPSocketConnection, url: string): Promise<void> {
    if (url.length === 0) {
      await this.send(client, 400, 'Bad Request', 'text/plain', encodeText('missing u'), []);
      return;
    }
    try {
      const raw = await this.fetchUpstream(url);
      let plain = raw;
      if (imageKind(raw).length === 0) {
        plain = stripPadding(await aesCbcDecrypt(raw));
      }
      const kind = imageKind(plain);
      if (kind.length === 0) {
        await this.send(client, 502, 'Bad Gateway', 'text/plain', encodeText('not an image'), []);
        return;
      }
      await this.send(client, 200, 'OK', kind, plain, [
        'Cache-Control: public, max-age=3600'
      ]);
    } catch (e) {
      const msg = (e as Error).message;
      await this.send(client, 502, 'Bad Gateway', 'text/plain', encodeText(msg), []);
    }
  }

  private readRaw(rel: string): Uint8Array | null {
    try {
      return this.mgr.getRawFileContentSync(rel);
    } catch (e) {
      return null;
    }
  }

  /** 前端产物缺失时的说明页：把「为什么白屏」和「怎么修」直接写在页面上 */
  private missingBundleHtml(path: string): string {
    return `<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">`
      + `<style>body{background:#111;color:#eee;font:15px/1.7 -apple-system,sans-serif;padding:22px}`
      + `code{background:#222;padding:2px 6px;border-radius:4px;word-break:break-all}`
      + `h3{color:#ff8a80;margin:0 0 12px}li{margin:6px 0}</style></head><body>`
      + `<h3>本地服务已启动，但 App 里没有前端页面</h3>`
      + `<p><code>entry/src/main/resources/rawfile/www/</code> 是空的（只有 README.txt），`
      + `所以 <code>${path}</code> 取不到内容 —— 这就是白屏的原因。</p>`
      + `<p><b>修复（在仓库根执行）：</b></p>`
      + `<ol><li><code>node harmony/patches/apply-patch.mjs .</code></li>`
      + `<li><code>harmony/scripts/build-web.sh</code>（装依赖 + 构建 + 同步，一步到位）</li>`
      + `<li>重新 Build HAP 并安装</li></ol>`
      + `<p>它会把前端 dist 同步成 <code>rawfile/www/index.html</code> 与 <code>assets/</code>。</p>`
      + `</body></html>`;
  }

  private async serveStatic(
    client: socket.TCPSocketConnection,
    path: string,
    headOnly: boolean
  ): Promise<void> {
    const clean = path === '/' ? '/index.html' : path;
    if (clean.indexOf('..') >= 0) {
      await this.send(client, 403, 'Forbidden', 'text/plain', encodeText('forbidden'), []);
      return;
    }
    let bytes = this.readRaw(`www${clean}`);
    if (bytes === null) {
      // SPA fallback：无扩展名的路由交给 index.html
      const dot = clean.lastIndexOf('.');
      const slash = clean.lastIndexOf('/');
      const hasExt = dot > slash;
      if (!hasExt) {
        bytes = this.readRaw('www/index.html');
      }
    }
    if (bytes === null) {
      if (!this.bundleReady) {
        // 前端产物没同步进来：给一页能看懂的中文说明，而不是让用户对着白屏猜
        await this.send(client, 200, 'OK', 'text/html; charset=utf-8',
          encodeText(this.missingBundleHtml(clean)), []);
        return;
      }
      await this.send(client, 404, 'Not Found', 'text/plain', encodeText(`not found: ${clean}`), []);
      return;
    }
    await this.send(client, 200, 'OK', mimeOf(clean), headOnly ? new Uint8Array(0) : bytes, [
      'Cache-Control: no-cache'
    ], headOnly ? bytes.byteLength : undefined);
  }

  private async send(
    client: socket.TCPSocketConnection,
    status: number,
    statusText: string,
    contentType: string,
    body: Uint8Array,
    extra: string[],
    contentLength?: number
  ): Promise<void> {
    const headerLines: string[] = [];
    headerLines.push(`HTTP/1.1 ${status} ${statusText}`);
    headerLines.push(`Content-Type: ${contentType}`);
    headerLines.push(`Content-Length: ${contentLength === undefined ? body.byteLength : contentLength}`);
    headerLines.push('Access-Control-Allow-Origin: *');
    headerLines.push('X-Content-Type-Options: nosniff');
    for (const line of extra) {
      headerLines.push(line);
    }
    headerLines.push('Connection: close');
    headerLines.push('');
    headerLines.push('');
    const headBytes = encodeText(headerLines.join('\r\n'));
    const merged = concatBytes(headBytes, body);
    try {
      await client.send({ data: toArrayBuffer(merged) });
    } catch (e) {
      // 客户端提前断开（拖动进度条时很常见），忽略
    }
    try {
      client.close();
    } catch (e) {
    }
  }
}
