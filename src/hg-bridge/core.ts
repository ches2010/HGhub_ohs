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
function hasHarmonyBridge(): boolean {
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

/** 纯 HTTPS origin 归一（不接受路径/查询/片段/凭据） */
function normalizeBase(raw: string): string | null {
  const text = raw.trim();
  if (text.length === 0) return null;
  try {
    const parsed = new URL(text);
    if (parsed.protocol !== "https:") return null;
    if (parsed.pathname !== "/" || parsed.search !== "" || parsed.hash !== "") return null;
    if (parsed.username !== "" || parsed.password !== "") return null;
    return parsed.origin;
  } catch {
    return null;
  }
}

/** 切线路并丢弃旧站点的会话（我们只存一份 token，不按 origin 隔离） */
function applyBaseAndDropSession(url: string): void {
  const previous = getBase();
  setBase(url);
  if (previous !== url) setSession(null, null);
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

  const resp = await nativeHttp(`${base}/api/edge/request`, "POST", headers, JSON.stringify(envelope), timeoutMs);
  if (resp.status === 401 || resp.status === 403) throw "401";
  const text = decoder.decode(resp.bytes);
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
    return;
  }
  localStorage.setItem(LS_TOKEN, token);
  if (user === null || user === undefined) localStorage.removeItem(LS_USER);
  else localStorage.setItem(LS_USER, JSON.stringify(user));
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
      return true as T;
    case "api_login": {
      const base = getBase();
      const data = await edge("POST", "/api/account/loginByPassword", { username: a.username, password: a.password }, false);
      const token = data?.token;
      if (typeof token !== "string") throw "登录返回缺少 token";
      if (getBase() !== base) throw "登录期间线路已变化，请重新登录";
      setSession(token, data.user ?? null);
      return { user: data.user ?? null } as T;
    }
    case "api_register": {
      const data = await edge(
        "POST",
        "/api/account/registerByPassword",
        { username: a.username, password: a.password, email: a.email ?? "" },
        false,
      );
      if (typeof data?.token === "string") setSession(data.token, data.user ?? null);
      return { user: data?.user ?? null } as T;
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
    case "api_me":
      return (await edge("GET", "/api/account/me")) as T;

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
      return (await edge("GET", `/api/topics/${enc(a.slug)}`)) as T;
    case "api_tags":
      return (await edge("GET", "/api/tags")) as T;
    case "api_tag_videos":
      return (await edge("GET", `/api/videos/tag/${enc(a.tag)}?page=${a.page ?? 1}&size=${a.size ?? 20}`)) as T;
    case "api_category":
      return (await edge(
        "GET",
        `/api/videos/category/${enc(a.cate)}?page=${a.page ?? 1}&size=${a.size ?? 20}${sortSuffix(a.sort)}`,
      )) as T;
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
    case "api_post_category":
      return (await edge(
        "GET",
        `/api/posts/category/${enc(a.route)}?page=${a.page ?? 1}&size=${a.size ?? 20}${sortSuffix(a.sort)}`,
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
      setBase(url);
      if (previous !== url) setSession(null, null);
      return url as T;
    }
    case "line_custom_set": {
      const url = normalizeBase(String(a.url ?? ""));
      if (url === null) throw "线路必须是纯 HTTPS origin";
      const previous = getBase();
      lineStateStore.setCustom(url);
      native().setBase(url);
      if (previous !== url) setSession(null, null);
      return { base: url, custom: true } as T;
    }
    case "line_reset": {
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
      return { mode: a.mode ?? "system", url: a.url ?? "" } as T;
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
      native().clearCache();
      return null as T;
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
      return { enabled: false, path: "" } as T;
    case "playback_log_set":
      return false as T;
    case "playback_log_write":
      return null as T;
    case "playback_log_read":
      return "" as T;

    default:
      return notPorted(cmd);
  }
}

/** clipboard.ts 里会用 isTauri 判断是否走 Tauri 剪贴板插件 */
export const isTauri = true;

/** 启动时把当前线路同步给 ArkTS 侧（媒体代理要用它做 Referer） */
export function syncBaseToNative(): void {
  try {
    native().setBase(getBase());
  } catch {
    /* 页面首次加载时桥可能还没注入，忽略 */
  }
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
