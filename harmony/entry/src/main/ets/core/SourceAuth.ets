/**
 * P5：host.auth 登录凭据槽（filesDir 落盘）。
 *
 * 前端在登录 / 退出 / 切线路时经 Bridge.sourceSetAuthToken 推送；
 * 自定义线路（用户手输域名）由前端负责推空串——对齐 RFC 0001
 * 「未登录或不可信线路时为 null」。落盘是为了让 QuickJS 会话与
 * EntryAbility 启动自检都能读到当前值。token 只在应用沙箱内流转，
 * 任何日志都不得输出 token 本身。
 */
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

interface SourceAuthFile {
  token: string;
}

const AUTH_FILE: string = 'source_auth.json';

export function loadSourceAuthToken(filesDir: string): string {
  try {
    const path: string = filesDir + '/' + AUTH_FILE;
    const stat = fileIo.statSync(path);
    const buffer = new ArrayBuffer(stat.size);
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    fileIo.readSync(file.fd, buffer);
    fileIo.closeSync(file.fd);
    const text: string = new util.TextDecoder().decode(new Uint8Array(buffer));
    const parsed = JSON.parse(text) as SourceAuthFile;
    return typeof parsed.token === 'string' ? parsed.token : '';
  } catch (err) {
    return '';
  }
}

export function saveSourceAuthToken(filesDir: string, token: string): void {
  const path: string = filesDir + '/' + AUTH_FILE;
  const payload: SourceAuthFile = { token: token };
  const text: string = JSON.stringify(payload);
  const bytes = new util.TextEncoder().encodeInto(text);
  const buffer = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buffer).set(bytes);
  const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  fileIo.writeSync(file.fd, buffer);
  fileIo.closeSync(file.fd);
}
