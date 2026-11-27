# 上游 v3.0.0 鸿蒙移植评估

日期：2026-11-27

## 结论

上游 `zxsos/HGhubX` 的 `main` 已重写为 **v3.0.0 纯壳 + 视频源插件架构**，当前 HEAD 为 `57ad208c8f66437566db181862d0291f68611c14`。

这次不是普通功能更新：

- 上游 `main` 只有 3 个提交，历史从 v3.0.0 重新开始。
- 与当前 fork `41be6db9724c2ddda0fffbfbb46668fe843f3f37` 没有共同祖先，GitHub compare 返回 `No common ancestor`。
- 因此不能直接 `merge` 或 `rebase` 到现有 `main`。
- 直接覆盖 `main` 会让现有鸿蒙版失去站点 API、线路探测和播放能力。

本分支只做评估，不修改 `main`。

## 基线

| 项目 | 当前值 |
| --- | --- |
| 上游 HEAD | `57ad208c8f66437566db181862d0291f68611c14` |
| 上游版本 | `3.0.0` |
| 上游 versionCode | `3000000` |
| fork HEAD | `41be6db9724c2ddda0fffbfbb46668fe843f3f37` |
| fork 版本 | `2.2.10` |

## 差异规模

按文件内容比较：

- 共同文件：388
- 上游修改：152
- 上游新增：56
- 仅 fork 存在：88（主要是 `harmony/**`、`src/hg-bridge/**`、旧站点解析和鸿蒙 CI）

上游新增的核心目录包括：

- `src-tauri/src/source/**`：源清单、验签、运行时、存储、局域网推送
- `src/features/settings/SourceManager.tsx`
- `src/app/startup/SourceOnboarding.tsx`
- `src/shared/model/sourceAutoUpdate.ts`
- `src/shared/lib/deepLink.ts`
- `src/shared/lib/qrDecode.ts`
- `src/features/authors/**`

## 架构变化

v3.0.0 把站点逻辑从客户端剥离：

- 视频源由独立的 Ed25519 验签插件提供。
- 插件声明能力、分类、加解密、线路发现规则。
- 客户端通过 QuickJS 沙箱执行插件 `source.js`。
- 无源时进入导入/试用离线示例源引导。
- 新增 `source_*`、`cache_*`、`tv_peer_*` 命令。
- 旧站点专属的 `channel_page.rs`、`search_hot.rs`、`publish_parser.rs` 不再属于上游主路径。

## 鸿蒙移植阻塞项

### 1. QuickJS 运行时

上游使用 Rust `rquickjs` 嵌入 QuickJS。鸿蒙 ArkTS/ArkWeb 没有现成的等价运行时。

可选路线：

1. 将 QuickJS 编译为 OHOS 原生库，通过 NAPI 暴露给 ArkTS。
2. 在 ArkWeb 的隔离 Worker/隐藏页面中执行 source.js，并用桥限制 host API。
3. 先只支持受信任的内置源，不允许第三方插件执行。

这是 v3 移植的第一阻塞项，必须先做技术验证。

### 2. 命令面缺口

鸿蒙桥当前实现的是旧 `api_*` / `line_*` 命令。v3 新增至少：

- `source_state`
- `source_import`
- `source_activate`
- `source_remove`
- `source_rollback`
- `source_test`
- `source_check_update`
- `source_export_share_code`
- `source_set_allow_untrusted`
- `source_take_deep_link`
- `source_lan_push_start` / `status` / `stop` / `to_tv`
- `tv_peer_pair_qr`
- `tv_peer_sync`

以及 v3 缓存命令：

- `cache_stats`
- `cache_set_limit`
- `cache_clear`

### 3. 现有站点能力保留

v3 默认没有内置站点。鸿蒙版若要平滑升级，需要二选一：

- 把现有站点封装成内置受信任源（推荐过渡方案）。
- 要求用户导入社区源后再使用（与上游一致，但现有用户会中断）。

### 4. 鸿蒙专属能力

以下能力需要在 ArkTS 侧补齐或重新接线：

- 深链 `hghubx://`
- 剪贴板口令读取
- 扫码 / 二维码解码
- 局域网推送与 TV 配对
- 源文件选择与导入
- 缓存统计与清理
- 版本回滚与源更新

## 分阶段方案

### P0 评估与分支

- 建立本评估分支。
- 不修改 `main`。
- 固定上游 v3.0.0 基线。

### P1 QuickJS 技术验证

- 在鸿蒙上跑通一个最小 source.js。
- 验证 `host.fetch`、存储、超时、取消和错误隔离。
- 比较 NAPI QuickJS 与 Worker 隔离两条路线。

### P2 源命令桥

- 在 `src/hg-bridge/core.ts` 增加 `source_*` 命令。
- 先实现状态、导入、激活、测试、回滚。
- 保留旧 `api_*` 命令作为兼容层。

### P3 内置兼容源

- 将现有站点 API 封装为内置源。
- 保持现有线路、加密网关、播放代理和返回键行为。
- 再逐步接入第三方源。

### P4 版本与构建

- 版本切到 `3.0.0`，versionCode `3000000`。
- 同步 `package.json`、Tauri 配置、Cargo 版本。
- 重建 `harmony/entry/src/main/resources/rawfile/www/`。
- 构建 HAP 并做真机回归。

## 当前建议

不要直接把 v3.0.0 覆盖到 `main`。先在独立分支完成 P1，确认 QuickJS 在鸿蒙上的可行路线，再决定是否进入 P2。
