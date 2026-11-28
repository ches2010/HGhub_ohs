/**
 * P3b：hghubx-src:// 分享口令编解码。
 *
 * 格式与上游一致：hghubx-src:// + base64url(gzip(utf8(packageJson)))。
 * HarmonyOS ZStream.totalOut 在部分设备上不可靠，这里改用系统 GZip 文件式 API；
 * gzread 的返回值就是实际解压字节数，安全且上限明确。
 */
import { zlib } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

const SHARE_PREFIX = 'hghubx-src://';
const MAX_PACKAGE_JSON_BYTES = 512 * 1024;

function textToBytes(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text);
}

function bytesToText(bytes: Uint8Array): string {
  return new util.TextDecoder().decode(bytes);
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

function writeTempFile(tempDir: string, suffix: string, bytes: Uint8Array): string {
  const path = tempDir + '/hghubx-share-' + Date.now() + '-' + Math.floor(Math.random() * 100000) + suffix;
  const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  const buffer = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buffer).set(bytes);
  fileIo.writeSync(file.fd, buffer);
  fileIo.closeSync(file.fd);
  return path;
}

function readTempFile(path: string): Uint8Array {
  const stat = fileIo.statSync(path);
  const buffer = new ArrayBuffer(stat.size);
  const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
  fileIo.readSync(file.fd, buffer);
  fileIo.closeSync(file.fd);
  return new Uint8Array(buffer);
}

function removeTempFile(path: string): void {
  try {
    if (fileIo.statSync(path) !== undefined) {
      fileIo.unlinkSync(path);
    }
  } catch (e) {
    // 临时文件不存在时忽略
  }
}

export async function decodeShareCode(raw: string, tempDir: string): Promise<string> {
  const trimmed = raw.trim();
  if (!trimmed.startsWith(SHARE_PREFIX)) {
    throw new Error('分享口令前缀无效');
  }
  const encoded = compact(trimmed.substring(SHARE_PREFIX.length));
  if (encoded.length === 0) {
    throw new Error('分享口令为空');
  }
  const sourceBytes = decodeBase64Url(encoded);
  if (sourceBytes.byteLength === 0) {
    throw new Error('分享口令编码无效（Base64URL 解码失败）');
  }
  const tempPath = writeTempFile(tempDir, '.gz', sourceBytes);
  const gzip = zlib.createGZipSync();
  const dest = new ArrayBuffer(MAX_PACKAGE_JSON_BYTES);
  let opened = false;
  try {
    await gzip.gzopen(tempPath, 'rb');
    opened = true;
    const readLength = await gzip.gzread(dest);
    if (readLength <= 0 || readLength > MAX_PACKAGE_JSON_BYTES) {
      throw new Error('分享口令解压后超出大小上限（最大 512 KB）');
    }
    return bytesToText(new Uint8Array(dest, 0, readLength));
  } finally {
    if (opened) {
      try {
        await gzip.gzclose();
      } catch (e) {
        // 关闭失败不覆盖原始错误
      }
    }
    removeTempFile(tempPath);
  }
}

export async function encodeShareCode(packageJson: string, tempDir: string): Promise<string> {
  const sourceBytes = textToBytes(packageJson);
  if (sourceBytes.byteLength > MAX_PACKAGE_JSON_BYTES) {
    throw new Error('视频源体积超出限制（最大 512 KB）');
  }
  const tempPath = writeTempFile(tempDir, '.gz', new Uint8Array(0));
  const gzip = zlib.createGZipSync();
  let opened = false;
  try {
    await gzip.gzopen(tempPath, 'wb9');
    opened = true;
    // gzwrite 的第一个参数是输入数据本身，必须把包内容拷进缓冲区；
    // 直接 new ArrayBuffer(len) 得到的是全零缓冲，压缩出来的是零字节流。
    const buffer = new ArrayBuffer(sourceBytes.byteLength);
    new Uint8Array(buffer).set(sourceBytes);
    const written = await gzip.gzwrite(buffer, sourceBytes.byteLength);
    if (written !== sourceBytes.byteLength) {
      throw new Error('分享口令压缩失败');
    }
    const closeStatus = await gzip.gzclose();
    opened = false;
    if (closeStatus !== zlib.ReturnStatus.OK) {
      throw new Error('分享口令压缩收尾失败');
    }
    const compressed = readTempFile(tempPath);
    if (compressed.byteLength === 0) {
      throw new Error('分享口令压缩结果为空');
    }
    return SHARE_PREFIX + encodeBase64UrlNoPad(compressed);
  } finally {
    if (opened) {
      try {
        await gzip.gzclose();
      } catch (e) {
        // 关闭失败不覆盖原始错误
      }
    }
    removeTempFile(tempPath);
  }
}