import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import quickjsSpike from 'libquickjs_spike.so';
import { SourceHostContext, SourceHostInfo, SourceHostSession, hostPrelude } from './SourceHost';

const TAG: string = 'HGhubX';
const SOURCE_ROOT = 'sources';
export const DEMO_ID: string = 'com.hghubx.demo-offline';
const MAX_STORAGE_KEYS = 64;
const MAX_STORAGE_VALUE_BYTES = 32 * 1024;
const MAX_ORIGINS = 16;
const SOURCE_TIMEOUT_MS = 12000;
const MAX_HTML_BYTES = 2 * 1024 * 1024;
const MAX_RESPONSE_BYTES = 2 * 1024 * 1024;

export interface SourceRuntime {
  kind: string;
  entry: string;
}

export interface SourceNetwork {
  origins: string[];
  mediaOrigins: string[];
  publishOrigins: string[];
}

export interface SourceCapabilities {
  home?: boolean;
  search?: boolean;
  catalog?: Object;
  detail?: Object;
  playback?: Object;
  posts?: boolean;
  account?: boolean;
  lines?: boolean;
}

export interface SourceManifest {
  schemaVersion: number;
  id: string;
  name: string;
  version: string;
  apiVersion: string;
  runtime: SourceRuntime;
  capabilities?: SourceCapabilities;
  network?: SourceNetwork;
  updateUrls?: string[];
}

export interface SourceDescriptor {
  id: string;
  name: string;
  version: string;
  trusted: boolean;
  updatedAt: number;
}

export interface SourceActive {
  activeId: string | null;
  previousId: string | null;
  updatedAt: number;
}

export interface SourceState {
  runtime: string;
  pilot: boolean;
  activeId: string | null;
  previousId: string | null;
  installed: SourceDescriptor[];
}

export interface SourceUpdateResult {
  updated: string;
  reason: string;
}

/**
 * P2/P3a pilot source package store.
 *
 * P3a 落实上游 source contract 的 host 原语和安全边界：
 * - QuickJS 原生线程只拿到内存/栈/中断超时和通用 host 桥；
 * - host.fetch 白名单、HTML 只读查询、crypto、per-source storage 都在 ArkTS 侧；
 * - 内置 offline demo 仍是唯一信任源。
 *
 * P3b 仍未做：非信任包导入、Ed25519 验签、分享口令、updateUrls 真实更新检查。
 */
export class SourceManager {
  private context: common.UIAbilityContext;
  private root: string;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.root = context.filesDir + '/' + SOURCE_ROOT;
  }

  state(): SourceState {
    const active = this.readActive();
    const installed = this.readIndex();
    return {
      runtime: 'quickjs',
      pilot: true,
      activeId: active.activeId,
      previousId: active.previousId,
      installed: installed
    };
  }

  importDemo(): Promise<void> {
    return Promise.all([
      this.readRawFile('quickjs/demo-offline/manifest.json'),
      this.readRawFile('quickjs/demo-offline/source.js')
    ]).then((values: string[]) => {
      this.importTrusted(values[0], values[1], true);
    });
  }

  importTrusted(manifestText: string, sourceText: string, trusted: boolean): SourceDescriptor {
    const manifest = this.parseManifest(manifestText);
    if (sourceText.trim().length === 0) {
      throw new Error('source.js is empty');
    }
    const dir = this.packageDir(manifest.id);
    this.ensureDir(dir);
    this.writeText(dir + '/manifest.json', manifestText);
    this.writeText(dir + '/source.js', sourceText);

    const descriptor: SourceDescriptor = {
      id: manifest.id,
      name: manifest.name,
      version: manifest.version,
      trusted: trusted,
      updatedAt: Date.now()
    };
    const index = this.readIndex();
    let replaced = false;
    for (let i = 0; i < index.length; i++) {
      if (index[i].id === descriptor.id) {
        index[i] = descriptor;
        replaced = true;
        break;
      }
    }
    if (!replaced) {
      index.push(descriptor);
    }
    this.writeIndex(index);
    hilog.info(0x0000, TAG, 'source import ok id=%{public}s trusted=%{public}s', descriptor.id, String(trusted));
    return descriptor;
  }

  activate(id: string): SourceState {
    if (!this.validId(id)) {
      throw new Error('invalid source id');
    }
    if (!this.installedContains(id)) {
      throw new Error('source not installed');
    }
    const active = this.readActive();
    if (active.activeId === id) {
      return this.state();
    }
    const next: SourceActive = {
      activeId: id,
      previousId: active.activeId,
      updatedAt: Date.now()
    };
    this.writeActive(next);
    hilog.info(0x0000, TAG, 'source activate ok id=%{public}s previous=%{public}s', id, String(next.previousId));
    return this.state();
  }

  rollback(): SourceState {
    const active = this.readActive();
    if (active.previousId === null || active.previousId.length === 0) {
      throw new Error('no previous source to roll back');
    }
    if (!this.installedContains(active.previousId)) {
      throw new Error('previous source is not installed');
    }
    const next: SourceActive = {
      activeId: active.previousId,
      previousId: null,
      updatedAt: Date.now()
    };
    this.writeActive(next);
    hilog.info(0x0000, TAG, 'source rollback ok id=%{public}s', String(next.activeId));
    return this.state();
  }

  remove(id: string): SourceState {
    if (!this.validId(id)) {
      throw new Error('invalid source id');
    }
    const active = this.readActive();
    if (active.activeId === id) {
      throw new Error('cannot remove active source');
    }
    if (!this.installedContains(id)) {
      throw new Error('source not installed');
    }
    const dir = this.packageDir(id);
    this.removeFile(dir + '/manifest.json');
    this.removeFile(dir + '/source.js');
    this.removeFile(dir + '/storage.json');
    try {
      fileIo.rmdirSync(dir);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'source dir remove failed id=%{public}s', id);
    }
    let index = this.readIndex();
    index = index.filter((item: SourceDescriptor) => item.id !== id);
    this.writeIndex(index);
    if (active.previousId === id) {
      this.writeActive({ activeId: active.activeId, previousId: null, updatedAt: Date.now() });
    }
    hilog.info(0x0000, TAG, 'source remove ok id=%{public}s', id);
    return this.state();
  }

  test(id: string): Promise<string> {
    if (!this.validId(id)) {
      return Promise.reject(new Error('invalid source id'));
    }
    const manifestPath = this.packageDir(id) + '/manifest.json';
    const sourcePath = this.packageDir(id) + '/source.js';
    if (!this.exists(manifestPath) || !this.exists(sourcePath)) {
      return Promise.reject(new Error('source package is not installed'));
    }
    const manifest = this.parseManifest(this.readText(manifestPath));
    const sourceText = this.readText(sourcePath);
    const context = this.hostContext(manifest);
    const script = [
      hostPrelude(),
      'var __manifest = ' + JSON.stringify(manifest) + ';',
      'var module = { exports: {} };',
      'var exports = module.exports;',
      sourceText,
      "var required = ['init', 'home', 'search', 'tags', 'hotTags', 'tagVideos', 'detail', 'playback'];",
      "for (var i = 0; i < required.length; i++) { if (typeof module.exports[required[i]] !== 'function') { throw new Error('missing source export: ' + required[i]); } }",
      'var __out = {',
      '  id: __manifest.id,',
      '  init: module.exports.init(),',
      '  home: module.exports.home({ page: 1, size: 2 }),',
      '  detail: module.exports.detail({ id: 90001 }),',
      '  playback: module.exports.playback({ id: 90001, ep: 1 })',
      '};',
      'JSON.stringify(__out);'
    ].join('\n');
    const session = new SourceHostSession(context, this);
    return quickjsSpike
      .evaluateAsync(script, (requestId: number, request: string): void => {
        this.dispatchHost(session, requestId, request);
      }, JSON.stringify(context))
      .then((result: string) => {
        session.close();
        return result;
      })
      .catch((err: Error) => {
        session.close();
        throw err;
      });
  }

  checkUpdate(id: string): SourceUpdateResult {
    if (!this.validId(id)) {
      const invalid: SourceUpdateResult = { updated: 'false', reason: 'invalid source id' };
      return invalid;
    }
    const manifestPath = this.packageDir(id) + '/manifest.json';
    if (!this.exists(manifestPath)) {
      const missing: SourceUpdateResult = { updated: 'false', reason: 'source not installed' };
      return missing;
    }
    const manifest = this.parseManifest(this.readText(manifestPath));
    const updateUrls = manifest.updateUrls;
    if (updateUrls === undefined || !Array.isArray(updateUrls) || updateUrls.length === 0) {
      const noUrls: SourceUpdateResult = { updated: 'false', reason: 'no update urls' };
      return noUrls;
    }
    const disabled: SourceUpdateResult = { updated: 'false', reason: 'pilot update check disabled (P3b)' };
    return disabled;
  }

  async hostPilotCheck(): Promise<string> {
    const info: SourceHostInfo = {
      sourceId: DEMO_ID,
      name: '离线示例源',
      version: '1.0.0',
      baseUrl: '',
      origins: [],
      mediaOrigins: [],
      publishOrigins: [],
      limits: {
        maxHtmlBytes: MAX_HTML_BYTES,
        maxResponseBytes: MAX_RESPONSE_BYTES,
        timeoutMs: SOURCE_TIMEOUT_MS
      }
    };
    const context: SourceHostContext = { sourceId: DEMO_ID, info: info, allowedOrigins: [] };
    const session = new SourceHostSession(context, this);
    const script = [
      hostPrelude(),
      'var out = {',
      '  info: host.info.sourceId,',
      '  sha256: host.crypto.sha256Hex("p3a"),',
      '  random: host.crypto.randomBytes(8).b64url,',
      '  base64: host.crypto.base64Encode("hghubx").b64,',
      '  base64Text: host.crypto.base64Decode(host.crypto.base64Encode("hghubx").b64),',
      '  hmac: host.crypto.hmacSha256({ keyB64: host.crypto.randomBytes(16).b64, dataUtf8: "p3a" }).hex,',
      '  htmlItems: host.htmlQuery("<ul><li class=\\"a\\">A</li><li class=\\"b\\">B</li></ul>", "li.a").length,',
      '  insecureBlocked: false,',
      '  privateBlocked: false,',
      '  originBlocked: false',
      '};',
      'try { host.fetch({ url: "http://example.com/" }); } catch (e) { out.insecureBlocked = true; }',
      'try { host.fetch({ url: "https://127.0.0.1/x" }); } catch (e) { out.privateBlocked = true; }',
      'try { host.fetch({ url: "https://example.com/x" }); } catch (e) { out.originBlocked = true; }',
      'host.storage.set("p3a-host", "ok");',
      'out.storage = host.storage.get("p3a-host");',
      'var a = host.crypto.ecdhP256Create();',
      'var b = host.crypto.ecdhP256Create();',
      'var ka = host.crypto.ecdhP256Derive(a.handle, b.publicKeyB64Url, "", ["p3a"]);',
      'var kb = host.crypto.ecdhP256Derive(b.handle, a.publicKeyB64Url, "", ["p3a"]);',
      'out.ecdh = ka.length === 1 && kb.length === 1 && ka[0] === kb[0];',
      'var aesKey = host.crypto.randomBytes(32).b64;',
      'var nonce = host.crypto.randomBytes(12).b64;',
      'var sealed = host.crypto.aes256GcmEncrypt({ keyB64: aesKey, nonceB64: nonce, plaintextUtf8: "p3a-host", aadUtf8: "hghubx" });',
      'var opened = host.crypto.aes256GcmDecrypt({ keyB64: aesKey, nonceB64: nonce, ciphertextB64Url: sealed.ciphertextB64Url, aadUtf8: "hghubx" });',
      'out.aesGcm = opened.plaintextUtf8 === "p3a-host";',
      'JSON.stringify(out);'
    ].join('\n');
    try {
      return await quickjsSpike.evaluateAsync(script, (requestId: number, request: string): void => {
        this.dispatchHost(session, requestId, request);
      }, JSON.stringify(context));
    } finally {
      session.close();
    }
  }

  storageGet(sourceId: string, key: string): string | null {
    if (!this.validId(sourceId) || key.length === 0 || key.length > 128) {
      return null;
    }
    const path = this.packageDir(sourceId) + '/storage.json';
    if (!this.exists(path)) {
      return null;
    }
    try {
      const map = JSON.parse(this.readText(path)) as Record<string, string>;
      return map[key] !== undefined ? map[key] : null;
    } catch (e) {
      return null;
    }
  }

  storageSet(sourceId: string, key: string, value: string | null): void {
    if (!this.validId(sourceId) || key.length === 0 || key.length > 128) {
      throw new Error('invalid source storage key');
    }
    const map = this.readStorageMap(sourceId);
    if (value === null) {
      if (map[key] === undefined) {
        return;
      }
      delete map[key];
      this.writeStorageMap(sourceId, map);
      return;
    }
    if (byteLength(value) > MAX_STORAGE_VALUE_BYTES) {
      throw new Error('source storage value exceeds 32 KB');
    }
    if (map[key] === undefined && Object.keys(map).length >= MAX_STORAGE_KEYS) {
      throw new Error('source storage key limit exceeded');
    }
    map[key] = value;
    this.writeStorageMap(sourceId, map);
  }

  private dispatchHost(session: SourceHostSession, id: number, request: string): void {
    session.handle(request).then((response: string) => {
      quickjsSpike.resolveHost(id, response);
    }).catch((err: Error) => {
      quickjsSpike.resolveHost(id, JSON.stringify({ __hostError: err.message }));
    });
  }

  private hostContext(manifest: SourceManifest): SourceHostContext {
    const network = this.manifestNetwork(manifest);
    const info: SourceHostInfo = {
      sourceId: manifest.id,
      name: manifest.name,
      version: manifest.version,
      baseUrl: network.origins.length > 0 ? network.origins[0] : '',
      origins: network.origins,
      mediaOrigins: network.mediaOrigins,
      publishOrigins: network.publishOrigins,
      limits: {
        maxHtmlBytes: MAX_HTML_BYTES,
        maxResponseBytes: MAX_RESPONSE_BYTES,
        timeoutMs: SOURCE_TIMEOUT_MS
      }
    };
    return {
      sourceId: manifest.id,
      info: info,
      allowedOrigins: uniqueStrings(network.origins.concat(network.publishOrigins), MAX_ORIGINS)
    };
  }

  private manifestNetwork(manifest: SourceManifest): SourceNetwork {
    const raw = manifest.network;
    return {
      origins: stringArray(raw !== undefined ? raw.origins : undefined, MAX_ORIGINS),
      mediaOrigins: stringArray(raw !== undefined ? raw.mediaOrigins : undefined, MAX_ORIGINS),
      publishOrigins: stringArray(raw !== undefined ? raw.publishOrigins : undefined, MAX_ORIGINS)
    };
  }

  private parseManifest(text: string): SourceManifest {
    const manifest = JSON.parse(text) as SourceManifest;
    if (manifest.schemaVersion !== 1) {
      throw new Error('manifest schemaVersion must be 1');
    }
    if (!this.validId(manifest.id)) {
      throw new Error('manifest id is invalid');
    }
    if (manifest.name.length === 0 || manifest.version.length === 0) {
      throw new Error('manifest name/version is required');
    }
    if (manifest.apiVersion !== '1') {
      throw new Error('manifest apiVersion must be 1');
    }
    if (manifest.runtime === undefined || manifest.runtime.kind !== 'quickjs' || manifest.runtime.entry !== 'source.js') {
      throw new Error('manifest runtime must be quickjs/source.js');
    }
    if (manifest.capabilities === undefined) {
      throw new Error('manifest capabilities is required');
    }
    const network = this.manifestNetwork(manifest);
    if (network.origins.length + network.mediaOrigins.length + network.publishOrigins.length > MAX_ORIGINS) {
      throw new Error('manifest network origins exceed the limit');
    }
    return manifest;
  }

  private validId(id: string): boolean {
    return id.length > 0 && id.length <= 128 && /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id) && id.indexOf('..') < 0;
  }

  private packageDir(id: string): string {
    return this.root + '/' + id;
  }

  private installedContains(id: string): boolean {
    const index = this.readIndex();
    for (const item of index) {
      if (item.id === id) {
        return true;
      }
    }
    return false;
  }

  private readIndex(): SourceDescriptor[] {
    const path = this.root + '/installed.json';
    if (!this.exists(path)) {
      return [];
    }
    try {
      return JSON.parse(this.readText(path)) as SourceDescriptor[];
    } catch (e) {
      return [];
    }
  }

  private writeIndex(index: SourceDescriptor[]): void {
    this.ensureDir(this.root);
    this.writeText(this.root + '/installed.json', JSON.stringify(index));
  }

  private readActive(): SourceActive {
    const path = this.root + '/active.json';
    if (!this.exists(path)) {
      return { activeId: null, previousId: null, updatedAt: 0 };
    }
    try {
      return JSON.parse(this.readText(path)) as SourceActive;
    } catch (e) {
      return { activeId: null, previousId: null, updatedAt: 0 };
    }
  }

  private writeActive(active: SourceActive): void {
    this.ensureDir(this.root);
    this.writeText(this.root + '/active.json', JSON.stringify(active));
  }

  private readStorageMap(sourceId: string): Record<string, string> {
    const path = this.packageDir(sourceId) + '/storage.json';
    if (!this.exists(path)) {
      return {};
    }
    try {
      return JSON.parse(this.readText(path)) as Record<string, string>;
    } catch (e) {
      return {};
    }
  }

  private writeStorageMap(sourceId: string, map: Record<string, string>): void {
    const dir = this.packageDir(sourceId);
    this.ensureDir(dir);
    this.writeText(dir + '/storage.json', JSON.stringify(map));
  }

  private readRawFile(name: string): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      this.context.resourceManager.getRawFileContent(name, (err: BusinessError, data: Uint8Array) => {
        if (err !== undefined && err !== null) {
          reject(err);
          return;
        }
        try {
          resolve(new util.TextDecoder().decode(data));
        } catch (e) {
          reject(e as Error);
        }
      });
    });
  }

  private ensureDir(path: string): void {
    if (!this.exists(path)) {
      fileIo.mkdirSync(path, true);
    }
  }

  private exists(path: string): boolean {
    try {
      fileIo.statSync(path);
      return true;
    } catch (e) {
      return false;
    }
  }

  private readText(path: string): string {
    const stat = fileIo.statSync(path);
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    const buffer = new ArrayBuffer(stat.size);
    fileIo.readSync(file.fd, buffer);
    fileIo.closeSync(file.fd);
    return new util.TextDecoder().decode(new Uint8Array(buffer));
  }

  private writeText(path: string, text: string): void {
    const encoded = new util.TextEncoder().encodeInto(text);
    const buffer = new ArrayBuffer(encoded.byteLength);
    new Uint8Array(buffer).set(encoded);
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, buffer);
    fileIo.closeSync(file.fd);
  }

  private removeFile(path: string): void {
    if (this.exists(path)) {
      fileIo.unlinkSync(path);
    }
  }
}

function stringArray(value: Object | undefined, max: number): string[] {
  const out: string[] = [];
  if (value === undefined || value === null || !Array.isArray(value)) {
    return out;
  }
  const raw = value as string[];
  for (const item of raw) {
    if (typeof item === 'string' && item.length > 0) {
      out.push(item);
    }
    if (out.length >= max) {
      break;
    }
  }
  return out;
}

function uniqueStrings(values: string[], max: number): string[] {
  const out: string[] = [];
  for (const value of values) {
    let found = false;
    for (const item of out) {
      if (item === value) {
        found = true;
        break;
      }
    }
    if (!found) {
      out.push(value);
    }
    if (out.length >= max) {
      break;
    }
  }
  return out;
}

function byteLength(text: string): number {
  return new util.TextEncoder().encodeInto(text).byteLength;
}
