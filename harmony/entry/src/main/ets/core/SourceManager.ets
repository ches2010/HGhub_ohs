import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { httpRequest } from './Http';
import quickjsSpike from 'libquickjs_spike.so';

const TAG: string = 'HGhubX';
const SOURCE_ROOT = 'sources';
const DEMO_ID = 'com.hghubx.demo-offline';

export interface SourceRuntime {
  kind: string;
  entry: string;
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

export interface HttpFetchResult {
  status: number;
  body: string;
}

export interface SourceHostError {
  __hostError: string;
}

/**
 * P2 pilot source package store.
 *
 * Only the built-in offline demo source is trusted in this pilot.
 * Untrusted import, Ed25519 verification, share codes and updateUrls remain P3 work.
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
    const manifestText = this.readText(manifestPath);
    const sourceText = this.readText(sourcePath);
    const manifest = this.parseManifest(manifestText);
    const script = [
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
    return quickjsSpike.evaluateAsync(script, (requestId: number, request: string): void => {
      this.handleHostFetch(requestId, request);
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
    const disabled: SourceUpdateResult = { updated: 'false', reason: 'pilot update check disabled' };
    return disabled;
  }

  private handleHostFetch(id: number, request: string): void {
    this.httpFetch(request).then((response: HttpFetchResult) => {
      quickjsSpike.resolveFetch(id, JSON.stringify(response));
    }).catch((err: Error) => {
      const errorResult: SourceHostError = { __hostError: err.message };
      quickjsSpike.resolveFetch(id, JSON.stringify(errorResult));
    });
  }

  private async httpFetch(request: string): Promise<HttpFetchResult> {
    const parsed: Record<string, string> = JSON.parse(request) as Record<string, string>;
    const url = parsed.url !== undefined ? parsed.url : '';
    const method = parsed.method !== undefined ? parsed.method : 'GET';
    const body = parsed.body !== undefined ? parsed.body : '';
    const response = await httpRequest(url, method, '{}', body, false, 15000);
    const text = new util.TextDecoder().decode(new Uint8Array(response.bytes));
    const result: HttpFetchResult = { status: response.status, body: text };
    return result;
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
