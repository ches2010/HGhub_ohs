/**
 * 鸿蒙版播放诊断日志。
 *
 * 设计与桌面版 `src-tauri/src/playback_log.rs` 对齐：
 * - 默认关闭；开启后写入应用沙箱 filesDir。
 * - 只保存前端送来并已脱敏的 JSONL 行；不保存播放直链、token 或响应体。
 * - 日志按 2 MiB 轮转，导出最多 256 KiB，保留最近事件。
 */
import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';

const MAX_FILE: number = 2 * 1024 * 1024;
const MAX_EXPORT: number = 256 * 1024;

export interface PlaybackStatus {
  enabled: boolean;
  path: string;
  error: string;
}

export class PlaybackLog {
  private dir: string;
  private enabled: boolean = false;
  private error: string = '';
  private seq: number = 0;

  constructor(filesDir: string) {
    this.dir = filesDir.endsWith('/') ? filesDir.substring(0, filesDir.length - 1) : filesDir;
    this.bind();
  }

  private logPath(): string {
    return `${this.dir}/playback.log`;
  }

  private previousPath(): string {
    return `${this.dir}/playback.previous.log`;
  }

  private statePath(): string {
    return `${this.dir}/playback-diagnostics.json`;
  }

  private exists(path: string): boolean {
    try {
      fs.statSync(path);
      return true;
    } catch (e) {
      return false;
    }
  }

  private fileSize(path: string): number {
    try {
      return fs.statSync(path).size;
    } catch (e) {
      return 0;
    }
  }

  private readFile(path: string): string | null {
    try {
      return fs.readTextSync(path);
    } catch (e) {
      return null;
    }
  }

  private removeFile(path: string): void {
    try {
      fs.unlinkSync(path);
    } catch (e) {
      // 缺失或不可删除都不是诊断失败的主因
    }
  }

  private writeFile(path: string, text: string): void {
    this.removeFile(path);
    this.appendRaw(path, text, Number.MAX_SAFE_INTEGER);
  }

  private appendRaw(path: string, line: string, limit: number): void {
    if (this.fileSize(path) + line.length + 1 > limit) {
      if (this.exists(this.previousPath())) {
        this.removeFile(this.previousPath());
      }
      if (this.exists(path)) {
        fs.renameSync(path, this.previousPath());
      }
    }
    const file = fs.openSync(
      path,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND
    );
    try {
      fs.writeSync(file.fd, `${line}\n`);
    } finally {
      fs.closeSync(file);
    }
  }

  private appendEvent(event: string, dataJson: string): void {
    this.seq += 1;
    const line = JSON.stringify({
      ts: new Date().toISOString(),
      pid: 0,
      seq: this.seq,
      event: event,
      strict: true,
      data: JSON.parse(dataJson) as Object
    });
    try {
      this.appendRaw(this.logPath(), line, MAX_FILE);
      this.error = '';
    } catch (e) {
      this.error = '无法写入诊断日志';
    }
  }

  private bind(): void {
    this.enabled = false;
    const state = this.readFile(this.statePath());
    if (state !== null && state.includes('"enabled":true')) {
      this.enabled = true;
    }
    if (this.enabled) {
      this.appendEvent('process.start', JSON.stringify({ os: 'HarmonyOS' }));
    }
  }

  status(): PlaybackStatus {
    return {
      enabled: this.enabled,
      path: this.logPath(),
      error: this.error
    };
  }

  setEnabled(on: boolean): PlaybackStatus {
    if (on) {
      this.appendRaw(this.logPath(), '', MAX_FILE);
    }
    this.writeFile(this.statePath(), JSON.stringify({ enabled: on }));
    this.enabled = on;
    this.error = '';
    this.appendEvent('diagnostics.toggle', JSON.stringify({ enabled: on, os: 'HarmonyOS' }));
    return this.status();
  }

  appendLines(linesJson: string): void {
    if (!this.enabled) {
      return;
    }
    let parsed: Object = JSON.parse(linesJson) as Object;
    if (!Array.isArray(parsed)) {
      throw new Error('日志批次无效');
    }
    const lines = parsed as string[];
    if (lines.length > 128) {
      throw new Error('日志批次过大');
    }
    for (const line of lines) {
      if (typeof line !== 'string' || line.length === 0 || line.length > 16384) {
        throw new Error('日志条目无效');
      }
      this.appendRaw(this.logPath(), line, MAX_FILE);
    }
    this.error = '';
  }

  export(host: string): string {
    const body: string[] = [];
    for (const path of [this.previousPath(), this.logPath()]) {
      if (!this.exists(path)) {
        continue;
      }
      if (this.fileSize(path) > MAX_FILE + 16384) {
        throw new Error('日志文件超出大小限制');
      }
      const raw = this.readFile(path);
      if (raw !== null) {
        for (const line of raw.split(/\r?\n/)) {
          if (line.length > 0) {
            body.push(line);
          }
        }
      }
    }
    this.seq += 1;
    const header = JSON.stringify({
      ts: new Date().toISOString(),
      pid: 0,
      seq: this.seq,
      event: 'diagnostics.env',
      strict: true,
      data: { os: 'HarmonyOS', line: host }
    });
    let text = `${header}\n`;
    const total = body.reduce((sum: number, line: string) => sum + line.length + 1, 0);
    if (total > MAX_EXPORT) {
      const note = JSON.stringify({
        event: 'log.truncated',
        data: { total_bytes: total, kept_bytes: MAX_EXPORT }
      });
      text += `${note}\n`;
      let used = note.length + 1;
      let start = body.length;
      while (start > 0 && used + body[start - 1].length + 1 <= MAX_EXPORT) {
        used += body[start - 1].length + 1;
        start -= 1;
      }
      for (const line of body.slice(start)) {
        text += `${line}\n`;
      }
    } else {
      for (const line of body) {
        text += `${line}\n`;
      }
    }
    return text;
  }
}
