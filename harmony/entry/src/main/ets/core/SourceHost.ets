/**
 * P3a QuickJS host 原语会话。
 *
 * 原生 QuickJS 只暴露一个通用 `__hostCall(op, payload)`；源 JS 看不到它，
 * 只看到按上游契约冻结的 `host.info / auth / fetch / htmlQuery / crypto / storage`。
 * 所有特权能力都在 ArkTS 侧执行，并在这里落实安全边界：
 * - fetch：仅允许 https 公网地址，且 origin 必须在 manifest.network 白名单内；
 * - htmlQuery：只读解析，2 MB 输入、200 条结果上限；
 * - crypto：私钥 / 共享秘密留在 ArkTS vault，不进源 JS；
 * - storage：按 sourceId 隔离，最多 64 键、单值 32 KB。
 *
 * Pilot 阶段明确不做：逐跳重定向白名单校验、DNS 固定、host.auth 真实账号绑定、
 * 二进制响应。这些是 P3b / 正式移植的安全缺口，不能默认放行。
 */
import { util } from '@kit.ArkTS';
import { httpRequest } from './Http';
import { SourceCrypto, SourceCryptoVault } from './SourceCrypto';
import { SourceHtml } from './SourceHtml';

export interface SourceHostLimits {
  maxHtmlBytes: number;
  maxResponseBytes: number;
  timeoutMs: number;
}

export interface SourceHostInfo {
  sourceId: string;
  name: string;
  version: string;
  baseUrl: string;
  origins: string[];
  mediaOrigins: string[];
  publishOrigins: string[];
  limits: SourceHostLimits;
}

export interface SourceHostContext {
  sourceId: string;
  info: SourceHostInfo;
  allowedOrigins: string[];
}

export interface SourceHostStorage {
  storageGet(sourceId: string, key: string): string | null;
  storageSet(sourceId: string, key: string, value: string | null): void;
}

interface ParsedPublicUrl {
  origin: string;
  host: string;
  port: string;
  path: string;
  url: string;
}

interface SourceHostFetchResponse {
  ok: boolean;
  status: number;
  url: string;
  headers: Record<string, string>;
  text: string;
}

const MAX_REQUEST_BODY_BYTES = 256 * 1024;
const MAX_RESPONSE_BYTES = 2 * 1024 * 1024;
const MIN_FETCH_TIMEOUT_MS = 2000;
const MAX_FETCH_TIMEOUT_MS = 20000;
const DEFAULT_FETCH_TIMEOUT_MS = 10000;

const FORBIDDEN_HEADERS: string[] = [
  'host',
  'connection',
  'keep-alive',
  'transfer-encoding',
  'upgrade',
  'proxy-authorization',
  'cookie'
];

export function hostPrelude(): string {
  return [
    '(function() {',
    '  const call = globalThis.__hostCall;',
    '  const context = globalThis.__hostContext || {};',
    '  if (typeof call !== "function") { throw new Error("host bridge is missing"); }',
    '  function unwrap(response) {',
    '    const res = JSON.parse(response);',
    '    if (res && res.__hostError) { throw new Error(String(res.__hostError)); }',
    '    return res;',
    '  }',
    '  function request(op, payload) {',
    '    return unwrap(call(op, JSON.stringify(Object.assign({ sourceId: context.sourceId || "", allowedOrigins: context.allowedOrigins || [] }, payload))));',
    '  }',
    '  const info = Object.freeze(context.info || {});',
    '  globalThis.host = Object.freeze({',
    '    info: info,',
    '    auth: Object.freeze({ token: null }),',
    '    fetch: function(req) { return request("fetch", { request: req || {} }); },',
    '    htmlQuery: function(html, selector) {',
    '      return request("htmlQuery", { request: { html: String(html == null ? "" : html), selector: String(selector == null ? "" : selector) } });',
    '    },',
    '    crypto: Object.freeze({',
    '      sha256Hex: function(text) { return request("crypto", { request: { op: "sha256Hex", text: String(text == null ? "" : text) } }).hex; },',
    '      randomBytes: function(len) { return request("crypto", { request: { op: "randomBytes", len: len || 16 } }); },',
    '      base64Encode: function(text) { return request("crypto", { request: { op: "base64Encode", text: String(text == null ? "" : text) } }); },',
    '      base64Decode: function(b64) { return request("crypto", { request: { op: "base64Decode", b64: String(b64 == null ? "" : b64) } }).text; },',
    '      ecdhP256Create: function() { return request("crypto", { request: { op: "ecdhP256Create" } }); },',
    '      ecdhP256Derive: function(handle, peerPubB64Url, saltB64Url, infos) {',
    '        return request("crypto", { request: { op: "ecdhP256Derive", handle: handle, peerPubB64Url: String(peerPubB64Url == null ? "" : peerPubB64Url), saltB64Url: String(saltB64Url == null ? "" : saltB64Url), infos: infos || [] } }).keysB64;',
    '      },',
    '      aes256GcmEncrypt: function(opts) { return request("crypto", { request: Object.assign({ op: "aes256GcmEncrypt" }, opts || {}) }); },',
    '      aes256GcmDecrypt: function(opts) { return request("crypto", { request: Object.assign({ op: "aes256GcmDecrypt" }, opts || {}) }); },',
    '      hmacSha256: function(opts) { return request("crypto", { request: Object.assign({ op: "hmacSha256" }, opts || {}) }); }',
    '    }),',
    '    storage: Object.freeze({',
    '      get: function(key) { return request("storageGet", { request: { key: String(key == null ? "" : key) } }).value; },',
    '      set: function(key, val) {',
    '        const clear = (val === null || val === undefined);',
    '        request("storageSet", { request: { key: String(key == null ? "" : key), value: clear ? "" : String(val), clear: clear } });',
    '      }',
    '    })',
    '  });',
    '  delete globalThis.__hostCall;',
    '  delete globalThis.__hostContext;',
    '})();'
  ].join('\n');
}

export class SourceHostSession {
  private context: SourceHostContext;
  private storage: SourceHostStorage;
  private html: SourceHtml;
  private crypto: SourceCrypto;
  private vault: SourceCryptoVault;

  constructor(context: SourceHostContext, storage: SourceHostStorage) {
    this.context = context;
    this.storage = storage;
    this.html = new SourceHtml();
    this.crypto = new SourceCrypto();
    this.vault = new SourceCryptoVault();
  }

  close(): void {
    this.vault.clear();
  }

  async handle(requestJson: string): Promise<string> {
    try {
      const outer = JSON.parse(requestJson) as Record<string, string>;
      const op = readString(outer, 'op');
      const payloadText = readString(outer, 'payload');
      const payload = JSON.parse(payloadText.length > 0 ? payloadText : '{}') as Record<string, Object>;
      const sourceId = readString(payload, 'sourceId');
      if (sourceId !== this.context.sourceId) {
        throw new Error('host sourceId mismatch');
      }
      let request: Record<string, Object> = {};
      if (payload['request'] !== undefined && payload['request'] !== null) {
        request = payload['request'] as Record<string, Object>;
      }
      let result: Object;
      if (op === 'fetch') {
        result = await this.fetch(request);
      } else if (op === 'htmlQuery') {
        const html = readString(request, 'html');
        const selector = readString(request, 'selector');
        result = JSON.parse(this.html.query(html, selector)) as Object;
      } else if (op === 'crypto') {
        result = await this.crypto.run(request, this.vault);
      } else if (op === 'storageGet') {
        const key = readString(request, 'key');
        const value = this.storage.storageGet(this.context.sourceId, key);
        const storageResult: Record<string, Object | null> = {};
        storageResult['value'] = value;
        result = storageResult;
      } else if (op === 'storageSet') {
        const key = readString(request, 'key');
        const value = readString(request, 'value');
        const clear = readBoolean(request, 'clear');
        this.storage.storageSet(this.context.sourceId, key, clear ? null : value);
        const okResult: Record<string, Object> = {};
        okResult['ok'] = true;
        result = okResult;
      } else {
        throw new Error('不支持的 host 操作：' + op);
      }
      return JSON.stringify(result);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return JSON.stringify({ __hostError: message });
    }
  }

  private async fetch(request: Record<string, Object>): Promise<SourceHostFetchResponse> {
    const rawUrl = readString(request, 'url');
    const method = readString(request, 'method').toUpperCase();
    if (method.length === 0) {
      throw new Error('host.fetch requires GET/POST/HEAD/PUT/DELETE');
    }
    if (method !== 'GET' && method !== 'POST' && method !== 'HEAD' && method !== 'PUT' && method !== 'DELETE') {
      throw new Error('不支持的 HTTP 方法：' + method);
    }
    const parsed = parseHttpsUrl(rawUrl);
    if (parsed === null) {
      throw new Error('host.fetch requires a public https URL');
    }
    if (!originAllowed(parsed.origin, this.context.allowedOrigins)) {
      throw new Error('目标域名未在视频源 manifest.network 白名单内');
    }
    const body = readString(request, 'body');
    if (byteLength(body) > MAX_REQUEST_BODY_BYTES) {
      throw new Error('请求体超出上限（256 KB）');
    }
    const headers = safeHeaders(readHeaders(request['headers']));
    const timeoutMs = clampNumber(readNumber(request, 'timeoutMs'), MIN_FETCH_TIMEOUT_MS, MAX_FETCH_TIMEOUT_MS, DEFAULT_FETCH_TIMEOUT_MS);
    const response = await httpRequest(parsed.url, method, JSON.stringify(headers), body, true, timeoutMs);
    const text = fromBytes(new Uint8Array(response.bytes));
    if (byteLength(text) > MAX_RESPONSE_BYTES) {
      throw new Error('响应超出上限（2 MB）');
    }
    return {
      ok: response.status >= 200 && response.status < 300,
      status: response.status,
      url: parsed.url,
      headers: {},
      text: text
    };
  }
}

function readString(map: Record<string, Object>, key: string): string {
  const value = map[key];
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value === 'string') {
    return value;
  }
  return String(value);
}

function readNumber(map: Record<string, Object>, key: string): number {
  const value = map[key];
  if (value === undefined || value === null) {
    return 0;
  }
  if (typeof value === 'number') {
    return value;
  }
  const parsed = Number(value);
  return isNaN(parsed) ? 0 : parsed;
}

function readBoolean(map: Record<string, Object>, key: string): boolean {
  return map[key] === true;
}

function readHeaders(value: Object | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  if (value === undefined || value === null) {
    return out;
  }
  const raw = value as Record<string, Object>;
  const keys = Object.keys(raw);
  for (const key of keys) {
    const item = raw[key];
    if (typeof item === 'string') {
      out[key] = item;
    }
  }
  return out;
}

function safeHeaders(headers: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  const keys = Object.keys(headers);
  for (const key of keys) {
    if (!isForbiddenHeader(key)) {
      out[key] = headers[key];
    }
  }
  return out;
}

function isForbiddenHeader(name: string): boolean {
  const lower = name.trim().toLowerCase();
  for (const item of FORBIDDEN_HEADERS) {
    if (item === lower) {
      return true;
    }
  }
  return false;
}

function byteLength(text: string): number {
  return new util.TextEncoder().encodeInto(text).byteLength;
}

function fromBytes(bytes: Uint8Array): string {
  return new util.TextDecoder().decode(bytes);
}

function clampNumber(value: number, min: number, max: number, fallback: number): number {
  const parsed = isNaN(value) ? fallback : value;
  if (parsed < min) {
    return min;
  }
  if (parsed > max) {
    return max;
  }
  return parsed;
}

function parseHttpsUrl(url: string): ParsedPublicUrl | null {
  if (!url.startsWith('https://')) {
    return null;
  }
  const rest = url.substring(8);
  if (rest.length === 0) {
    return null;
  }
  let authorityEnd = rest.length;
  for (let i = 0; i < rest.length; i++) {
    const ch = rest.charAt(i);
    if (ch === '/' || ch === '?' || ch === '#') {
      authorityEnd = i;
      break;
    }
  }
  const authority = rest.substring(0, authorityEnd);
  let path = rest.substring(authorityEnd);
  if (authority.length === 0 || authority.indexOf('@') >= 0 || authority.startsWith('[')) {
    return null;
  }
  let host = authority;
  let port = '';
  const colon = authority.indexOf(':');
  if (colon >= 0) {
    host = authority.substring(0, colon);
    port = authority.substring(colon + 1);
    if (port.length === 0 || !isDigits(port)) {
      return null;
    }
  }
  const hostLower = host.toLowerCase();
  if (!isPublicHost(hostLower)) {
    return null;
  }
  const origin = 'https://' + hostLower + (port.length > 0 && port !== '443' ? ':' + port : '');
  if (path.length === 0) {
    path = '/';
  }
  return { origin: origin, host: hostLower, port: port, path: path, url: origin + path };
}

function isDigits(text: string): boolean {
  if (text.length === 0) {
    return false;
  }
  for (let i = 0; i < text.length; i++) {
    const ch = text.charAt(i);
    if (ch < '0' || ch > '9') {
      return false;
    }
  }
  return true;
}

function isPublicHost(host: string): boolean {
  if (host.length === 0 || host.indexOf(':') >= 0) {
    return false;
  }
  if (host === 'localhost' || hasSuffix(host, '.local') || hasSuffix(host, '.internal') ||
      hasSuffix(host, '.lan') || hasSuffix(host, '.test') || hasSuffix(host, '.example') ||
      hasSuffix(host, '.invalid') || hasSuffix(host, '.localhost')) {
    return false;
  }
  if (host.indexOf('.') < 0) {
    return false;
  }
  if (isIpv4Literal(host)) {
    return isPublicIpv4(host);
  }
  return true;
}

function hasSuffix(text: string, suffix: string): boolean {
  if (text.length < suffix.length) {
    return false;
  }
  return text.substring(text.length - suffix.length) === suffix;
}

function isIpv4Literal(host: string): boolean {
  const parts = host.split('.');
  if (parts.length !== 4) {
    return false;
  }
  for (const part of parts) {
    if (part.length === 0 || part.length > 3 || !isDigits(part)) {
      return false;
    }
  }
  return true;
}

function isPublicIpv4(host: string): boolean {
  const parts = host.split('.');
  const octets: number[] = [];
  for (const part of parts) {
    octets.push(Number(part));
  }
  const first = octets[0];
  const second = octets[1];
  if (first === 0 || first === 10 || first === 127) {
    return false;
  }
  if (first === 169 && second === 254) {
    return false;
  }
  if (first === 172 && second >= 16 && second <= 31) {
    return false;
  }
  if (first === 192 && second === 168) {
    return false;
  }
  if (first === 100 && second >= 64 && second <= 127) {
    return false;
  }
  if (first === 198 && (second === 18 || second === 19)) {
    return false;
  }
  if (first === 192 && second === 0 && octets[2] === 2) {
    return false;
  }
  if (first === 198 && second === 51 && octets[2] === 100) {
    return false;
  }
  if (first === 203 && second === 0 && octets[2] === 113) {
    return false;
  }
  if (first >= 224) {
    return false;
  }
  return true;
}

function originAllowed(targetOrigin: string, allowed: string[]): boolean {
  if (allowed.length === 0) {
    return false;
  }
  const target = targetOrigin.toLowerCase();
  for (const entry of allowed) {
    const parsed = parseHttpsUrl(entry.trim());
    if (parsed !== null && parsed.origin.toLowerCase() === target) {
      return true;
    }
  }
  return false;
}
