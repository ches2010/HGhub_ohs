/**
 * P3b：视频源包 Ed25519 验签。
 *
 * 与上游 src-tauri/src/source/verify.rs 保持同一份 canonical payload：
 *   hghubx-source-v1
 *   id=...
 *   version=...
 *   ...
 *   code_sha256=...
 *
 * 纯壳客户端不预置受信任公钥；带签名包必须验签通过，失败一律拒绝。
 * 无签名包允许导入，但标记为 unsigned；自签包标记为 self_signed。
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

export interface VerifyRuntime {
  kind: string;
  entry: string;
}

export interface VerifyNetwork {
  origins: string[];
  mediaOrigins: string[];
  publishOrigins: string[];
}

export interface VerifyImageDecrypt {
  algorithm: string;
  key: string;
  iv: string;
}

export interface VerifyMedia {
  imageDecrypt?: VerifyImageDecrypt;
}

export interface VerifyManifest {
  id: string;
  version: string;
  apiVersion: string;
  runtime: VerifyRuntime;
  network: VerifyNetwork;
  media?: VerifyMedia;
}

export interface VerifySignature {
  algorithm: string;
  keyId: string;
  publicKey?: string;
  sig: string;
}

export interface VerifiablePackage {
  manifest: VerifyManifest;
  code: string;
  updateUrls: string[];
  signature?: VerifySignature;
}

export interface SourceSignatureInfo {
  status: string;
  keyId: string;
  fingerprint: string;
}

function toBytes(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text);
}

function toHex(bytes: Uint8Array): string {
  let out = '';
  for (const byte of bytes) {
    const high = (byte >> 4) & 0x0f;
    const low = byte & 0x0f;
    out += hexDigit(high) + hexDigit(low);
  }
  return out;
}

function hexDigit(value: number): string {
  return value < 10 ? String.fromCharCode(48 + value) : String.fromCharCode(87 + value);
}

function sha256Bytes(data: Uint8Array): Uint8Array {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: data });
  return md.digestSync().data;
}

export function sha256Hex(text: string): string {
  return toHex(sha256Bytes(toBytes(text)));
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

// HarmonyOS cryptoFramework requires RFC 8410 SubjectPublicKeyInfo DER for raw Ed25519 public keys.
const ED25519_SPKI_PREFIX: number[] = [
  0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00
];

function ed25519PublicDer(rawPublic: Uint8Array): Uint8Array {
  const out = new Uint8Array(ED25519_SPKI_PREFIX.length + rawPublic.length);
  out.set(ED25519_SPKI_PREFIX);
  out.set(rawPublic, ED25519_SPKI_PREFIX.length);
  return out;
}

export function keyFingerprint(rawPublicKey: Uint8Array): string {
  const digest = sha256Bytes(rawPublicKey);
  const parts: string[] = [];
  for (let i = 0; i < 8 && i < digest.length; i++) {
    parts.push(toHex(digest.subarray(i, i + 1)));
  }
  return parts.join(':');
}

export function canonicalPayload(pkg: VerifiablePackage): string {
  const manifest = pkg.manifest;
  let imgDec = '';
  if (manifest.media !== undefined && manifest.media.imageDecrypt !== undefined) {
    const dec = manifest.media.imageDecrypt;
    imgDec = dec.algorithm + ':' + dec.key + ':' + dec.iv;
  }
  return [
    'hghubx-source-v1',
    'id=' + manifest.id,
    'version=' + manifest.version,
    'api=' + manifest.apiVersion,
    'runtime=' + manifest.runtime.kind,
    'origins=' + manifest.network.origins.join(','),
    'media=' + manifest.network.mediaOrigins.join(','),
    'publish=' + manifest.network.publishOrigins.join(','),
    'updates=' + pkg.updateUrls.join(','),
    'imgdec=' + imgDec,
    'code_sha256=' + sha256Hex(pkg.code),
    ''
  ].join('\n');
}

/**
 * P4 试点信任根：keyId → base64url(原始 32 字节 Ed25519 公钥)。
 * 私钥只保存在维护者本地签名机，仓库与源包内只出现公钥；
 * 命中信任根且验签通过的包标记为 trusted，允许在关闭
 * allowUntrusted 时导入。正式版应改为可滚动配置的信任库。
 */
function pilotTrustedPublicKey(keyId: string): string {
  if (keyId === 'p4-pilot-1') {
    return 'Ut3Ob2gewMEUqNtO7kisR2LWbcS-Wp65gicdtldixh4';
  }
  return '';
}

function unsignedInfo(keyId: string): SourceSignatureInfo {
  const info: SourceSignatureInfo = { status: 'unsigned', keyId: keyId, fingerprint: '' };
  return info;
}

export function verifyPackage(pkg: VerifiablePackage): SourceSignatureInfo {
  const signature = pkg.signature;
  if (signature === undefined) {
    return unsignedInfo('');
  }
  if (signature.algorithm.toLowerCase() !== 'ed25519') {
    throw new Error('不支持的签名算法：' + signature.algorithm);
  }
  const publicText = signature.publicKey !== undefined ? signature.publicKey.trim() : '';
  if (publicText.length === 0) {
    return unsignedInfo(signature.keyId.trim());
  }
  const rawPublic = decodeBase64Url(publicText);
  if (rawPublic.length !== 32) {
    throw new Error('签名公钥长度无效');
  }
  const signatureBytes = decodeBase64Url(signature.sig);
  if (signatureBytes.length !== 64) {
    throw new Error('签名长度无效');
  }
  const payload = toBytes(canonicalPayload(pkg));
  const generator = cryptoFramework.createAsyKeyGenerator('Ed25519');
  const keyPair = generator.convertKeySync({ data: ed25519PublicDer(rawPublic) }, null);
  const verifier = cryptoFramework.createVerify('Ed25519');
  verifier.initSync(keyPair.pubKey);
  const ok = verifier.verifySync({ data: payload }, { data: signatureBytes });
  if (!ok) {
    throw new Error('视频源签名验证失败：内容可能已被篡改');
  }
  const trustedKey = pilotTrustedPublicKey(signature.keyId.trim());
  const info: SourceSignatureInfo = {
    status: trustedKey.length > 0 && trustedKey === publicText ? 'trusted' : 'self_signed',
    keyId: signature.keyId.trim(),
    fingerprint: keyFingerprint(rawPublic)
  };
  return info;
}