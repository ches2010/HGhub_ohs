# 鸿蒙（HarmonyOS）端更新日志

本文件只记录 **`harmony/`（HAP 移植层）** 及其配套补丁层、构建脚本、CI 的变更。
上游前端 / Rust 侧的变更请看上游仓库的 release notes（本仓库同步上游时会在提交里注明基线）。

当前 HAP 版本：**2.2.4**（`versionCode` 2002004，跟随上游 v2.2.4）
技术栈：ArkWeb 宿主 + ArkTS 桥 + loopback HTTP 服务（`127.0.0.1:17860`）

---

## [未发布] 2026-11-21 — 审计与首帧修复

提交：`3c6b894`（+539 / −73）

### 修复
- **首帧白屏兜底**：`onPageEnd` 后若索引页已加载但 React 未挂载，自动做一次原生 `reload`（最多 1 次）。
  首次 WebView 渲染可能停留在空白，手动刷新可恢复，现在由代码兜住。
- **返回键语义**：`Bridge.handleBack()` 在无法接管时返回 `true`，让系统把 UIAbility 移到后台，
  而不是销毁进程。
- **大响应截断**：`httpRequest` 的 `maxLimit` 提到 64 MiB（默认 5 MiB 对部分分片与封面不够）。
- **协议相对地址**：m3u8 里的 `//host/...` 现在正确绝对化（原实现会拼错）。
- **`EXT-X-DATERANGE`**：剔除其中的 `URI` 属性，与 Rust 版 `media.rs` 行为对齐。

### 安全
- **本地代理 SSRF 防护**：`LocalServer` 与 `hg-bridge` 都新增 IPv4/IPv6 私网与保留地址判定
  （`0.0.0.0/8`、`10/8`、`100.64/10`、`127/8`、`169.254/16`、`172.16/12`、`192.168/16`、
  `224/4`、`240/4` 等），FakeIP 段 `198.18.0.0/15` 保留为白名单例外。

### 前端（随层内补丁）
- `LinePicker`：鸿蒙下切线路提示改为「切换线路后需重新登录」（移植层只存一份 token，切线路即清会话）。

### 版本
- `AppScope/app.json5`、`oh-package.json5` 对齐 `2.2.4`。

---

## [2.2.4] 2026-11-20

- 同步上游 **v2.2.4**（`d69dd0a`），HarmonyOS 层在其上重放（`a70d048`）。
- CI 对齐上游：`ci.yml` 跟进 v2.2.4（`fee4889`），保留上游 `tv.yml` 以免文档链接失效（`96de229`）。
- CI 重建前端产物与 zip（`bfcf3d3`）。

---

## [2.2.0] 2026-11-18

- 同步上游 **v2.2.0**（`a7d22db`），HarmonyOS 层重放（`82993ad`、`6b8b3d2`）。
- CI 两次重建 `rawfile/www` 与 zip（`90f2cb2` 等）。

---

## [2.0.0] 2026-11-15 ~ 11-16 — 首次移植

### 新增
- **HAP 工程骨架**：ArkWeb 宿主 + ArkTS `LocalServer`（loopback HTTP，路由 `/` `/hls` `/seg` `/img` `/__ping`）。
  选 loopback 而非 `onInterceptRequest`：后者是同步回调，拿不到异步网络结果，媒体代理会全挂。
- **`Bridge`**：`http` / `setBase` / `openUrl` / `setOrientation` / `log` / `clearCache` /
  `setBackEnabled` / `background` / `netInfo`。
- **`hg-bridge` 补丁层**（`patches/src/hg-bridge/`）：
  - 边缘信封复刻（`POST /api/edge/request`，base64 body）与约 60 条命令的 path 拼装；
  - 线路与镜像：`publish.js` 当数据解析（自带 JS 词法器，拒绝动态数组）、并发探测取最小延迟、代次语义；
  - 热搜榜：`DOMParser` 解析官网 SSR；
  - 更新检查：tag 抠 `x.y.z` + 数字段比较，404 视为未发版；
  - 返回键桥：对接 `App.tsx` 的 `addPluginListener`，末端退到后台。
- **脚本**：`apply-patch.mjs`、`build-web.sh`、`sync-web.sh`、`build-hap.sh`、
  `bootstrap-node.sh`、`setup-and-build.sh`、`fix-stale-build.sh`。
- **CI**：`.github/workflows/harmony-web.yml`（手动触发，runner 上构建前端并提交产物）。

### 修复
- 首轮 7 处 ArkTS 编译错误：`WebviewController.clearCache` 不存在、`cryptoFramework` 的
  `DataBlob.data` 必须是 `Uint8Array`（连带 4 个重载错误）、`getContext` 已废弃等。
- `onConsole` 回调必须返回 `boolean`（`Callback<OnConsoleEvent, boolean>`）。
- **白屏定位三连**：根因是 `rawfile/www` 没同步 → 产物改为随仓库提交；补诊断面板；
  再用「显式 `controller.loadUrl()` + 6 秒看门狗 + `/__ping` 自检」替代「靠 `@State` 驱动 `Web.src`」。

### 文档
- `harmony/docs/PORTING.md`：验证状态、装机步骤、真机自检顺序、白屏排查、编译对齐记录、已知风险。
- `harmony/README.md`：构建前提（`hvigorw` 由 DevEco / command-line-tools 提供）、command-line-tools 用法。

---

## 已知限制

- **ArkTS 侧没有 CI 编译**：`harmony/` 的 `.ets` 只能在本机用 DevEco / command-line-tools 验证，
  CI 只构建前端产物。
- **切线路会清会话**：移植层只存一份 token（Rust 版按 origin 隔离），切换线路需重新登录。
- **`net_diag` 为精简版**：没有真正发起 DNS 查询与独立 TCP 连接，报告里如实标 `tcp.skipped`。
- **未移植**：`proxy_test`（鸿蒙走系统代理/VPN）、`playback_log_*`（移动端关闭）。
- **仓库不含签名证书**：需 DevEco 自动签名，或用 `hap-sign-tool` 配自己的调试证书手动签。
