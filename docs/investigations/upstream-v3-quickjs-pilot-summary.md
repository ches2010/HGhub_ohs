# 上游 v3 QuickJS 源运行时移植试点总结（P1–P4）

> 分支：`sync/upstream-3.0.0-pilot`（`main` 保持 2.2.10 稳定，未合并）
> 试点 HAP：`2.2.10-p5` / versionCode `2002023`（构建 run 45，`cd0085d`）
> 状态：P1–P4 全部真机验证通过；合并 `main` / 切版本号 `3.0.0` 需维护者明确授权。

## 1. 背景与总体决策

- 上游 `zxsos/HGhubX` `main` 重写为 v3.0.0（仅 3 个提交，历史与 fork 无共同祖先，GitHub compare 返回 `No common ancestor`），**不能 merge / rebase**；直接覆盖会破坏现有站点能力。
- 决策：不覆盖 `main`，在独立分支按「运行时 → 存储 → host 能力 → 包与验签 → 前端 → 真实升级链路」分阶段试点（P1–P4），每阶段真机验证后再进入下一阶段。
- 鸿蒙路线保持不变：ArkWeb 壳 + ArkTS 原生桥 + LocalServer loopback `127.0.0.1:17860`（媒体仅 `/img` `/hls` `/seg` `/__ping`）。

## 2. 关键架构决策

- 上游 v3 = 纯壳 + QuickJS 视频源插件（`source.js` 沙箱、Ed25519 验签源包、`source_*` / `cache_*` / `tv_peer_*` 命令、SourceOnboarding / SourceManager、局域网配对）。
- **不能用 `quickjs-emscripten`**：上游 `runtime.rs` 的 `host.fetch` 是同步函数（内部 `block_on`），ArkWeb 主线程无法同步回调 HTTP。
- 方案：原生 QuickJS（QuickJS-NG v0.18.0）+ NAPI + 独立原生线程 + `napi_threadsafe_function` 回调 ArkTS HTTP，原生线程 mutex/condvar 阻塞等待（20s 超时）。
- 原生运行时限制：16 MiB 堆 / 512 KiB 栈 / 12s 中断；源脚本执行前删除 `__hostCall` / `__hostContext` 原始全局。
- 通用桥：`__hostCall(op, payload)` ↔ ArkTS `host.info / auth / fetch / htmlQuery / crypto / storage`（`Bridge.ets` + `SourceHost.ets`）。
- host 能力边界：
  - `host.fetch`：HTTPS 公网 + manifest origin 白名单 + 禁 Host/Cookie 等敏感头 + 256 KiB 请求体 / 2 MiB 响应（未做逐跳重定向与 DNS 固定）。
  - `host.htmlQuery`：只读子集（tag / `.class` / `#id` / `[attr]` / `[attr=value]`，200 条上限）。
  - `host.crypto`：sha256 / random / base64 / hmac / AES-256-GCM / ECDH P-256 + HKDF-SHA256。
  - `host.storage`：per-source 64 键 / 32 KB。
  - `host.auth`：P5 起按 RFC 0001 实现真实语义（`{ token }`，未登录或自定义线路为 `null`）；token 由前端登录 / 切线时经 `sourceSetAuthToken` 推送并落盘 `filesDir/source_auth.json`。

## 3. 包格式与安全模型

- 包格式 `SourcePackage {schemaVersion, manifest, code, updateUrls, signature?}`，`runtime.entry` 支持 `inline` / `source.js`；对齐上游 `manifest.rs`。
- canonical payload 逐行复刻上游 `verify.rs`：`hghubx-source-v1` 开头，`id/version/api/runtime/origins/media/publish/updates/imgdec/code_sha256` 行，末尾空行。
- Ed25519 验签：HarmonyOS `cryptoFramework` 需 RFC 8410 SPKI DER 前缀包装原始 32 字节公钥。
- 签名状态：`trusted`（命中试点信任根 `pilotTrustedPublicKey()` 且内嵌公钥一致）/ `self_signed`（内嵌公钥验签通过）/ `unsigned`。
- `allowUntrusted` 门禁默认开启；关闭后仅 `trusted` 可导入（含 updateUrls 更新路径）。
- 导入与更新都先在 QuickJS 里跑 `init()` 冒烟，通过才落盘；更新额外要求 id 一致 + semver 递增。
- 分享口令 `hghubx-src://` = `base64url(gzip(utf8(packageJson)))`，512 KB 上限；用系统 `GZip.gzopen/gzread/gzwrite` 文件式 API（`ZStream.totalOut` 真机不可靠）。
- 源数据落盘 `filesDir/sources/<id>/` + `installed.json` + `active.json`；当前保留上一激活源用于回滚，尚无版本级备份目录。

## 4. 签名机规程（P4）

- keyId：`p4-pilot-1`；公钥 base64url：`Ut3Ob2gewMEUqNtO7kisR2LWbcS-Wp65gicdtldixh4`；指纹：`81:f0:13:0c:db:0e:c5:b4`（sha256 前 8 字节）。
- **私钥只存维护者本地签名机（不入库、不上传）**；仓库与源包内只出现公钥。
- 签发流程：构建 manifest/code/updateUrls → 计算 canonical payload → Ed25519 签名 → 包内嵌 `signature {algorithm, keyId, publicKey, sig}`。
- 发布通道：仓库 `sources/pilot/p4-demo/` → raw.githubusercontent（分支，实时）+ cdn.jsdelivr.net @commit-sha（不可变，国内可达性好）。
- 更新通道设计：`latest.json` 必须是**全新 URL**（避免 CDN 陈旧缓存误报无新版本）；种子包 `updateUrls` 双通道，`checkUpdate` 按序尝试、首个成功者生效。
- 轮换：改 `SourceVerify.ets` 的 `pilotTrustedPublicKey()` 并重签全部在发源包。

## 5. 分阶段记录（全部真机验证）

| 阶段 | 内容 | 提交 | 构建 run |
| --- | --- | --- | --- |
| P1a | QuickJS spike（arm64 交叉编译） | — | run ≤18 |
| P1b | `.so` 入包 + 同步 evaluate | — | — |
| P1c | 异步 evaluate + TSF 回调 HTTP | — | — |
| P1c2/P1c4 | rawfile 真实源包 init/home/detail/playback | — | — |
| P2 / P2r1 | SourceManager 存储/激活/回滚 | — | run 25 内 |
| P3a | 通用 `__hostCall` 桥 + host 六能力 | — | run 32–34 |
| P3b | 包格式 / 验签 / 分享码 | `4c2b2ad` `40a52ef` `d325b75` | run 39 / 41 |
| P3c | 源管理 UI + 前端桥接线 | `5b0ca14` `0bd915a` | run 42 / 43 |
| P4 | 信任根 + HTTPS 导入 + 升级链路 | `ac71828` `fff33f2` | run 44 |
| P5 | host.auth 真实登录态（RFC 0001 语义） | `cd0085d` | run 45 |
| P6 | hghubx:// 深链导入（上游暂存/取走契约） | `2c8a079` | run 46 |

关键真机验证输出：

```text
quickjs eval: 2
source pilot state / source pilot test / source pilot active
source host pilot: {"info":...,"sha256":...,"random":...,"base64":...,"hmac":...}
source package pilot: {"id":"com.hghubx.demo-signed","sigStatus":"self_signed","keyId":"p3b-demo","fingerprint":"29:34:e8:6a:3b:ed:13:27","shareOk":true,"tamperRejected":true}
```

P4 真机链路：jsDelivr URL 导入 v1.0.0（trusted，指纹 `81:f0:13:0c:db:0e:c5:b4`）→ 检查更新到 v1.0.1 → 测试输出标题变为「P4 已更新到 1.0.1」。

## 6. 踩坑与修复记录（按阶段）

1. P1a：CMake 链接到 x86_64 `libace_napi.z.so`（`incompatible with aarch64linux`）→ 查找 `*aarch64-linux-ohos*`。
2. P1b：ArkTS 保留字 `eval` → 导出改名 `evaluate`。
3. P1c：C 侧对对象参数直接 `JS_ToCString` 得 `[object Object]` → `JS_JSONStringify`。
4. P2：`importTrusted` 无条件 `mkdirSync(dir, true)` 报 `File exists` → `ensureDir()`（stat 失败才创建）。
5. P3a：`JS_SetPropertyStr` 接管值后代码又 `JS_FreeValue` 造成双重释放 → 真机闪退修复；`pending_set_result` 错误路径释放字符串字面量。
6. P3a：ECDH 空 salt 传 `Base64Helper.decodeSync('')` 抛 Parameter error → `decodeFlexibleBase64` 空串返回空 `Uint8Array`。
7. P3b：`convert key fail` → RFC 8410 SPKI 前缀包装公钥。
8. P3b：`ZStream.totalOut` 真机不可靠 → `GZip.gzopen/gzread`；`decodeShareCode` 补 cacheDir 参数。
9. P3c：`registerJavaScriptProxy` 从未注册 source 方法 → 补齐 10 个；`encodeShareCode` 的 `gzwrite` 传入全零 `ArrayBuffer`（未拷入 payload）→ 分享码导出实为零字节流，导入报 `Unexpected end in JSON`；按钮样式（`bg-s3` 同色隐形 / `variant="danger"` 44px 圆钮）。
10. 前端类型：ArkTS 无 `delete`、无结构化类型（`SourcePackage extends VerifiablePackage` 显式继承）、对象字面量需显式类型。

## 7. 已知限制与后续工作

- 未接桥命令：`source_lan_push_*`、`tv_peer_pair_qr` / `tv_peer_sync`、`cache_stats` / `cache_set_limit` / `cache_clear`。
- 旧前端平台识别仍输出 `[env] platform=android`，接 v3 UI 时改 HarmonyOS。
- 无版本级备份/回滚目录（仅保留上一激活源）。
- `host.fetch` 未做逐跳重定向校验与 DNS 固定。
- 版本切换 `3.0.0` / `3000000` 与合并 `main` / 打 tag / 发布 Release：须待全量回归并获维护者明确授权。

## 8. 文件清单（本试点新增/修改）

- `harmony/native/quickjs-spike/{CMakeLists.txt,napi_init.c,README.md}` + `.github/workflows/harmony-quickjs-spike.yml`
- `harmony/entry/libs/arm64-v8a/libquickjs_spike.so`、`harmony/entry/src/main/cpp/types/libquickjs_spike/{Index.d.ts,oh-package.json5}`
- `harmony/entry/src/main/ets/core/{SourceManager,SourceVerify,SourceShare,SourceHost,SourceCrypto,SourceHtml,Bridge}.ets`
- `harmony/entry/src/main/ets/pages/Index.ets`（JS 代理注册）、`harmony/entry/src/main/ets/entryability/EntryAbility.ets`（启动自检）
- `harmony/entry/src/main/resources/rawfile/quickjs/{demo-offline,p3b-signed}/`
- `sources/pilot/p4-demo/{package.json,latest.json}`（P4 已发布源包）
- `src/features/settings/SourceManagerSettings.tsx`、`src/features/settings/Settings.tsx`、`src/hg-bridge/core.ts`
- 既有阶段文档：`upstream-v3-quickjs-feasibility.md`、`upstream-v3-quickjs-p1a-result.md`、`upstream-v3-quickjs-p1b-result.md`、`upstream-v3-quickjs-p3a-plan.md`、`upstream-v3-quickjs-p3b-plan.md`

## 9. 上游依据

- `src-tauri/src/source/runtime.rs`（`host.fetch` 同步 `block_on`，决定原生 QuickJS 方案）
- `src-tauri/src/source/verify.rs`（canonical payload 格式）
- `src-tauri/src/source/manifest.rs`（包格式 / 分享口令 / 校验）
- `src-tauri/src/source/commands.rs`（`source_*` 命令契约）
- `examples/sources/demo-offline/`、`scripts/pack-source.mjs`、`docs/rfc/0001-source-contract.md`、`src/shared/api/api.ts`（v3 命令名）
