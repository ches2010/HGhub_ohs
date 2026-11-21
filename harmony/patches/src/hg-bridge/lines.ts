/**
 * 线路与镜像（对应 src-tauri/src/lines.rs）
 * ---------------------------------------------------------------
 * 站点会换域名，官方发布页上有 `publish.js`，里面声明：
 *     var urls = ['huangguoai.com', ...];
 *     var subdomains = ['www', ...];       // 可选，会与 urls 组合
 * 这里把发布脚本**当数据解析**（绝不执行远端 JS），再做可达性探测。
 *
 * 与 Rust 版一致的要点：
 *   · 只接受字面量字符串数组；含函数调用/拼接/重复声明一律失败
 *   · 只认同源 HTTPS 的 publish.js
 *   · 探测判据是"接口返回了有效的视频列表数据"，不是 HTTP 200
 *   · 探测失败不会改线路；只有真正 better 的候选才切换
 */

export interface LineHit {
  tier: string;
  url: string;
  ok: boolean;
  reachable: boolean;
  ms: number;
  status: number | null;
  error?: string;
}

export interface MirrorItem {
  url: string;
  host: string;
}

export interface FixedLine {
  name: string;
  url: string;
}

export const FIXED: FixedLine[] = [
  { name: "固定线路 1", url: "https://huangguoai.com" },
];

/** 与 Rust `net::base()` 之外的最小依赖：只在这里解析主机名 */
export function hostOf(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
}

const PUBLISH_PAGES = ["https://huangguoai.pages.dev/", "https://huang-guo.pages.dev/"];
const MIRROR_MAX = 60;
const PUBLISH_ARRAY_MAX = 256;
const RECOMMENDED_MAX = 20;
const PAGE_TIMEOUT = 8000;
const MAX_PUBLISH_BYTES = 512 * 1024;
export const AUTO_PROBE_PATH = "/api/videos?page=1&size=1";
const AUTO_PROBE_TIMEOUT = 5000;
const AUTO_MIRROR_MAX = 10;

/* ── 传送门（由 core.ts 注入，避免循环依赖）──────────────── */

export interface LineTransport {
  /** 无凭据的 edge 请求，返回已解包的 data，失败抛字符串 */
  edgeGuest(base: string, path: string, timeoutMs: number): Promise<unknown>;
  /** 拉文本（发布页/脚本） */
  getText(url: string, timeoutMs: number, maxBytes: number): Promise<string>;
  normalizeBase(raw: string): string | null;
  currentBase(): string;
}

let transport: LineTransport | null = null;

export function bindLineTransport(next: LineTransport): void {
  transport = next;
}

function tx(): LineTransport {
  if (transport === null) {
    throw "线路模块尚未初始化";
  }
  return transport;
}

/* ── 可信镜像集合 ─────────────────────────────────────── */

const trustedMirrors: string[] = [];

export function isTrustedMirror(origin: string): boolean {
  return trustedMirrors.includes(origin);
}

function rememberPublished(items: MirrorItem[]): void {
  for (const item of items) {
    if (!trustedMirrors.includes(item.url)) {
      if (trustedMirrors.length >= 256) trustedMirrors.shift();
      trustedMirrors.push(item.url);
    }
  }
}

export function isFixed(url: string): boolean {
  return FIXED.some((entry) => entry.url === url);
}

/* ── 发布脚本解析（JS 词法 → 只接受字面量数组）──────────── */

type Token =
  | { kind: "ident"; value: string }
  | { kind: "string"; value: string }
  | { kind: "sym"; value: string };

const REGEX_PREV_KEYWORDS = new Set([
  "return", "typeof", "case", "in", "of", "new", "delete", "void",
  "instanceof", "do", "else", "yield", "await",
]);

function canStartRegex(prev: Token | null): boolean {
  if (prev === null) return true;
  if (prev.kind === "ident") return REGEX_PREV_KEYWORDS.has(prev.value);
  return !(prev.value === ")" || prev.value === "]" || prev.value === "}");
}

function decodeJsString(raw: string): string {
  // raw 不含两侧引号
  let out = "";
  for (let i = 0; i < raw.length; i++) {
    const ch = raw[i];
    if (ch !== "\\") {
      if (ch.charCodeAt(0) < 0x20) throw "镜像字符串含控制字符";
      out += ch;
      continue;
    }
    const next = raw[++i];
    if (next === undefined) throw "镜像字符串转义无效";
    if (next === "\\" || next === "'" || next === '"' || next === "/") {
      out += next;
    } else if (next === "x") {
      const code = raw.slice(i + 1, i + 3);
      if (!/^[0-9a-fA-F]{2}$/.test(code)) throw "镜像字符串转义无效";
      out += String.fromCharCode(parseInt(code, 16));
      i += 2;
    } else if (next === "u") {
      const code = raw.slice(i + 1, i + 5);
      if (!/^[0-9a-fA-F]{4}$/.test(code)) throw "镜像字符串转义无效";
      out += String.fromCharCode(parseInt(code, 16));
      i += 4;
    } else {
      throw "镜像字符串含不支持的转义";
    }
  }
  return out;
}

/** 极简 JS 词法：跳过注释 / 字符串 / 模板 / 正则，只留可判定结构的 token。 */
function jsTokens(source: string): Token[] {
  const tokens: Token[] = [];
  let i = 0;
  let prev: Token | null = null;
  const push = (token: Token) => {
    tokens.push(token);
    prev = token;
  };
  while (i < source.length) {
    const ch = source[i];
    if (ch === " " || ch === "\t" || ch === "\n" || ch === "\r") {
      i++;
      continue;
    }
    if (ch === "/" && source[i + 1] === "/") {
      const end = source.indexOf("\n", i);
      i = end < 0 ? source.length : end + 1;
      continue;
    }
    if (ch === "/" && source[i + 1] === "*") {
      const end = source.indexOf("*/", i + 2);
      i = end < 0 ? source.length : end + 2;
      continue;
    }
    if (ch === "/" && canStartRegex(prev)) {
      // 正则字面量：整体吞掉
      let j = i + 1;
      let inClass = false;
      while (j < source.length) {
        const c = source[j];
        if (c === "\\") { j += 2; continue; }
        if (c === "[") inClass = true;
        else if (c === "]") inClass = false;
        else if (c === "/" && !inClass) break;
        else if (c === "\n") throw "发布脚本正则字面量未闭合";
        j++;
      }
      j++;
      while (j < source.length && /[a-z]/.test(source[j])) j++;
      push({ kind: "string", value: "" });
      i = j;
      continue;
    }
    if (ch === "'" || ch === '"') {
      let j = i + 1;
      let raw = "";
      while (j < source.length && source[j] !== ch) {
        if (source[j] === "\\") {
          raw += source[j] + (source[j + 1] ?? "");
          j += 2;
          continue;
        }
        raw += source[j];
        j++;
      }
      if (j >= source.length) throw "发布脚本字符串未闭合";
      push({ kind: "string", value: decodeJsString(raw) });
      i = j + 1;
      continue;
    }
    if (ch === "`") {
      // 模板字面量：整体当作字符串（含 ${} 内的内容也不解析）
      let j = i + 1;
      let raw = "";
      while (j < source.length && source[j] !== "`") {
        if (source[j] === "\\") { raw += source[j] + (source[j + 1] ?? ""); j += 2; continue; }
        raw += source[j];
        j++;
      }
      if (j >= source.length) throw "发布脚本模板字符串未闭合";
      push({ kind: "string", value: decodeJsString(raw) });
      i = j + 1;
      continue;
    }
    if (/[A-Za-z_$]/.test(ch)) {
      let j = i;
      while (j < source.length && /[A-Za-z0-9_$]/.test(source[j])) j++;
      push({ kind: "ident", value: source.slice(i, j) });
      i = j;
      continue;
    }
    push({ kind: "sym", value: ch });
    i++;
  }
  return tokens;
}

/** 只接受顶层 `var/let/const name = ['..','..']`；其它形式一律抛错。 */
function jsArray(source: string, name: string): string[] | null {
  const tokens = jsTokens(source);
  let depth = 0;
  let result: string[] | null = null;
  for (let at = 0; at < tokens.length; at++) {
    const token = tokens[at];
    const declaration =
      token.kind === "ident" && (token.value === "var" || token.value === "let" || token.value === "const");
    const next = tokens[at + 1];
    if (depth === 0 && declaration && next?.kind === "ident" && next.value === name) {
      if (result !== null) throw `发布脚本重复声明 ${name}`;
      const eq = tokens[at + 2];
      const open = tokens[at + 3];
      if (eq?.kind !== "sym" || eq.value !== "=" || open?.kind !== "sym" || open.value !== "[") {
        throw `发布脚本的 ${name} 必须是字符串数组`;
      }
      let cursor = at + 4;
      const values: string[] = [];
      while (true) {
        const current = tokens[cursor];
        if (current?.kind === "sym" && current.value === "]") break;
        if (current === undefined || current.kind !== "string") {
          throw `发布脚本的 ${name} 含非字符串值`;
        }
        if (values.length >= PUBLISH_ARRAY_MAX) {
          throw `${name} exceeds the publisher array size limit`;
        }
        values.push(current.value);
        cursor++;
        const sep = tokens[cursor];
        if (sep?.kind === "sym" && sep.value === ",") {
          cursor++;
          continue;
        }
        if (sep?.kind === "sym" && sep.value === "]") continue;
        throw `发布脚本的 ${name} 数组格式无效`;
      }
      const after = tokens[cursor + 1];
      if (after !== undefined && !(after.kind === "sym" && after.value === ";")) {
        throw `发布脚本的 ${name} 不能使用动态表达式`;
      }
      result = values;
    }
    if (token.kind === "sym") {
      if (token.value === "{" || token.value === "(" || token.value === "[") depth++;
      else if (token.value === "}" || token.value === ")" || token.value === "]") {
        depth = Math.max(0, depth - 1);
      }
    }
  }
  return result;
}

/** 测试用出口：暴露字面量数组解析（Rust 里对应 js_array） */
export function parseJsStringArray(source: string, name: string): string[] | null {
  return jsArray(source, name);
}

function validDnsLabel(value: string): boolean {
  if (value.length === 0 || value.length > 63) return false;
  if (!/^[A-Za-z0-9-]+$/.test(value)) return false;
  return /^[A-Za-z0-9]/.test(value) && /[A-Za-z0-9]$/.test(value);
}

const RESERVED_SUFFIXES = ["localhost", "local", "internal", "home.arpa"];

export function validDnsName(value: string): boolean {
  if (value.length === 0 || value.length > 253) return false;
  if (!value.includes(".")) return false;
  if (!value.split(".").every(validDnsLabel)) return false;
  for (const suffix of RESERVED_SUFFIXES) {
    if (value === suffix || value.endsWith(`.${suffix}`)) return false;
  }
  return true;
}

export function parseMirrors(js: string): MirrorItem[] {
  const domains = jsArray(js, "urls") ?? [];
  const subs = jsArray(js, "subdomains") ?? [];
  if (domains.length === 0) {
    throw "发布脚本中没有找到镜像域名";
  }
  const items: MirrorItem[] = [];
  const seen = new Set<string>();
  outer: for (const rawDomain of domains) {
    const domain = rawDomain.trim().replace(/\/+$/, "").toLowerCase();
    if (!validDnsName(domain)) continue;
    const hosts: string[] = [];
    if (subs.length === 0) {
      hosts.push(domain);
    } else {
      for (const rawSub of subs) {
        const sub = rawSub.trim().toLowerCase();
        if (validDnsLabel(sub)) hosts.push(`${sub}.${domain}`);
      }
    }
    for (const host of hosts) {
      if (!validDnsName(host) || seen.has(host)) continue;
      const origin = tx().normalizeBase(`https://${host}`);
      if (origin === null) continue;
      seen.add(host);
      items.push({ url: origin, host });
      if (items.length >= MIRROR_MAX) break outer;
    }
  }
  if (items.length === 0) {
    throw "发布脚本中没有合法镜像地址";
  }
  return items;
}

/* ── 发布页抓取 ───────────────────────────────────────── */

/** 取第一个同源的 https publish.js（Rust 用 DOM 选择器，这里用等价的正则扫描）。 */
export function scriptSrc(page: string, html: string): string {
  const re = /<script\b[^>]*\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/gi;
  let match: RegExpExecArray | null;
  while ((match = re.exec(html)) !== null) {
    const raw = (match[1] ?? match[2] ?? match[3] ?? "").trim();
    if (!raw) continue;
    if (/[\u0000-\u001f]/.test(raw)) throw "发布脚本地址含控制字符";
    let target: URL;
    try {
      target = new URL(raw, page);
    } catch {
      continue;
    }
    const base = new URL(page);
    if (base.protocol !== "https:" || target.protocol !== "https:") continue;
    if (target.origin !== base.origin) continue;
    if (target.username || target.password || target.hash) continue;
    if (target.pathname.split("/").pop() !== "publish.js") continue;
    return target.toString();
  }
  throw "地址发布页没有同源 publish.js 脚本";
}

interface PublishedPage {
  source: string;
  script: string;
  items: MirrorItem[];
}

async function mirrorsFromPage(page: string): Promise<PublishedPage> {
  const html = await tx().getText(page, PAGE_TIMEOUT, MAX_PUBLISH_BYTES);
  const script = scriptSrc(page, html);
  const js = await tx().getText(script, PAGE_TIMEOUT, MAX_PUBLISH_BYTES);
  const items = parseMirrors(js);
  return { source: page, script, items };
}

export interface MirrorListing {
  source: string;
  script: string;
  items: MirrorItem[];
  recommended_source: string;
  recommended: MirrorItem[];
  errors: string[];
}

export async function mirrors(): Promise<MirrorListing> {
  const settled = await Promise.allSettled([mirrorsFromPage(PUBLISH_PAGES[0]), mirrorsFromPage(PUBLISH_PAGES[1])]);
  const pages: PublishedPage[] = [];
  const errors: string[] = [];
  settled.forEach((result, index) => {
    if (result.status === "fulfilled") pages.push(result.value);
    else {
      const reason = result.reason;
      errors.push(`${PUBLISH_PAGES[index]}: ${typeof reason === "string" ? reason : "获取失败"}`);
    }
  });

  const items: MirrorItem[] = [];
  const seen = new Set<string>();
  // 两个发布页交替取，避免第一页过长把第二页挤掉
  for (let index = 0; index < MIRROR_MAX; index++) {
    for (const page of pages) {
      const item = page.items[index];
      if (item === undefined) continue;
      if (items.length < MIRROR_MAX && !seen.has(item.url)) {
        seen.add(item.url);
        items.push(item);
      }
    }
  }
  if (items.length === 0) {
    throw errors.length === 0 ? "地址发布页里没有可用的镜像地址" : errors.join("；");
  }

  const recommended: MirrorItem[] = [];
  const recommendedSeen = new Set<string>();
  const current = tx().normalizeBase(tx().currentBase());
  if (current !== null) {
    recommendedSeen.add(current);
    recommended.push({ url: current, host: hostOf(current) });
  }
  for (const item of items) {
    if (recommended.length >= RECOMMENDED_MAX) break;
    if (!recommendedSeen.has(item.url)) {
      recommendedSeen.add(item.url);
      recommended.push(item);
    }
  }

  const listing: MirrorListing = {
    source: pages.map((page) => page.source).join(", "),
    script: pages.map((page) => page.script).join(", "),
    items,
    recommended_source: pages.map((page) => page.source).join(", "),
    recommended,
    errors,
  };
  rememberPublished(items);
  return listing;
}

/* ── 探测 ─────────────────────────────────────────────── */

/** 判据：解包后的 data 必须是"看起来真能用"的视频列表，不然只是能连上而已。 */
export function healthyVideoData(data: unknown): boolean {
  if (data === null || typeof data !== "object") return false;
  const root = data as { items?: unknown; pagination?: Record<string, unknown> };
  if (!Array.isArray(root.items)) return false;
  const pagination = root.pagination;
  if (pagination === null || typeof pagination !== "object") return false;
  const int = (key: string): number | null => {
    const value = (pagination as Record<string, unknown>)[key];
    return typeof value === "number" && Number.isInteger(value) && value >= 0 ? value : null;
  };
  const page = int("page");
  const size = int("size");
  if (page === null || page === 0 || size === null || size === 0) return false;
  if (int("pages") === null || int("total") === null) return false;
  return (root.items as unknown[]).every((item) => {
    if (item === null || typeof item !== "object") return false;
    const row = item as { id?: unknown; title?: unknown };
    const id = row.id;
    const title = row.title;
    return typeof id === "number" && id > 0 && typeof title === "string" && title.trim().length > 0;
  });
}

function hitJson(hit: LineHit): Record<string, unknown> {
  const out: Record<string, unknown> = {
    tier: hit.tier,
    url: hit.url,
    ok: hit.ok,
    reachable: hit.reachable,
    ms: hit.ms,
    status: hit.status,
  };
  if (hit.error !== undefined) out.error = hit.error;
  return out;
}

async function probeHit(tier: string, raw: string): Promise<LineHit> {
  const hit: LineHit = { tier, url: raw, ok: false, reachable: false, ms: 0, status: null };
  const origin = tx().normalizeBase(raw);
  if (origin === null) {
    hit.error = "线路必须是安全 HTTPS origin";
    return hit;
  }
  hit.url = origin;
  const started = Date.now();
  try {
    const data = await tx().edgeGuest(origin, AUTO_PROBE_PATH, AUTO_PROBE_TIMEOUT);
    hit.reachable = true;
    hit.status = 200;
    hit.ok = healthyVideoData(data);
    if (!hit.ok) hit.error = "接口未返回有效视频列表数据";
  } catch (e) {
    const message = typeof e === "string" ? e : "探测失败";
    hit.error = /timeout|超时/i.test(message) ? "视频接口探测超时（5 秒）" : message;
  }
  hit.ms = Date.now() - started;
  return hit;
}

/** 手动探测：只报结果，不改信任也不改线路。 */
export async function probe(urls: string[]): Promise<Record<string, unknown>[]> {
  const out: Record<string, unknown>[] = [];
  const list = urls.slice(0, MIRROR_MAX);
  for (let i = 0; i < list.length; i += 6) {
    const chunk = list.slice(i, i + 6);
    const hits = await Promise.all(chunk.map((origin) => probeHit("mirror", origin)));
    for (const hit of hits) out.push(hitJson(hit));
  }
  return out;
}

function autoCandidates(items: MirrorItem[], current: string): string[] {
  const candidates: string[] = [];
  const seen = new Set<string>();
  const normalizedCurrent = tx().normalizeBase(current);
  const published = items
    .map((item) => tx().normalizeBase(item.url))
    .filter((origin): origin is string => origin !== null)
    .filter((origin) => !isFixed(origin) && isTrustedMirror(origin));
  // 当前线路如果确实是发布去的，优先保留（哪怕发布列表很长）
  if (normalizedCurrent !== null && published.includes(normalizedCurrent)) {
    seen.add(normalizedCurrent);
    candidates.push(normalizedCurrent);
  }
  for (const origin of published) {
    if (candidates.length >= AUTO_MIRROR_MAX) break;
    if (!seen.has(origin)) {
      seen.add(origin);
      candidates.push(origin);
    }
  }
  return candidates;
}

export function pickFromHits(hits: LineHit[]): Record<string, unknown> {
  let winner: LineHit | null = null;
  for (const hit of hits) {
    if (!hit.ok) continue;
    if (winner === null || hit.ms < winner.ms) winner = hit;
  }
  const candidates = hits.map(hitJson);
  if (winner === null) {
    return { base: "", tier: "none", ms: 0, reason: "all-down", candidates };
  }
  return {
    base: winner.url,
    tier: winner.tier,
    ms: winner.ms,
    reason: winner.tier === "main" ? "main-ok" : "mirror-ok",
    candidates,
  };
}

/**
 * 自动选线：先探主站，主站不行再抓发布页并发探镜像。
 * 代次校验（探测期间用户手动切了线路就作废）由 core.ts 负责，这里只做"测 + 选"。
 */
export async function autoPick(): Promise<Record<string, unknown>> {
  const hits: LineHit[] = [await probeHit("main", FIXED[0].url)];
  let mirrorError: string | null = null;
  if (!hits[0].ok) {
    try {
      const listing = await mirrors();
      const targets = autoCandidates(listing.items, tx().currentBase());
      const probed = await Promise.all(targets.map((origin) => probeHit("mirror", origin)));
      for (const hit of probed) hits.push(hit);
    } catch (e) {
      mirrorError = typeof e === "string" ? e : "获取镜像失败";
    }
  }
  const pick = pickFromHits(hits);
  if (mirrorError !== null) pick.mirror_error = mirrorError;
  return pick;
}

export async function tryMain(): Promise<Record<string, unknown>> {
  const hit = await probeHit("main", FIXED[0].url);
  return { ...hitJson(hit), base: hit.url };
}

export async function health(): Promise<Record<string, unknown>> {
  const hit = await probeHit("current", tx().currentBase());
  return { ...hitJson(hit), base: hit.url };
}
