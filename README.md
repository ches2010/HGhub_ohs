<div align="center">

<img src="hghubx.svg" alt="HGhubX" width="128" height="128" />

# HGhubX

**第三方客户端 · Rust + Tauri 2**

Windows / macOS / Linux / Android / iOS · iOS 圆角与玻璃材质 · 沉浸式竖屏播放
**+ HarmonyOS（本分支移植，产出 HAP）**

当前版本 **v2.2.10** · [Releases 下载与更新说明](https://github.com/ches2010/HGhub_ohs/releases) · [鸿蒙端更新日志](CHANGELOG-harmony.md)

</div>

## 鸿蒙（HarmonyOS）移植

本仓库在 [zxsos/HGhubX](https://github.com/zxsos/HGhubX) 源码之上，加了 `harmony/` 子工程，把原来的
Tauri 2 应用搬到鸿蒙，产出可安装的 HAP（Mate 80 / 鸿蒙 6、7 实测方向）。

> 为什么不是"编一下就行"：Tauri 没有 HarmonyOS 手机端 target（上游只有面向鸿蒙 PC 的实验分支），
> 现有 APK 在纯血鸿蒙上也装不上。所以这里换了宿主：**ArkWeb 跑原前端，ArkTS 顶替 Rust 层**。

### 架构

```
HAP
├── ArkWeb(Web 组件) ── http://127.0.0.1:17860/index.html   ← 原 HGhubX 前端（几乎不改）
│      └── window.hghub  ◀── registerJavaScriptProxy
└── ArkTS
     ├── Bridge      http / setBase / background / netInfo / setBackEnabled …
     └── LocalServer loopback HTTP（同源，规避 CORS 与自定义协议）
          ├── /          静态前端（rawfile/www）
          ├── /hls?u=    拉 m3u8 + 改写分片/key 地址
          ├── /seg?u=    分片/key 透传（含 Range），内层 m3u8 继续改写
          └── /img?u=    封面 AES-128-CBC 解密
```

Rust 侧的业务接口收敛成一个信封（`POST /api/edge/request`），所以 `patches/src/hg-bridge/` 里
只要复刻信封 + 拼 path，不用重写几十个命令的业务逻辑；换来的是前端代码几乎零改动
（只改平台识别与媒体基址）。

> 不用 `onInterceptRequest` 做媒体代理：它是同步回调，拿不到异步网络结果，`/hls` `/seg` 会全部失败。
> 这也是上游 Linux 桌面版起 loopback 代理的同一原因。

### 快速开始

> **前端产物已随仓库提交**（`harmony/entry/src/main/resources/rawfile/www/`，约 1.1 MB）。
> 所以下面第 1、2 步只是"改了前端才需要重做"的步骤；只改 ArkTS/页面时，直接跳到第 3 步。
>
> 也可以直接下载仓库根的 `HGhub_ohs_harmony.zip`（含 `harmony/` 与根 README，自带产物），解压后从第 3 步开始。

```bash
git clone https://github.com/ches2010/HGhub_ohs.git && cd HGhub_ohs

# 1) 改过 src/ 前端代码时才需要：打补丁 + 重新构建产物
node harmony/patches/apply-patch.mjs .     # 幂等
harmony/scripts/build-web.sh               # 装依赖 + 构建 + 同步进 rawfile/www

#   不想在本地装 Node：在 Actions 里跑 `Harmony web bundle`（workflow_dispatch），
#   它会在 runner 上构建并把产物提交回仓库。

# 2) 构建 HAP：工程里不含 hvigorw（由 DevEco / command-line-tools 提供），
#    推荐一键脚本（自动发现工具链与 SDK，默认 assembleHap，可透传自定义参数）；
#    或用 DevEco Studio 打开 harmony/ → 选本机 SDK → 自动签名 → Build Hap(s)
bash harmony/scripts/build-hap.sh
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
```

`harmony/build-profile.json5` 里的 `compatibleSdkVersion` 是占位值，要改成你本机装的 SDK。
端口 17860 出现在三处（`Index.ets` 的 `PORT`、`apply-patch.mjs` 的 `LOCAL_ORIGIN`、打过补丁的
`src/api.ts` 的 `LOCAL`），要改必须一起改。

### 移植范围

| 状态 | 内容 |
|---|---|
| ✅ 已移植 | 登录/注册/me、首页 feed、分类/标签/专题/榜单/搜索、吃瓜帖全套、详情、`api_play`（新旧接口回退）、评论与互动、用户页、**线路与镜像**（`publish.js` 解析 + 探测 + 自动选线）、**热搜榜**（SSR 解析）、**更新检查**、**返回键**（退到后台）、**网络诊断**（精简版）、媒体代理与封面解密 |
| ⚠️ 简化 | `net_diag` 的 DNS/TCP 分段（报告里如实标 `tcp.skipped`） |
| ❌ 未做 | `proxy_test`（鸿蒙无应用级代理配置，本来走系统代理/VPN）、`playback_log_*`（移动端关闭） |

差异说明：Rust 版 token 按 origin 隔离，切线路不掉登录；鸿蒙版只存一份 token，**切线路会清会话**
（宁可让用户重登，也不把 A 站 token 发给 B 站）。

### 验证状态

- 补丁层（`harmony/patches/src/hg-bridge/*.ts`）在基线 commit `bebfb7a` 上 `tsc --noEmit` **零错误**
- 线路模块 25 项断言、更新检查 21 项断言、热搜解析 6 用例 + 7 个 href 边界、返回键链路、线路/诊断端到端
  —— 均以 Node + 假上游跑过，用例取自上游 Rust 单测的原始样本
- **ArkTS 已通过 command-line-tools 构建验证**：HAP 已生成、签名并安装到真机；CI 中仍只构建前端产物，ArkTS 编译依赖本机 HarmonyOS SDK

细节见 [`harmony/docs/PORTING.md`](harmony/docs/PORTING.md)（真机自检顺序、已知风险都在里面）。

### 当前鸿蒙构建

- 版本：`v2.2.5`
- 最新 Release：[`v2.2.5-harmony`](https://github.com/ches2010/HGhub_ohs/releases/tag/v2.2.5-harmony)
- 资产：`HGhub_ohs-harmony-unsigned.hap`
- 更新日志：[`CHANGELOG-harmony.md`](CHANGELOG-harmony.md)

### 源码基线

上游 `zxsos/HGhubX` `main` @ `24e1b9c5c7d0dc26e950bfd6baad954319eb39d2`（v2.2.5）。
本仓库 `main` 已包含上游 v2.2.5 同步与鸿蒙适配；补丁靠"原文锚点"定位，上游继续改版时 `apply-patch.mjs` 仍会**报错停下**（不会静默改错位置）。


> ⚠️ 免责声明：本项目仅供 **学习与技术交流**，不提供、不存储、不分发任何音视频内容，与任何内容提供方无关联。
> 所有内容均来自第三方站点，版权归原作者与上游站点所有；使用者应自行遵守所在地法律法规，因使用产生的任何后果由使用者自行承担。

> 如您是版权方、上游站点、平台或有关机构，认为本仓库或官方发布渠道的内容涉及您的权益，请通过 GitHub Issues 联系；我会尽快核实并配合处理，包括修改或移除内容、暂停功能、停止维护、归档或调整仓库可见性。

**使用须知**

- **以访客身份正常使用**：像普通访客一样浏览就好，请勿滥用本项目。
- **不要给上游增加压力**：本项目本身不提供下载功能，请勿改动代码去做批量下载 / 批量抓取，也不要高频轮询、并发轰炸接口或挂机刷播放量；内置的封面与播放列表缓存请不要改小或关掉。
- **尊重上游版权**：不要去除水印与站点标识，不要把剧集搬运、转码、修改后二次分发到别处（网盘、资源站、其他 App 等），更不能改完拿出去出售。
- **不要公开传播接口与直链**：接口地址、播放直链、解密方式请勿公开张贴或打包成「资源站」——上游一旦封禁，所有人都没法再用。
- **不要商业化**：禁止打包出售、接入广告 / 会员 / 付费点播，或作为收费服务的一部分分发（详见 [LICENSE](LICENSE)）。
- **合理使用**：仅供个人学习、研究与自用；请在 24 小时内删除相关资源，并支持正版。
- **遵守当地法律**：使用者应自行判断并承担合规责任。

> ⚖️ 许可证自 v1.1.0 版本起改为 **PolyForm Noncommercial 1.0.0**：**禁止任何商业用途**——
> 包括打包出售、接入付费/会员/广告变现、作为收费产品或服务的一部分分发。
> 个人学习、研究、自用与非营利使用不受限制，详见 [LICENSE](LICENSE)。

## 仿冒提醒

> 🚫 **已发现的恶意修改版**：[`hichuv 仓库`](https://github.com/hichuv 仓库)
>
> 该仓库与本项目无关，是在旧版本源码基础上擅自加入**卡密验证、VIP 付费解锁**等变现功能的修改版，
> 代码改动不透明、安全性无法验证。**请勿下载、勿注册、勿付费**；如已安装，建议立即卸载，改用官方 Release 包安装。
>
> 本项目**从未、也不会**加入任何卡密 / VIP / 付费解锁 / 广告功能。如果你遇到的「HGhubX」要求输入卡密或付费开通，那一定不是官方版本。

## 免责声明

- 本项目与内容提供方无任何关联，作者不参与内容的制作、上传与分发。
- 本项目仅在上述官方渠道发布；任何第三方修改版（尤其是加卡密、VIP 变现的版本）均与作者无关，请自行甄别。
- 使用者应自行遵守所在地法律法规；因使用本项目产生的任何后果由使用者自行承担。
- 若相关权利方认为本项目存在侵权，请通过 Issue 联系，我们会及时处理。

## 升级兼容

- 本地收藏、观看记录、偏好、切集迁移标记和主题使用 `hghubx_*` 存储键。首次启动时，当前 WebView 存储中的旧 `hghub_*` 数据会迁移到新键；已有新数据优先，确认写入成功后才清理对应旧键。写入失败时保留并读取旧数据，下次启动重试。此迁移针对同一存储空间，不会跨应用标识或跨浏览器配置目录读取其他安装的数据。
- 环境变量统一使用 `HGHUBX_PROXY`、`HGHUBX_STRICT`、`HGHUBX_TEST_COVER_URL`、`HGHUBX_TEST_MEDIA_URL` 和 `HGHUBX_TEST_MEDIA_OUTPUT`。旧 `HGHUB_*` 名称继续兼容；新变量未设置时才回退旧变量，显式设置的新值（包括空值）优先。安全模式的命令行参数仍优先于环境变量。
- 网络诊断中的显式代理字段统一为 `HGHUBX_PROXY`，展示兼容读取后的有效值并保持脱敏。

## License

[PolyForm Noncommercial License 1.0.0](LICENSE) —— **仅限非商业用途**。

- **允许**：个人学习、研究、自用、爱好项目，以及在非营利组织内部使用；可以自由修改、二次开发。
- **禁止**：任何商业用途。包括但不限于打包出售、接入付费/会员/广告变现、作为收费服务或商业产品的一部分分发。
- **保留声明**：分发本项目或其修改版时，必须附带本许可证全文（或上面的链接）以及 `Required Notice` 声明行。
