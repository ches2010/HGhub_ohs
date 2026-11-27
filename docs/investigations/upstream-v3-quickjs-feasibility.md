# 上游 v3.0.0 QuickJS 鸿蒙可行性验证

日期：2026-11-27

## 结论

P1 的路线判定已完成：**不能直接用 `quickjs-emscripten` 在 ArkWeb 主线程执行上游 source 插件**。

推荐路线是：

- 使用 OHOS NDK 编译原生 QuickJS
- 通过 NAPI 暴露模块
- QuickJS 运行在独立原生线程
- `host.fetch` 通过 NAPI ThreadSafeFunction 回到 ArkTS/ArkWeb，并在原生线程阻塞等待结果

这样可以保持上游 source.js 的同步 `host.fetch` 调用语义。

## 上游契约

上游 `src-tauri/src/source/runtime.rs` 中，`host.fetch` 是同步函数：

```rust
Function::new(ctx.clone(), move |req_json: String| -> String {
    ...
    fetch_handle.block_on(host_http_request(...))
})
```

因此 source.js 可以这样写：

```js
const res = host.fetch({ url: "https://..." });
```

如果换成 `quickjs-emscripten` 的 Asyncify，插件必须改成 `await host.fetch(...)`，与上游契约不兼容。

## 候选方案

| 方案 | 结论 | 原因 |
| --- | --- | --- |
| ArkWeb 主线程 + quickjs-emscripten | 不采用 | `host.fetch` 同步阻塞会卡死 UI；Asyncify 破坏上游契约 |
| ArkWeb Worker + WASM + Atomics | 可研究 | 需要 Worker 阻塞、主线程异步 fetch、共享内存，复杂度高且仍有 WASM 体积 |
| 原生 QuickJS + NAPI + 独立线程 | 推荐 | 与上游同步 host API 语义一致，可复用 QuickJS C 代码 |
| 只支持内置源，不执行第三方 JS | 保底 | 最安全、最快，但失去 v3 插件能力 |

## 已完成验证

对上游离线示例源 `examples/sources/demo-offline/source.js` 做了契约冒烟测试：

- 成功加载 `module.exports`
- 导出函数：`init, home, search, tags, hotTags, tagVideos, detail, playback`
- `home({page:1,size:2})` 返回 2 条示例视频
- `detail({id:90001})` 返回 12 集
- `playback({id:90001,ep:1})` 返回第 1 集播放对象

说明 source 包的 CommonJS 形态和返回结构可以直接复用。

## 尚未验证

1. OHOS NDK 编译 QuickJS 的具体命令与 ABI。
2. NAPI 模块在 HarmonyOS 真机上的加载。
3. QuickJS 独立线程的创建、销毁和并发安全。
4. `host.fetch` 的 NAPI ThreadSafeFunction 阻塞回传。
5. 内存上限、栈上限、执行超时和中断。
6. `host.htmlQuery`、`host.crypto`、`host.storage` 的桥接。
7. Ed25519 验签、分享码、源包导入和回滚。
8. HAP 体积与启动时间。

## P1 下一步

### P1a 编译验证

- 在 `harmony/native/quickjs-spike/` 引入 QuickJS C 源码。
- 用 OHOS NDK 编译 `libquickjs_spike.so`。
- 暴露最小 NAPI `eval(script)`，返回字符串。
- 在 GitHub Actions 上传 `.so` 产物。

### P1b 执行验证

- 在 ArkTS 中加载 `.so`。
- 执行 `1 + 1` 和 demo source.js。
- 验证异常、超时和内存上限。

### P1c host.fetch 验证

- 原生线程运行 QuickJS。
- `host.fetch` 通过 TSFN 调用 ArkTS。
- ArkTS 完成 HTTP 后回传，原生线程继续执行。
- 验证取消、超时和线程退出。

## 风险

- NAPI + 原生线程 + TSFN 的调试成本高。
- QuickJS C 源码需要按 OHOS 工具链调整编译参数。
- 第三方插件安全边界必须保留：网络白名单、响应上限、禁 Cookie/Host、私钥不暴露给 JS。
- 如果 P1c 失败，建议退到“只支持内置受信任源”，暂不开放第三方 source.js。

## 当前状态

- 评估分支：`sync/upstream-3.0.0-pilot`
- `main` 未改动。
- 现有 `2.2.10` 鸿蒙版不受影响。
