# QuickJS NAPI P1a 编译结果

日期：2026-11-27

## 结果

P1a 编译验证通过。

- QuickJS：`quickjs-ng v0.18.0`
- HarmonyOS command-line-tools：`6.0.1.251`
- 目标 ABI：`arm64-v8a`
- 产物：`libquickjs_spike.so`
- 大小：`1,151,992` 字节
- SHA-256：`34456b05b7f32a6333b23e9977584606d4d28d67dbaa3064283c1d92a57eb917`
- ELF：64 位、小端、`AArch64`、共享对象

GitHub Actions：

https://github.com/ches2010/HGhub_ohs/actions/runs/45965448279

产物 artifact：`quickjs-spike-arm64`

## 已验证

- QuickJS-NG 源码可以用 OHOS NDK 交叉编译。
- `libqjs.a` 静态库可以链接进 NAPI 共享模块。
- `napi_init.c` 能注册 `quickjs_spike` 模块并导出 `eval`。
- 链接时使用 `aarch64-linux-ohos` 的 `libace_napi.z.so`，不再误用 x86_64 版本。
- 生成物为 AArch64 共享库。

## 未验证

- 在 HarmonyOS 真机加载 `libquickjs_spike.so`。
- 通过 NAPI 调用 `eval("1 + 1")`。
- 执行 demo `source.js`。
- 原生线程、TSFN、同步 `host.fetch`。
- 内存上限、栈上限、超时和中断。

## 下一步

P1b：

1. 把 `libquickjs_spike.so` 放入 HAP 的 `libs/arm64-v8a/`。
2. 在 ArkTS 中 `import quickjs_spike from 'libquickjs_spike.so'`。
3. 调用 `quickjs_spike.eval('1 + 1')`。
4. 再执行 demo source.js 的 `home()`。

P1c：

- 将 QuickJS 移到独立原生线程。
- 用 NAPI ThreadSafeFunction 实现同步 `host.fetch`。
