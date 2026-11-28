# 鸿蒙（HarmonyOS）端更新日志

本文件只记录 **`harmony/`（HAP 移植层）** 及其配套补丁层、构建脚本、CI 的变更。
上游前端 / Rust 侧的变更请看上游仓库的 release notes（本仓库同步上游时会在提交里注明基线）。

当前 HAP 版本：**2.2.10**（`versionCode` 2002010，跟随上游 v2.2.10）
试点分支 `sync/upstream-3.0.0-pilot`：**2.2.10-p4**（`versionCode` 2002022，QuickJS 源运行时试点 P1–P4，未合并 main）
技术栈：ArkWeb 宿主 + ArkTS 桥 + loopback HTTP 服务（`127.0.0.1:17860`）

文末「[验证与测试记录](#验证与测试记录)」是移植过程中实际跑过的检查项（含命令、用例数与结果，
以及**未覆盖**的部分），可作为回归时的自检清单。

---

## [2.2.10-p5] 2026-11-28 — QuickJS 源运行时试点 P5：host.auth 真实登录态

- 按上游 RFC 0001 实现 `host.auth` 真实语义：返回 `{ token }`，未登录或不可信线路（用户手输的自定义域名）时为 `null`。此前 P3a 为固定 `token: null` 占位。
- 线路信任策略放在前端（只有前端知道 `lineStateStore.isCustom()`）：登录 / 退出（`setSession`）、切线路（`setBase` / `line_custom_set`）、启动会话恢复（`syncBaseToNative`）都会经新桥方法 `sourceSetAuthToken` 把当前 token 推给原生；自定义线路推空串。
- 新增 `SourceAuth.ets`：token 槽落盘 `filesDir/source_auth.json`，供 QuickJS 会话与 EntryAbility 启动自检读取；日志只记 present / cleared，绝不输出 token 本身。
- `SourceHost` prelude 的 `host.auth` 从静态 `{ token: null }` 改为 getter（每次访问走 `__hostCall("auth")`），host 对象保持冻结；新增 op `auth`。
- `Index.ets` JS 代理注册补 `sourceSetAuthToken`；启动自检 `source host pilot` 新增 `authHasToken` 字段（只报布尔）。
- 示例源升级 `com.hghubx.demo-p4` v1.0.2（p4-pilot-1 签名，raw 通道发布）：`init()` 调 `host.auth` 返回 `authHasToken`，覆盖已登录 / 未登录 / 自定义线路三种真机状态。
- 提交 `cd0085d`；构建 run 45。

---

## [2.2.10-p4] 2026-11-28 — QuickJS 源运行时试点 P4：信任根与升级链路

- 新增试点信任根 `p4-pilot-1`（Ed25519 公钥内置 `SourceVerify.ets`，指纹 `81:f0:13:0c:db:0e:c5:b4`）：命中信任根且验签通过的包标记 `trusted`，关闭「允许导入未签名源」时也可导入。此前 `trusted` 仅 demo 源硬编码，验签路径只会产出 `self_signed`。
- 私钥仅存维护者本地签名机（不入库），仓库与源包只含公钥；正式版应改为可滚动配置的信任库。
- 签发真实源包 `com.hghubx.demo-p4` v1.0.0 / v1.0.1（基于 demo-offline 代码，标题可区分版本），发布到 `sources/pilot/p4-demo/`：raw.githubusercontent 分支通道 + jsDelivr @commit-sha 不可变通道，发布后均实测 200 且内容一致。
- 种子包 `updateUrls` 双通道：raw 优先、jsDelivr 兜底；`latest.json` 为全新 URL，避免 CDN 陈旧缓存误报「无新版本」。
- 真机全链路通过：HTTPS URL 导入（验签 + init 冒烟）→ 检查更新（下载 → 验签 → semver 递增 → 冒烟 → 安装）→ 测试输出标题由「P4 示例视频 1」变为「P4 已更新到 1.0.1」。
- 提交 `ac71828`（信任根 + 包发布）、`fff33f2`（种子包补 jsDelivr 兜底）；构建 run 44。

---

## [2.2.10-p3c] 2026-11-28 — QuickJS 源运行时试点 P3c：源管理前端

- 设置页新增「视频源」分区（`src/features/settings/SourceManagerSettings.tsx`）：分享口令 / JSON / HTTPS 地址导入、导入后直接激活开关、已装源列表（版本 + 签名状态 + 指纹 + 使用中标记）、激活 / 测试 / 检查更新 / 分享码（复制失败回退为回显）/ 移除（二次点击确认）/ 回滚 / 「允许导入未签名源」开关；非鸿蒙宿主显示不可用提示。
- 前端 `invoke()` 新增 9 个 `source_*` 命令分支（`source_state` / `source_import` / `source_export_share_code` / `source_set_allow_untrusted` / `source_test` / `source_activate` / `source_rollback` / `source_remove` / `source_check_update`），命令名与上游 v3 对齐，为后续切 v3 UI 做准备。
- 修复：`Index.ets` 的 `registerJavaScriptProxy` 方法列表从未注册任何 `source*` 方法，前端此前完全调不到 P2/P3b 桥——本次补齐全部 10 个。
- 修复分享码导出：`encodeShareCode` 的 `gzwrite` 传入的是从未拷入内容的全零 `ArrayBuffer`，导出口令实际是「零字节流的 gzip」，导入必报 `Unexpected end in JSON`；改为先拷贝 payload 再压缩（P3b 真机自检只覆盖解码路径，故未暴露）。
- 修复操作按钮样式：芯片底色 `bg-s3` 与卡片同色导致隐形、「移除」因 `variant="danger"` + `.ios-button` 44px 最小尺寸规则渲染为大红圆钮；统一为 `bg-s4` + 红字小按钮。
- TypeScript 5.9.3 严格模式对本分支 `tsc --noEmit` 通过（改动文件零新增错误）。
- 提交 `5b0ca14`（面板 + 桥接线）、`0bd915a`（gzwrite 修复 + 样式）；构建 run 42 / 43；真机通过（含分享码导出 → 粘贴 → 导入闭环）。

---

## [2.2.10-p3b] 2026-11-28 — QuickJS 源运行时试点 P3b：包格式与验签

- 新增 `SourcePackage` 包格式（`{schemaVersion, manifest, code, updateUrls, signature?}`，`runtime.entry` 支持 `inline` / `source.js`），对齐上游 `src-tauri/src/source/manifest.rs`。
- 新增 `SourceVerify.ets`：canonical payload 逐行复刻上游 `verify.rs`（`hghubx-source-v1` 开头、`code_sha256` 结尾带空行）、Ed25519 验签、SHA-256、base64url、公钥指纹（sha256 前 8 字节冒号分隔）。
- 新增 `SourceShare.ets`：`hghubx-src://` 分享口令 = `base64url(gzip(utf8(packageJson)))`，解压上限 512 KB。
- `SourceManager` 重构为包存储：包校验、导入、`updateUrls` 手动检查（id 一致 + 验签 + semver 递增 + init 冒烟）、导出分享码、`allowUntrusted` 门禁（默认开启）。
- 修复：HarmonyOS `cryptoFramework` 不接受 32 字节原始 Ed25519 公钥（报 `convert key fail`），需先包 RFC 8410 SPKI DER 前缀 `302a300506032b6570032100`。
- 修复：`ZStream.totalOut` 在真机不可靠导致解压长度错判（报「超出 512 KB 上限」），改用系统 `GZip.gzopen/gzread` 文件式 API，`gzread` 返回值为真实字节数；临时文件放 `cacheDir` 用完即删。
- 自检夹具：rawfile `quickjs/p3b-signed/`（package.json / share.txt / tampered.json，Python cryptography 本地签发），启动自检验证解码、验签、篡改拒绝。
- 提交 `4c2b2ad`、`40a52ef`、`d325b75`；构建 run 39 / 41；真机 `source package pilot: {"id":"com.hghubx.demo-signed",...,"shareOk":true,"tamperRejected":true}` 通过。

---

## [2.2.10-p1a~p3a] 2026-11-27 ~ 11-28 — QuickJS 源运行时试点 P1–P3a

- 背景与决策见 `docs/investigations/upstream-v3-quickjs-pilot-summary.md`。上游 v3.0.0 重写历史与 fork 无共同祖先，不能 merge；在 `sync/upstream-3.0.0-pilot` 分支分阶段试点，`main` 保持稳定。
- P1a：QuickJS spike——QuickJS-NG v0.18.0 + OHOS command-line-tools 6.0.1.251 编译 arm64 `libquickjs_spike.so`（首次失败为链接 x86_64 `libace_napi.z.so`，改匹配 `*aarch64-linux-ohos*`）。
- P1b：`.so` 入包（`harmony/entry/libs/arm64-v8a/`）+ ArkTS 同步 `evaluate`（首次失败为 ArkTS 保留字 `eval`，导出改名 `evaluate`）。
- P1c：`evaluateAsync` + `napi_threadsafe_function` 回调 ArkTS `httpRequest`、原生线程 mutex/condvar 阻塞等待（20s 超时）；修复 C 侧对对象参数 `JS_ToCString` 得 `[object Object]`，改 `JS_JSONStringify`。P1c2 / P1c4：从 rawfile 读取上游 demo 源包，校验 schema/runtime/capabilities 并执行 `init/home/detail/playback`。
- P2：`SourceManager`（`filesDir/sources/<id>`、`installed.json` / `active.json` 持久化、导入 / 激活 / 回滚 / 删除 / 测试 / 禁用更新检查）；修复 `importTrusted` 无条件 `mkdirSync` 报 `File exists`，改 `ensureDir`。
- P3a：通用 `__hostCall(op, payload)` 桥 + host 六能力（info / auth（试点固定 token:null）/ fetch / htmlQuery / crypto / storage）；原生运行时限制 16 MiB 堆 / 512 KiB 栈 / 12s 中断，执行前删除 `__hostCall` 原始全局。关键修复：`JS_SetPropertyStr` 接管值后再次 `JS_FreeValue` 双重释放导致真机闪退；ECDH 空 salt 传 `Base64Helper.decodeSync('')` 崩溃。
- host.fetch 边界：HTTPS 公网 + manifest origin 白名单 + 禁 Host/Cookie 等敏感头 + 256 KiB 请求体 / 2 MiB 响应；htmlQuery 只读子集 200 条上限；storage per-source 64 键 / 32 KB。
- 构建 run 18–34；真机 `source pilot` / `source pilot active` / `source host pilot` 通过。

---

## [2.2.10] 2026-11-24 — 同步上游 v2.2.10 / TV v2.2.5

- 合并上游 main（v2.2.10 / TV v2.2.5，上游 HEAD `6370c44`）。GitHub 自动合并成功，无文本冲突。
- 上游要点：
  - 业务 API 迁移到 `dx150-edge-v1` 作用域加密网关（#256）
  - 网络切换与 401 同步失败时静默恢复（#246）
  - 移动端长按加速改为右半屏触摸 + 顶部提示（#251）
  - 完结结果卡显示总集数（#248）
  - 发现页标签支持长按置顶，并在标签页头部显示（#252）
  - 搜索热门标签改为官网首页 SSR 同步（#254）
  - 窄屏多语言下的换行/裁剪修复（#249）
  - 版本更新至 `2.2.10`，TV 更新至 `2.2.5`
- 鸿蒙版本对齐 `2.2.10`；`api.ts`、`App.tsx`、`Profile.tsx`、`LinePicker.tsx` 的鸿蒙分支均保留。
- 修复本地媒体服务的 HTTP suffix Range 语义：`bytes=-N` 现在返回文件末尾 N 字节。
- 修复 HLS 相对路径归一化：支持 `.` / `..` 片段，避免上游分片 URL 拼接失败。
- 新增鸿蒙播放诊断日志：设置页可开关并复制日志；写入应用沙箱 `filesDir/playback.log`，按 2 MiB 轮转，导出上限 256 KiB。
- 播放诊断写入前统一脱敏 URL、token、Cookie、密码等字段；原生日志透传也会脱敏。

---
---

## [2.2.9] 2026-11-24 — 同步上游 v2.2.9

- 合并上游 main（v2.2.9，上游 HEAD `7c761b3`）。GitHub 自动合并成功，无文本冲突。
- 上游要点：
  - 播放器移除 Android WebView 视频上层的模糊与动画层（#240）
  - 个人库收藏状态筛选合并为单图标菜单（#243）
  - 频道与标签视频列表新增热度/时间等指标排序（#244）
  - 版本更新至 `2.2.9`
- 鸿蒙版本对齐 `2.2.9`；`api.ts`、`App.tsx`、`Profile.tsx`、`LinePicker.tsx` 的鸿蒙分支均保留。

---
---

## [2.2.8] 2026-11-23 — 同步上游 v2.2.8

- 合并上游 main（v2.2.8，上游 HEAD `ccf80c3`）。
- 上游要点：
  - 播放器/信息流 UI 修复：顶部搜索高度、操作栏图标、提示 toast、全屏锁与横屏舞台保持（#217–#220、#215）
  - 频道/搜索/发现/帖子数据源与排序继续对齐官网 SSR（#226、#225、#228、#229、#232）
  - 搜索页支持横向滑动切换，导航激活时重置搜索（#230、#234）
  - 分类页新增最新/推荐列表，个人库支持收藏排序与完结角标（#238、#239）
  - 全屏暂停时显示集数提示；隐藏被覆盖页面并释放被埋藏的解码器（#236、#240）
  - Android 增加 Material You 单色自适应图标；CI 预览构建修复（#216、#222）
  - 版本更新至 `2.2.8`
- 鸿蒙版本对齐 `2.2.8`；`App.tsx` 合并上游 `PageCoveredContext` 与鸿蒙返回键/身份逻辑；`api.ts`、i18n 保留鸿蒙分支。
- 冲突解决：仅 `App.tsx` 存在导入区冲突，合并后同时保留 `PageCoveredContext` 与 `isHarmony`。
- 验证：主工程/Node/测试三套 `tsc` 通过；i18n 800 keys、文档 200 links、体积预算与版本同步通过；`Harmony web bundle` 已成功重建 `www` 与压缩包。

---
---

## [2.2.6] 2026-11-21 — 同步上游 v2.2.6

- 合并上游 main（v2.2.6 / TV v2.2.4，上游 HEAD `848a199`）。
- 上游要点：
  - TV 端新增应用内更新器，支持 SHA-256 校验（#201）
  - FakeIP DNS 回答改为可固定，避免整组 DNS 被拒绝（#199）
  - 个人库支持批量全选，并移除底部清空历史入口（#205）
  - 搜索历史 chip 字号与间距优化（#207）
  - 搜索榜单、个人库与频道页支持横向滑动切换（#208 / #209）
  - 频道列表 SSR 同步、滚动自动加载与海报角标（#211）
  - CI / Release workflow 拆分，新增测试预览与自动合并流程（#210 / #212 / #214）
- 鸿蒙层版本对齐 `2.2.6`；`hg-bridge` 与 loopback 媒体服务无接口变化。
- 全面屏适配：窗口启用沉浸式全屏布局，状态栏与导航条透明，消除播放页竖屏/横屏上下白边；ArkWeb 继续用 `viewport-fit=cover` 和 safe-area 避让关键控件。
- 补齐 `hg-bridge` 的 Tauri `Channel` 兼容层，修复上游 TV 更新器导致鸿蒙前端构建失败的问题。
- 返回键语义优化：每次返回只关闭一层弹层/页面；鸿蒙版回到首页后移动到后台，不退出应用。
- 修复侧滑返回手势：在 `Index` 页面增加 `onBackPress` 拦截，避免返回手势直接落到 Ability 层而退到后台。
- 冲突解决：`Profile` 页脚保留鸿蒙身份；`tests/tv-remote-fixture.mjs` 同时保留 Tauri callback id 与上游 update/download fixture 能力。

---
---

## [2.2.5] 2026-11-21 — 同步上游 v2.2.5

- 合并上游 main（v2.2.5，合并提交 `d64bb2d`）。上游要点（详见 `docs/release-notes/v2.2.5.md`）：
  - 繁体字幕轨与界面繁体本地化（#190），支持按系统语言自动选择
  - 播放器组件抽离重构（#192），修复快进后拖动进度条画面跳动
  - 倍速按钮长按弹出自定义倍速面板（#193），预设 0.5x 步进与常用档位
  - 私人壳 / 影子壳封面图防串扰（#194），仅显示当前条目
  - 键盘输入法面板避让（#191），评论框随键盘上移
  - 打包更新：Windows NSIS 校验、macOS Universal DMG、Linux amd64 `.deb`、Android ABI 分包 `versionCode=2002005`、iOS `.ipa` 已签名
- 本仓库随合并自动获得上述前端与 Rust 变更；鸿蒙层无接口变化，`app.json5` 版本对齐 `2.2.5`。

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

### 同步上游（PR #10，合并提交 `f5cd74e`）

- 合并上游 74 个提交（v2.2.2 / v2.2.3 / v2.2.4，至 `d69dd0a`）：
  - 播放与全屏切集系列修复（上游 #176–#182）、横竖屏提示不堆叠、移除横版视频重复控件
  - 移动端播放控件与横屏布局优化、桌面全屏锚定与闲置隐藏
  - 搜索历史长按批量删除（#184）、启动页偏好（#180/#185）
  - 帖子详情防闪烁（#165/#166）、个人库滚动加载与多选删除（#168/#169）
  - TV 子项目独立版本号（`src-tauri/tauri.tv.conf.json`）与独立 CI/CD `tv.yml`
  - `AGENTS.md` 维护者约定更新；回归测试扩充（post-flicker、home-controls、ui-feedback）

### 鸿蒙层重放与适配

- `vite.config.ts` 三方合并：上游「标准版 / TV 版双版本号注入」+ 本仓库 hg-bridge alias（合并结果与「fork + 上游 diff」逐行一致）
- `src/shared/api/api.ts` 三方合并：上游 `api_login` reauth 参数 + 本仓库 `isHarmony` UA 检测、平台判定与 hg 本地服务地址
- hg-bridge 命令面核对：上游新增 invoke 调用均在既有 64 个 case 内，无需增补

### CI 与工作流

- `ci.yml` 对齐上游 v2.2.4：playback `tv` 场景移至 `tv.yml` 独立验收（消除 fixture 端口冲突）、core 增加 post-flicker 回归、ffmpeg .deb 缓存安装修复
- 恢复上游 `tv.yml` 以满足 `check-doc-links` 对 `docs/subsystems/build-release.md` 的链接校验

### 过程记录

1. 巡检发现上游领先 74 个提交，且 PR #2–#7 改动已全部包含于 main，关闭这 6 个冗余 PR。
2. 以「上游 `d69dd0a` 树为基线 + 73 条差异覆盖」构造同步树；合并文件先经 `PUT /contents` 写入临时分支 `tmp-blobs24` 取得 blob sha 再引用。
3. 首轮树构造误用 sync 分支空提交的树当作 main 树，导致 `harmony-web-bundle.yml` 丢失、`ci.yml` 被覆盖；改用 main 真实树 `50212f98` 重新分类重建。
4. CI 第 1 轮：Frontend build 失败（`check-doc-links` 要求 `tv.yml` 存在）→ 恢复上游 `tv.yml`（`96de229`）。
5. CI 第 2 轮：Playback (extended) 失败（旧 `ci.yml` 的 `tv` 场景与新测试脚本端口冲突，12/13 通过）→ 经确认将 `ci.yml` 全量对齐上游 v2.2.4（`fee4889`）。
6. 第 3 轮全绿后合并；`harmony-web-bundle` run #2 重建产物并回写 main（`bfcf3d3`）；补空提交 `e547e0c8` 使 main 具备完整检查结论；删除临时分支。

---

## [2.2.0] 2026-11-18

### 同步上游（PR #9，合并提交 `684e5a3`）

- 合并上游 49 个提交（v2.2.0，`a7d22db`）：前端目录重构为 `features / shared / app / tv` 并新增 Android TV 版；Rust 端拆分为 `api / net / media / lines`；会话跨线路保持、启动 overlay、诊断导出限制；回归套件精简为 smoke + 6 项。

### 鸿蒙层重放与适配

- `hg-bridge` 增补 v2.2.0 命令：观看历史云端同步 `api_account_history*`、`api_post_tag`、`api_topic` 分页
- 无 `window.hghub` 时 `invoke` / `addPluginListener` 回退 Tauri 官方通道（修复浏览器测试全红）
- `isTauri` 恢复函数语义；剪贴板写入走插件 IPC
- `scripts/fixtures/app-ui.mjs` 与 `tests/tv-remote-fixture.mjs` 兼容 Tauri v2 数字回调 id
- `harmony/patches/apply-patch.mjs` 锚点重写至 v2.2.0 文件布局

### 前置修复批次（PR #2–#7，内容随 #9 生效；相应 PR 已于 2026-11-20 关闭）

- PR #2：修复 hg-bridge 无 `window.hghub` 时的调用回退（CI 全红根因）
- PR #3：根 README 构建说明与 `harmony/README` 对齐（`hvigorw` → `build-hap.sh`）
- PR #4：`compatibleSdkVersion` 升至 `6.0.0(20)`、hvigor `modelVersion` 升至 `6.0.0`（面向鸿蒙 6/7）
- PR #5：`harmony/README.md` 重复「## 许可」标题修复
- PR #6：重打包自包含 zip 并同步补丁层修复
- PR #7：`oh-package` `modelVersion` 同步 6.0.0、`build-hap.sh` 增加 unsigned HAP 签名提示

### 过程记录

1. 先尝试跨仓库 sync PR #8（head `zxsos:main`），因两仓库提交历史不同无法自动合并，关闭；改用「自建分支 + 树构造」方案。
2. 首次合并误用上游旧基线 `bebfb7a`，src-tauri 处于 v2.1.x/v2.2.0 混合态（Rust 通过但 Frontend/smoke/playback 失败）；改为「以上游 `a7d22db` 树为基线 + 重放鸿蒙差异」后解决。
3. `POST /git/blobs` 上传大 blob 内容损坏（core.ts、apply-patch.mjs、vite.config.ts、api.ts 共 4 个），改经 `PUT /contents` 写入临时分支后引用正确 sha；同步补上两个 fixture 修复版。
4. 最终同步提交 `6b8b3d2` CI 全绿；`harmony-web-bundle` run #1（`44392530763`，约 57 秒）重建 www 并重打包 zip，回写 sync 分支（`90f2cb2`）。
5. GITHUB_TOKEN 提交不触发 CI，补空提交 `6b5448a` 让 PR 检查在最终 head 重跑，全绿后合并 PR #9。
6. 合并后 main CI 首轮出现两个基础设施抖动失败（apt 源临时找不到 ffmpeg、kernel.org 镜像 IPv6 不可达），`rerun-failed-jobs` 重跑后全部通过。

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
| `harmony-web-bundle` run #1（`44392530763`） | v2.2.0 同步后触发 | success（约 57 s）：构建 www → 重打包 zip → 回写 `90f2cb2` |
| `harmony-web-bundle` run #2（`44790422678`） | v2.2.4 同步合并后触发 | success（约 59 s）：v2.2.4 www 22 资产 + zip 946 KB/106 条目回写 `bfcf3d3` |
| PR #10 三轮 CI | doc-links → 恢复 `tv.yml`；extended 端口冲突 → `ci.yml` 对齐上游 | 第 3 轮全绿（Frontend/smoke/Playback core+extended/Rust/TV build & acceptance） |
| main `e547e0c8` CI | 产物回写后补空提交触发 | 全绿 |

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
