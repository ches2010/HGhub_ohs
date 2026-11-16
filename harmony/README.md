# 鸿蒙（HarmonyOS）移植工程

本目录是 [HGhubX](https://github.com/zxsos/HGhubX) 的鸿蒙化宿主工程：用 ArkWeb 跑原有 Web 前端，
用 ArkTS 顶替 Rust 层，产出可安装的 **HAP**。仓库根 README 有完整说明，这里只放工程本身。

```
harmony/
├── AppScope/ app.json5            版本号 / bundleName（com.hghubx.harmony）
├── entry/  DevEco 模块
│   └── src/main/ets/
│       ├── core/LocalServer.ets   loopback HTTP：静态前端 + /hls /seg /img 媒体代理
│       ├── core/Media.ets         封面 AES-128-CBC 解密 + m3u8 改写
│       ├── core/Http.ets          原生 HTTP 封装
│       ├── core/Bridge.ets        window.hghub 注入（http/setBase/background/netInfo…）
│       └── pages/Index.ets        Web 组件 + 服务启动 + 桥注册
├── patches/                       前端补丁层（invoke 复刻 / 线路 / 更新检查）
├── scripts/sync-web.sh            构建前端并同步进 rawfile
└── docs/PORTING.md                验证状态、装机步骤、风险清单
```

## 构建

前端产物（`entry/src/main/resources/rawfile/www/`）已随仓库提交，**直接 Build 即可**：

```bash
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default assembleHap
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
```

只改过 ArkTS/ETS 时不需要做别的；**改过 `src/` 前端代码**时才需要重新生成产物：

```bash
# 在仓库根执行（需要 Node 20+；没有 node 就先跑 scripts/bootstrap-node.sh）
node harmony/patches/apply-patch.mjs .     # 幂等
harmony/scripts/build-web.sh               # 构建并同步进 rawfile/www
```

也可以在 GitHub Actions 里手动跑 `Harmony web bundle`，由 runner 构建并提交产物。

详细步骤、真机自检顺序、已移植/未移植清单、已知风险都在 [`docs/PORTING.md`](docs/PORTING.md)。

## 许可

沿用上游 PolyForm Noncommercial 1.0.0：仅限个人学习、自用与非营利使用，禁止商业分发。
