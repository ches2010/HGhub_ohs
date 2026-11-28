/**
 * P3a host.crypto 子集。
 *
 * 对齐上游 ring 合约：sha256Hex / randomBytes / base64Encode / base64Decode /
 * ecdhP256Create / ecdhP256Derive / aes256GcmEncrypt / aes256GcmDecrypt /
 * hmacSha256。私钥留在 ArkTS 侧的会话 vault，不暴露给源 JS。
 *
 * ECDH 使用系统 cryptoFramework（ECC256），共享秘密后再做 HKDF-SHA256；
 * 每个 info 派生 32 字节密钥，与上游 ring HKDF 行为一致。
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

const MAX_RANDOM_BYTES = 256;
const MAX_ECDH_KEYS = 16;
const MAX_ECDH_INFOS = 8;
const AES_KEY_BYTES = 32;
const GCM_NONCE_BYTES = 12;
const GCM_TAG_BYTES = 16;
const HKDF_KEY_BYTES = 32;

const ECC256_SPKI_PREFIX: number[] = [
  0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
  0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00
];

interface VaultEntry {
  handle: number;
  keyPair: cryptoFramework.KeyPair;
}

export class SourceCryptoVault {
  private entries: VaultEntry[] = [];
  private nextHandle: number = 1;

  create(keyPair: cryptoFramework.KeyPair): number {
    if (this.entries.length >= MAX_ECDH_KEYS) {
      throw new Error('单次执行临时密钥数量超出上限');
    }
    const handle = this.nextHandle;
    this.nextHandle++;
    this.entries.push({ handle: handle, keyPair: keyPair });
    return handle;
  }

  take(handle: number): cryptoFramework.KeyPair | null {
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].handle === handle) {
        const entry = this.entries[i];
        this.entries.splice(i, 1);
        return entry.keyPair;
      }
    }
    return null;
  }

  clear(): void {
    this.entries = [];
  }
}

function toBytes(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text);
}

function fromBytes(bytes: Uint8Array): string {
  return new util.TextDecoder().decode(bytes);
}

function concatBytes(first: Uint8Array, second: Uint8Array): Uint8Array {
  const out = new Uint8Array(first.length + second.length);
  out.set(first);
  out.set(second, first.length);
  return out;
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

function encodeStandardBase64(bytes: Uint8Array): string {
  return new util.Base64Helper().encodeToStringSync(bytes);
}

function decodeStandardBase64(text: string): Uint8Array {
  return new util.Base64Helper().decodeSync(text);
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

function decodeFlexibleBase64(text: string): Uint8Array {
  const trimmed = text.trim();
  if (trimmed.length === 0) {
    return new Uint8Array(0);
  }
  if (trimmed.indexOf('-') >= 0 || trimmed.indexOf('_') >= 0) {
    return decodeStandardBase64(urlToStandard(trimmed));
  }
  return decodeStandardBase64(trimmed);
}

function base64Pair(bytes: Uint8Array): Record<string, Object> {
  const standard = encodeStandardBase64(bytes);
  const out: Record<string, Object> = {};
  out['b64'] = standard;
  out['b64url'] = standardToUrlNoPad(standard);
  return out;
}

function sha256Bytes(data: Uint8Array): Uint8Array {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: data });
  return md.digestSync().data;
}

function hmacSha256Bytes(key: Uint8Array, data: Uint8Array): Uint8Array {
  let keyBytes = key;
  if (keyBytes.length > 64) {
    keyBytes = sha256Bytes(keyBytes);
  }
  const padded = new Uint8Array(64);
  padded.set(keyBytes);
  const ipad = new Uint8Array(64);
  const opad = new Uint8Array(64);
  for (let i = 0; i < 64; i++) {
    ipad[i] = padded[i] ^ 0x36;
    opad[i] = padded[i] ^ 0x5c;
  }
  return sha256Bytes(concatBytes(opad, sha256Bytes(concatBytes(ipad, data))));
}

function hkdfSha256Keys(ikm: Uint8Array, salt: Uint8Array, infos: string[]): Uint8Array[] {
  const prkKey = salt.length > 0 ? salt : new Uint8Array(32);
  const prk = hmacSha256Bytes(prkKey, ikm);
  const out: Uint8Array[] = [];
  for (const info of infos) {
    const infoBytes = toBytes(info);
    let t = new Uint8Array(0);
    const derived = new Uint8Array(HKDF_KEY_BYTES);
    let offset = 0;
    let counter = 1;
    while (offset < HKDF_KEY_BYTES) {
      t = hmacSha256Bytes(prk, concatBytes(concatBytes(t, infoBytes), new Uint8Array([counter & 0xff])));
      const remain = HKDF_KEY_BYTES - offset;
      const take = remain < t.length ? remain : t.length;
      for (let i = 0; i < take; i++) {
        derived[offset + i] = t[i];
      }
      offset += take;
      counter++;
    }
    out.push(derived);
  }
  return out;
}

function rawPublicKeyFromEncoded(encoded: Uint8Array): Uint8Array {
  if (encoded.length === 65) {
    return encoded;
  }
  if (encoded.length > 65) {
    return encoded.subarray(encoded.length - 65);
  }
  throw new Error('ECC 公钥编码长度无效');
}

function derPublicKeyFromRaw(raw: Uint8Array): Uint8Array {
  if (raw.length === 65 && raw[0] === 0x04) {
    const prefix = new Uint8Array(ECC256_SPKI_PREFIX.length);
    prefix.set(ECC256_SPKI_PREFIX);
    return concatBytes(prefix, raw);
  }
  if (raw.length > 65) {
    return raw;
  }
  throw new Error('ECDH 对端公钥编码无效');
}

function requireStringArray(value: Object | undefined): string[] {
  if (value === undefined) {
    throw new Error('缺少 infos 数组');
  }
  const raw = value as string[];
  if (raw === null || raw === undefined || !Array.isArray(raw)) {
    throw new Error('infos 必须是数组');
  }
  const out: string[] = [];
  for (const item of raw) {
    if (typeof item !== 'string') {
      throw new Error('infos 数组元素必须是字符串');
    }
    out.push(item);
  }
  if (out.length === 0 || out.length > MAX_ECDH_INFOS) {
    throw new Error('infos 数量无效（1..=8）');
  }
  return out;
}

export class SourceCrypto {
  async run(request: Record<string, Object>, vault: SourceCryptoVault): Promise<Record<string, Object>> {
    const op = readString(request, 'op');
    if (op === 'sha256Hex') {
      const digest = sha256Bytes(toBytes(readString(request, 'text')));
      const out: Record<string, Object> = {};
      out['hex'] = toHex(digest);
      return out;
    }
    if (op === 'randomBytes') {
      const len = clampNumber(readNumber(request, 'len'), 1, MAX_RANDOM_BYTES, 16);
      const random = cryptoFramework.createRandom().generateRandomSync(len);
      const bytes = random.data;
      return base64Pair(bytes);
    }
    if (op === 'base64Encode') {
      const bytes = toBytes(readString(request, 'text'));
      return base64Pair(bytes);
    }
    if (op === 'base64Decode') {
      const bytes = decodeFlexibleBase64(readString(request, 'b64'));
      const out: Record<string, Object> = {};
      out['text'] = fromBytes(bytes);
      return out;
    }
    if (op === 'ecdhP256Create') {
      const generator = cryptoFramework.createAsyKeyGenerator('ECC256');
      const keyPair = await generator.generateKeyPair();
      const rawPublic = rawPublicKeyFromEncoded(keyPair.pubKey.getEncoded().data);
      const handle = vault.create(keyPair);
      const publicStandard = encodeStandardBase64(rawPublic);
      const out: Record<string, Object> = {};
      out['handle'] = handle;
      out['publicKeyB64Url'] = standardToUrlNoPad(publicStandard);
      out['publicKeyB64'] = publicStandard;
      return out;
    }
    if (op === 'ecdhP256Derive') {
      const handle = readNumber(request, 'handle');
      const peerRaw = decodeFlexibleBase64(readString(request, 'peerPubB64Url'));
      const salt = decodeFlexibleBase64(readString(request, 'saltB64Url'));
      const infos = requireStringArray(request['infos']);
      const local = vault.take(handle);
      if (local === null) {
        throw new Error('ECDH handle 无效或已消费');
      }
      const generator = cryptoFramework.createAsyKeyGenerator('ECC256');
      const peerPair = generator.convertKeySync({ data: derPublicKeyFromRaw(peerRaw) }, null);
      const agreement = cryptoFramework.createKeyAgreement('ECC256');
      const secret = await agreement.generateSecret(local.priKey, peerPair.pubKey);
      const keys = hkdfSha256Keys(secret.data, salt, infos);
      const out: string[] = [];
      for (const key of keys) {
        out.push(encodeStandardBase64(key));
      }
      const result: Record<string, Object> = {};
      result['keysB64'] = out;
      return result;
    }
    if (op === 'aes256GcmEncrypt') {
      return this.aesGcm(request, true);
    }
    if (op === 'aes256GcmDecrypt') {
      return this.aesGcm(request, false);
    }
    if (op === 'hmacSha256') {
      const key = decodeStandardBase64(readString(request, 'keyB64'));
      const data = request['dataB64'] !== undefined ? decodeStandardBase64(readString(request, 'dataB64')) : toBytes(readString(request, 'dataUtf8'));
      const tag = hmacSha256Bytes(key, data);
      const out: Record<string, Object> = {};
      out['b64'] = encodeStandardBase64(tag);
      out['hex'] = toHex(tag);
      return out;
    }
    throw new Error('不支持的 crypto 操作：' + op);
  }

  private aesGcm(request: Record<string, Object>, encrypt: boolean): Record<string, Object> {
    const key = decodeStandardBase64(readString(request, 'keyB64'));
    const nonce = decodeStandardBase64(readString(request, 'nonceB64'));
    if (key.length !== AES_KEY_BYTES) {
      throw new Error('AES-256 密钥长度无效');
    }
    if (nonce.length !== GCM_NONCE_BYTES) {
      throw new Error('AES-256-GCM Nonce 必须为 12 字节');
    }
    const aad = toBytes(readString(request, 'aadUtf8'));
    const generator = cryptoFramework.createSymKeyGenerator('AES256');
    const symKey = generator.convertKeySync({ data: key });
    if (encrypt) {
      const plain = request['plaintextB64'] !== undefined ? decodeStandardBase64(readString(request, 'plaintextB64')) : toBytes(readString(request, 'plaintextUtf8'));
      const params = this.gcmParams(nonce, aad, new Uint8Array(GCM_TAG_BYTES));
      const cipher = cryptoFramework.createCipher('AES256|GCM');
      cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, params);
      const body = cipher.updateSync({ data: plain });
      const tag = cipher.doFinalSync(null);
      if (tag === null) {
        throw new Error('AES-256-GCM 加密认证标签失败');
      }
      const ciphertext = concatBytes(body.data, tag.data);
      const standard = encodeStandardBase64(ciphertext);
      const out: Record<string, Object> = {};
      out['ciphertextB64'] = standard;
      out['ciphertextB64Url'] = standardToUrlNoPad(standard);
      return out;
    }
    const cipherText = request['ciphertextB64Url'] !== undefined ? decodeFlexibleBase64(readString(request, 'ciphertextB64Url')) : decodeStandardBase64(readString(request, 'ciphertextB64'));
    if (cipherText.length < GCM_TAG_BYTES) {
      throw new Error('AES-256-GCM 密文长度无效');
    }
    const tagStart = cipherText.length - GCM_TAG_BYTES;
    const body = cipherText.subarray(0, tagStart);
    const tag = cipherText.subarray(tagStart);
    const params = this.gcmParams(nonce, aad, tag);
    const decoder = cryptoFramework.createCipher('AES256|GCM');
    decoder.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, params);
    const bodyOut = decoder.updateSync({ data: body });
    const finalOut = decoder.doFinalSync(null);
    const plain = finalOut === null ? bodyOut.data : concatBytes(bodyOut.data, finalOut.data);
    const out: Record<string, Object> = {};
    out['plaintextB64'] = encodeStandardBase64(plain);
    out['plaintextUtf8'] = fromBytes(plain);
    return out;
  }

  private gcmParams(nonce: Uint8Array, aad: Uint8Array, authTag: Uint8Array): cryptoFramework.GcmParamsSpec {
    return {
      iv: { data: nonce },
      aad: { data: aad },
      authTag: { data: authTag },
      algName: 'GcmParamsSpec'
    };
  }
}

function readString(map: Record<string, Object>, key: string): string {
  const value = map[key];
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value === 'string') {
    return value;
  }
  return String(value);
}

function readNumber(map: Record<string, Object>, key: string): number {
  const value = map[key];
  if (value === undefined || value === null) {
    return 0;
  }
  if (typeof value === 'number') {
    return value;
  }
  const parsed = Number(value);
  return isNaN(parsed) ? 0 : parsed;
}

function clampNumber(value: number, min: number, max: number, fallback: number): number {
  const parsed = isNaN(value) ? fallback : value;
  if (parsed < min) {
    return min;
  }
  if (parsed > max) {
    return max;
  }
  return parsed;
}
