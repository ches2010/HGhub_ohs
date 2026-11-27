# quickjs-spike (HarmonyOS NAPI)

P3a 之后的导出契约：

- `evaluate(script: string): string`
  - 同步执行，主要用于启动期自检；每次新建 QuickJS runtime，带 16 MiB 内存和 512 KiB 栈上限。
- `evaluateAsync(script: string, onHost: (id: number, request: string) => void, contextJson?: string): Promise<string>`
  - 在独立原生线程执行 QuickJS，带 12 秒中断超时。
  - 源脚本只能看到 ArkTS prepend 的冻结 `host` 对象；原始 `__hostCall` / `__hostContext` 在 shim 执行后被删除。
  - `contextJson` 携带 `sourceId`、`info`、`allowedOrigins`。
  - `onHost` 收到 `{ op, payload }`，必须异步调用 `resolveHost(id, responseJson)`。
- `resolveHost(id: number, response: string): void`
  - 通用 host 调用结果；`resolveFetch` 保留为别名，兼容 P1c/P2 日志。

安全边界：

- 源 JS 没有直接网络、文件、环境变量或 NAPI 能力。
- host.fetch 白名单、HTML 只读查询、crypto、storage 都在 ArkTS 侧实现。
- ECDH 私钥保存在 ArkTS 会话 vault，不暴露给源 JS。

CI 使用 OHOS command-line-tools 6.0.1.251 + QuickJS-NG v0.18.0 编译 arm64 `libquickjs_spike.so`。
