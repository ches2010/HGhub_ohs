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

## 命令行构建

工程里**不含** `hvigorw` / `hvigorw.bat` / `hvigor/hvigor-wrapper.js`——它们由 DevEco Studio 或
HarmonyOS command-line-tools 提供，不是项目源码的一部分。所以不要在工程里找 `./hvigorw`。

**推荐：用工具链的全局 hvigorw**（在 `harmony/` 目录下执行）：

```bash
CT=/mnt/workspace/tools/harmonyos/command-line-tools   # 改成你的安装路径
export DEVECO_SDK_HOME=$CT/sdk
export PATH="$CT/bin:$CT/hvigor/bin:$CT/ohpm/bin:$PATH"

cd harmony
hvigorw --mode module -p module=entry@default -p product=default assembleHap
```

或者直接用脚本（自动发现工具链、SDK、node，并检查前端产物）：

```bash
bash harmony/scripts/build-hap.sh
# 自定义路径：HARMONY_CLI_HOME=/your/command-line-tools bash harmony/scripts/build-hap.sh
```

也可以让 DevEco Studio 打开一次 `harmony/`，它会生成工程内的 `hvigorw`，之后 `./hvigorw ...` 同样可用；
GUI 的 Build 菜单本就等价。

> `hvigor-wrapper.js` / 全局 hvigorw 首次运行会从 `https://ohpm.openharmony.cn/ohpm/` 取 `@ohos/hvigor`，
> 所以构建机需要能访问 ohpm 源（不能访问 GitHub 不影响）。

## 许可## 许可

沿用上游 PolyForm Noncommercial 1.0.0：仅限个人学习、自用与非营利使用，禁止商业分发。
