# QuickJS NAPI P1b 打包结果

日期：2026-11-27

## 结果

P1b 打包验证通过。

- HAP 已包含 `libs/arm64-v8a/libquickjs_spike.so`
- ArkTS 已成功编译对 `libquickjs_spike.so` 的导入
- NAPI 导出名改为 `evaluate`，避开 ArkTS 的保留字 `eval`
- 启动时调用 `quickjsSpike.evaluate('1 + 1')` 并写入 hilog

## 产物

Pilot HAP：

`HGhubX_ohs_sync-upstream-3.0.0-pilot_unsigned.hap`

- 版本：`2.2.10`
- versionCode：`2002010`
- 大小：`2,970,216` 字节
- SHA-256：`b2015ce8eaf69e86b1248635611a494ce0a93f3b1c661239f8f976bab0ec313b`

HAP 内 `libquickjs_spike.so`：

- 大小：`1,022,000` 字节（已 strip）
- SHA-256：`1deeb2d0b789d7bcbbfbeeab72b833e7eae2f10775508b60021be9d645ad3b78`
- ELF：`AArch64`
- 含 `evaluate` 导出

GitHub Actions：

https://github.com/ches2010/HGhub_ohs/actions/runs/45969611232

## 已验证

- `harmony/entry/libs/arm64-v8a/libquickjs_spike.so` 进入 HAP。
- `oh-package.json5` 的类型依赖配置可编译。
- `Index.d.ts` 的 `evaluate` 声明可编译。
- `EntryAbility.ets` 的静态导入可编译。
- ArkTS 不再因 `eval` 保留字报错。
- HAP 构建和 artifact 收集成功。

## 未验证

- 真机安装后 NAPI 模块能否成功加载。
- hilog 是否出现 `quickjs eval: 2`。
- QuickJS 执行 demo source.js。
- 原生线程、TSFN 和同步 `host.fetch`。

## 真机验证方法

安装 pilot HAP 后过滤日志：

```bash
hdc hilog | grep -E "quickjs eval|quickjs eval failed"
```

预期：

```text
quickjs eval: 2
```

如果出现 `quickjs eval failed`，说明模块加载或 NAPI 注册仍有问题，需要看具体错误。

## 注意

这是 `sync/upstream-3.0.0-pilot` 分支的试验 HAP，不是稳定版。`main` 和现有 2.2.10 稳定包未改动。
