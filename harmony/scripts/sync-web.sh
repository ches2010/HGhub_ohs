#!/usr/bin/env bash
# 把前端 dist 同步进鸿蒙工程的 rawfile，供 loopback 服务读取
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"   # 仓库根：内含 package.json 与 src/
SRC_REPO="${1:-$REPO_ROOT}"
DEST="$SCRIPT_DIR/../entry/src/main/resources/rawfile/www"

if [ ! -f "$SRC_REPO/package.json" ]; then
  echo "找不到前端仓库：$SRC_REPO" >&2
  echo "用法：$0 [/path/to/HGhubX]" >&2
  exit 1
fi

if [ ! -d "$SRC_REPO/src/hg-bridge" ]; then
  echo "提示：前端还没打补丁，先跑 node harmony/patches/apply-patch.mjs ." >&2
fi

echo "→ 构建前端 ($SRC_REPO)"
(cd "$SRC_REPO" && pnpm install --frozen-lockfile && pnpm build)

echo "→ 同步到 $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -r "$SRC_REPO/dist/." "$DEST/"

echo "✓ 完成，共 $(find "$DEST" -type f | wc -l | tr -d ' ') 个文件"
