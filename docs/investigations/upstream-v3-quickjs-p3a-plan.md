# QuickJS 源运行时 P3a：host 原语与安全边界

日期：2026-11-27
分支：`sync/upstream-3.0.0-pilot`
状态：P3a 实现，等待真机验证；不是 v3.0.0 正式移植。

## 目标

把 P1/P2 的“能跑 QuickJS + 源包存储”推进到上游 RFC 0001 的 host 原语契约：

- `host.info`：只读源元信息。
- `host.auth`：pilot 固定返回 `{ token: null }`，不做真实账号绑定。
- `host.fetch`：HTTPS 公网地址 + manifest.network 白名单。
- `host.htmlQuery`：只读 HTML 子集查询。
- `host.crypto`：sha256Hex / randomBytes / base64Encode / base64Decode / ecdhP256Create / ecdhP256Derive / aes256GcmEncrypt / aes256GcmDecrypt / hmacSha256。
- `host.storage`：按 sourceId 隔离的 KV 存储。

## 架构

原生 QuickJS 不再直接暴露 `host.fetch`，而是暴露一个通用同步桥：

- C 侧设置 16 MiB 内存上限、512 KiB 栈上限、12 秒中断超时。
- C 侧只注入 `__hostCall(op, payload)` 和 `__hostContext`。
- ArkTS 侧 prepend 一段 host shim，定义冻结的 `globalThis.host`，随后删除两个原始全局对象。
- 所有 host 调用经 NAPI ThreadSafeFunction 回到 ArkTS 主线程执行，源 JS 不能直接碰网络、文件、系统 API。
- `evaluateAsync(script, onHost, contextJson)` 的第三个参数携带 sourceId、info 和允许的 origins。

## 安全边界

- fetch：仅 `https://`，拒绝 localhost、保留后缀、IPv4 私有/环回/链路本地/组播地址；origin 必须匹配 manifest.network.origins + publishOrigins；禁止 Host/Connection/Cookie 等受限头；请求体 256 KB、响应 2 MB、超时 2–20 秒。
- htmlQuery：只读解析，不执行脚本；输入 2 MB、选择器 256 字符、结果 200 条、节点 50000。
- crypto：ECDH 私钥保存在 ArkTS 会话 vault，不进源 JS；AES-GCM 使用系统 cryptoFramework。
- storage：每个 sourceId 独立 `sources/<id>/storage.json`，最多 64 键、单值 32 KB。
- QuickJS：内存/栈/中断超时与上游一致；host shim 在源脚本执行前删除原始桥全局。

## Pilot 明确限制

- htmlQuery 只支持 tag / `.class` / `#id` / `[attr]` / `[attr=value]`、后代与子代组合子、逗号分组；不支持完整 CSS。
- fetch 不做逐跳重定向白名单和 DNS 固定；HarmonyOS HTTP 栈的跳转行为需要在 P3b 接进严格网络策略。
- host.fetch 响应 headers pilot 返回空对象；`Http.ets` 不暴露响应头。
- ECDH/AES 使用系统 cryptoFramework；ECDH 私钥对象在会话结束后从 vault 移除，但不能保证立即零化。
- 仍只信任内置 offline demo 源；非信任包导入、Ed25519 验签、分享口令、updateUrls 检查属于 P3b。
- 没有源管理前端 UI；`source_*` 命令桥仍是 P2 形态。

## 真机验证预期

启动后除原有 `source import ok` / `source pilot state` / `source pilot test` / `source pilot active` 外，还应看到：

```text
source host pilot: {"info":"com.hghubx.demo-offline","sha256":"...","random":"...","base64":"...","base64Text":"hghubx","hmac":"...","htmlItems":1,"insecureBlocked":true,"privateBlocked":true,"originBlocked":true,"storage":"ok","ecdh":true,"aesGcm":true}
```

关键断言：

- `insecureBlocked` / `privateBlocked` / `originBlocked` 必须为 `true`，且不能触发真实网络请求。
- `ecdh` 和 `aesGcm` 必须为 `true`。
- `source pilot test` 仍要通过，证明 host shim 不影响现有 demo 源生命周期。

## 下一步

P3b：非信任包导入边界、Ed25519 验签、`hghubx-src://` 分享口令解码、`updateUrls` 手动更新检查、`host.htmlQuery` 可选增强、源管理前端命令接 UI。
