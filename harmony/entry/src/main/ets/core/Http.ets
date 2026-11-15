/**
 * 原生传输层：只做「给我 URL + 方法 + 头 + body，返回 status 与字节」。
 * 所有业务逻辑（信封、token、路线）都在前端 TS shim 里，ArkTS 侧保持无状态，
 * 这样移植面最小，出了问题也好定位。
 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';

export interface HttpResult {
  status: number;
  bytes: ArrayBuffer;
}

function toBuffer(data: string | Object | ArrayBuffer | undefined): ArrayBuffer {
  if (data === undefined) {
    return new ArrayBuffer(0);
  }
  if (data instanceof ArrayBuffer) {
    return data;
  }
  if (typeof data === 'string') {
    const encoded = new util.TextEncoder().encodeInto(data);
    const out = new ArrayBuffer(encoded.byteLength);
    new Uint8Array(out).set(encoded);
    return out;
  }
  const text = JSON.stringify(data);
  const encoded = new util.TextEncoder().encodeInto(text);
  const out = new ArrayBuffer(encoded.byteLength);
  new Uint8Array(out).set(encoded);
  return out;
}

function parseHeaders(json: string): Record<string, string> {
  const out: Record<string, string> = {};
  if (json.length === 0) {
    return out;
  }
  try {
    const parsed = JSON.parse(json) as Record<string, string>;
    const keys = Object.keys(parsed);
    for (const k of keys) {
      const v = parsed[k];
      if (typeof v === 'string') {
        out[k] = v;
      }
    }
  } catch (e) {
    // 头 JSON 坏了不应该让请求整体失败，退化成空头
  }
  return out;
}

/** 文本/二进制统一入口；text=true 时按字符串读再转字节（保留 UTF-8 语义）。 */
export async function httpRequest(
  url: string,
  method: string,
  headersJson: string,
  body: string,
  text: boolean,
  timeoutMs: number
): Promise<HttpResult> {
  const request = http.createHttp();
  try {
    const headers = parseHeaders(headersJson);
    const options: http.HttpRequestOptions = {
      method: method as http.RequestMethod,
      header: headers,
      expectDataType: text ? http.HttpDataType.STRING : http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 10000,
      readTimeout: timeoutMs,
      usingCache: false
    };
    if (body.length > 0 && (method === 'POST' || method === 'PUT' || method === 'PATCH')) {
      options.extraData = body;
    }
    const resp = await request.request(url, options);
    return { status: resp.responseCode as number, bytes: toBuffer(resp.result) };
  } finally {
    request.destroy();
  }
}
