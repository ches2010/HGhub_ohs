#!/usr/bin/env bash
# 用 HarmonyOS command-line-tools 构建 HAP（自动发现 hvigorw / SDK / node）
#
#   bash harmony/scripts/build-hap.sh
#   HARMONY_CLI_HOME=/mnt/workspace/tools/harmonyos/command-line-tools bash harmony/scripts/build-hap.sh
#   bash harmony/scripts/build-hap.sh --mode module -p product=default assembleHap   # 自定义参数
#
# 说明：hvigorw / hvigorw.bat / hvigor/hvigor-wrapper.js 由 DevEco 或 command-line-tools 提供，
# 工程里不一定有。本脚本优先用工具链里的全局 hvigorw（在 harmony/ 目录下执行即可），
# 其次看 PATH，最后才用工程内的 hvigorw。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARMONY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── 1. 定位 command-line-tools ──────────────────────────────
CLI=""
CANDIDATES=(
  "${HARMONY_CLI_HOME:-}"
  "/mnt/workspace/tools/harmonyos/command-line-tools"
  "${HOME:-/root}/command-line-tools"
  "/opt/command-line-tools"
  "/usr/local/command-line-tools"
)
for c in "${CANDIDATES[@]}"; do
  if [ -n "$c" ] && [ -x "$c/hvigor/bin/hvigorw" ]; then
    CLI="$c"
    break
  fi
done

if [ -n "$CLI" ]; then
  HVIGORW="$CLI/hvigor/bin/hvigorw"
  if [ -z "${DEVECO_SDK_HOME:-}" ] && [ -d "$CLI/sdk" ]; then
    export DEVECO_SDK_HOME="$CLI/sdk"
  fi
  export PATH="$CLI/bin:$CLI/hvigor/bin:$CLI/ohpm/bin:${PATH:-}"
elif command -v hvigorw >/dev/null 2>&1; then
  HVIGORW="$(command -v hvigorw)"
elif [ -x "$HARMONY_DIR/hvigorw" ]; then
  HVIGORW="$HARMONY_DIR/hvigorw"
else
  echo "✗ 找不到 hvigorw。三种办法：" >&2
  echo "  1) export HARMONY_CLI_HOME=<command-line-tools 目录>" >&2
  echo "  2) 把 <command-line-tools>/hvigor/bin 加进 PATH" >&2
  echo "  3) 让 DevEco 打开一次本工程（会生成工程内 hvigorw）" >&2
  exit 1
fi

# ── 2. node（工具链通常自带 tool/node）─────────────────────
if ! command -v node >/dev/null 2>&1 && [ -n "$CLI" ]; then
  for n in "$CLI/tool/node/bin" "$CLI/node/bin"; do
    if [ -x "$n/node" ]; then
      export PATH="$n:${PATH:-}"
      break
    fi
  done
fi
if ! command -v node >/dev/null 2>&1; then
  echo "✗ 找不到 node（command-line-tools 一般自带 tool/node/bin/node）" >&2
  exit 1
fi

# ── 3. 前端产物自检 ────────────────────────────────────────
if [ ! -f "$HARMONY_DIR/entry/src/main/resources/rawfile/www/index.html" ]; then
  echo "⚠ rawfile/www 里没有 index.html —— 装到手机上会白屏！" >&2
  echo "  修复：仓库根执行 harmony/scripts/build-web.sh，或跑 Actions 的 Harmony web bundle。" >&2
fi

echo "hvigorw: $HVIGORW"
echo "node:    $(node -v)"
echo "SDK:     ${DEVECO_SDK_HOME:-未设置（若报 SDK 错误：export DEVECO_SDK_HOME=<cli>/sdk）}"
echo "工程:    $HARMONY_DIR"
echo "签名:    signingConfigs 为空时 assembleHap 产出 unsigned HAP（hdc install 会拒绝）；真机安装请用 DevEco 自动签名或配置 signingConfigs"
echo

cd "$HARMONY_DIR"
if [ "$#" -eq 0 ]; then
  set -- --mode module -p module=entry@default -p product=default assembleHap
fi
exec "$HVIGORW" "$@"
