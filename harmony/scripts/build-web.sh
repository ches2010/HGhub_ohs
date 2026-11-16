#!/usr/bin/env bash
# 一步到位：打补丁 → 装依赖 → 构建前端 → 同步进 rawfile/www
#
#   harmony/scripts/build-web.sh
#
# 为什么必须有这一步：HAP 里的前端页面来自 harmony/entry/src/main/resources/rawfile/www/，
# 而该目录被 .gitignore 排除（不进仓库）。不同步就只有一个空目录，装到手机上必然白屏。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARMONY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$HARMONY_DIR/.." && pwd)"

if [ ! -f "$REPO_ROOT/package.json" ]; then
  echo "找不到前端工程：$REPO_ROOT（调用时请在仓库根或 harmony 内）" >&2
  exit 1
fi

command -v node >/dev/null 2>&1 || { echo "缺少 node（建议 22+）" >&2; exit 1; }
if ! command -v pnpm >/dev/null 2>&1; then
  echo "未发现 pnpm，尝试用 corepack 启用…"
  corepack enable >/dev/null 2>&1 || true
  command -v pnpm >/dev/null 2>&1 || { echo "请先安装：npm i -g pnpm（或 npm i -g corepack && corepack enable）" >&2; exit 1; }
fi

echo "→ 1/4 打补丁（幂等，可重复执行）"
node "$HARMONY_DIR/patches/apply-patch.mjs" "$REPO_ROOT"

echo "→ 2/4 安装依赖"
(cd "$REPO_ROOT" && pnpm install --frozen-lockfile)

echo "→ 3/4 构建前端"
(cd "$REPO_ROOT" && pnpm build)

if [ ! -d "$REPO_ROOT/dist" ]; then
  echo "✗ 构建后没有 dist/ 目录，检查 package.json 的 build 脚本" >&2
  exit 1
fi

echo "→ 4/4 同步到 harmony/entry/src/main/resources/rawfile/www"
DEST="$HARMONY_DIR/entry/src/main/resources/rawfile/www"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -r "$REPO_ROOT/dist/." "$DEST/"

if [ ! -f "$DEST/index.html" ]; then
  echo "✗ 同步后仍未生成 index.html，请检查前端构建产物结构" >&2
  exit 1
fi

echo "✓ 完成：$(find "$DEST" -type f | wc -l | tr -d ' ') 个文件，index.html 已就位"
echo "  现在回 DevEco 重新 Build HAP 并安装即可。"
