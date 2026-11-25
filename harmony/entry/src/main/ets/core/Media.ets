/**
 * 媒体层：封面 AES-128-CBC 解密 + m3u8 改写。
 * 与 Rust 侧 media.rs 对齐：
 *   IMG_KEY / IMG_IV 硬编码（站点封面是 AES-128-CBC 密文）
 *   m3u8 里的分片 / key / MAP 一律改写到本地 loopback 的 /seg?u=
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

const IMG_KEY: string = 'f5d965df75336270';
const IMG_IV: string = '97b60394abc2fbe1';

function asciiBytes(s: string): Uint8Array {
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) {
    out[i] = s.charCodeAt(i) & 0xff;
  }
  return out;
}

export function startsWithBytes(buf: Uint8Array, sig: number[]): boolean {
  if (buf.byteLength < sig.length) {
    return false;
  }
  for (let i = 0; i < sig.length; i++) {
    if (buf[i] !== sig[i]) {
      return false;
    }
  }
  return true;
}

/** 图片真实类型（站点封面可能是密文，这里是解密后的判定）。 */
export function imageKind(buf: Uint8Array): string {
  if (buf.byteLength < 12) {
    return '';
  }
  if (buf[0] === 0xFF && buf[1] === 0xD8) {
    return 'image/jpeg';
  }
  if (startsWithBytes(buf, [0x89, 0x50, 0x4E, 0x47])) {
    return 'image/png';
  }
  if (startsWithBytes(buf, [0x47, 0x49, 0x46, 0x38])) {
    return 'image/gif';
  }
  if (startsWithBytes(buf, [0x52, 0x49, 0x46, 0x46]) &&
    buf[8] === 0x57 && buf[9] === 0x45 && buf[10] === 0x42 && buf[11] === 0x50) {
    return 'image/webp';
  }
  return '';
}

export function looksLikePlaylist(buf: Uint8Array): boolean {
  if (buf.byteLength >= 7 && startsWithBytes(buf, [0x23, 0x45, 0x58, 0x54, 0x4D, 0x33, 0x55])) {
    return true;
  }
  // 带 BOM 的 #EXTM3U
  return buf.byteLength >= 10 && startsWithBytes(buf, [0xEF, 0xBB, 0xBF, 0x23, 0x45, 0x58, 0x54, 0x4D, 0x33, 0x55]);
}

/**
 * AES-128-CBC/NoPadding 解密（Padding 由调用方 stripPadding 处理）。
 *
 * 注意：HarmonyOS 的 cryptoFramework 要求 DataBlob.data 是 **Uint8Array**，
 * 传 ArrayBuffer 会直接编译报错（"Type 'ArrayBuffer' is missing ... from type 'Uint8Array'"）。
 */
export async function aesCbcDecrypt(data: Uint8Array): Promise<Uint8Array> {
  if (data.byteLength === 0 || data.byteLength % 16 !== 0) {
    throw new Error('封面密文长度非法');
  }
  const generator = cryptoFramework.createSymKeyGenerator('AES128');
  const symKey = await generator.convertKey({ data: asciiBytes(IMG_KEY) });
  const cipher = cryptoFramework.createCipher('AES128|CBC|NoPadding');
  const spec: cryptoFramework.IvParamsSpec = {
    algName: 'IvParamsSpec',
    iv: { data: asciiBytes(IMG_IV) }
  };
  await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, spec);
  const plain: cryptoFramework.DataBlob = await cipher.doFinal({ data: data });
  return plain.data;
}

export function stripPadding(buf: Uint8Array): Uint8Array {
  if (buf.byteLength === 0) {
    return buf;
  }
  const pad = buf[buf.byteLength - 1];
  if (pad === 0 || pad > 16 || pad > buf.byteLength) {
    return buf;
  }
  let ok = true;
  for (let i = buf.byteLength - pad; i < buf.byteLength; i++) {
    if (buf[i] !== pad) {
      ok = false;
      break;
    }
  }
  return ok ? buf.subarray(0, buf.byteLength - pad) : buf;
}

function splitUrlSuffix(value: string): [string, string] {
  let cut = value.length;
  const query = value.indexOf('?');
  if (query >= 0) cut = Math.min(cut, query);
  const hash = value.indexOf('#');
  if (hash >= 0) cut = Math.min(cut, hash);
  return [value.substring(0, cut), value.substring(cut)];
}

function normalizePathSegments(path: string): string {
  const parts = path.split('/');
  const out: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i];
    if (i === 0 && part === '') {
      out.push('');
      continue;
    }
    if (i === parts.length - 1 && part === '') {
      out.push('');
      continue;
    }
    if (part === '' || part === '.') continue;
    if (part === '..') {
      if (out.length > 1 || (out.length === 1 && out[0] !== '')) out.pop();
      continue;
    }
    out.push(part);
  }
  return out.join('/');
}

/** 把 m3u8 里的相对地址绝对化（不引 URL 库，按协议/主机/目录三段拼并归一化 ..）。 */
export function absoluteUrl(pageUrl: string, target: string): string {
  const t = target.trim();
  if (t.startsWith('http://') || t.startsWith('https://')) {
    return t;
  }
  const schemeEnd = pageUrl.indexOf('://');
  if (schemeEnd < 0) {
    return t;
  }
  const origin = pageUrl.substring(0, schemeEnd);
  if (t.startsWith('//')) {
    return `${origin}:${t}`;
  }
  const pathStart = pageUrl.indexOf('/', schemeEnd + 3);
  const currentPath = pathStart < 0 ? '/' : splitUrlSuffix(pageUrl.substring(pathStart))[0];
  const urlParts = splitUrlSuffix(t);
  const rawPath = urlParts[0];
  const suffix = urlParts[1];
  let path: string;
  if (t.startsWith('?') || t.startsWith('#')) {
    return `${origin}${currentPath}${t}`;
  }
  if (rawPath.startsWith('/')) {
    path = normalizePathSegments(rawPath);
  } else {
    const dir = currentPath.substring(0, currentPath.lastIndexOf('/') + 1);
    path = normalizePathSegments(`${dir}${rawPath}`);
  }
  return `${origin}${path}${suffix}`;
}

export function pctEncode(s: string): string {
  return encodeURIComponent(s);
}

function rewriteUriAttributes(line: string, rewrite: (uri: string) => string): string {
  const colon = line.indexOf(':');
  if (colon < 0) {
    return line;
  }
  const tag = line.substring(0, colon);
  const rest = line.substring(colon + 1);
  // 属性值里可能有逗号，必须按引号切分
  const parts: string[] = [];
  let quoted = false;
  let start = 0;
  for (let i = 0; i < rest.length; i++) {
    const ch = rest.charAt(i);
    if (ch === '"') {
      quoted = !quoted;
    }
    if (ch === ',' && !quoted) {
      parts.push(rest.substring(start, i));
      start = i + 1;
    }
  }
  parts.push(rest.substring(start));
  const mapped: string[] = [];
  for (const attr of parts) {
    const eq = attr.indexOf('=');
    if (eq > 0 && attr.substring(0, eq).trim() === 'URI') {
      const value = attr.substring(eq + 1).trim();
      if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
        const uri = value.substring(1, value.length - 1);
        mapped.push(`${attr.substring(0, eq)}="${rewrite(uri)}"`);
        continue;
      }
    }
    mapped.push(attr);
  }
  return `${tag}:${mapped.join(',')}`;
}

function removeUriAttributes(line: string): string {
  const colon = line.indexOf(':');
  if (colon < 0) return line;
  const tag = line.substring(0, colon);
  const rest = line.substring(colon + 1);
  const parts: string[] = [];
  let quoted = false;
  let start = 0;
  for (let i = 0; i < rest.length; i++) {
    const ch = rest.charAt(i);
    if (ch === '"') quoted = !quoted;
    if (ch === ',' && !quoted) {
      parts.push(rest.substring(start, i));
      start = i + 1;
    }
  }
  parts.push(rest.substring(start));
  const kept = parts.filter((attr: string) => {
    const eq = attr.indexOf('=');
    return !(eq > 0 && attr.substring(0, eq).trim() === 'URI');
  });
  return `${tag}:${kept.join(',')}`;
}

/**
 * 改写整份播放列表：分片与所有 URI 属性都指向 `${localOrigin}/seg?u=`。
 * 与 Rust 版一致：丢弃 EXT-X-CONTENT-STEERING，DATERANGE 只保留非 URI 属性。
 */
export function rewritePlaylist(localOrigin: string, pageUrl: string, text: string): string {
  const body = text.startsWith('\uFEFF') ? text.substring(1) : text;
  const lines = body.split('\n');
  const out: string[] = [];
  for (const raw of lines) {
    const line = raw.replace(/\s+$/, '');
    if (line.length === 0) {
      out.push('');
      continue;
    }
    if (line.startsWith('#')) {
      if (line.startsWith('#EXT-X-CONTENT-STEERING:')) {
        continue;
      }
      if (line.startsWith('#EXT-X-DATERANGE:')) {
        out.push(removeUriAttributes(line));
        continue;
      }
      if (line.indexOf('URI="') >= 0) {
        out.push(rewriteUriAttributes(line, (uri: string) => {
          return `${localOrigin}/seg?u=${pctEncode(absoluteUrl(pageUrl, uri))}`;
        }));
      } else {
        out.push(line);
      }
      continue;
    }
    out.push(`${localOrigin}/seg?u=${pctEncode(absoluteUrl(pageUrl, line))}`);
  }
  return out.join('\n');
}

export function decodeText(buf: Uint8Array): string {
  return new util.TextDecoder().decodeToString(buf);
}

export function encodeText(s: string): Uint8Array {
  return new util.TextEncoder().encodeInto(s);
}
