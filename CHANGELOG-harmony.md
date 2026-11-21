# 鸿蒙（HarmonyOS）端更新日志

本文件只记录 **`harmony/`（HAP 移植层）** 及其配套补丁层、构建脚本、CI 的变更。
上游前端 / Rust 侧的变更请看上游仓库的 release notes（本仓库同步上游时会在提交里注明基线）。

当前 HAP 版本：**2.2.4**（`versionCode` 2002004，跟随上游 v2.2.4）
技术栈：ArkWeb 宿主 + ArkTS 桥 + loopback HTTP 服务（`127.0.0.1:17860`）

文末「[验证与测试记录](#验证与测试记录)」是移植过程中实际跑过的检查项（含命令、用例数与结果，
以及**未覆盖**的部分），可作为回归时的自检清单。

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

## 验证与测试记录

以下是移植与排障过程中**实际执行过**的检查，按层归类。凡标「待确认」的都是当时未能闭环的项。

### 1. 补丁层类型检查（前端 TS）

| 项 | 做法 | 结果 |
|---|---|---|
| `tsc --noEmit` | 在基线 commit `bebfb7a`（v2.0.0）的**全新解包**目录上打补丁后执行 | 零错误（多次复跑，含干净目录） |
| `apply-patch.mjs` 幂等 | 同一目录连跑两次 | 第二次 8 处改动全部输出「已是目标状态」，不重复改文件 |
| blob sha 校验 | 本地按 `sha1("blob <len>\0"+content)` 计算，与 GitHub API 返回对比 | 一致（如 `src/api.ts` = `603a24ac…`），据此确认「推送内容 = 本地内容」 |

### 2. `hg-bridge` 各模块单测（Node + 真实编译产物）

用 `tsc` 把 `patches/src/hg-bridge/*.ts` 编成 CommonJS 后直接 require，配假执行环境（stub 桥、stub 上游）。

**线路与镜像 `lines.ts` — 25 项断言，全绿**
- `publish.js` 词法：注释 / 单双引号 / 模板 / 正则里的假 `var urls=[...]` 一律不生效（7 个样本）
- 动态数组 fail-closed：函数调用、字符串拼接、`.concat()`、重复声明、非字符串元素
- `domains × subdomains` 组合顺序，与 Rust 单测期望的 4 条 origin 完全一致
- `validDnsName`：拒绝无点、`localhost`/`.local`、双点
- `healthyVideoData`：`size=0`、缺 `pagination`、空标题、`id=0`、非对象 全部返回 false
- `scriptSrc`：同源 `publish.js` 通过，跨域、改名一律拒绝
- `pickFromHits`：取最小延迟；全挂 → `all-down`
- `mirrors()`：两个发布页交替合并 + 去重 + 推荐列表以当前线路开头 + 记为可信镜像

**更新检查 `update.ts` — 21 项断言，全绿**
- 直接复刻上游 Rust 单测用例：`v1.0.2>1.0.1`、`v1.1>1.0.9`、`1.0.10>1.0.9`、`v1.0.1==1.0.1`、`v0.9.9<1.0.1`、空串
- `versionIn`：`hgfix-1.2.1-r5`→`1.2.1`、`v1.2.0`→`1.2.0`、`HGhubX 1.2.1+hg.1`→`1.2.1`、`1.2`→空
- `assetRank`/`pickAsset`：无 `.hap` 时为 null，有则选中
- `buildUpdateInfo`：`notes` 截断到 **800 码点**、同版本/旧版本不判更新、`html_url` 空则回退 Release 页

**热搜榜解析 `parseSearchHot` — 6 用例 + 7 个 href 边界（jsdom）**
- 实体解码 + DOM 顺序（`琼明&nbsp;神女录 &amp; 特别篇`）、缺 `.hg-search-hot__name` 回退 `data-search-hot`、同 id 去重、无 `section` 报错、仅外域链接报错、空 section 报错、25 条截断到 20
- href 边界：`/video/0/`、`/video/1/extra/`、绝对地址、`//` 协议相对、`2^53` 全拒；`MAX_SAFE_INTEGER` 与普通 id 接受

**返回键链路 — 端到端 5 项**
- 注册前 `__hgBackEvent()` → `false`（不吞键）；注册后 → `true` 且监听器被调用 1 次；连按 3 次 → 3 次；注销后 → `false`
- `plugin:app|exit` → 调到 `background()`；未知事件 `app/volume-button` 被拒绝

**线路 / 诊断端到端 — 9 个条件**
- `line_state` 返回 2 条固定线路；`line_health` → `ok/status=200/ms`；`line_auto` 在镜像抓取失败时 `reason=all-down`、`switched=false` 且带 `mirror_error`
- `net_diag` → `verdict=ok`、`http.status=200`、`dns.count=2`、`runtime.os=HarmonyOS`；探测超时场景 → `verdict=http_fail`、`kind=timeout`、`http.status=null`

### 3. ArkTS 编译（DevEco / command-line-tools，真机侧）

| 轮次 | 结果 | 处理 |
|---|---|---|
| 第 1 轮 | `FAIL {ERROR:7 WARN:12}` | `WebviewController.clearCache` 不存在、`cryptoFramework` 的 `DataBlob.data` 必须是 `Uint8Array`（连带 4 个重载错误）、`getContext` 已废弃 → 修 5 处 |
| 第 2 轮 | `FAIL {ERROR:2 WARN:13}` | `onConsole` 回调必须返回 `boolean`（`Callback<OnConsoleEvent, boolean>`）→ 改为 `return true` |
| 第 3 轮 | **BUILD SUCCESSFUL**（33 tasks，30s644ms） | 产物 `entry-default-signed.hap` |

> 遗留告警（不阻塞）：`cryptoFramework` 的 syscap 泛型提示、`build-profile.json5` 未显式声明 `targetSdkVersion`。

### 4. CI 与仓库一致性

| 项 | 做法 | 结果 |
|---|---|---|
| `Harmony web bundle` workflow | `workflow_dispatch` 触发 run `43805685394` | **success**（31 s）：打补丁 → `pnpm install` → `pnpm build` → 同步 www → 提交 |
| 产物完整性 | 逐个比对远端 blob sha 与本地下载文件 | 一致：`index.html` `0f68ed5a`(1140 B)、`index.js` `906746f2`(1 023 750 B)、`index.css` `f35c6dab`(89 722 B)、`logo.svg` `b99ea214`(1167 B) |
| `harmony/` 全量一致性 | 拉递归 tree 与本地逐文件比 sha | 33/33 完全一致（无漏推、无内容漂移） |
| 自包含 zip | 打包后回读 zip，逐条比 sha | 包内 33 个 harmony 文件与远端全等 |
| 权限定位 | 同一 blob 分别写普通路径与 `.github/workflows/` | 前者 201、后者 403 → 确认缺 `Workflows: write`（非内容问题） |

### 5. 真机排障记录（按发生顺序）

1. 首装白屏，且**无任何错误输出** → 加诊断面板（ArkUI 覆盖层，不依赖 Web 渲染）。
2. 面板报「`rawfile/www` 为空」→ 确认根因是产物未随仓库提交；改为**产物入库 + CI 构建**。
3. 产物到位后仍白屏、且**面板没出现** → 说明 `bundle`/`bootError` 都正常，问题在「页面未加载」；
   改为 **显式 `controller.loadUrl()`**（不再靠 `@State` 驱动 `Web.src`）+ **6 秒看门狗** + **`/__ping` 原生自检**。
4. 该轮构建成功并安装，**最终显示效果待确认**（对话在此中断；后续仓库已同步上游 v2.2.0 / v2.2.4，
   并在 `3c6b894` 中补了首帧自动 `reload` 兜底）。

### 6. 未覆盖 / 待确认

- **ArkTS 没有 CI 编译**：`.ets` 只能本机 DevEco / command-line-tools 验证，CI 仅构建前端产物。
- **真机端到端未闭环**：白屏修到「有诊断输出」阶段，最后一版的实机表现未回传。
- **真机播放链路未验证**：ArkWeb 对 HEVC / fMP4 / 加密 HLS 的支持，以及 `LocalServer` 的 socket 行为
  （`TCPSocketServer` 分包、`family` 取值）都只在纸面推演过。
- **签名**：仓库不含证书，`assembleHap` 默认产出 unsigned 包；签名流程由 DevEco 或 `hap-sign-tool` 承担，未纳入自动化。

## 已知限制

- **ArkTS 侧没有 CI 编译**：`harmony/` 的 `.ets` 只能在本机用 DevEco / command-line-tools 验证，
  CI 只构建前端产物。
- **切线路会清会话**：移植层只存一份 token（Rust 版按 origin 隔离），切换线路需重新登录。
- **`net_diag` 为精简版**：没有真正发起 DNS 查询与独立 TCP 连接，报告里如实标 `tcp.skipped`。
- **未移植**：`proxy_test`（鸿蒙走系统代理/VPN）、`playback_log_*`（移动端关闭）。
- **仓库不含签名证书**：需 DevEco 自动签名，或用 `hap-sign-tool` 配自己的调试证书手动签。
