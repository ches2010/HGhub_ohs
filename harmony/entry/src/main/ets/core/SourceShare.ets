/**
 * P3b：hghubx-src:// 分享口令编解码。
 *
 * 格式与上游一致：hghubx-src:// + base64url(gzip(utf8(packageJson)))。
 * 使用系统 @ohos.zlib 的 gzip 流（windowBits=31），解压后最多 512 KB。
 */
import { zlib } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';

const SHARE_PREFIX = 'hghubx-src://';
const MAX_PACKAGE_JSON_BYTES = 512 * 1024;
const GZIP_WINDOW_BITS = 31;

function textToBytes(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text);
}

function bytesToText(bytes: Uint8Array): string {
  return new util.TextDecoder().decode(bytes);
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const out = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(out).set(bytes);
  return out;
}

function standardToUrlNoPad(text: string): string {
  let out = '';
  for (let i = 0; i < text.length; i++) {
    const ch = text.charAt(i);
    if (ch === '+') {
      out += '-';
    } else if (ch === '/') {
      out += '_';
    } else if (ch === '=') {
      break;
    } else {
      out += ch;
    }
  }
  return out;
}

function urlToStandard(text: string): string {
  let out = '';
  for (let i = 0; i < text.length; i++) {
    const ch = text.charAt(i);
    if (ch === '-') {
      out += '+';
    } else if (ch === '_') {
      out += '/';
    } else {
      out += ch;
    }
  }
  while (out.length % 4 !== 0) {
    out += '=';
  }
  return out;
}

function decodeBase64Url(text: string): Uint8Array {
  const trimmed = text.trim();
  if (trimmed.length === 0) {
    return new Uint8Array(0);
  }
  return new util.Base64Helper().decodeSync(urlToStandard(trimmed));
}

function encodeBase64UrlNoPad(bytes: Uint8Array): string {
  return standardToUrlNoPad(new util.Base64Helper().encodeToStringSync(bytes));
}

function compact(text: string): string {
  let out = '';
  for (let i = 0; i < text.length; i++) {
    const ch = text.charAt(i);
    if (ch !== ' ' && ch !== '\t' && ch !== '\n' && ch !== '\r') {
      out += ch;
    }
  }
  return out;
}

export async function decodeShareCode(raw: string): Promise<string> {
  const trimmed = raw.trim();
  if (!trimmed.startsWith(SHARE_PREFIX)) {
    throw new Error('分享口令前缀无效');
  }
  const encoded = compact(trimmed.substring(SHARE_PREFIX.length));
  if (encoded.length === 0) {
    throw new Error('分享口令为空');
  }
  const sourceBytes = decodeBase64Url(encoded);
  const sourceBuffer = toArrayBuffer(sourceBytes);
  const dest = new ArrayBuffer(MAX_PACKAGE_JSON_BYTES + 1);
  const zip = zlib.createZipSync();
  let strm: zlib.ZStream = {
    nextIn: sourceBuffer,
    availableIn: sourceBuffer.byteLength,
    nextOut: dest,
    availableOut: dest.byteLength
  };
  try {
    const initStatus = await zip.inflateInit2(strm, GZIP_WINDOW_BITS);
    if (initStatus !== zlib.ReturnStatus.OK && initStatus !== zlib.ReturnStatus.STREAM_END) {
      throw new Error('分享口令解压初始化失败');
    }
    const inflateStatus = await zip.inflate(strm, zlib.CompressFlushMode.FINISH);
    if (inflateStatus !== zlib.ReturnStatus.OK && inflateStatus !== zlib.ReturnStatus.STREAM_END) {
      throw new Error('分享口令解压失败，请确认复制完整');
    }
    const outLength = strm.totalOut !== undefined ? strm.totalOut : 0;
    if (outLength <= 0 || outLength > MAX_PACKAGE_JSON_BYTES) {
      throw new Error('分享口令解压后超出大小上限（最大 512 KB）');
    }
    return bytesToText(new Uint8Array(dest, 0, outLength));
  } finally {
    try {
      await zip.inflateEnd(strm);
    } catch (e) {
      // 解压失败时释放流失败不覆盖原始错误
    }
  }
}

export async function encodeShareCode(packageJson: string): Promise<string> {
  const sourceBytes = textToBytes(packageJson);
  if (sourceBytes.byteLength > MAX_PACKAGE_JSON_BYTES) {
    throw new Error('视频源体积超出限制（最大 512 KB）');
  }
  const sourceBuffer = toArrayBuffer(sourceBytes);
  const dest = new ArrayBuffer(sourceBuffer.byteLength + 64 * 1024);
  const zip = zlib.createZipSync();
  let strm: zlib.ZStream = {
    nextIn: sourceBuffer,
    availableIn: sourceBuffer.byteLength,
    nextOut: dest,
    availableOut: dest.byteLength
  };
  try {
    const initStatus = await zip.deflateInit2(
      strm,
      zlib.CompressLevel.COMPRESS_LEVEL_BEST_COMPRESSION,
      zlib.CompressMethod.DEFLATED,
      GZIP_WINDOW_BITS,
      zlib.MemLevel.MEM_LEVEL_DEFAULT,
      zlib.CompressStrategy.COMPRESS_STRATEGY_DEFAULT_STRATEGY
    );
    if (initStatus !== zlib.ReturnStatus.OK) {
      throw new Error('分享口令压缩初始化失败');
    }
    const deflateStatus = await zip.deflate(strm, zlib.CompressFlushMode.FINISH);
    if (deflateStatus !== zlib.ReturnStatus.OK && deflateStatus !== zlib.ReturnStatus.STREAM_END) {
      throw new Error('分享口令压缩失败');
    }
    const outLength = strm.totalOut !== undefined ? strm.totalOut : 0;
    if (outLength <= 0) {
      throw new Error('分享口令压缩结果为空');
    }
    return SHARE_PREFIX + encodeBase64UrlNoPad(new Uint8Array(dest, 0, outLength));
  } finally {
    try {
      await zip.deflateEnd(strm);
    } catch (e) {
      // 压缩失败时释放流失败不覆盖原始错误
    }
  }
}