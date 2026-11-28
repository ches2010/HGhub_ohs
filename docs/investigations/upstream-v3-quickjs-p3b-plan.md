# QuickJS 源运行时 P3b：包格式、分享码与 Ed25519

日期：2026-11-28
分支：`sync/upstream-3.0.0-pilot`
状态：P3b 后端实现，等待真机自检。

## 已实现

- `SourcePackage` 包格式：`{schemaVersion, manifest, code, updateUrls, signature?}`
- `hghubx-src://` 分享码：base64url(gzip(utf8(packageJson)))，解压上限 512 KB
- Ed25519 验签：
  - canonical payload 与上游 `src-tauri/src/source/verify.rs` 一致
  - 带签名包必须验签通过，篡改包拒绝
  - 无签名包标记 `unsigned`，自签包标记 `self_signed`
- 非信任导入开关 `allowUntrusted`，默认 true
- 导入前 QuickJS `init()` 冒烟测试
- `updateUrls` 手动检查：id 一致、验签、语义化版本递增、init 通过后安装
- 分享码导出
- Bridge 新增 `sourceImport` / `sourceExportShareCode` / `sourceSetAllowUntrusted`
- 启动自检 `source package pilot`：
  - 解码自签示例包分享码
  - 验签自签包
  - 用同一签名验证篡改包必须失败

## 自检数据

`rawfile/quickjs/p3b-signed/`：

- `package.json`：自签示例包
- `share.txt`：对应分享码
- `tampered.json`：篡改 code 但保留原签名，必须验签失败

## 真机预期

```text
source package pilot: {"id":"com.hghubx.demo-signed","sigStatus":"self_signed","keyId":"p3b-demo","fingerprint":"...","shareOk":true,"tamperRejected":true}
```

## 当前限制

- 没有源管理 UI；Bridge 命令已就绪，前端接入在 P3c/P4。
- 未预置受信任公钥，`trusted` 状态暂时不会出现。
- 更新安装保留当前包，未做版本级备份目录；init 失败会在安装前拒绝。
- fetch 仍未做逐跳重定向和 DNS 固定，沿用 P3a 边界。
