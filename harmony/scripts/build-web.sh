#!/usr/bin/env bash
# 一步到位：打补丁 → 装依赖 → 构建前端 → 同步进 rawfile/www
#
#   harmony/scripts/build-web.sh            # 在仓库根或任意目录执行都行
#
# 为什么必须有这一步：HAP 里的前端页面来自 harmony/entry/src/main/resources/rawfile/www/，
# 该目录被 .gitignore 排除（不进仓库）。不同步就只有一个空目录，装到手机上必然白屏。
#
# 环境要求：Node >= 20（DevEco 自带 node，见下）+ pnpm 或 npm + 能访问 npm 源。
#   DevEco 自带的 node 在：<DevEco 安装目录>/tools/node/bin/（Windows: tools\node\node.exe）
#   临时用它可以：export PATH="<DevEco>/tools/node/bin:$PATH"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARMONY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$HARMONY_DIR/.." && pwd)"

if [ ! -f "$REPO_ROOT/package.json" ]; then
  echo "找不到前端工程：$REPO_ROOT" >&2
  echo "请在仓库根（含 package.json）或 harmony 目录下执行" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "找不到 node。两种办法：" >&2
  echo "  1) 安装 Node 20+；" >&2
  echo "  2) 用 DevEco 自带的：export PATH=\"<DevEco 安装目录>/tools/node/bin:\$PATH\"" >&2
  exit 1
fi
echo "node $(node -v)"

# 优先 pnpm（仓库有 pnpm-lock），没有就 corepack，再没有就退回 npm
PM=""
if command -v pnpm >/dev/null 2>&1; then
  PM="pnpm"
else
  corepack enable >/dev/null 2>&1 || true
  if command -v pnpm >/dev/null 2>&1; then
    PM="pnpm"
  elif command -v npm >/dev/null 2>&1; then
    PM="npm"
    echo "未发现 pnpm，改用 npm（首次会按 package.json 解析依赖，比 pnpm 慢一些）"
  else
    echo "既没有 pnpm 也没有 npm，无法安装依赖" >&2
    exit 1
  fi
fi

echo "→ 1/4 打补丁（幂等，可重复执行）"
node "$HARMONY_DIR/patches/apply-patch.mjs" "$REPO_ROOT"

echo "→ 2/4 安装依赖（$PM）"
if [ "$PM" = "pnpm" ]; then
  (cd "$REPO_ROOT" && pnpm install --frozen-lockfile)
else
  (cd "$REPO_ROOT" && npm install --no-audit --no-fund)
fi

echo "→ 3/4 构建前端"
(cd "$REPO_ROOT" && $PM run build)

if [ ! -f "$REPO_ROOT/dist/index.html" ]; then
  echo "✗ 构建后 dist/index.html 不存在，前端构建可能失败了（看上面的日志）" >&2
  exit 1
fi

echo "→ 4/4 同步到 harmony/entry/src/main/resources/rawfile/www"
DEST="$HARMONY_DIR/entry/src/main/resources/rawfile/www"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -r "$REPO_ROOT/dist/." "$DEST/"

echo
echo "✓ 完成：$(find "$DEST" -type f | wc -l | tr -d ' ') 个文件 → $DEST"
ls -1 "$DEST" | head -10
echo "  现在回 DevEco 重新 Build HAP 并安装即可。"
