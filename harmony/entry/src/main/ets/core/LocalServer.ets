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

export class LocalServer {
  private port: number;
  private mgr: resourceManager.ResourceManager;
  private baseProvider: () => string;
  private server: socket.TCPSocketServer | null = null;
  private running: boolean = false;

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
    for (let i = 1; i < lines.length; i++) {
      const colon = lines[i].indexOf(':');
      if (colon > 0 && lines[i].substring(0, colon).trim().toLowerCase() === 'range') {
        range = lines[i].substring(colon + 1).trim();
      }
    }
    const q = target.indexOf('?');
    const path = q < 0 ? target : target.substring(0, q);
    const query = q < 0 ? '' : target.substring(q + 1);
    const upstream = param(query, 'u');

    if (path === '/hls') {
      await this.servePlaylist(client, upstream);
      return;
    }
    if (path === '/seg') {
      await this.serveSegment(client, upstream, range, method === 'HEAD');
      return;
    }
    if (path === '/img') {
      await this.serveImage(client, upstream);
      return;
    }
    await this.serveStatic(client, path, method === 'HEAD');
  }

  private async fetchUpstream(url: string): Promise<Uint8Array> {
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
      let status = 200;
      let statusText = 'OK';
      const extra: string[] = ['Cache-Control: public, max-age=60', 'Accept-Ranges: bytes'];
      if (range.startsWith('bytes=')) {
        const spec = range.substring(6);
        const dash = spec.indexOf('-');
        const startText = dash < 0 ? spec : spec.substring(0, dash);
        const endText = dash < 0 ? '' : spec.substring(dash + 1);
        const total = bytes.byteLength;
        const start = startText.length === 0 ? 0 : parseInt(startText, 10);
        let end = endText.length === 0 ? total - 1 : parseInt(endText, 10);
        if (isNaN(start) || start >= total) {
          await this.send(client, 416, 'Range Not Satisfiable', 'text/plain', encodeText('range'), [
            `Content-Range: bytes */${total}`
          ]);
          return;
        }
        if (isNaN(end) || end >= total) {
          end = total - 1;
        }
        bytes = bytes.subarray(start, end + 1);
        status = 206;
        statusText = 'Partial Content';
        extra.push(`Content-Range: bytes ${start}-${end}/${total}`);
      }
      const body = headOnly ? new Uint8Array(0) : bytes;
      await this.send(client, status, statusText, contentType, body, extra);
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
      await this.send(client, 200, 'OK', kind.length > 0 ? kind : 'image/jpeg', plain, [
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
      await this.send(client, 404, 'Not Found', 'text/plain', encodeText(`not found: ${clean}`), []);
      return;
    }
    await this.send(client, 200, 'OK', mimeOf(clean), headOnly ? new Uint8Array(0) : bytes, [
      'Cache-Control: no-cache'
    ]);
  }

  private async send(
    client: socket.TCPSocketConnection,
    status: number,
    statusText: string,
    contentType: string,
    body: Uint8Array,
    extra: string[]
  ): Promise<void> {
    const headerLines: string[] = [];
    headerLines.push(`HTTP/1.1 ${status} ${statusText}`);
    headerLines.push(`Content-Type: ${contentType}`);
    headerLines.push(`Content-Length: ${body.byteLength}`);
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
