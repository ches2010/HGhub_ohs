import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { httpRequest } from './Http';
import quickjsSpike from 'libquickjs_spike.so';
import { SourceHostContext, SourceHostInfo, SourceHostSession, hostPrelude, isPublicHttpsUrl } from './SourceHost';
import { canonicalPayload, SourceSignatureInfo, verifyPackage, VerifiablePackage, VerifyImageDecrypt, VerifyManifest, VerifyMedia, VerifyNetwork, VerifyRuntime, VerifySignature } from './SourceVerify';
import { decodeShareCode, encodeShareCode } from './SourceShare';

const TAG: string = 'HGhubX';
const SOURCE_ROOT = 'sources';
export const DEMO_ID: string = 'com.hghubx.demo-offline';
const MAX_STORAGE_KEYS = 64;
const MAX_VERSION_BACKUPS = 5;
const MAX_STORAGE_VALUE_BYTES = 32 * 1024;
const MAX_ORIGINS = 16;
const MAX_UPDATE_URLS = 8;
const MAX_PACKAGE_BYTES = 512 * 1024;
const MAX_CODE_BYTES = 256 * 1024;
const SOURCE_TIMEOUT_MS = 12000;
const MAX_HTML_BYTES = 2 * 1024 * 1024;
const MAX_RESPONSE_BYTES = 2 * 1024 * 1024;

export interface SourceRuntime extends VerifyRuntime {
}

export interface SourceNetwork extends VerifyNetwork {
}

export interface SourceCatalogCapabilities {
  categories?: boolean;
  tags?: boolean;
  rankings?: boolean;
  authors?: boolean;
}

export interface SourceDetailCapabilities {
  episodes?: boolean;
  related?: boolean;
  comments?: boolean;
}

export interface SourcePlaybackCapabilities {
  hls?: boolean;
  mp4?: boolean;
  subtitles?: boolean;
}

export interface SourceCapabilities {
  home?: boolean;
  search?: boolean;
  catalog?: SourceCatalogCapabilities;
  detail?: SourceDetailCapabilities;
  playback?: SourcePlaybackCapabilities;
  posts?: boolean;
  account?: boolean;
  lines?: boolean;
}

export interface SourceImageDecrypt extends VerifyImageDecrypt {
}

export interface SourceMedia extends VerifyMedia {
  imageDecrypt?: SourceImageDecrypt;
}

export interface SourceManifest extends VerifyManifest {
  schemaVersion: number;
  name: string;
  description?: string;
  author?: string;
  capabilities?: SourceCapabilities;
  catalog?: Object;
  links?: Object;
  updateUrls?: string[];
}

export interface SourceSignature extends VerifySignature {
}

export interface SourcePackage extends VerifiablePackage {
  schemaVersion: number;
  manifest: SourceManifest;
  signature?: SourceSignature;
}

export interface SourceDescriptor {
  id: string;
  name: string;
  version: string;
  trusted: boolean;
  updatedAt: number;
  signatureStatus?: string;
  signatureKeyId?: string;
  signatureFingerprint?: string;
  versions: string[];
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
  allowUntrusted: boolean;
  installed: SourceDescriptor[];
}

export interface SourceUpdateResult {
  updated: string;
  reason: string;
  fromVersion?: string;
  toVersion?: string;
}

interface SourceSettings {
  allowUntrusted: boolean;
}

interface Semver {
  major: number;
  minor: number;
  patch: number;
}

/**
 * P3b source package store.
 *
 * 包格式对齐上游 SourcePackage：{schemaVersion, manifest, code, updateUrls, signature?}。
 * 签名包必须通过 Ed25519 验签；无签名 / 自签包受 allowUntrusted 控制。
 * 导入和 updateUrls 更新都会先在 QuickJS 里跑 init()，通过后才落盘。
 */
export class SourceManager {
  private context: common.UIAbilityContext;
  private root: string;
  private allowUntrusted: boolean = true;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.root = context.filesDir + '/' + SOURCE_ROOT;
    this.allowUntrusted = this.readSettings().allowUntrusted;
  }

  state(): SourceState {
    const active = this.readActive();
    const installed = this.readIndex();
    // P8：老版本 installed.json 没有 versions 字段，补空数组避免前端 undefined
    for (const item of installed) {
      if (!Array.isArray(item.versions)) {
        item.versions = [];
      }
    }
    return {
      runtime: 'quickjs',
      pilot: true,
      activeId: active.activeId,
      previousId: active.previousId,
      allowUntrusted: this.allowUntrusted,
      installed: installed
    };
  }

  setAllowUntrusted(allow: boolean): SourceState {
    this.allowUntrusted = allow;
    const settings: SourceSettings = { allowUntrusted: allow };
    this.ensureDir(this.root);
    this.writeText(this.root + '/settings.json', JSON.stringify(settings));
    return this.state();
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
    const pkg = this.packageFromManifest(manifest, sourceText);
    const signature: SourceSignatureInfo = {
      status: trusted ? 'trusted' : 'unsigned',
      keyId: '',
      fingerprint: ''
    };
    return this.installPackage(pkg, signature, trusted, false);
  }

  async importInput(input: string, activate: boolean): Promise<SourceDescriptor> {
    const raw = await this.resolveInput(input);
    const pkg = await this.decodePackageInput(raw);
    this.validatePackage(pkg);
    const signature = verifyPackage(pkg);
    if (!this.allowUntrusted && signature.status !== 'trusted') {
      throw new Error('当前未允许导入未受信任视频源');
    }
    await this.smokeTestPackage(pkg);
    return this.installPackage(pkg, signature, signature.status === 'trusted', activate);
  }

  async exportShareCode(id: string): Promise<string> {
    const pkg = this.readPackage(id);
    return encodeShareCode(JSON.stringify(pkg), this.context.cacheDir);
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
    this.removeFile(dir + '/package.json');
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
    let pkg: SourcePackage;
    try {
      pkg = this.readPackage(id);
    } catch (err) {
      return Promise.reject(err as Error);
    }
    return this.testPackage(pkg);
  }

  async checkUpdate(id: string): Promise<SourceUpdateResult> {
    if (!this.validId(id)) {
      return { updated: 'false', reason: 'invalid source id' };
    }
    let current: SourcePackage;
    try {
      current = this.readPackage(id);
    } catch (err) {
      return { updated: 'false', reason: 'source not installed' };
    }
    const urls = current.updateUrls;
    if (urls.length === 0) {
      return { updated: 'false', reason: 'no update urls' };
    }
    const fromVersion = current.manifest.version;
    let lastError = '所有更新链接均不可用';
    for (const url of urls) {
      try {
        const raw = await this.fetchRemoteText(url);
        const candidate = await this.decodePackageInput(raw);
        if (candidate.manifest.id !== id) {
          lastError = '远程视频源 id 与当前源不一致，已拒绝覆盖';
          continue;
        }
        this.validatePackage(candidate);
        const signature = verifyPackage(candidate);
        if (!this.allowUntrusted && signature.status !== 'trusted') {
          lastError = '当前未允许导入未受信任视频源';
          continue;
        }
        if (!this.isNewerVersion(candidate.manifest.version, fromVersion)) {
          return {
            updated: 'false',
            reason: 'no newer version',
            fromVersion: fromVersion,
            toVersion: fromVersion
          };
        }
        await this.smokeTestPackage(candidate);
        this.installPackage(candidate, signature, signature.status === 'trusted', false);
        return {
          updated: 'true',
          reason: 'updated',
          fromVersion: fromVersion,
          toVersion: candidate.manifest.version
        };
      } catch (err) {
        lastError = err instanceof Error ? err.message : String(err);
      }
    }
    return {
      updated: 'false',
      reason: lastError,
      fromVersion: fromVersion,
      toVersion: fromVersion
    };
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

  async packagePilotCheck(): Promise<string> {
    const packageText = await this.readRawFile('quickjs/p3b-signed/package.json');
    const shareText = await this.readRawFile('quickjs/p3b-signed/share.txt');
    const pkg = JSON.parse(packageText) as SourcePackage;
    this.validatePackage(pkg);
    const signature = verifyPackage(pkg);
    const shareJson = await decodeShareCode(shareText.trim(), this.context.cacheDir);
    const shared = JSON.parse(shareJson) as SourcePackage;
    const shareOk = canonicalPayload(pkg) === canonicalPayload(shared);
    let tamperRejected = false;
    try {
      const tamperedText = await this.readRawFile('quickjs/p3b-signed/tampered.json');
      const tampered = JSON.parse(tamperedText) as SourcePackage;
      verifyPackage(tampered);
    } catch (err) {
      tamperRejected = true;
    }
    const result: Record<string, Object> = {};
    result['id'] = pkg.manifest.id;
    result['sigStatus'] = signature.status;
    result['keyId'] = signature.keyId;
    result['fingerprint'] = signature.fingerprint;
    result['shareOk'] = shareOk;
    result['tamperRejected'] = tamperRejected;
    return JSON.stringify(result);
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
      const next: Record<string, string> = {};
      const keys = Object.keys(map);
      for (const item of keys) {
        if (item !== key) {
          next[item] = map[item];
        }
      }
      this.writeStorageMap(sourceId, next);
      return;
    }
    if (textByteLength(value) > MAX_STORAGE_VALUE_BYTES) {
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

  private async resolveInput(input: string): Promise<string> {
    const trimmed = input.trim();
    if (trimmed.length === 0) {
      throw new Error('请输入视频源口令、JSON 内容或 HTTPS 链接');
    }
    if (trimmed.startsWith('hghubx-src://') || trimmed.startsWith('{')) {
      return trimmed;
    }
    const deepLink = this.parseDeepLink(trimmed);
    if (deepLink !== null) {
      return this.resolveInput(deepLink);
    }
    if (trimmed.startsWith('https://')) {
      return this.fetchRemoteText(trimmed);
    }
    if (trimmed.indexOf('.') > 0 && trimmed.indexOf(' ') < 0) {
      return this.fetchRemoteText('https://' + trimmed);
    }
    throw new Error('无法识别的格式：请粘贴 hghubx-src:// 口令、JSON 文本或 https:// 链接');
  }

  private parseDeepLink(raw: string): string | null {
    if (!raw.toLowerCase().startsWith('hghubx://')) {
      return null;
    }
    const query = raw.indexOf('?');
    if (query < 0) {
      return null;
    }
    const pairs = raw.substring(query + 1).split('&');
    for (const pair of pairs) {
      const eq = pair.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const key = pair.substring(0, eq);
      const value = pair.substring(eq + 1);
      if ((key === 'url' || key === 'src' || key === 'code') && value.length > 0) {
        return decodeURIComponent(value);
      }
    }
    return null;
  }

  private async fetchRemoteText(url: string): Promise<string> {
    if (!isPublicHttpsUrl(url)) {
      throw new Error('远程视频源必须是 HTTPS 公网地址');
    }
    const response = await httpRequest(url, 'GET', '{}', '', true, 15000);
    if (response.status < 200 || response.status >= 300) {
      throw new Error('拉取远程视频源失败（HTTP ' + response.status + '）');
    }
    const text = new util.TextDecoder().decode(new Uint8Array(response.bytes));
    if (textByteLength(text) > MAX_PACKAGE_BYTES) {
      throw new Error('远程视频源超出大小上限（最大 512 KB）');
    }
    return text;
  }

  private async decodePackageInput(raw: string): Promise<SourcePackage> {
    const trimmed = raw.trim();
    if (trimmed.startsWith('hghubx-src://')) {
      const json = await decodeShareCode(trimmed, this.context.cacheDir);
      return JSON.parse(json) as SourcePackage;
    }
    if (trimmed.startsWith('{')) {
      if (textByteLength(trimmed) > MAX_PACKAGE_BYTES) {
        throw new Error('视频源 JSON 超出大小上限（最大 512 KB）');
      }
      return JSON.parse(trimmed) as SourcePackage;
    }
    throw new Error('无法识别的视频源格式');
  }

  private validatePackage(pkg: SourcePackage): void {
    if (pkg.schemaVersion !== 1 || pkg.manifest.schemaVersion !== 1) {
      throw new Error('不支持的视频源格式版本');
    }
    if (pkg.manifest.apiVersion.trim() !== '1') {
      throw new Error('不兼容的视频源契约版本');
    }
    if (!this.validPackageId(pkg.manifest.id)) {
      throw new Error('视频源 id 无效：仅允许 3~96 位小写字母、数字、点、横杠或下划线');
    }
    const semver = this.parseSemver(pkg.manifest.version);
    if (semver === null || pkg.manifest.version.length > 32 ||
        pkg.manifest.version.indexOf('..') >= 0 ||
        pkg.manifest.version.indexOf('/') >= 0 ||
        pkg.manifest.version.indexOf('\\') >= 0) {
      throw new Error('视频源版本号必须符合语义化版本（如 1.0.0）');
    }
    const name = pkg.manifest.name.trim();
    if (name.length === 0 || name.length > 80 || name.indexOf('<') >= 0 || name.indexOf('>') >= 0) {
      throw new Error('视频源名称无效（不能为空、不超过 80 字符且不含 HTML 标签）');
    }
    if (pkg.manifest.runtime.kind !== 'quickjs') {
      throw new Error('不支持的运行环境：' + pkg.manifest.runtime.kind);
    }
    const entry = pkg.manifest.runtime.entry;
    if (entry !== 'inline' && entry !== 'source.js') {
      throw new Error('runtime.entry 必须是 inline 或 source.js');
    }
    if (entry.indexOf('..') >= 0 || entry.startsWith('/') || entry.startsWith('\\')) {
      throw new Error('runtime.entry 包含非法路径');
    }
    const caps = pkg.manifest.capabilities;
    if (caps === undefined || caps.search !== true || caps.detail === undefined || caps.detail.episodes !== true) {
      throw new Error('视频源缺少必选核心能力（需要 search、detail.episodes 与 playback）');
    }
    const playback = caps.playback;
    const hasPlayback = playback !== undefined && (playback.hls === true || playback.mp4 === true);
    const network = this.packageNetwork(pkg);
    const offlineDemo = network.origins.length === 0 && network.mediaOrigins.length === 0 && network.publishOrigins.length === 0;
    if (!hasPlayback && !offlineDemo) {
      throw new Error('视频源缺少必选核心能力（需要 search、detail.episodes 与 playback）');
    }
    if (pkg.code.trim().length === 0) {
      throw new Error('视频源脚本 code 不能为空');
    }
    if (textByteLength(pkg.code) > MAX_CODE_BYTES) {
      throw new Error('视频源脚本超出大小上限（最大 256 KB）');
    }
    this.validateOrigins('network.origins', network.origins, MAX_ORIGINS);
    this.validateOrigins('network.mediaOrigins', network.mediaOrigins, MAX_ORIGINS);
    this.validateOrigins('network.publishOrigins', network.publishOrigins, MAX_ORIGINS);
    this.validateOrigins('updateUrls', pkg.updateUrls, MAX_UPDATE_URLS);
  }

  private validateOrigins(label: string, values: string[], max: number): void {
    if (values.length > max) {
      throw new Error(label + ' 数量超出限制');
    }
    for (const value of values) {
      if (!isPublicHttpsUrl(value)) {
        throw new Error(label + ' 必须是 HTTPS 公网地址');
      }
    }
  }

  private async smokeTestPackage(pkg: SourcePackage): Promise<void> {
    const script = this.buildPackageScript(pkg, true);
    await this.runPackageScript(pkg, script);
  }

  private testPackage(pkg: SourcePackage): Promise<string> {
    return this.runPackageScript(pkg, this.buildPackageScript(pkg, false));
  }

  private buildPackageScript(pkg: SourcePackage, smokeOnly: boolean): string {
    const lines: string[] = [
      hostPrelude(),
      'var __manifest = ' + JSON.stringify(pkg.manifest) + ';',
      'var module = { exports: {} };',
      'var exports = module.exports;',
      pkg.code,
      "var required = ['init', 'home', 'search', 'tags', 'hotTags', 'tagVideos', 'detail', 'playback'];",
      "for (var i = 0; i < required.length; i++) { if (typeof module.exports[required[i]] !== 'function') { throw new Error('missing source export: ' + required[i]); } }"
    ];
    if (smokeOnly) {
      lines.push('JSON.stringify({ id: __manifest.id, init: module.exports.init({}) });');
    } else {
      lines.push('var __out = {');
      lines.push('  id: __manifest.id,');
      lines.push('  init: module.exports.init(),');
      lines.push('  home: module.exports.home({ page: 1, size: 2 }),');
      lines.push('  detail: module.exports.detail({ id: 90001 }),');
      lines.push('  playback: module.exports.playback({ id: 90001, ep: 1 })');
      lines.push('};');
      lines.push('JSON.stringify(__out);');
    }
    return lines.join('\n');
  }

  private runPackageScript(pkg: SourcePackage, script: string): Promise<string> {
    const context = this.hostContext(pkg.manifest);
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

  private installPackage(pkg: SourcePackage, signature: SourceSignatureInfo, trusted: boolean, activate: boolean): SourceDescriptor {
    const manifest = pkg.manifest;
    const network = this.packageNetwork(pkg);
    manifest.network = network;
    const dir = this.packageDir(manifest.id);
    this.ensureDir(dir);
    // P8：覆写前把当前版本备份为 versions/<version>.json，便于精确回滚。
    try {
      const currentPath = dir + '/package.json';
      if (this.exists(currentPath)) {
        const current = JSON.parse(this.readText(currentPath)) as SourcePackage;
        if (current.manifest !== undefined && current.manifest.version !== manifest.version) {
          this.backupVersion(dir, current.manifest.version, JSON.stringify(current));
        }
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'source version backup failed id=%{public}s', String(manifest.id));
    }
    this.writeText(dir + '/package.json', JSON.stringify(pkg));
    this.writeText(dir + '/manifest.json', JSON.stringify(manifest));
    this.writeText(dir + '/source.js', pkg.code);

    const descriptor: SourceDescriptor = {
      id: manifest.id,
      name: manifest.name,
      version: manifest.version,
      trusted: trusted,
      updatedAt: Date.now(),
      signatureStatus: signature.status,
      signatureKeyId: signature.keyId,
      signatureFingerprint: signature.fingerprint,
      versions: this.readVersions(manifest.id)
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
    if (activate) {
      const active = this.readActive();
      const next: SourceActive = {
        activeId: descriptor.id,
        previousId: active.activeId === descriptor.id ? active.previousId : active.activeId,
        updatedAt: Date.now()
      };
      this.writeActive(next);
    }
    hilog.info(0x0000, TAG, 'source install ok id=%{public}s version=%{public}s sig=%{public}s',
      descriptor.id, descriptor.version, signature.status);
    return descriptor;
  }

  private packageFromManifest(manifest: SourceManifest, code: string): SourcePackage {
    manifest.network = this.manifestNetwork(manifest);
    const updateUrls = manifest.updateUrls !== undefined ? stringArray(manifest.updateUrls, MAX_UPDATE_URLS) : [];
    const pkg: SourcePackage = {
      schemaVersion: 1,
      manifest: manifest,
      code: code,
      updateUrls: updateUrls
    };
    return pkg;
  }

  /**
   * P8：回滚到某个已备份版本（验收签 + init 冒烟，与导入同安全标准）。
   * 回滚后保留当前版本为备份，可再次切回。
   */
  async revertVersion(id: string, version: string): Promise<SourceState> {
    if (!this.validId(id) || !this.validVersion(version)) {
      throw new Error('invalid source id or version');
    }
    if (!this.installedContains(id)) {
      throw new Error('source not installed');
    }
    const path = this.packageDir(id) + '/versions/' + version + '.json';
    if (!this.exists(path)) {
      throw new Error('version backup not found');
    }
    const pkg = JSON.parse(this.readText(path)) as SourcePackage;
    const signature = verifyPackage(pkg);
    if (!this.allowUntrusted && signature.status !== 'trusted') {
      throw new Error('当前未允许导入未受信任视频源');
    }
    await this.smokeTestPackage(pkg);
    this.installPackage(pkg, signature, signature.status === 'trusted', false);
    hilog.info(0x0000, TAG, 'source version revert ok id=%{public}s version=%{public}s', id, version);
    return this.state();
  }

  private validVersion(version: string): boolean {
    return /^[0-9A-Za-z.+-]{1,32}$/.test(version);
  }

  private versionsDir(id: string): string {
    return this.packageDir(id) + '/versions';
  }

  private backupVersion(dir: string, version: string, packageJson: string): void {
    if (!this.validVersion(version)) {
      return;
    }
    const vdir = this.versionsDirFromDir(dir);
    this.ensureDir(vdir);
    this.writeText(vdir + '/' + version + '.json', packageJson);
    // 只保留最近 MAX_VERSION_BACKUPS 份（按版本号升序，旧者先删）
    const all = this.readVersionsFromDir(vdir);
    if (all.length <= MAX_VERSION_BACKUPS) {
      return;
    }
    let oldest = all[0];
    for (const v of all) {
      if (this.isNewerVersion(oldest, v)) {
        oldest = v;
      }
    }
    this.removeFile(vdir + '/' + oldest + '.json');
  }

  private versionsDirFromDir(dir: string): string {
    return dir + '/versions';
  }

  private readVersions(id: string): string[] {
    if (!this.validId(id)) {
      return [];
    }
    return this.readVersionsFromDir(this.versionsDir(id));
  }

  private readVersionsFromDir(vdir: string): string[] {
    const out: string[] = [];
    try {
      const names = fileIo.readdirSync(vdir);
      for (const name of names) {
        if (name.endsWith('.json')) {
          const v = name.substring(0, name.length - 5);
          if (this.validVersion(v)) {
            out.push(v);
          }
        }
      }
    } catch (e) {
      return out;
    }
    return out;
  }

  private readPackage(id: string): SourcePackage {
    if (!this.validId(id)) {
      throw new Error('invalid source id');
    }
    const dir = this.packageDir(id);
    const packagePath = dir + '/package.json';
    if (this.exists(packagePath)) {
      const pkg = JSON.parse(this.readText(packagePath)) as SourcePackage;
      pkg.manifest.network = this.packageNetwork(pkg);
      if (!Array.isArray(pkg.updateUrls)) {
        pkg.updateUrls = [];
      }
      return pkg;
    }
    const manifestPath = dir + '/manifest.json';
    const sourcePath = dir + '/source.js';
    if (!this.exists(manifestPath) || !this.exists(sourcePath)) {
      throw new Error('source package is not installed');
    }
    const manifest = this.parseManifest(this.readText(manifestPath));
    return this.packageFromManifest(manifest, this.readText(sourcePath));
  }

  private packageNetwork(pkg: SourcePackage): SourceNetwork {
    return this.manifestNetwork(pkg.manifest);
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
    if (manifest.runtime === undefined || manifest.runtime.kind !== 'quickjs' ||
        (manifest.runtime.entry !== 'source.js' && manifest.runtime.entry !== 'inline')) {
      throw new Error('manifest runtime must be quickjs/source.js');
    }
    if (manifest.capabilities === undefined) {
      throw new Error('manifest capabilities is required');
    }
    manifest.network = this.manifestNetwork(manifest);
    return manifest;
  }

  private validId(id: string): boolean {
    return id.length > 0 && id.length <= 128 && /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id) && id.indexOf('..') < 0;
  }

  private validPackageId(id: string): boolean {
    return id.length >= 3 && id.length <= 96 && /^[a-z0-9][a-z0-9._-]*$/.test(id) && id.indexOf('..') < 0;
  }

  private parseSemver(version: string): Semver | null {
    const core = version.trim().split('-')[0];
    const parts = core.split('.');
    if (parts.length !== 3) {
      return null;
    }
    const major = Number(parts[0]);
    const minor = Number(parts[1]);
    const patch = Number(parts[2]);
    if (!Number.isInteger(major) || !Number.isInteger(minor) || !Number.isInteger(patch)) {
      return null;
    }
    const semver: Semver = { major: major, minor: minor, patch: patch };
    return semver;
  }

  private isNewerVersion(candidate: string, current: string): boolean {
    const a = this.parseSemver(candidate);
    const b = this.parseSemver(current);
    if (a === null || b === null) {
      return false;
    }
    if (a.major !== b.major) {
      return a.major > b.major;
    }
    if (a.minor !== b.minor) {
      return a.minor > b.minor;
    }
    return a.patch > b.patch;
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

  private readSettings(): SourceSettings {
    const path = this.root + '/settings.json';
    if (!this.exists(path)) {
      return { allowUntrusted: true };
    }
    try {
      const settings = JSON.parse(this.readText(path)) as SourceSettings;
      return { allowUntrusted: settings.allowUntrusted !== false };
    } catch (e) {
      return { allowUntrusted: true };
    }
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

function stringArray(value: string[] | undefined, max: number): string[] {
  const out: string[] = [];
  if (value === undefined || value === null || !Array.isArray(value)) {
    return out;
  }
  for (const item of value) {
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

function textByteLength(text: string): number {
  return new util.TextEncoder().encodeInto(text).byteLength;
}