/**
 * HGhubX → HarmonyOS 移植层（替换 @tauri-apps/api/core）
 * ---------------------------------------------------------------
 * 原理：Rust 侧的业务逻辑其实只有一个「边缘信封」入口 ——
 *   POST {base}/api/edge/request
 *   body: { method, path, body(base64 JSON), content_type }
 *   header: Accept / Referer / Authorization: Bearer <token>
 *   响应: { status: 1, data: ... } 取 data；否则抛 msg；HTTP 401/403 → "401"
 * 所以这里不需要重写 60 个命令的业务逻辑，只要复刻信封 + 每个命令的 path 拼装
 * （path 与 src-tauri/src/api.rs 一一对应），再把 invoke 改成走本地桥。
 *
 * 真正的跨域问题由 ArkTS 侧的 http() 解决（原生请求没有 CORS）。
 */
import { lineStateStore } from "./line";
import { tr } from "../shared/i18n";
import { buildUpdateInfo, noReleaseInfo, type ReleaseAsset } from "./update";
import {
  autoPick,
  AUTO_PROBE_PATH,
  bindLineTransport,
  FIXED,
  health as lineHealth,
  hostOf,
  mirrors as lineMirrors,
  probe as lineProbe,
  tryMain as lineTryMain,
} from "./lines";

declare const __APP_VERSION__: string;

const appVersion = (): string => {
  try {
    return typeof __APP_VERSION__ === "string" ? __APP_VERSION__ : "";
  } catch {
    return "";
  }
};

type Json = any;

interface Pending {
  resolve: (value: Json) => void;
  reject: (reason: string) => void;
  timer: number;
}

const pending = new Map<string, Pending>();
let seq = 0;
let playbackSeq = 0;

/**
 * 复刻 Tauri v2 的 Channel：上游 TV 更新器会用它把下载进度回传给前端。
 * 真正的 Tauri 环境走 __TAURI_INTERNALS__.transformCallback；
 * 鸿蒙桥没有这个注册表，先保留回调并序列化为占位通道（TV 更新命令本身未移植）。
 */
export class Channel<T = unknown> {
  readonly id: number;

  constructor(callback: (response: T) => void) {
    const internals = (window as unknown as {
      __TAURI_INTERNALS__?: {
        transformCallback?: (callback: (...args: unknown[]) => unknown) => number;
      };
    }).__TAURI_INTERNALS__;
    if (typeof internals?.transformCallback === "function") {
      this.id = internals.transformCallback(callback as (...args: unknown[]) => unknown);
    } else {
      this.id = 0;
      (this as unknown as { __hgCallback?: (response: T) => void }).__hgCallback = callback;
    }
  }

  toJSON(): string {
    return `__CHANNEL__:${this.id}`;
  }
}

/* ── 硬件返回键（鸿蒙 UIAbility.onBackPressed → window.__hgBackEvent） ── */
type BackListener = () => void;
const backListeners = new Set<BackListener>();

/**
 * 复刻 Tauri 的 addPluginListener：App.tsx 在 platform==="android" 时会注册
 * app/back-button 监听，里面就是整条返回逻辑（面板 → 全屏 → 登录框 → 页面栈 → 回首页 → 退出）。
 * 鸿蒙侧的 EntryAbility.onBackPressed 触发 window.__hgBackEvent()，落到这里。
 */
export async function addPluginListener(
  plugin: string,
  event: string,
  cb: (...args: Json[]) => void,
): Promise<{ unregister: () => Promise<void> }> {
  if (!hasHarmonyBridge()) {
    // 测试 fixture / Tauri 桌面：走 Tauri 官方插件事件协议（transformCallback + register_listener），
    // 让基于 __TAURI_INTERNALS__ 的 mock（如 scripts/fixtures/app-ui.mjs）能接住返回键通道。
    const internals = (window as unknown as {
      __TAURI_INTERNALS__?: {
        invoke: (cmd: string, args?: Record<string, unknown>) => Promise<unknown>;
        transformCallback?: (cb: (...args: unknown[]) => unknown) => number;
      };
    }).__TAURI_INTERNALS__;
    if (internals?.transformCallback) {
      const handler = internals.transformCallback(cb);
      await internals.invoke(`plugin:${plugin}|register_listener`, { event, handler });
      return {
        unregister: async () => {
          await internals
            .invoke(`plugin:${plugin}|unregister_listener`, { event, handler })
            .catch(() => {});
        },
      };
    }
  }
  if (plugin !== "app" || event !== "back-button") {
    throw `尚未支持的事件：${plugin}/${event}`;
  }
  const listener: BackListener = () => cb();
  backListeners.add(listener);
  try {
    native().setBackEnabled(true);
  } catch {
    /* 页面刚加载时桥可能还没注入 */
  }
  return {
    unregister: async () => {
      backListeners.delete(listener);
      if (backListeners.size === 0) {
        try {
          native().setBackEnabled(false);
        } catch {
          /* ignore */
        }
      }
    },
  };
}

/** ArkTS 侧 onBackPressed 会执行这段：true = 本次返回已由页面接管 */
(window as unknown as { __hgBackEvent?: () => boolean }).__hgBackEvent = (): boolean => {
  if (backListeners.size === 0) return false;
  for (const listener of Array.from(backListeners)) {
    try {
      listener();
    } catch {
      /* 单个监听器出错不能阻塞返回 */
    }
  }
  return true;
};

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8");

/** ArkTS 侧回传：__hgResolve(id, ok, payload) */
(window as unknown as { __hgResolve?: (id: string, ok: boolean, payload: string) => void }).__hgResolve = (
  id: string,
  ok: boolean,
  payload: string,
) => {
  const p = pending.get(id);
  if (!p) return;
  pending.delete(id);
  clearTimeout(p.timer);
  if (ok) {
    try {
      p.resolve(payload ? JSON.parse(payload) : null);
    } catch {
      p.reject("桥接返回值不是合法 JSON");
    }
  } else {
    p.reject(payload);
  }
};

/** 是否运行在鸿蒙宿主（ArkTS 已通过 registerJavaScriptProxy 注入 window.hghub）。
 *  未注入时（CI 的 Playwright fixture、Tauri 桌面端）由 invoke() 回退到
 *  Tauri 的 __TAURI_INTERNALS__.invoke 通道，保证测试与桌面端不被别名劫持卡死。 */
export function hasHarmonyBridge(): boolean {
  return typeof window !== "undefined" &&
    !!(window as unknown as { hghub?: unknown }).hghub;
}

function native(): Record<string, (...args: any[]) => void> {
  const bridge = (window as unknown as { hghub?: Record<string, (...args: any[]) => void> }).hghub;
  if (!bridge) {
    throw "HarmonyOS 移植层未注入：window.hghub 不存在（检查 ArkTS 侧 registerJavaScriptProxy）";
  }
  return bridge;
}

const DEFAULT_BASE = "https://huangguoai.com";
const LS_TOKEN = "hghubx_hon_token";
const LS_USER = "hghubx_hon_user";

/* ── 线路（base） ─────────────────────────────────────── */

export function getBase(): string {
  return lineStateStore.get();
}

function ipv4ToInt(value: string): number | null {
  const parts = value.split(".");
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
  const [base, prefixText] = cidr.split("/");
  const valueInt = ipv4ToInt(value);
  const baseInt = ipv4ToInt(base);
  const prefix = Number(prefixText);
  if (valueInt === null || baseInt === null || !Number.isInteger(prefix) || prefix < 0 || prefix > 32) return false;
  const mask = prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0;
  return ((valueInt & mask) >>> 0) === ((baseInt & mask) >>> 0);
}

function isForbiddenIpv4(value: string): boolean {
  // 198.18.0.0/15 stays allowed: it is the documented FakeIP exception.
  const ranges = [
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
    "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24",
    "192.168.0.0/16", "198.51.100.0/24", "203.0.113.0/24",
    "224.0.0.0/4", "240.0.0.0/4",
  ];
  return ranges.some((cidr) => ipv4InCidr(value, cidr));
}

function ipv6Groups(value: string): number[] | null {
  let text = value.toLowerCase().split("%")[0];
  let head = text;
  let tail = "";
  let compressed = false;
  if (text.includes("::")) {
    const parts = text.split("::");
    if (parts.length !== 2) return null;
    compressed = true;
    head = parts[0];
    tail = parts[1];
  }
  const headGroups = head.length === 0 ? [] : head.split(":");
  const tailGroups = tail.length === 0 ? [] : tail.split(":");
  const missing = 8 - headGroups.length - tailGroups.length;
  if (missing < 0 || (!compressed && missing !== 0)) return null;
  const groups = [...headGroups, ...new Array(compressed ? missing : 0).fill("0"), ...tailGroups];
  const out: number[] = [];
  for (const group of groups) {
    if (!/^[0-9a-f]{1,4}$/.test(group)) return null;
    out.push(parseInt(group, 16));
  }
  return out;
}

function isForbiddenIpv6(value: string): boolean {
  const groups = ipv6Groups(value);
  if (groups === null) return true;
  if (groups.every((group) => group === 0)) return true; // ::
  if (groups[0] >= 0xfc00 && groups[0] <= 0xfdff) return true; // unique local
  if (groups[0] >= 0xfe80 && groups[0] <= 0xfebf) return true; // link local
  if (groups[0] >= 0xfec0 && groups[0] <= 0xfeef) return true; // deprecated site local
  if (groups[0] >= 0xff00) return true; // multicast
  if (groups[0] === 0x2001 && groups[1] === 0x0db8) return true; // documentation
  if (groups.slice(0, 5).every((group) => group === 0)) {
    const low = groups[6] * 65536 + groups[7];
    const ipv4 = `${Math.floor(low / 16777216) % 256}.${Math.floor(low / 65536) % 256}.${Math.floor(low / 256) % 256}.${low % 256}`;
    if (groups[5] === 0 || groups[5] === 0xffff) return isForbiddenIpv4(ipv4);
  }
  return false;
}

function isForbiddenHost(host: string): boolean {
  const value = host.trim().replace(/^\[/, "").replace(/\]$/, "").toLowerCase();
  if (value.length === 0) return true;
  if (/(^|\.)localhost$/.test(value) || /(^|\.)local$/.test(value) || /(^|\.)internal$/.test(value) || /(^|\.)home\.arpa$/.test(value)) return true;
  if (value.includes(":")) return isForbiddenIpv6(value);
  if (/^\d+\.\d+\.\d+\.\d+$/.test(value)) return isForbiddenIpv4(value);
  // A single-label HTTPS origin is not a usable public line.
  return !value.includes(".");
}

/** 纯 HTTPS 公网 origin 归一（不接受路径/查询/片段/凭据/内网目标） */
function normalizeBase(raw: string): string | null {
  const text = raw.trim();
  if (text.length === 0) return null;
  try {
    const parsed = new URL(text);
    if (parsed.protocol !== "https:") return null;
    if (parsed.pathname !== "/" || parsed.search !== "" || parsed.hash !== "") return null;
    if (parsed.username !== "" || parsed.password !== "") return null;
    if (isForbiddenHost(parsed.hostname)) return null;
    return parsed.origin;
  } catch {
    return null;
  }
}

/** 切线路前先清旧会话；即使后续写线路失败，也不会把旧 token 发到新 origin。 */
function applyBaseAndDropSession(url: string): void {
  const previous = getBase();
  if (previous !== url) setSession(null, null);
  setBase(url);
}

/** 线路代次：用户在探测期间手动切线路 → 旧结果作废 */
let lineGeneration = 0;

function setBase(url: string): string {
  lineStateStore.set(url);
  try {
    native().setBase(url);
  } catch {
    /* 启动早期桥可能还没注入，忽略即可 */
  }
  syncSourceAuthToken();
  return url;
}

/* ── 二进制 / base64 ─────────────────────────────────── */

function bytesToB64(bytes: Uint8Array): string {
  let bin = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    bin += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(bin);
}

function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/* ── 原生 HTTP ───────────────────────────────────────── */

interface NativeResponse {
  status: number;
  bytes: Uint8Array;
}

/** 调 ArkTS 桥的任意方法：统一 { id, resolve, reject } 约定 */
function nativeInvoke(method: string, ...args: Json[]): Promise<Json> {
  const bridge = native();
  return new Promise<Json>((resolve, reject) => {
    const id = `c${++seq}`;
    const timer = setTimeout(() => {
      if (pending.delete(id)) reject("桥接超时");
    }, 20000) as unknown as number;
    pending.set(id, { resolve, reject, timer });
    (bridge[method] as (...list: Json[]) => void)(id, ...args);
  });
}

function nativeHttp(
  url: string,
  method: string,
  headers: Record<string, string>,
  body = "",
  timeoutMs = 30000,
): Promise<NativeResponse> {
  const bridge = native();
  return new Promise<NativeResponse>((resolve, reject) => {
    const id = `n${++seq}`;
    // ArkTS 侧按 timeoutMs 断流；这里再放一层兜底，避免 Promise 永远挂着
    const timer = setTimeout(() => {
      if (pending.delete(id)) reject("请求超时");
    }, timeoutMs + 10000) as unknown as number;
    pending.set(id, {
      resolve: (value: Json) => resolve({ status: Number(value.status), bytes: b64ToBytes(String(value.b64)) }),
      reject,
      timer,
    });
    bridge.http(id, url, method, JSON.stringify(headers), body, timeoutMs);
  });
}

/* ── 信封 ────────────────────────────────────────────── */

type Method = "GET" | "POST" | "DELETE" | "PUT";

/* ── dx150-edge-v1 加密网关 ─────────────────────────────
 * 与 src-tauri/src/edge_crypto.rs 对齐：
 * ECDH P-256 + HKDF-SHA256 + AES-256-GCM。
 * ArkWeb 的 WebCrypto 在 http://127.0.0.1 下视为安全上下文，可直接使用。
 */

const EDGE_PROTOCOL = "dx150-edge-v1";
const EDGE_MAX_SEQUENCE = 16384;
type EdgeScope = "Public" | "Dynamic" | "Playback" | "User";

interface EdgeSession {
  info: string;
  kid: string;
  sid: string;
  clockOffset: number;
  expiresAt: number;
  sequence: number;
  reqKey: CryptoKey;
  resKey: CryptoKey;
}

interface EdgeHttpReply {
  status: number;
  ctype: string;
  gateway: string;
  publicJson: boolean;
  text: string;
}

class EdgeLegacyFallback extends Error {}

const edgeSessions = new Map<string, Promise<EdgeSession>>();

function edgeSubtle(): SubtleCrypto {
  const subtle = globalThis.crypto?.subtle;
  if (!subtle) throw "当前 WebView 不支持 WebCrypto，无法使用加密接口网关";
  return subtle;
}

function edgeEndpoint(scope: EdgeScope): string {
  if (scope === "Public") return "/api/public/request";
  if (scope === "Dynamic") return "/api/dynamic/request";
  if (scope === "Playback") return "/api/playback/request";
  return "/api/user/request";
}

function edgeScopeName(scope: EdgeScope): string {
  return scope.toLowerCase();
}

function edgeIsDigits(value: string): boolean {
  return value.length > 0 && /^\d+$/.test(value);
}

function edgeHasRandomSort(query: string): boolean {
  return Array.from(new URLSearchParams(query).entries()).some(([key, value]) => {
    const sort = value.trim().toLowerCase();
    return key === "sort" && (sort === "random" || sort === "rand");
  });
}

function edgeScopeFor(method: string, pathWithQuery: string): EdgeScope {
  const normalizedMethod = method.toUpperCase() === "HEAD" ? "GET" : method.toUpperCase();
  const [pathname, query] = pathWithQuery.split("?") as [string, string?];
  const segments = pathname.split("/").filter((segment: string) => segment.length > 0);

  const playbackMatches: boolean =
    (segments.length === 6 && segments[0] === "api" && segments[1] === "videos" && segments[3] === "episodes" && segments[5] === "playback" && normalizedMethod === "POST" && edgeIsDigits(segments[2]) && edgeIsDigits(segments[4]))
    || (segments.length === 4 && segments[0] === "api" && segments[1] === "videos" && segments[3] === "playback" && normalizedMethod === "POST" && edgeIsDigits(segments[2]))
    || (segments.length === 4 && segments[0] === "api" && segments[1] === "videos" && segments[3] === "play" && normalizedMethod === "GET" && edgeIsDigits(segments[2]))
    || (segments.length === 4 && segments[0] === "api" && segments[1] === "posts" && segments[3] === "playback" && normalizedMethod === "POST" && edgeIsDigits(segments[2]))
    || (segments.length === 4 && segments[0] === "api" && segments[1] === "media" && segments[2] === "playback" && segments[3] === "previews" && normalizedMethod === "POST")
    || (segments.length === 5 && segments[0] === "api" && segments[1] === "media" && segments[2] === "prerolls" && segments[4] === "playback" && normalizedMethod === "POST" && edgeIsDigits(segments[3]));
  if (playbackMatches) return "Playback";

  const userMatches: boolean =
    (segments.length >= 2 && segments[0] === "api" && segments[1] === "account")
    || (segments.length >= 3 && segments[0] === "api" && segments[1] === "users" && segments[2] === "me")
    || (segments.length === 3 && segments[0] === "api" && segments[1] === "videos" && segments[2] === "following" && normalizedMethod === "GET")
    || (segments.length === 2 && segments[0] === "api" && segments[1] === "ai-wish" && normalizedMethod === "POST")
    || (segments.length === 4 && segments[0] === "api" && segments[1] === "users" && segments[3] === "follow" && edgeIsDigits(segments[2]))
    || (segments.length === 4 && segments[0] === "api" && segments[1] === "videos" && edgeIsDigits(segments[2]) && ["like", "collect", "feedback", "rating", "report", "interaction-state"].includes(segments[3]))
    || (segments.length === 4 && segments[0] === "api" && segments[1] === "videos" && segments[3] === "comments" && normalizedMethod === "POST" && edgeIsDigits(segments[2]))
    || (segments.length === 5 && segments[0] === "api" && segments[1] === "videos" && segments[3] === "comments" && ["liked", "state"].includes(segments[4]) && edgeIsDigits(segments[2]))
    || (segments.length === 5 && segments[0] === "api" && segments[1] === "videos" && segments[3] === "comments" && ["like", "guest-like"].includes(segments[4]) && edgeIsDigits(segments[2]) && edgeIsDigits(segments[4]))
    || (segments.length === 4 && segments[0] === "api" && segments[1] === "videos" && edgeIsDigits(segments[2]) && ["guest-comments", "guest-like", "guest-liked"].includes(segments[3]))
    || (segments.length === 4 && segments[0] === "api" && segments[1] === "posts" && edgeIsDigits(segments[2]) && ["like", "collect", "visit", "guest-comments", "guest-like", "guest-liked"].includes(segments[3]))
    || (segments.length === 4 && segments[0] === "api" && segments[1] === "posts" && segments[3] === "comments" && normalizedMethod === "POST" && edgeIsDigits(segments[2]))
    || (segments.length === 5 && segments[0] === "api" && segments[1] === "posts" && segments[3] === "comments" && segments[4] === "liked" && edgeIsDigits(segments[2]))
    || (segments.length === 5 && segments[0] === "api" && segments[1] === "posts" && segments[3] === "comments" && ["like", "guest-like"].includes(segments[4]) && edgeIsDigits(segments[2]) && edgeIsDigits(segments[4]));
  if (userMatches) return "User";

  if (normalizedMethod === "GET") {
    const two = segments.length === 2 ? segments[1] : "";
    const three = segments.length === 3 ? segments[2] : "";
    const four = segments.length === 4 ? segments[3] : "";
    const publicMatches: boolean =
      (segments.length === 2 && segments[0] === "api" && ["videos", "topics", "tags", "posts"].includes(segments[1]))
      || (segments.length === 3 && segments[0] === "api" && segments[1] === "videos" && ["long", "report-reasons"].includes(segments[2]))
      || (segments.length === 3 && segments[0] === "api" && segments[1] === "feed" && ["post", "today"].includes(segments[2]))
      || (segments.length === 3 && segments[0] === "api" && segments[1] === "home" && ["latest", "recommends"].includes(segments[2]))
      || (segments.length === 3 && segments[0] === "api" && segments[1] === "search" && ["hot", "suggest"].includes(segments[2]))
      || (segments.length === 3 && segments[0] === "api" && segments[1] === "site" && ["categories", "sorts", "config", "links", "menus", "meta", "pages", "transit", "watermark"].includes(segments[2]))
      || (segments.length === 3 && segments[0] === "api" && ["videos", "posts"].includes(segments[1]) && ["category", "tag"].includes(three))
      || (segments.length === 3 && segments[0] === "api" && segments[1] === "ranks")
      || (segments.length === 3 && segments[0] === "api" && segments[1] === "topics")
      || (segments.length === 4 && segments[0] === "api" && segments[1] === "site" && ["pages"].includes(segments[2]))
      || (segments.length === 4 && segments[0] === "api" && segments[1] === "videos" && segments[2] === "user" && edgeIsDigits(four))
      || (segments.length === 4 && segments[0] === "api" && segments[1] === "videos" && segments[3] === "related" && edgeIsDigits(three))
      || (segments.length === 4 && segments[0] === "api" && segments[1] === "posts" && segments[2] === "user" && edgeIsDigits(four))
      || (segments.length === 4 && segments[0] === "api" && segments[1] === "posts" && ["adjacent", "related"].includes(segments[3]) && edgeIsDigits(three))
      || (segments.length === 4 && segments[0] === "api" && segments[1] === "users" && segments[3] === "stats" && edgeIsDigits(three))
      || (segments.length === 4 && segments[0] === "api" && segments[1] === "search" && segments[2] === "tags" && segments[3] === "hot");
    if (publicMatches) return edgeHasRandomSort(query ?? "") ? "Dynamic" : "Public";
  }
  return "Dynamic";
}

function edgeSortPublicPath(pathWithQuery: string): string {
  const parts = pathWithQuery.split("?");
  if (parts.length !== 2 || parts[1].length === 0) return pathWithQuery;
  const params = new URLSearchParams(parts[1]);
  params.sort();
  const sorted = params.toString();
  return sorted.length > 0 ? `${parts[0]}?${sorted}` : parts[0];
}

function edgeValidId(value: string): boolean {
  return value.length >= 1 && value.length <= 64 && /^[A-Za-z0-9_-]+$/.test(value);
}

function edgeValidSid(value: string): boolean {
  return value.length >= 16 && value.length <= 128 && /^[A-Za-z0-9_-]+$/.test(value);
}

function edgeValidSite(value: string): boolean {
  return value.length >= 1 && value.length <= 256 && /^[A-Za-z0-9.:\[\]-]+$/.test(value);
}

function edgeBuffer(bytes: Uint8Array): ArrayBuffer {
  const out = new Uint8Array(bytes.byteLength);
  out.set(bytes);
  return out.buffer as ArrayBuffer;
}

function edgeBase64UrlEncode(bytes: Uint8Array): string {
  return bytesToB64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function edgeBase64UrlDecode(value: string): Uint8Array {
  let normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  while (normalized.length % 4 !== 0) normalized += "=";
  return b64ToBytes(normalized);
}

function edgeNonce(sequence: number): Uint8Array {
  const iv = new Uint8Array(12);
  new DataView(iv.buffer).setUint32(8, sequence, false);
  return iv;
}

function edgeAad(info: string, direction: "req" | "res", sequence: number, ts: number): Uint8Array {
  return encoder.encode(`${info}\n${direction}\n${sequence}\n${ts}`);
}

async function edgeDeriveKey(prk: CryptoKey, salt: Uint8Array, info: string, direction: "req" | "res"): Promise<CryptoKey> {
  const subtle = edgeSubtle();
  const bits = await subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: edgeBuffer(salt), info: edgeBuffer(encoder.encode(`${info}\n${direction}`)) },
    prk,
    256,
  );
  return subtle.importKey("raw", bits, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

async function edgeOpenSession(origin: string, scope: EdgeScope, timeoutMs: number): Promise<EdgeSession> {
  const subtle = edgeSubtle();
  const pair = await subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  const clientPub = new Uint8Array(await subtle.exportKey("raw", pair.publicKey));
  const hello = { v: 1, type: "hello", client_pub: edgeBase64UrlEncode(clientPub) };
  const url = `${origin}${edgeEndpoint(scope)}`;
  const reply = await edgePostJson(
    url,
    `${origin}/`,
    hello,
    null,
    false,
    timeoutMs,
  );
  if (reply.status === 404 || reply.status === 405) throw new EdgeLegacyFallback("scope not migrated");
  if (reply.status < 200 || reply.status >= 300) throw new Error(`加密握手返回 HTTP ${reply.status}`);

  let helloData: Record<string, Json>;
  try {
    helloData = JSON.parse(reply.text) as Record<string, Json>;
  } catch {
    throw new Error("加密握手响应格式无效");
  }
  const kid = String(helloData.kid ?? "");
  const sid = String(helloData.sid ?? "");
  const site = String(helloData.site ?? "");
  const serverPubB64 = String(helloData.server_pub ?? "");
  const saltB64 = String(helloData.salt ?? "");
  const serverTime = Number(helloData.server_time ?? 0);
  const expiresAt = Number(helloData.expires_at ?? 0);
  if (
    Number(helloData.v) !== 1 || helloData.type !== "hello" || !edgeValidId(kid) || !edgeValidSid(sid)
    || !edgeValidSite(site) || !Number.isSafeInteger(serverTime) || !Number.isSafeInteger(expiresAt)
    || expiresAt <= serverTime || expiresAt - serverTime > 600
  ) throw new Error("加密握手响应参数无效");

  const serverPub = edgeBase64UrlDecode(serverPubB64);
  const salt = edgeBase64UrlDecode(saltB64);
  if (serverPub.byteLength !== 65 || salt.byteLength !== 32) throw new Error("加密握手公钥或盐值无效");
  const shared = new Uint8Array(await subtle.deriveBits(
    { name: "ECDH", public: await subtle.importKey("raw", edgeBuffer(serverPub), { name: "ECDH", namedCurve: "P-256" }, false, []) },
    pair.privateKey,
    256,
  ));
  const prk = await subtle.importKey("raw", edgeBuffer(shared), "HKDF", false, ["deriveBits"]);
  const info = `${EDGE_PROTOCOL}\n${edgeScopeName(scope)}\n${site}\n${kid}\n${sid}`;
  const reqKey = await edgeDeriveKey(prk, salt, info, "req");
  const resKey = await edgeDeriveKey(prk, salt, info, "res");
  const localTime = Math.floor(Date.now() / 1000);
  return {
    info,
    kid,
    sid,
    clockOffset: serverTime - localTime,
    expiresAt: localTime + (expiresAt - serverTime),
    sequence: 0,
    reqKey,
    resKey,
  };
}

async function edgeSession(origin: string, scope: EdgeScope, timeoutMs: number): Promise<EdgeSession> {
  const key = `${origin}\n${scope}`;
  const existing = edgeSessions.get(key);
  if (existing) {
    try {
      const session = await existing;
      if (session.expiresAt > Math.floor(Date.now() / 1000) + 5 && session.sequence < EDGE_MAX_SEQUENCE) return session;
    } catch {
      /* fallthrough: rebuild below */
    }
  }
  const pending = edgeOpenSession(origin, scope, timeoutMs);
  edgeSessions.set(key, pending);
  try {
    return await pending;
  } finally {
    if (edgeSessions.get(key) === pending) edgeSessions.delete(key);
  }
}

async function edgeEncrypt(session: EdgeSession, scope: EdgeScope, envelope: Json, token: string | null): Promise<Json> {
  session.sequence += 1;
  if (session.sequence > EDGE_MAX_SEQUENCE) throw new Error("session_expired");
  const ts = Math.floor(Date.now() / 1000) + session.clockOffset;
  const packet: Record<string, Json> = { request: envelope };
  if (scope !== "Public" && token !== null && token.length > 0) packet.authorization = `Bearer ${token}`;
  const subtle = edgeSubtle();
  const plain = encoder.encode(JSON.stringify(packet));
  const aad = edgeAad(session.info, "req", session.sequence, ts);
  const cipher = new Uint8Array(await subtle.encrypt(
    { name: "AES-GCM", iv: edgeBuffer(edgeNonce(session.sequence)), additionalData: edgeBuffer(aad), tagLength: 128 },
    session.reqKey,
    edgeBuffer(plain),
  ));
  return {
    v: 1,
    type: "call",
    kid: session.kid,
    sid: session.sid,
    seq: session.sequence,
    ts,
    ciphertext: edgeBase64UrlEncode(cipher),
  };
}

async function edgeDecrypt(session: EdgeSession, method: string, sequence: number, ts: number, text: string): Promise<EdgeHttpReply> {
  let envelope: Record<string, Json>;
  try {
    envelope = JSON.parse(text) as Record<string, Json>;
  } catch {
    throw new Error("加密接口响应格式无效");
  }
  if (
    Number(envelope.v) !== 1 || envelope.type !== "result" || String(envelope.kid ?? "") !== session.kid
    || String(envelope.sid ?? "") !== session.sid || Number(envelope.seq) !== sequence || Number(envelope.ts) !== ts
  ) throw new Error("加密接口响应不匹配");
  const cipher = edgeBase64UrlDecode(String(envelope.ciphertext ?? ""));
  const subtle = edgeSubtle();
  const plainBuffer = await subtle.decrypt(
    { name: "AES-GCM", iv: edgeBuffer(edgeNonce(sequence)), additionalData: edgeBuffer(edgeAad(session.info, "res", sequence, ts)), tagLength: 128 },
    session.resKey,
    edgeBuffer(cipher),
  );
  let inner: { status?: Json; headers?: Record<string, Json>; body?: Json };
  try {
    inner = JSON.parse(new TextDecoder().decode(edgeBuffer(new Uint8Array(plainBuffer)))) as { status?: Json; headers?: Record<string, Json>; body?: Json };
  } catch {
    throw new Error("加密接口内层响应无效");
  }
  const status = Number(inner.status ?? 0);
  if (status < 200 || status > 599) throw new Error("加密接口内层状态码无效");
  let contentType = "";
  const headers = inner.headers;
  if (headers && typeof headers === "object") {
    for (const [key, values] of Object.entries(headers)) {
      if (key.toLowerCase() === "content-type" && Array.isArray(values) && values.length > 0) {
        contentType = String(values[0]);
        break;
      }
    }
  }
  const bodyB64 = String(inner.body ?? "");
  const body = method.toUpperCase() === "HEAD" || status === 204 || status === 205 || status === 304 || bodyB64.length === 0
    ? ""
    : new TextDecoder().decode(b64ToBytes(bodyB64));
  return { status, ctype: contentType, gateway: "dx150-edge-v1", publicJson: false, text: body };
}

async function edgePostJson(
  url: string,
  referer: string,
  payload: Json,
  token: string | null,
  publicJson: boolean,
  timeoutMs: number,
): Promise<EdgeHttpReply> {
  const headers: Record<string, string> = { Accept: "application/json", "Content-Type": "application/json", Referer: referer };
  if (publicJson) headers["X-HG-Public-JSON"] = "1";
  if (token !== null && token.length > 0) headers.Authorization = `Bearer ${token}`;
  const resp = await nativeHttp(url, "POST", headers, JSON.stringify(payload), timeoutMs);
  return {
    status: resp.status,
    ctype: "",
    gateway: "other",
    publicJson: false,
    text: decoder.decode(resp.bytes),
  };
}

function edgeSessionExpired(text: string): boolean {
  try {
    const value = JSON.parse(text) as { error?: Json };
    return value.error === "session_expired";
  } catch {
    return false;
  }
}

function edgeFallbackToCrypto(status: number, text: string): boolean {
  if (status !== 400) return false;
  try {
    const value = JSON.parse(text) as { error?: Json };
    return ["invalid_request", "unsupported_version"].includes(String(value.error ?? ""));
  } catch {
    return false;
  }
}

async function edgeCallEncrypted(
  origin: string,
  scope: EdgeScope,
  method: string,
  envelope: Json,
  token: string | null,
  timeoutMs: number,
): Promise<EdgeHttpReply> {
  for (let retry = 0; retry < 2; retry++) {
    const session = await edgeSession(origin, scope, timeoutMs);
    let payload: Json;
    try {
      payload = await edgeEncrypt(session, scope, envelope, token);
    } catch (e) {
      if (e instanceof Error && e.message === "session_expired" && retry === 0) continue;
      throw e;
    }
    const reply = await edgePostJson(`${origin}${edgeEndpoint(scope)}`, `${origin}/`, payload, null, false, timeoutMs);
    if (reply.status === 404 || reply.status === 405) throw new EdgeLegacyFallback("scope not migrated");
    if (reply.status < 200 || reply.status >= 300) {
      if (edgeSessionExpired(reply.text) && retry === 0) continue;
      throw new Error(`加密网关返回 HTTP ${reply.status}`);
    }
    return await edgeDecrypt(session, method, Number(payload.seq), Number(payload.ts), reply.text);
  }
  throw new Error("加密会话重建失败");
}

async function edgeRequest(
  origin: string,
  method: string,
  path: string,
  envelope: Json,
  token: string | null,
  timeoutMs: number,
): Promise<EdgeHttpReply> {
  const scope = edgeScopeFor(method, path);
  const scopeUrl = `${origin}${edgeEndpoint(scope)}`;
  const legacyUrl = `${origin}/api/edge/request`;
  const referer = `${origin}/`;
  if (scope === "Public") {
    const publicEnvelope: Json = {
      method,
      path: edgeSortPublicPath(path),
      body: envelope.body,
      content_type: envelope.content_type,
    };
    try {
      const reply = await edgePostJson(scopeUrl, referer, publicEnvelope, null, true, timeoutMs);
      if (reply.status === 404 || reply.status === 405) throw new EdgeLegacyFallback("scope not migrated");
      if (reply.status >= 200 && reply.status < 300 || !edgeFallbackToCrypto(reply.status, reply.text)) return reply;
    } catch (e) {
      if (!(e instanceof EdgeLegacyFallback)) throw e;
    }
  }
  try {
    return await edgeCallEncrypted(origin, scope, method, envelope, token, timeoutMs);
  } catch (e) {
    if (!(e instanceof EdgeLegacyFallback)) throw e;
  }
  return edgePostJson(legacyUrl, referer, envelope, token, false, timeoutMs);
}

async function edge(method: Method, path: string, body: Json = null, auth = true): Promise<Json> {
  return edgeOn(getBase(), method, path, body, auth ? getToken() : null);
}

/** 指定线路/凭据/超时的信封请求；线路探测（无凭据）也走这里。 */
async function edgeOn(
  base: string,
  method: Method,
  path: string,
  body: Json = null,
  token: string | null = null,
  timeoutMs = 30000,
): Promise<Json> {
  const envelope = {
    method,
    path,
    body: body === null ? "" : bytesToB64(encoder.encode(JSON.stringify(body))),
    content_type: body === null ? "" : "application/json",
  };
  const headers: Record<string, string> = { Accept: "application/json", Referer: `${base}/` };
  if (token) headers["Authorization"] = `Bearer ${token}`;

  const resp = await edgeRequest(base, method, path, envelope, token, timeoutMs);
  if (resp.status === 401 || resp.status === 403) throw "401";
  const text = resp.text;
  if (resp.status < 200 || resp.status >= 300) {
    throw `HTTP ${resp.status}: ${text.slice(0, 160)}`;
  }
  if (!text.trim()) return null;
  let value: Json;
  try {
    value = JSON.parse(text);
  } catch {
    throw `${text.slice(0, 160)}`;
  }
  if (value === null) return null;
  if (value.status === 1) return value.data ?? null;
  const msg = typeof value.msg === "string" && value.msg.length > 0 ? value.msg : "接口返回失败";
  throw msg;
}

/* ── 会话 ────────────────────────────────────────────── */

function getToken(): string | null {
  return localStorage.getItem(LS_TOKEN);
}

function getUser(): Json {
  const raw = localStorage.getItem(LS_USER);
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function setSession(token: string | null, user: Json): void {
  if (token === null) {
    localStorage.removeItem(LS_TOKEN);
    localStorage.removeItem(LS_USER);
  } else {
    localStorage.setItem(LS_TOKEN, token);
    if (user === null || user === undefined) localStorage.removeItem(LS_USER);
    else localStorage.setItem(LS_USER, JSON.stringify(user));
  }
  syncSourceAuthToken();
}

/**
 * 把当前会话 token 推给原生（host.auth 用），登录 / 退出 / 切线路时都会走到。
 * 自定义线路（用户手输域名，不可信）推空串——对齐 RFC 0001
 * 「未登录或不可信线路时为 null」。token 不落日志。
 */
function syncSourceAuthToken(): void {
  try {
    const token = lineStateStore.isCustom() ? "" : (getToken() ?? "");
    native().sourceSetAuthToken(token);
  } catch {
    /* 桥未注入或非鸿蒙宿主时忽略 */
  }
}

/* ── 工具 ────────────────────────────────────────────── */

const enc = (s: string) => encodeURIComponent(s);
const sortSuffix = (sort?: string | null) => (sort && sort.trim() ? `&sort=${enc(sort)}` : "");

function normalizePlayInfo(info: Json): Json {
  if (!info || typeof info !== "object") return info;
  const streams = info.streams;
  if (streams) {
    for (const [field, key] of [
      ["video_url", "main"],
      ["video_url_hevc", "hevc"],
    ] as const) {
      const url = streams[key];
      if (typeof url === "string" && url.trim() && !(typeof info[field] === "string" && info[field].trim())) {
        info[field] = url;
      }
    }
  }
  return info;
}

const hasPlayUrl = (info: Json) => typeof info?.video_url === "string" && info.video_url.trim().length > 0;

/* ── 热搜榜（对应 src-tauri/src/search_hot.rs）───────── */

const JS_MAX_SAFE_INTEGER = 9007199254740991;
const MAX_HOT_ITEMS = 20;
const MAX_HOT_HTML_BYTES = 2 * 1024 * 1024;
let hotSeq = 0;

const normText = (value: string | null | undefined) => (value ?? "").replace(/\s+/g, " ").trim();

/** 只接受站内 /video/<id>/ 形式；绝对值、外域、0、超安全整数一律拒绝 */
function videoIdFromHref(href: string): number | null {
  const m = /^\/video\/(\d+)\/$/.exec(href);
  if (!m) return null;
  const id = Number(m[1]);
  if (!Number.isSafeInteger(id) || id <= 0 || id > JS_MAX_SAFE_INTEGER) return null;
  return id;
}

async function fetchSearchHotHtml(): Promise<string> {
  const base = getBase();
  const url = `${base}/search/?_hghubx_hot=${Date.now()}-${hotSeq++}`;
  const resp = await nativeHttp(url, "GET", {
    Referer: `${base}/`,
    Accept: "text/html,application/xhtml+xml",
  });
  if (resp.status < 200 || resp.status >= 300) {
    throw `官网搜索页请求失败（HTTP ${resp.status}）`;
  }
  if (resp.bytes.byteLength > MAX_HOT_HTML_BYTES) {
    throw "官网搜索页超过 2 MiB 限制";
  }
  return decoder.decode(resp.bytes);
}

/** 与 Rust 版对齐：section.hg-search-hot → a.hg-search-hot__item，按 video_id 去重 */
export function parseSearchHot(html: string): { video_id: number; title: string; plays: string }[] {
  const doc = new DOMParser().parseFromString(html, "text/html");
  const sections = doc.querySelectorAll("section.hg-search-hot");
  if (sections.length === 0) {
    throw "官网搜索页没有找到热搜榜区域";
  }
  const seen = new Set<number>();
  const items: { video_id: number; title: string; plays: string }[] = [];
  for (const section of Array.from(sections)) {
    const anchors = Array.from(section.querySelectorAll("a.hg-search-hot__item"));
    for (const anchor of anchors) {
      const id = videoIdFromHref(anchor.getAttribute("href") ?? "");
      if (id === null || seen.has(id)) continue;
      let title = normText(anchor.querySelector(".hg-search-hot__name")?.textContent);
      if (!title) title = normText(anchor.getAttribute("data-search-hot"));
      const plays = normText(anchor.querySelector(".hg-search-hot__plays")?.textContent);
      if (!title || !plays) continue;
      seen.add(id);
      items.push({ video_id: id, title, plays });
      if (items.length === MAX_HOT_ITEMS) return items;
    }
  }
  if (items.length === 0) {
    throw "官网热搜榜没有可用条目";
  }
  return items;
}

/* ── 官网 SSR 频道/吃瓜页（对应 src-tauri/src/channel_page.rs）─ */

const MAX_CHANNEL_HTML_BYTES = 2 * 1024 * 1024;
const DEFAULT_SSR_PAGE_SIZE = 39;
const DEFAULT_LIST_SSR_PAGE_SIZE = 28;
const DEFAULT_GOSSIP_SSR_PAGE_SIZE = 12;
const PREVIEW_TRUNCATE_LIMIT = 20;

type SsrPaged = { items: Json[]; pagination: { page: number; pages: number; size: number; total: number } };

async function fetchSiteHtml(path: string): Promise<string> {
  const base = getBase();
  const resp = await nativeHttp(`${base}${path}`, "GET", {
    Accept: "text/html,application/xhtml+xml",
    Referer: `${base}/`,
  }, "", 12000);
  if (resp.status < 200 || resp.status >= 300) {
    throw `官网页面请求失败（HTTP ${resp.status}）`;
  }
  if (resp.bytes.byteLength > MAX_CHANNEL_HTML_BYTES) {
    throw "官网页面超过 2 MiB 限制";
  }
  return decoder.decode(resp.bytes);
}

function ssrText(element: Element | null | undefined): string {
  return normText(element?.textContent);
}

function ssrAttr(element: Element | null | undefined, name: string): string {
  return (element?.getAttribute(name) ?? "").trim();
}

function ssrPositiveInt(value: string | null | undefined): number {
  const parsed = Number((value ?? "").trim());
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : 0;
}

function ssrIdFromValue(raw: string | null | undefined): number | null {
  const value = (raw ?? "").trim();
  if (!/^\d+$/.test(value)) return null;
  const id = Number(value);
  return Number.isSafeInteger(id) && id > 0 && id <= JS_MAX_SAFE_INTEGER ? id : null;
}

function ssrVideoIdFromHref(href: string): number | null {
  const match = /^\/video\/(\d+)\/$/.exec(href.trim());
  return match === null ? null : ssrIdFromValue(match[1]);
}

function ssrPostIdFromHref(href: string): number | null {
  let path = href.trim();
  const absolute = /^https?:\/\/[^/]+(.*)$/.exec(path);
  if (absolute !== null) path = absolute[1];
  path = path.split("?")[0].split("#")[0];
  const match = /^\/archives\/(\d+)\/$/.exec(path);
  return match === null ? null : ssrIdFromValue(match[1]);
}

function ssrScore(raw: string): number {
  const parsed = Number(raw.trim().replace(/分$/, "").trim());
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
}

function ssrFirstUint(raw: string): number {
  const match = /\d+/.exec(raw);
  return match === null ? 0 : Number(match[0]);
}

function ssrEpisode(raw: string): { isFinished: boolean; episodeCount: number; totalEpisodes: number } {
  const text = normText(raw);
  if (!text) return { isFinished: false, episodeCount: 0, totalEpisodes: 0 };
  const isFinished = text.includes("全") || text.includes("完结");
  const rest = text.includes("更新至") ? text.split("更新至")[1] : text.includes("全") ? text.split("全")[1] : text;
  const episodeCount = ssrFirstUint(rest ?? "");
  return { isFinished, episodeCount, totalEpisodes: isFinished ? episodeCount : 0 };
}

function ssrViews(raw: string): number {
  const text = raw.trim().replace(/,/g, "");
  if (!text) return 0;
  let multiplier = 1;
  let numeric = text.toLowerCase();
  if (numeric.endsWith("k") || text.endsWith("千")) { multiplier = 1000; numeric = numeric.slice(0, -1); }
  else if (numeric.endsWith("w") || text.endsWith("万")) { multiplier = 10000; numeric = numeric.slice(0, -1); }
  else if (text.endsWith("亿")) { multiplier = 100000000; numeric = numeric.slice(0, -1); }
  const match = /^\d+(?:\.\d+)?/.exec(numeric);
  if (match === null) return 0;
  return Math.round(Number(match[0]) * multiplier);
}

function ssrCountAfterPrefix(raw: string, prefix: string): number {
  const after = raw.includes(prefix) ? raw.split(prefix).slice(1).join(prefix) : raw;
  const digits = (after.match(/\d+/g) ?? []).join("");
  return digits.length > 0 ? Number(digits) : 0;
}

function ssrCover(card: Element): string {
  const img = card.querySelector(".hg-drama-card__cover img");
  for (const name of ["data-src", "src"]) {
    const value = ssrAttr(img, name);
    if (value.length > 0 && !value.includes("cover-placeholder")) return value;
  }
  return "";
}

function ssrDramaCard(card: Element): { id: number; title: string } | null {
  const id = ssrIdFromValue(ssrAttr(card, "data-track-id"))
    ?? ssrVideoIdFromHref(ssrAttr(card.querySelector(".hg-drama-card__cover-link"), "href"))
    ?? ssrVideoIdFromHref(ssrAttr(card.querySelector(".hg-drama-card__title a"), "href"));
  if (id === null) return null;
  let title = ssrText(card.querySelector(".hg-drama-card__title"));
  if (!title) title = normText(ssrAttr(card, "data-track-title"));
  return title.length > 0 ? { id, title } : null;
}

function ssrParseDramaGrid(
  scope: Element,
  grid: Element,
  page: number,
  requestedSize: number,
  totalHint: number,
  defaultPageSize: number,
  emptyError: string,
): SsrPaged {
  const safePage = Math.max(1, page);
  const seen = new Set<number>();
  const items: Json[] = [];
  for (const card of Array.from(grid.querySelectorAll(".hg-drama-card"))) {
    const identity = ssrDramaCard(card);
    if (identity === null || seen.has(identity.id)) continue;
    seen.add(identity.id);
    const episode = ssrEpisode(ssrText(card.querySelector(".hg-drama-card__episode")));
    const tags: string[] = [];
    const seenTags = new Set<string>();
    for (const tag of Array.from(card.querySelectorAll(".hg-drama-card__tags .hg-tag"))) {
      const name = ssrText(tag);
      if (name.length > 0 && !seenTags.has(name)) {
        seenTags.add(name);
        tags.push(name);
      }
    }
    let isOriginal = 0;
    let isHot = 0;
    let newAt: number | null = null;
    for (const badge of Array.from(card.querySelectorAll(".hg-drama-card__badges .hg-drama-card__badge"))) {
      const className = ssrAttr(badge, "class");
      const text = ssrText(badge);
      if (text === "原创") isOriginal = 1;
      else if (className.includes("hg-drama-card__badge--hot") || text === "热播") isHot = 1;
      else if (className.includes("hg-drama-card__badge--new") || text === "新片") {
        const parsed = ssrPositiveInt(ssrAttr(badge, "data-new-at"));
        newAt = parsed > 0 ? parsed : 1;
      }
    }
    items.push({
      id: identity.id,
      title: identity.title,
      cover: ssrCover(card),
      tags,
      score: ssrScore(ssrText(card.querySelector(".hg-drama-card__score"))),
      episode_count: episode.episodeCount,
      total_episodes: episode.totalEpisodes,
      hot: ssrViews(ssrText(card.querySelector(".hg-drama-card__views"))),
      like_count: 0,
      collect_count: 0,
      comment_count: 0,
      is_finished: episode.isFinished,
      is_original: isOriginal,
      is_hot: isHot,
      new_at: newAt,
    });
  }
  if (items.length === 0) throw emptyError;
  const fullPageSize = items.length;
  let pages = ssrPositiveInt(ssrAttr(scope.querySelector(".hg-pager__jump, [data-hg-pager-jump]"), "data-pages"));
  if (pages === 0) {
    for (const link of Array.from(scope.querySelectorAll(".hg-pager a.hg-pager__page, .hg-pager span.hg-pager__page"))) {
      pages = Math.max(pages, ssrPositiveInt(ssrText(link)));
    }
  }
  const total = Math.max(totalHint, items.length);
  if (pages === 0) {
    const perPage = Math.max(fullPageSize, defaultPageSize);
    pages = Math.max(Math.ceil(total / perPage), safePage);
  }
  if (safePage === 1 && requestedSize > 0 && requestedSize < PREVIEW_TRUNCATE_LIMIT) {
    items.length = Math.min(items.length, requestedSize);
  }
  return { items, pagination: { page: safePage, pages: Math.max(pages, safePage), size: items.length, total } };
}

function ssrParseChannelHtml(html: string, panel: string, page: number, requestedSize: number): SsrPaged {
  const doc = new DOMParser().parseFromString(html, "text/html");
  const section = doc.querySelector("section.hg-channel-page");
  if (section === null) throw "官网频道页缺少频道主体区域";
  const grid = section.querySelector(`.hg-card-grid[data-channel-panel="${panel}"]`);
  if (grid === null) throw `官网频道页缺少 ${panel} 面板`;
  if (grid.hasAttribute("hidden")) throw `官网频道页 ${panel} 面板处于隐藏状态`;
  const totalHint = ssrPositiveInt(ssrAttr(grid, "data-panel-total"));
  return ssrParseDramaGrid(section, grid, page, requestedSize, totalHint, DEFAULT_SSR_PAGE_SIZE, `官网频道页 ${panel} 面板没有可用条目`);
}

function ssrParseListPageHtml(html: string, page: number, requestedSize: number): SsrPaged {
  const doc = new DOMParser().parseFromString(html, "text/html");
  const section = doc.querySelector("section.hg-list-page");
  if (section === null) throw "官网列表页缺少主体区域";
  const grid = section.querySelector(".hg-card-grid");
  if (grid === null) throw "官网列表页缺少卡片网格";
  const totalHint = ssrCountAfterPrefix(ssrText(section.querySelector(".hg-page-header__extra")), "共");
  return ssrParseDramaGrid(section, grid, page, requestedSize, totalHint, DEFAULT_LIST_SSR_PAGE_SIZE, "官网列表页没有可用条目");
}

function ssrCategoryRoute(cate: string, page: number, sort: string | null | undefined): { path: string; panel: string } | null {
  if (cate !== "ai-duanju" && cate !== "ai-manju") return null;
  const safePage = Math.max(1, page);
  const trimmedSort = (sort ?? "").trim();
  const route = trimmedSort.length === 0 || trimmedSort === "latest"
    ? { sub: "", panel: "latest" }
    : trimmedSort === "hot" || trimmedSort === "hot_window"
      ? { sub: "hot/", panel: "hot" }
      : trimmedSort === "random"
        ? { sub: "random/", panel: "random" }
        : null;
  if (route === null) return null;
  return { path: safePage === 1 ? `/${cate}/${route.sub}` : `/${cate}/${route.sub}${safePage}/`, panel: route.panel };
}

function ssrListRoute(cate: string, page: number): string | null {
  const prefix = cate === "newest" ? "/newest/" : cate === "recommend" ? "/recommend/" : null;
  if (prefix === null) return null;
  const safePage = Math.max(1, page);
  return safePage === 1 ? prefix : `${prefix}${safePage}/`;
}

async function fetchCategorySsr(cate: string, page: number, size: number, sort: string | null | undefined): Promise<SsrPaged> {
  const safePage = Math.max(1, page);
  const listPath = ssrListRoute(cate, safePage);
  if (listPath !== null) {
    return ssrParseListPageHtml(await fetchSiteHtml(listPath), safePage, size);
  }
  const route = ssrCategoryRoute(cate, safePage, sort);
  if (route === null) throw `不支持的官网频道映射：${cate}`;
  return ssrParseChannelHtml(await fetchSiteHtml(route.path), route.panel, safePage, size);
}

function ssrGossipWindow(page: number): { page: number; size: number } {
  if (page <= 1) return { page: 1, size: 24 };
  const m = page - 1;
  for (const d of [3, 4, 5, 6, 7, 8]) {
    const r = m % d;
    if (r >= 1 && r <= d - 2) return { page: Math.floor(m / d) + 1, size: 12 * d };
  }
  return { page: Math.floor(m / 4) + 1, size: 48 };
}

function ssrParseGossipPostsHtml(
  html: string,
  page: number,
  requestedSize: number,
  enrichment: Map<number, Record<string, Json>>,
): SsrPaged {
  const safePage = Math.max(1, page);
  const doc = new DOMParser().parseFromString(html, "text/html");
  const section = doc.querySelector("section.hg-community-page");
  if (section === null) throw "官网吃瓜页容器缺失";
  const feed = section.querySelector(".hg-cate-feed");
  if (feed === null) throw "官网吃瓜页列表缺失";
  const seen = new Set<number>();
  const items: Json[] = [];
  for (const card of Array.from(feed.querySelectorAll("a.hg-cate-feed__card"))) {
    const id = ssrIdFromValue(ssrAttr(card, "data-track-item-id")) ?? ssrPostIdFromHref(ssrAttr(card, "href"));
    if (id === null || seen.has(id)) continue;
    seen.add(id);
    let title = ssrText(card.querySelector(".hg-cate-feed__title"));
    if (!title) title = normText(ssrAttr(card, "data-track-item-name"));
    if (!title) continue;
    const entry = enrichment.get(id);
    const entryString = (name: string): string => {
      const value = entry?.[name];
      return typeof value === "string" ? normText(value) : "";
    };
    const ssrCoverValue = (() => {
      const img = card.querySelector(".hg-cate-feed__cover img");
      for (const name of ["data-src", "src"]) {
        const value = ssrAttr(img, name);
        if (value.length > 0 && !value.includes("cover-placeholder")) return value;
      }
      return "";
    })();
    const ssrDesc = ssrText(card.querySelector(".hg-cate-feed__intro"));
    const statsRaw = ssrText(card.querySelector(".hg-cate-feed__stats span"));
    const ssrHot = ssrViews(statsRaw.replace(/次阅读|阅读|次浏览|浏览/g, "").trim());
    const tags: string[] = [];
    const rawTags = entry?.tags;
    if (Array.isArray(rawTags)) {
      for (const tag of rawTags) if (typeof tag === "string" && tag.trim().length > 0) tags.push(normText(tag));
    }
    items.push({
      id,
      title,
      cover: ssrCoverValue.length > 0 ? ssrCoverValue : entryString("cover"),
      desc: ssrDesc.length > 0 ? ssrDesc : entryString("desc"),
      tags,
      hot: ssrHot > 0 ? ssrHot : (typeof entry?.hot === "number" ? entry.hot : 0),
      created_at: entryString("created_at") || ssrText(card.querySelector(".hg-cate-feed__date")),
      publish_time: entryString("publish_time"),
    });
  }
  if (items.length === 0) throw "官网吃瓜页未解析到有效条目";
  const fullPageSize = items.length;
  const total = Math.max(ssrCountAfterPrefix(ssrText(section.querySelector(".hg-section-title")), "共"), items.length);
  let pages = ssrPositiveInt(ssrAttr(section.querySelector("[data-hg-pager-jump]"), "data-pages"));
  for (const link of Array.from(section.querySelectorAll("nav.hg-pager .hg-pager__page"))) {
    pages = Math.max(pages, ssrPositiveInt(ssrText(link)));
  }
  if (pages === 0) {
    const perPage = Math.max(fullPageSize, DEFAULT_GOSSIP_SSR_PAGE_SIZE);
    pages = Math.max(Math.ceil(total / perPage), safePage);
  }
  if (safePage === 1 && requestedSize > 0 && requestedSize < DEFAULT_GOSSIP_SSR_PAGE_SIZE) {
    items.length = Math.min(items.length, requestedSize);
  }
  return { items, pagination: { page: safePage, pages: Math.max(pages, safePage), size: items.length, total } };
}

async function fetchGossipPostsSsr(page: number, size: number): Promise<SsrPaged> {
  const safePage = Math.max(1, page);
  const htmlPath = safePage === 1 ? "/blog/gossip/" : `/blog/gossip/${safePage}/`;
  const windowInfo = ssrGossipWindow(safePage);
  const apiPath = `/api/posts/category/remen-chigua?page=${windowInfo.page}&size=${windowInfo.size}&sort=latest`;
  const [html, jsonData] = await Promise.all([
    fetchSiteHtml(htmlPath),
    edge("GET", apiPath).catch(() => null),
  ]);
  const enrichment = new Map<number, Record<string, Json>>();
  if (jsonData !== null && typeof jsonData === "object" && Array.isArray((jsonData as { items?: Json }).items)) {
    for (const item of (jsonData as { items: Json[] }).items) {
      if (item !== null && typeof item === "object" && typeof (item as { id?: Json }).id === "number") {
        enrichment.set((item as { id: number }).id, item as Record<string, Json>);
      }
    }
  }
  return ssrParseGossipPostsHtml(html, safePage, size, enrichment);
}

/* ── 更新检查（对应 api.rs::check_update）────────────── */

const REPO = "zxsos/HGhubX";
const RELEASE_PAGE = `https://github.com/${REPO}/releases`;

function parseRelease(text: string): { tag: string; htmlUrl: string; notes: string; name: string; publishedAt: string; assets: ReleaseAsset[] } {
  const raw = JSON.parse(text) as Record<string, unknown>;
  const assets: ReleaseAsset[] = [];
  const list = raw.assets;
  if (Array.isArray(list)) {
    for (const entry of list) {
      if (entry === null || typeof entry !== "object") continue;
      const row = entry as { name?: unknown; browser_download_url?: unknown };
      if (typeof row.name === "string" && typeof row.browser_download_url === "string") {
        assets.push({ name: row.name, url: row.browser_download_url });
      }
    }
  }
  const str = (value: unknown): string => (typeof value === "string" ? value : "");
  return {
    tag: str(raw.tag_name),
    htmlUrl: str(raw.html_url),
    notes: str(raw.body),
    name: str(raw.name),
    publishedAt: str(raw.published_at),
    assets,
  };
}

async function checkUpdate(): Promise<Record<string, unknown>> {
  const current = appVersion().length > 0 ? appVersion() : "0.0.0";
  const url = `https://api.github.com/repos/${REPO}/releases/latest`;
  const resp = await nativeHttp(
    url,
    "GET",
    { Accept: "application/vnd.github+json", "User-Agent": `HGhubX-Harmony/${current}` },
    "",
    12000,
  );
  // 404 = 还没发过 release，不是错误
  if (resp.status === 404) {
    return noReleaseInfo(current, RELEASE_PAGE);
  }
  const text = decoder.decode(resp.bytes);
  if (resp.status < 200 || resp.status >= 300) {
    throw `GitHub 返回 HTTP ${resp.status}`;
  }
  let payload: { tag: string; htmlUrl: string; notes: string; name: string; publishedAt: string; assets: ReleaseAsset[] };
  try {
    payload = parseRelease(text);
  } catch {
    throw `Release 数据解析失败：${text.slice(0, 160)}`;
  }
  return buildUpdateInfo(payload, current, RELEASE_PAGE);
}

/* ── 网络诊断（精简版，对应 net.rs::diagnose）─────────── */

interface NetInfoRaw {
  online?: boolean;
  bearerTypes?: string[];
  dnses?: string[];
  linkAddresses?: string[];
  mtu?: number;
}

async function buildNetDiag(): Promise<Record<string, unknown>> {
  const base = getBase();
  const host = hostOf(base);

  let info: NetInfoRaw | null = null;
  try {
    info = (await nativeInvoke("netInfo")) as NetInfoRaw;
  } catch {
    info = null;
  }
  const dnses = Array.isArray(info?.dnses) ? (info as NetInfoRaw).dnses as string[] : [];
  const bearers = Array.isArray(info?.bearerTypes) ? (info as NetInfoRaw).bearerTypes as string[] : [];
  const links = Array.isArray(info?.linkAddresses) ? (info as NetInfoRaw).linkAddresses as string[] : [];
  const online =
    info?.online !== false && (typeof navigator === "undefined" || navigator.onLine !== false);

  const started = Date.now();
  let status: number | null = null;
  let ok = false;
  let error = "";
  try {
    await edgeOn(base, "GET", AUTO_PROBE_PATH, null, null, 5000);
    ok = true;
    status = 200;
  } catch (e) {
    error = typeof e === "string" ? e : "请求失败";
  }
  const ms = Date.now() - started;
  const timedOut = /超时|timeout/i.test(error);

  const verdict = ok ? "ok" : !online ? "dns_fail" : "http_fail";
  const summary = ok
    ? `接口连通正常（${host} · ${ms}ms）`
    : !online
      ? "系统当前没有可用网络连接"
      : timedOut
        ? `接口探测超时（${host} · 5s）`
        : `接口请求失败（${host}）：${error.slice(0, 80)}`;

  const advice: string[] = [];
  if (!ok) {
    advice.push("确认手机已联网，必要时切换 Wi-Fi / 移动数据后重试");
    advice.push("若开着 VPN 或代理，试试关闭或换节点（鸿蒙版按系统代理走）");
    advice.push("在「设置 → 线路」换一条线路，或打开线路页刷新镜像");
  }

  return {
    base,
    host,
    runtime: { os: "HarmonyOS", arch: "", ver: appVersion() },
    dns: {
      ms: 0,
      count: dnses.length,
      kinds: dnses.length > 0 ? ["system"] : [],
      suspicious: [],
      detail: dnses.length > 0 ? `系统 DNS：${dnses.join(", ")}` : "未取到系统 DNS（桥接不可用时正常）",
      error: online ? undefined : "系统未连接网络",
    },
    tcp: { skipped: true, reason: "鸿蒙移植层用 HTTP 探测代替独立 TCP 探测" },
    http: {
      status,
      ms,
      error,
      kind: ok ? "" : timedOut ? "timeout" : "network",
      proxy_configured: false,
    },
    env: {
      app_proxy_mode: "system",
      hg_platform: "harmonyos",
      bearer: bearers.join("/"),
      mtu: info?.mtu ?? 0,
      link_addresses: links.join(","),
    },
    verdict,
    summary,
    advice,
  };
}

const ACCOUNT_FIELDS = [
  "id", "username", "nickname", "avatar", "avatar_color", "sign", "desc",
  "user_type", "counts", "interactions",
] as const;

/** 与 Rust normalize_account 对齐：只给前端账号资料和 origin，不透传 token。 */
function normalizeAccount(value: Json, origin: string): Json {
  if (value === null || typeof value !== "object") throw "账号资料响应无效";
  const source = value.user !== null && typeof value.user === "object" ? value.user : value;
  const user: Record<string, Json> = {};
  for (const key of ACCOUNT_FIELDS) {
    if (source[key] !== undefined) user[key] = source[key];
  }
  if (typeof user.id !== "number" || !Number.isSafeInteger(user.id) || user.id <= 0) {
    throw "账号资料响应无效";
  }
  const interactions = value.interactions !== undefined ? value.interactions : source.interactions;
  if (interactions !== undefined) user.interactions = interactions;
  const account: Record<string, Json> = { user, origin };
  if (interactions !== undefined) account.interactions = interactions;
  return account;
}

const PLAYBACK_SECRET_KEYS = [
  "url", "src", "token", "password", "cookie", "authorization", "body", "message", "reason",
] as const;

function scrubPlaybackValue(value: Json, depth = 0): Json {
  if (depth > 5 || value === null) return null;
  if (typeof value === "string") {
    const lower = value.toLowerCase();
    if (value.includes("://") || lower.includes("%3a")) return "[redacted]";
    return value.slice(0, 160);
  }
  if (Array.isArray(value)) return value.slice(0, 24).map((item: Json) => scrubPlaybackValue(item, depth + 1));
  if (typeof value === "object") {
    const out: Record<string, Json> = {};
    for (const [key, item] of Object.entries(value).slice(0, 64)) {
      const lower = key.toLowerCase();
      if (PLAYBACK_SECRET_KEYS.some((secret: string) => lower.includes(secret))) continue;
      out[key.slice(0, 64)] = scrubPlaybackValue(item, depth + 1);
    }
    return out;
  }
  return value;
}

function playbackLine(event: string, data: Json): string {
  return JSON.stringify({
    ts: new Date().toISOString(),
    pid: 0,
    seq: ++playbackSeq,
    event,
    strict: true,
    data: scrubPlaybackValue(data),
  });
}

function playbackEntryLines(entries: Json): string {
  if (!Array.isArray(entries)) throw "日志批次无效";
  if (entries.length > 128) throw "日志批次过大";
  const lines = entries.map((entry: Json) => {
    if (entry === null || typeof entry !== "object") throw "日志条目无效";
    const record = entry as Record<string, Json>;
    const event = String(record.event ?? "");
    if (event.length > 80 || !/^[A-Za-z0-9._-]+$/.test(event)) throw "日志条目无效";
    return playbackLine(`web.${event}`, record.data ?? {});
  });
  return JSON.stringify(lines);
}

function notPorted(cmd: string): never {
  throw `该功能尚未移植到鸿蒙版：${cmd}`;
}

/* ── invoke：命令分发表 ──────────────────────────────── */

export async function invoke<T = Json>(cmd: string, args: Record<string, Json> = {}): Promise<T> {
  const a = args ?? {};
  if (!hasHarmonyBridge()) {
    const tauri = (window as unknown as {
      __TAURI_INTERNALS__?: { invoke: (c: string, a?: Record<string, Json>) => Promise<unknown> };
    }).__TAURI_INTERNALS__;
    if (tauri) {
      return (await tauri.invoke(cmd, a)) as T;
    }
  }
  switch (cmd) {
    /* —— 启动 / 会话 —— */
    case "app_boot": {
      const base = getBase();
      const token = getToken();
      return {
        user: token ? getUser() : null,
        logged_in: !!token,
        base,
        strict_security: true,
        cli_relaxed: false,
      } as T;
    }
    case "security_set":
      if (!!a.strict) return true as T;
      throw "鸿蒙版暂不支持关闭严格安全模式";
    case "api_login": {
      const base = getBase();
      const data = await edge("POST", "/api/account/loginByPassword", { username: a.username, password: a.password }, false);
      const token = data?.token;
      if (typeof token !== "string") throw "登录返回缺少 token";
      if (getBase() !== base) throw "登录期间线路已变化，请重新登录";
      const account = normalizeAccount(data, base);
      setSession(token, account.user);
      return account as T;
    }
    case "api_register": {
      const base = getBase();
      const data = await edge(
        "POST",
        "/api/account/registerByPassword",
        { username: a.username, password: a.password, email: a.email ?? "" },
        false,
      );
      if (getBase() !== base) throw "注册期间线路已变化，请重新登录";
      const token = data?.token;
      if (typeof token !== "string") throw "注册返回缺少 token";
      const account = normalizeAccount(data, base);
      setSession(token, account.user);
      return account as T;
    }
    case "api_logout":
      try {
        await edge("POST", "/api/account/logout");
      } catch {
        /* 令牌失效也要清本地 */
      } finally {
        setSession(null, null);
      }
      return { ok: true } as T;
    case "api_me": {
      const base = getBase();
      const data = await edge("GET", "/api/account/me");
      if (getBase() !== base) throw "读取账号期间线路已变化";
      return normalizeAccount(data, base) as T;
    }
    case "api_account_history":
      return (await edge(
        "GET",
        `/api/users/me/history?page=${a.page ?? 1}&size=${a.size ?? 50}`,
      )) as T;
    case "api_account_history_record":
      return (await edge(
        "POST",
        "/api/users/me/history",
        { video_id: a.videoId, ep: a.ep },
      )) as T;
    case "api_account_history_delete":
      return (await edge(
        "POST",
        "/api/users/me/history/delete",
        { ids: a.ids },
      )) as T;

    /* —— 列表 —— */
    case "api_feed":
      return (await edge("GET", `/api/videos?page=${a.page ?? 1}&size=${a.size ?? 20}`)) as T;
    case "api_original_videos": {
      const suffix = `is_original=1&page=${a.page ?? 1}&size=${a.size ?? 20}${sortSuffix(a.sort)}`;
      const path =
        a.cate === "all" ? `/api/videos?${suffix}` : `/api/videos/category/${enc(a.cate)}?${suffix}`;
      return (await edge("GET", path)) as T;
    }
    case "api_topics":
      return (await edge("GET", "/api/topics?size=100")) as T;
    case "api_topic":
      return (await edge(
        "GET",
        `/api/topics/${enc(a.slug)}?page=${a.page ?? 1}&size=${a.size ?? 20}`,
      )) as T;
    case "api_tags":
      return (await edge("GET", "/api/tags")) as T;
    case "api_tag_videos":
      return (await edge("GET", `/api/videos/tag/${enc(a.tag)}?page=${a.page ?? 1}&size=${a.size ?? 20}`)) as T;
    case "api_category": {
      if (!a.jsonOnly) {
        try {
          return await fetchCategorySsr(String(a.cate), Number(a.page ?? 1), Number(a.size ?? 20), typeof a.sort === "string" ? a.sort : null) as T;
        } catch {
          /* 官网 SSR 不可用时继续走 JSON 网关 */
        }
      }
      const categoryPath = a.cate === "newest"
        ? `/api/videos?page=${a.page ?? 1}&size=${a.size ?? 20}&sort=new`
        : a.cate === "recommend"
          ? `/api/videos?page=${a.page ?? 1}&size=${a.size ?? 20}&sort=hot`
          : `/api/videos/category/${enc(a.cate)}?page=${a.page ?? 1}&size=${a.size ?? 20}${sortSuffix(a.sort)}`;
      return (await edge("GET", categoryPath)) as T;
    }
    case "api_rank": {
      const kind = a.kind === "recommend" || a.kind === "potential" ? a.kind : "hot";
      return (await edge("GET", `/api/ranks/${kind}`)) as T;
    }
    case "api_search": {
      const scope = a.kind === "post" ? "&type=post" : a.kind === "video" ? "&type=video" : "";
      return (await edge(
        "GET",
        `/api/search?q=${enc(a.q ?? "")}&page=${a.page ?? 1}&size=${a.size ?? 20}${scope}`,
      )) as T;
    }
    case "api_search_hot":
      try {
        return { items: parseSearchHot(await fetchSearchHotHtml()) } as T;
      } catch (e) {
        throw `获取官网热搜失败：${typeof e === "string" ? e : "解析失败"}`;
      }

    /* —— 吃瓜帖 —— */
    case "api_posts":
      return (await edge("GET", `/api/posts?page=${a.page ?? 1}&size=${a.size ?? 20}${sortSuffix(a.sort)}`)) as T;
    case "api_post":
      return (await edge("GET", `/api/posts/${a.id}`)) as T;
    case "api_post_playback":
      return (await edge("POST", `/api/posts/${a.id}/playback`, {})) as T;
    case "api_post_like":
      return (await edge(a.on ? "POST" : "DELETE", `/api/posts/${a.id}/like`)) as T;
    case "api_post_collect":
      return (await edge(a.on ? "POST" : "DELETE", `/api/posts/${a.id}/collect`)) as T;
    case "api_post_comments":
      return (await edge(
        "GET",
        `/api/posts/${a.id}/comments?page=${a.page ?? 1}&size=${a.size ?? 20}`,
      )) as T;
    case "api_post_categories":
      return (await edge("GET", "/api/site/categories/post")) as T;
    case "api_post_category": {
      if (a.route === "remen-chigua" && (a.sort === "latest" || a.sort === "new")) {
        try {
          return await fetchGossipPostsSsr(Number(a.page ?? 1), Number(a.size ?? 20)) as T;
        } catch {
          /* 吃瓜 SSR 不可用时继续走 JSON 网关 */
        }
      }
      return (await edge(
        "GET",
        `/api/posts/category/${enc(a.route)}?page=${a.page ?? 1}&size=${a.size ?? 20}${sortSuffix(a.sort)}`,
      )) as T;
    }
    case "api_post_tag":
      return (await edge(
        "GET",
        `/api/posts/tag/${enc(a.tag)}?page=${a.page ?? 1}&size=${a.size ?? 20}`,
      )) as T;

    /* —— 详情 / 播放 —— */
    case "api_video":
      return (await edge("GET", `/api/videos/${a.id}`)) as T;
    case "api_play": {
      let primary: Json = null;
      let primaryError: string | null = null;
      try {
        primary = normalizePlayInfo(await edge("POST", `/api/videos/${a.id}/episodes/${a.ep}/playback`, {}));
      } catch (e) {
        primaryError = typeof e === "string" ? e : "播放接口失败";
      }
      if (hasPlayUrl(primary)) return primary as T;
      try {
        const legacy = normalizePlayInfo(
          await edge("GET", `/api/videos/${a.id}/play?ep=${a.ep}&page_texts=0`),
        );
        if (hasPlayUrl(legacy) || primary === null) return legacy as T;
        return primary as T;
      } catch (e) {
        if (primary !== null) return primary as T;
        throw primaryError ?? (typeof e === "string" ? e : "播放接口失败");
      }
    }
    case "api_related":
      return (await edge("GET", `/api/videos/${a.id}/related`)) as T;

    /* —— 评论 / 互动 —— */
    case "api_comments":
      return (await edge(
        "GET",
        `/api/videos/${a.id}/comments?ep=${a.ep}&page=${a.page ?? 1}&size=${a.size ?? 20}`,
      )) as T;
    case "api_comment_send": {
      const replyId = a.replyId as number | null | undefined;
      const body: Record<string, Json> = { text: a.text };
      let path = `/api/videos/${a.id}/comments?ep=${a.ep}`;
      if (typeof replyId === "number" && replyId > 0) {
        body.reply_id = replyId;
        path = `/api/videos/${a.id}/comments`;
      }
      return (await edge("POST", path, body)) as T;
    }
    case "api_like":
      return (await edge(a.on ? "POST" : "DELETE", `/api/videos/${a.id}/like?ep=${a.ep}`)) as T;
    case "api_collect":
      return (await edge(a.on ? "POST" : "DELETE", `/api/videos/${a.id}/collect`)) as T;
    case "api_follow":
      return (await edge(a.on ? "POST" : "DELETE", `/api/users/${a.uid}/follow`)) as T;

    /* —— 用户 —— */
    case "api_user":
      return (await edge("GET", `/api/users/${a.id}`)) as T;
    case "api_user_stats":
      return (await edge("GET", `/api/users/${a.id}/stats`)) as T;
    case "api_user_videos":
      return (await edge(
        "GET",
        `/api/videos/user/${a.id}?page=${a.page ?? 1}&size=${a.size ?? 20}`,
      )) as T;
    case "api_following":
      return (await edge("GET", `/api/videos/following?page=${a.page ?? 1}&size=${a.size ?? 20}`)) as T;

    /* —— 线路 —— */
    case "line_state":
      return {
        base: getBase(),
        default: DEFAULT_BASE,
        custom: lineStateStore.isCustom(),
        fixed: FIXED,
      } as T;
    case "line_set": {
      const url = normalizeBase(String(a.url ?? ""));
      if (url === null) throw "线路必须是纯 HTTPS origin";
      const previous = getBase();
      if (previous !== url) setSession(null, null);
      lineGeneration += 1;
      setBase(url);
      return url as T;
    }
    case "line_custom_set": {
      const url = normalizeBase(String(a.url ?? ""));
      if (url === null) throw "线路必须是纯 HTTPS origin";
      const previous = getBase();
      if (previous !== url) setSession(null, null);
      lineGeneration += 1;
      lineStateStore.setCustom(url);
      native().setBase(url);
      syncSourceAuthToken();
      return { base: url, custom: true } as T;
    }
    case "line_reset": {
      const previous = getBase();
      if (previous !== DEFAULT_BASE) setSession(null, null);
      lineGeneration += 1;
      lineStateStore.reset();
      setBase(DEFAULT_BASE);
      return { base: DEFAULT_BASE, custom: false } as T;
    }
    case "line_cancel":
      // 让正在进行中的探测结果作废（对应 Rust 的 LINE_SELECTION 代次）
      lineGeneration += 1;
      return null as T;
    case "line_mirrors":
      return (await lineMirrors()) as T;
    case "line_probe": {
      const list = Array.isArray(a.urls) ? (a.urls as string[]).map((u) => String(u)) : [];
      return (await lineProbe(list)) as T;
    }
    case "line_auto": {
      lineGeneration += 1;
      const selection = lineGeneration;
      const previous = getBase();
      const pick = await autoPick();
      const cancelled = lineGeneration !== selection;
      const chosen = typeof pick.base === "string" ? pick.base : "";
      let switched = false;
      if (!cancelled && pick.reason !== "all-down" && chosen.length > 0 && chosen !== previous) {
        applyBaseAndDropSession(chosen);
        switched = getBase() !== previous;
      }
      return { previous, base: getBase(), switched, cancelled, pick } as T;
    }
    case "line_try_main": {
      lineGeneration += 1;
      const selection = lineGeneration;
      const previous = getBase();
      const probe = await lineTryMain();
      const cancelled = lineGeneration !== selection;
      let switched = false;
      if (!cancelled && probe.ok === true) {
        const chosen = typeof probe.base === "string" ? probe.base : "";
        if (chosen.length > 0 && chosen !== previous) {
          applyBaseAndDropSession(chosen);
          switched = getBase() !== previous;
        }
      }
      return { previous, base: getBase(), switched, probe, cancelled } as T;
    }
    case "line_health":
      return (await lineHealth()) as T;

    /* —— 代理 / 诊断 —— */
    case "proxy_state":
      return { mode: "system", url: "" } as T;
    case "proxy_set":
      if ((a.mode ?? "system") === "system") return { mode: "system", url: "" } as T;
      throw "鸿蒙版暂不支持应用内代理设置，请使用系统代理/VPN";
    case "proxy_test":
      throw "代理自检尚未移植（鸿蒙版走系统代理/VPN）";
    case "net_diag":
      return (await buildNetDiag()) as T;
    case "check_update":
      return (await checkUpdate()) as T;

    /* —— 平台能力 —— */
    case "open_url":
      native().openUrl(String(a.url ?? ""));
      return null as T;
    case "set_orientation":
      native().setOrientation(!!a.landscape);
      return null as T;
    case "set_text_interaction":
      return null as T;
    case "debug_log":
      try {
        native().log(String(a.msg ?? ""));
      } catch {
        /* 桥未注入时静默 */
      }
      return null as T;
    case "cache_clear":
      try {
        native().clearCache();
      } catch {
        /* 桥未注入时仍返回明确的“无可清理 Web 缓存”结果 */
      }
      return { webCache: false, platform: "harmonyos" } as T;
    case "plugin:app|background":
    case "plugin:app|exit":
      // App.tsx 返回链的末端。鸿蒙版按系统习惯「退到后台」而不是杀进程：
      // ArkTS 侧 background() → UIAbilityContext.moveAbilityToBackground()
      try {
        native().background();
      } catch {
        /* ignore */
      }
      return null as T;

    /* —— 播放诊断日志（桌面端功能，移动端未启用） —— */
    case "playback_log_status":
      return (await nativeInvoke("playbackLogStatus")) as T;
    case "playback_log_set":
      return (await nativeInvoke("playbackLogSet", !!a.enabled)) as T;
    case "playback_log_write":
      return (await nativeInvoke("playbackLogAppend", playbackEntryLines(a.entries ?? null))) as T;
    case "playback_log_read":
      return (await nativeInvoke("playbackLogRead")) as T;

    /* —— 视频源包（QuickJS 试点 P3c；命令名对齐上游 v3） —— */
    case "source_state":
      return (await nativeInvoke("sourceState")) as T;
    case "source_import":
      return (await nativeInvoke("sourceImport", String(a.input ?? ""), !!a.activate)) as T;
    case "source_export_share_code":
      return (await nativeInvoke("sourceExportShareCode", String(a.id ?? ""))) as T;
    case "source_set_allow_untrusted":
      return (await nativeInvoke("sourceSetAllowUntrusted", !!a.allow)) as T;
    case "source_test":
      return (await nativeInvoke("sourceTest", String(a.id ?? ""))) as T;
    case "source_activate":
      return (await nativeInvoke("sourceActivate", String(a.id ?? ""))) as T;
    case "source_rollback":
      return (await nativeInvoke("sourceRollback")) as T;
    case "source_remove":
      return (await nativeInvoke("sourceRemove", String(a.id ?? ""))) as T;
    case "source_check_update":
      return (await nativeInvoke("sourceCheckUpdate", String(a.id ?? ""))) as T;
    case "source_take_deep_link":
      return (await nativeInvoke("sourceTakeDeepLink")) as T;
    case "source_import_demo":
      return (await nativeInvoke("sourceImportDemo")) as T;

    default:
      return notPorted(cmd);
  }
}

/** clipboard.ts 里会用 isTauri() 判断是否走 Tauri 剪贴板插件。
 *  与官方 @tauri-apps/api 语义一致：鸿蒙宿主恒为 true；其余环境看
 *  window.isTauri（测试 fixture 用它模拟 Tauri 环境）。 */
export function isTauri(): boolean {
  if (hasHarmonyBridge()) return true;
  const flag = (window as unknown as { isTauri?: boolean }).isTauri;
  return flag === true;
}

/* ── 深链导入（P6，对齐上游 source_take_deep_link） ─────────────────
 * 系统层打开 hghubx://import?src=... 时 EntryAbility 暂存 URI；
 * 页面就绪后由 __hgDeepLinkArrived 或启动兜底取走，走同一套
 * source_import 流水线（验签 + init 冒烟），完成后广播 hg:sources-changed。
 */
(window as unknown as { __hgDeepLinkArrived?: () => void }).__hgDeepLinkArrived = () => {
  void runPendingDeepLink();
};

async function runPendingDeepLink(): Promise<void> {
  if (!hasHarmonyBridge()) return;
  let uri: string | null = null;
  try {
    uri = (await invoke<string | null>("source_take_deep_link")) ?? null;
  } catch {
    return;
  }
  if (typeof uri !== "string" || uri.length === 0) return;
  let ok = false;
  let message = "";
  try {
    const descriptor = (await invoke("source_import", { input: uri, activate: false })) as {
      name?: string;
      version?: string;
    } | null;
    ok = true;
    message = tr("已通过深链导入 {0} v{1}", String(descriptor?.name ?? ""), String(descriptor?.version ?? ""));
  } catch (e) {
    message = typeof e === "string" ? e : e instanceof Error ? e.message : tr("深链导入失败");
  }
  try {
    native().log(`[deep_link] ${ok ? "ok" : "failed"} ${message}`);
  } catch {
    /* 日志失败不影响流程 */
  }
  window.dispatchEvent(new CustomEvent("hg:sources-changed", { detail: { ok, message } }));
}

// 启动兜底：冷启动时 pending 在页面加载前就位，onPageEnd 会通知；这里再兜一次
setTimeout(() => { void runPendingDeepLink(); }, 2000);

/**
 * P7 r2：读系统剪贴板。ArkWeb 里 navigator.clipboard.readText 被隐私限制，
 * 鸿蒙宿主下一律走原生 pasteboard（粘贴按钮用）。
 */
export async function readSystemClipboard(): Promise<string> {
  return (await nativeInvoke("pasteFromClipboard")) as string;
}

/** 启动时把当前线路同步给 ArkTS 侧（媒体代理要用它做 Referer） */
export function syncBaseToNative(): void {
  try {
    native().setBase(getBase());
  } catch {
    /* 页面首次加载时桥可能还没注入，忽略 */
  }
  syncSourceAuthToken();
}

/* ── 线路模块的传输依赖 ───────────────────────────────── */

bindLineTransport({
  edgeGuest: (base: string, path: string, timeoutMs: number) => edgeOn(base, "GET", path, null, null, timeoutMs),
  getText: async (url: string, timeoutMs: number, maxBytes: number): Promise<string> => {
    const resp = await nativeHttp(
      url,
      "GET",
      { Accept: "text/html,application/javascript" },
      "",
      timeoutMs,
    );
    if (resp.status < 200 || resp.status >= 300) throw `HTTP ${resp.status}`;
    if (resp.bytes.byteLength > maxBytes) throw "地址发布页或脚本超过 512 KiB 限制";
    return decoder.decode(resp.bytes);
  },
  normalizeBase: (raw: string) => normalizeBase(raw),
  currentBase: () => getBase(),
});

// 模块加载即同步一次；之后每次切线路也会同步（见 line_set / line_custom_set）
syncBaseToNative();
