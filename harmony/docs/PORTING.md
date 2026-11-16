# 移植说明与验收清单

## 0. 验证状态（重要）

| 项目 | 状态 | 说明 |
|---|---|---|
| `patches/src/hg-bridge/*.ts` 类型检查 | ✅ 已通过 | 在真实 HGhubX 源码树上跑 `tsc --noEmit` 零错误 |
| `patches/apply-patch.mjs` | ✅ 已实测 | 对 `zxsos/HGhubX` **commit `bebfb7a`（v2.0.0）** 的全新解包跑通，6 处改动全部命中；`tsc --noEmit` 零错误 |
| 热搜榜解析 `parseSearchHot` | ✅ 已实测 | 用 jsdom 跑了 6 个用例 + 7 个 href 边界，全部与 Rust 单测期望一致 |
| 线路模块 `lines.ts` | ✅ 已实测 | 25 项断言：`publish.js` 词法（注释/字符串/模板/正则里的假声明）、动态数组 fail-closed、domains×subdomains 组合、DNS 名校验、`healthyVideoData` 判据、`scriptSrc` 同源校验、选线取最小延迟、双发布页交替合并去重 |
| 线路/诊断端到端 | ✅ 已实测 | 假桥 + 假上游跑通 `line_state`/`line_health`/`line_auto`/`net_diag`：健康返回、探测超时降级、镜像失败时保留当前线路 |
| 更新检查 `update.ts` | ✅ 已实测 | 21 项断言，含 Rust 单测原样用例（`compares_versions`、`reads_version_out_of_tag`）；端到端覆盖 200/404/500/非 JSON 四种响应 |
| 返回键链路 `addPluginListener`→`__hgBackEvent`→`background` | ✅ 已实测 | Node 里跑通：注册前不吞键、注册后逐次触发、注销后回退、`plugin:app\|exit` 调 `background()`（退到后台） |
| 前端 `vite build` | ⚠️ 未验证 | 沙箱 Node 缺 WebAssembly，vite 起不来（环境问题，不是代码问题）；你本机应能正常出包 |
| ArkTS 代码（`.ets`） | ❌ 未编译 | 本环境没有 HarmonyOS SDK，**必须在 DevEco Studio 里过一遍编译**，socket / resourceManager / cryptoFramework 的 API 签名请按你的 SDK 版本核对 |

也就是说：**前端那一半我验证过了，ArkTS 那一半需要你在 DevEco 里编译验证。**

## 1. 为什么是这个架构

- **不能用 `onInterceptRequest` 做媒体代理**：它是同步回调，拿不到异步网络结果；`/hls` `/seg` `/img` 都要现拉上游，同步返回空响应等于播放全挂。
- **所以自起 loopback HTTP 服务**：页面和媒体同源（`http://127.0.0.1:17860`），既没有 CORS，也不依赖自定义协议。HGhub 的 Linux 桌面版就是同样原因起了 loopback 代理（`src-tauri/src/linux_http.rs`）。
- **业务逻辑留在前端 TS**：Rust 的业务接口收敛成一个信封（`POST /api/edge/request` + base64 body），ArkTS 侧只做"哑传输"，避免在 ArkTS 里跟强类型 JSON 打架。

## 1.5 源码基线

本次移植以 `zxsos/HGhubX` 的 `main` @ `bebfb7a3385d8fde7918e6992692ec7b3b48489f`
（2026-11-13，`v2.0.0`）为基线。所有"原文锚点"都取自该 commit，命令 path 也逐条对照该
版本的 `src-tauri/src/api.rs`。复现：

```bash
git clone https://github.com/zxsos/HGhubX.git
cd HGhubX && git checkout bebfb7a3385d8fde7918e6992692ec7b3b48489f
```

上游更新后补丁会因原文不匹配而报错停下（这是刻意设计：宁可失败也不改错位置），
届时按报错提示更新锚点，并重新核对 `api.rs` 里的 path 与信封字段。

## 2. 编译与装机步骤

### 2.1 打补丁 + 前端构建

```bash
git clone https://github.com/zxsos/HGhubX.git
node HGhubHarmony/patches/apply-patch.mjs ./HGhubX
cd HGhubX && pnpm install && pnpm build
../HGhubHarmony/scripts/sync-web.sh .
```

补丁会做这些事（都有原文校验，上游改版会立刻报错而不是静默失败）：

1. 拷 `src/hg-bridge/{core,line,window,clipboard}.ts`
2. `src/api.ts`：加 `isHarmony`（UA 带 `OpenHarmony|ArkWeb`）、`platform` 归入移动端、`isMobile` 含鸿蒙
3. `src/api.ts`：`LOCAL` 改成 `http://127.0.0.1:17860`
4. `vite.config.ts`：把 `@tauri-apps/api/core|window`、`@tauri-apps/plugin-clipboard-manager` 别名指到 `hg-bridge`

> ⚠️ 17860 这个端口出现在三个地方，改就必须一起改：`Index.ets` 的 `PORT`、`apply-patch.mjs` 的 `LOCAL_ORIGIN`、已经打过补丁的 `src/api.ts`。

### 2.2 DevEco Studio

1. 打开 `HGhubHarmony` 目录（不是仓库根，是这份骨架根目录）。
2. 首次打开会提示同步 `ohpm`，允许它下载 `@ohos/hvigor-ohos-plugin` 等。
3. **改 SDK 版本**：`build-profile.json5` 里 `compatibleSdkVersion` 我填的是 `"5.0.0(12)"` 占位，请改成你本机为鸿蒙 7 安装的 SDK（IDE 会提示可用项）。`module.json5` 里的 `deviceTypes` 已含 phone/tablet。
4. 签名：Project Structure → Signing Configs → 勾 **Automatically generate signature**（需要登录已实名认证的华为账号）。它会生成调试证书 + profile，并把 Mate 80 的 UDID 注册进调试设备。
5. 编译：Build → Build Hap(s)/APP(s) → Build Hap(s)。

### 2.3 安装

```bash
hdc list targets
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa start -a EntryAbility -b com.hghubx.harmony
```

命令行等价编译：

```bash
./hvigorw --mode module -p module=entry@default -p product=default assembleHap
```

## 3. 真机自检顺序（出问题按这个顺序定位）

1. **本地服务起来了吗**：首页能显示出来 = loopback server 正常；显示"本地服务启动失败"= 端口占用或缺 INTERNET 权限。
2. **`window.hghub` 注入了吗**：DevEco 的 ArkWeb 调试（`chrome://inspect` 那一套）里执行 `typeof window.hghub`，应为 `object`。为 `undefined` 说明 `registerJavaScriptProxy` 没生效——`Index.ets` 里注册后调了一次 `refresh()`，如果仍然没有，改成"先注册再设 src"的写法。
3. **信封通不通**：控制台看 `自然` 请求；失败时抓 `hdc hilog | grep HGhubX`。
4. **封面出不出**：不出说明 `/img` 的 AES 解密或 Referer 有问题（`setBase()` 没同步会导致上游 403）。
5. **播放**：`/hls` 返回的是改写后的 m3u8（浏览器里直接打开 `http://127.0.0.1:17860/hls?u=<编码后的m3u8>` 看）。能出清单但画面不动，基本是 ArkWeb `<video>` 的 codec/封装问题，见下节。

## 4. 已移植 / 未移植

### 已移植（60 个命令里的绝大多数）

`app_boot`、`security_set`、`api_login/register/logout/me`、`api_feed`、`api_original_videos`、
`api_topics/topic/tags/tag_videos`、`api_category`、`api_rank`、`api_search`、`api_posts/post/post_playback`、
`api_post_like/post_collect/post_comments/post_categories/post_category`、`api_video`、`api_play`（含新旧接口回退）、
`api_related`、`api_comments/comment_send`、`api_like/collect/follow`、`api_user/user_stats/user_videos`、
`api_following`、`open_url`、`set_orientation`、`set_text_interaction`、`debug_log`、`cache_clear`、
`line_state/line_set/line_custom_set/line_reset/line_cancel`、
`line_mirrors`（发布页 `publish.js` 解析）、`line_probe`、`line_auto`、`line_try_main`、`line_health`、
`net_diag`（精简版：系统网络快照 + 真实接口探测）、`check_update`（GitHub Release + 版本号抠取）、`proxy_state/proxy_set`、
`api_search_hot`（DOM 解析官网 SSR 热搜榜）、`plugin:app|exit`（返回链末端 → 退到后台）。

### 未移植（有明确占位，不会静默出错）

| 命令 | 现状 | 需要做什么 |
|---|---|---|
| `proxy_test` | 抛错 | 鸿蒙没有应用级 HTTP 代理配置，本来就走系统代理/VPN；要做得接 `@ohos.net.connection` 的代理查询 |
| `net_diag` 的 DNS/TCP 分段 | 精简 | 现在给的是"系统 DNS 服务器 + HTTP 探测耗时"，没有真正发起 DNS 查询与独立 TCP 连接（`tcp.skipped=true` 会如实显示） |
| `playback_log_*` | 关闭 | 播放诊断日志依赖文件写入，移动端默认关掉 |

## 5. 已知风险（按踩坑概率排序）

1. **ArkTS socket 服务需要真机验证**：`@kit.NetworkKit` 的 `TCPSocketServer` 在回环地址上监听、`SocketMessageInfo` 的分包行为，都以你的 SDK 版本为准；如果 `listen()` 被拒，把 `family: 1` 的 IPv4 监听改成 `'127.0.0.1'` 显式绑定再试。
2. **ArkWeb 的 `<video>` 播放链路**：HLS 通常没问题，但 HEVC / fMP4 / 加密 HLS 的支持要实测。真不行就退到 `AVPlayer + XComponent`，那会是另一轮工作量（Rust 侧的 `media.rs` 分片改写逻辑可以复用思路）。
3. **m3u8 改写完整性**：我按 `media.rs` 的规则实现了分片行、`URI="..."`（KEY/MAP/MEDIA）、丢弃 `EXT-X-CONTENT-STEERING`。`#EXT-X-DATERANGE` 里的 URI 属性没有像 Rust 那样过滤掉，遇到带 SCTE-35 的源需要补。
4. **封面解密性能**：AES-CBC 走 `@kit.CryptoArchitectureKit`，一次解密整张图，列表页大图多时注意首屏；Rust 版有 240 张的内存缓存，这里没做（Web 层有 HTTP 缓存，影响有限）。
5. **防盗链**：所有媒体请求带 `Referer: <当前base>/`，`setBase()` 必须在首页加载前完成（`core.ts` 模块初始化时会同步一次）。
6. **返回键的"到底了"语义**：页面栈消费完之后 → **退到后台**（`moveAbilityToBackground()`），
   不再杀进程；只有该接口调用失败时才兜底 `terminateSelf()`。注意这与原 Android 版
   （`plugin:app|exit` 直接退出）是**刻意不同**的：鸿蒙用户按返回期待回到桌面而不是退出。

## 5.5 两块补齐的实现要点

### 返回键（对应原 `src/back.ts` + App.tsx 的 `addPluginListener`）

原逻辑在 `App.tsx` 里注册 `app/back-button`，链条是：面板/弹层 → 沉浸全屏 → 登录框 → 页面栈 →
回首页 tab → `invoke("plugin:app|exit")`。鸿蒙侧复刻：

```
UIAbility.onBackPressed()                      // 同步，必须立刻返回 boolean
  └─ Bridge.handleBack()
       ├─ pageReady && backEnabled ? 执行 window.__hgBackEvent() 并 return true
       └─ 否则 return false（交回系统，退到后台/退出）
```

- `backEnabled` 由前端在 `addPluginListener` 注册/注销时通过 `hghub.setBackEnabled()` 同步过来
  —— 这样 `onBackPressed` 的返回值才是同步且准确的（不能等 JS 异步结果）。
- `window.__hgBackEvent()` 逐个调用监听器（App.tsx 注册的那个），它内部走 `runBack()` 与页面栈；
  一路退到首页后再按一次，链末端是 `invoke("plugin:app|exit")` → `Bridge.background()` →
  `UIAbilityContext.moveAbilityToBackground()`，**退到后台，不杀进程**，回到桌面再进来还是原来的页面。
- `moveAbilityToBackground()` 是 API 12+ 且仅手机/平板支持；万一调用失败，兜底才 `terminateSelf()`
  （避免用户按返回毫无反应），并会打 error 日志。
- 已注册进 `registerJavaScriptProxy` 的方法表：`setBackEnabled`、`background`。

### 热搜榜（对应 `src-tauri/src/search_hot.rs`）

- 请求 `GET {base}/search/?_hghubx_hot=<时间戳>-<序号>`（带 `Referer: {base}/`、`Accept: text/html`），
  2 MiB 上限，失败文案与 Rust 一致（`获取官网热搜失败：…`）。
- 解析用 `DOMParser`（ArkWeb 自带，不需要额外 DOM 库）：`section.hg-search-hot` →
  `a.hg-search-hot__item`，`href` 必须是 `/video/<数字>/`，标题取 `.hg-search-hot__name` 文本
  （回退 `data-search-hot`），播放量取 `.hg-search-hot__plays`，按 `video_id` 去重，最多 20 条。
- 已用 Rust 单测里的原始 HTML 样本做过对照，实体解码（`&amp;`、`&nbsp;`）、去重、边界 id
  （`0` / 多段路径 / 绝对地址 / 协议相对地址 / `2^53`）行为一致。

### 线路与镜像（对应 `src-tauri/src/lines.rs`）

- 发布页 `https://huangguoai.pages.dev/`、`https://huang-guo.pages.dev/` 上的 `publish.js` 被**当数据解析**：
  自带一个极简 JS 词法器（跳过注释、字符串、模板、正则），只接受顶层
  `var/let/const name = ['..']` 字面量数组；出现函数调用、拼接、重复声明、非字符串一律失败。
- 只认同源 HTTPS、路径以 `publish.js` 结尾的脚本；跨域/改名一律拒绝。
- 探测判据与 Rust 一致：解包后的 data 必须"像真的视频列表"（`items[].id>0`、`title` 非空、
  `pagination.page/size` 非 0 且 `pages/total` 存在），只看 HTTP 200 不算通。
- 选线：主站优先；主站不行才抓发布页 → 并发探前 10 个可信镜像 → 取**延迟最小的可用项**；
  全挂则 `reason=all-down` 并保持当前线路不动。
- 代次语义照搬：`line_cancel` 与每次 `line_auto`/`line_try_main` 都会让 `lineGeneration` 自增，
  探测回来时代次变了就 `cancelled=true`，不切线路。
- ⚠️ 差异：Rust 把 token 按 origin 隔离存储，切线路不会掉登录；我们只存一份 token，
  所以**切线路会清掉会话**（宁可让用户重登，也不把 A 站 token 发给 B 站）。

### 网络诊断（对应 `net.rs::diagnose`，精简版）

- ArkTS 新增 `netInfo()`：`@ohos.net.connection` 读默认网络、承载类型、**系统 DNS 服务器**、链路地址、MTU。
- 前端 `net_diag` 再打一次真实接口（`/api/videos?page=1&size=1`，5 秒超时）拿状态与耗时，
  然后按 `src/netDiagReport.ts` 期望的结构输出 `verdict/summary/dns/tcp/http/env/advice`，
  能直接被「复制诊断报告」格式化。
- 没做的：真正发起 DNS 查询、独立 TCP 连接探测（`tcp.skipped=true` 会明确写在报告里，
  不会假装测过）。

### 更新检查（对应 `api.rs::check_update`）

- `GET https://api.github.com/repos/zxsos/HGhubX/releases/latest`，12 秒超时，带 `Accept: application/vnd.github+json`。
- 404 当作"还没发过 Release"（返回 `has_update:false` + Release 页地址），不是错误；
  其它非 2xx 抛 `GitHub 返回 HTTP <code>`；非 JSON 抛 `Release 数据解析失败：…`。
- 版本比较是**数字段比较**，不是字符串比较：`1.0.10 > 1.0.9` 必须成立。tag 不是纯版本号
  （`hgfix-1.2.1-r5`、`HGhubX 1.2.1+hg.1`），所以先抠出 `x.y.z` 再比——不抠就会"永远显示已是最新"。
- `notes` 按码点截断到 800 字（与 Rust 的 `chars().take(800)` 一致）。
- `asset`：Rust 按平台扩展名排序挑包；鸿蒙这边 GitHub 上没有 `.hap`，所以恒为 `null`，
  界面侧本来就用 `url` 打开 Release 页面（`Settings.tsx` 的 `doUpdate`）。若将来有人上传 `.hap`，
  会自动被选中最优包。
- ⚠️ **版本号要对齐两处**：`check_update` 比的是前端版本（vite 注入的 `package.json` version），
  而系统「应用信息」里显示的是 `AppScope/app.json5` 的 `versionName`。两者都保持 `2.0.0`，
  否则升级后会出现"检查更新一直说有新版"或"明明更新了还提示旧版"。

## 5.6 DevEco 首次编译对齐记录（2026-11-16）

Mate 80 上第一次 `assembleHap` 报了 7 个错误 + 12 个告警，已全部处理并提交：

| 报错 | 原因 | 处理 |
|---|---|---|
| `Property 'clearCache' does not exist on type 'WebviewController'`（Bridge.ets） | 本 SDK 的 `WebviewController` 只有 `clearSslCache`，没有 `clearCache` | 不用 `WebStorage.deleteAllData()`（那会连 localStorage 里的登录态/线路选择/观看记录一起清掉），`cache_clear` 明确降级为「无可清理 + 记日志」——Rust 版清的是内存缓存，移植版媒体代理不做内容缓存 |
| `Type 'ArrayBuffer' is missing ... from type 'Uint8Array'`（Media.ets ×2） | cryptoFramework 的 `DataBlob.data` 必须是 **Uint8Array** | 改为直接传 `Uint8Array`，删掉多余的 `toArrayBuffer` 转换 |
| `No overload matches this call`（Media.ets ×2，`init` / `doFinal`） | 上面那条的连带错误（`convertKey` 返回值被推成 `void & Promise<SymKey>`） | 同上；`plain` 显式标注 `cryptoFramework.DataBlob` |
| `Property 'data' does not exist on type 'void & Promise<DataBlob>'`（Media.ets） | 同上 | 同上 |

告警（不阻塞编译，也一并处理了）：
- `Http.ets` / `LocalServer.ets`：ArkTS 要求对可能抛异常的调用显式处理 → 分别给 `request.request()`、`TCPSocketServer` 构造与 `listen()` 加了 try/catch（错误信息里带上端口）。
- `Index.ets`：`getContext` 已废弃 → 改用 `getUIContext().getHostContext()`，取不到再兜底旧写法。

仍然会看到、且**不用管**的提示：
- `cryptoFramework` 的 syscap 提示（`createSymKeyGenerator` / `init` / `doFinal` 等"并非所有设备具备"）——这是泛型提示，手机平板都有。
- `build-profile.json5` 未显式声明 `targetSdkVersion` 的建议——DevEco 里选定 SDK 后会自己写，别手抄。

## 5.7 真机白屏排查（第一次装机最可能踩的坑）

> **现状（2026-11-16 之后）**：前端产物已通过 CI 提交进仓库
> （`harmony/entry/src/main/resources/rawfile/www/`：`index.html` + `assets/*.js/css` + `logo.svg`，约 1.1 MB），
> `.gitignore` 也去掉了对该目录的排除。直接 clone / 解压 zip 就能 Build，**不再需要本地 Node**。
> 下面的排查流程保留给"改了前端却忘了重新生成产物"或产物被清空的情况。



**头号原因：`rawfile/www/` 是空的。** 该目录被 `.gitignore` 排除，从仓库/zip 拿到的工程里只有 `README.txt`，
LocalServer 取不到 `index.html`，页面自然全白。排查顺序：

```bash
# ① 构建机上确认前端产物在不在（必须在，不能只有 README.txt）
ls harmony/entry/src/main/resources/rawfile/www/
# 缺的话一步补齐：
harmony/scripts/build-web.sh      # = 打补丁 + pnpm install + pnpm build + 同步 dist
# 然后重新 Build HAP

# ② 看本地服务与页面加载（App 里已把关键信息打到 hilog）
hdc shell hilog | grep HGhubX
#   local server on http://127.0.0.1:17860, bundle=true     ← 服务起来了、产物也在
#   page loaded: http://127.0.0.1:17860/index.html          ← 页面真的加载了
#   http 404 url=.../index.html                             ← 产物缺失（回到 ①）
#   load error: net::ERR_CONNECTION_REFUSED ...              ← 本地服务没起来（端口占用/权限）
#   web console: ...                                        ← 前端 JS 的报错，原样可见

# ③ 端口是否被占
hdc shell netstat -an | grep 17860
```

界面上也已经加了自证手段，**不依赖 Web 能渲染**：
- 产物缺失 → 由 ArkUI 直接盖一层红色标题的说明面板（含修复命令），不会再让你对着白屏猜；
- 页面加载失败 / 收到 4xx-5xx → 面板显示最后一次的错误与 URL；
- 本地服务启动失败 → 显示原因与端口号。

另外这版给 `Web` 组件接上了 `onConsole` / `onErrorReceive` / `onHttpErrorReceive`，
前端 console、资源加载错误、HTTP 错误码都会进 hilog（TAG = `HGhubX`），远程排查不用连调试器。

## 6. 合规

HGhubX 是 PolyForm Noncommercial 1.0.0：个人学习、自用、非营利可以；禁止打包出售、接广告/会员/付费点播。
客户端不含视频内容，播放源来自第三方站点，使用需自行遵守所在地法律与上游条款。
