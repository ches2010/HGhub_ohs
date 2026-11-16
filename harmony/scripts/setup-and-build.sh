#!/usr/bin/env bash
# 云实例一键：没有 node 就装（无 root）→ 打补丁 → 装依赖 → 构建前端 → 同步 rawfile/www
#
#   bash harmony/scripts/setup-and-build.sh            # 在仓库内任意目录执行
#   bash harmony/scripts/setup-and-build.sh /path/repo  # 指定仓库根
#
# 适用：ModelScope / 云 CPU 实例、CI 容器等「有 hvigor 但没有 node」的环境。
set -uo pipefail

REPO_ROOT="${1:-}"
if [ -z "$REPO_ROOT" ]; then
  HERE="$(cd "$(dirname "$0")" && pwd || true)"
  REPO_ROOT="$(cd "$HERE/../.." && pwd || true)"
fi
cd "$REPO_ROOT" 2>/dev/null || { echo "进不去目录：$REPO_ROOT（当前 shell 的 cwd 可能已被删除，先 cd / 再重试）" >&2; exit 1; }
if [ ! -f package.json ] || [ ! -d harmony ]; then
  echo "这不是仓库根（缺 package.json 或 harmony/）：$(pwd)" >&2
  exit 1
fi
echo "仓库根：$(pwd)"

# ── 1. Node ──────────────────────────────────────────────
NODE_VERSION="${NODE_VERSION:-22.20.0}"
if ! command -v node >/dev/null 2>&1; then
  case "$(uname -m)" in
    x86_64|amd64) NA=x64 ;;
    aarch64|arm64) NA=arm64 ;;
    *) echo "不支持的架构：$(uname -m)" >&2; exit 1 ;;
  esac
  PKG="node-v${NODE_VERSION}-linux-${NA}"
  PREFIX="$HOME/.local/node"
  mkdir -p "$PREFIX"
  got=0
  for U in "https://npmmirror.com/mirrors/node/v${NODE_VERSION}/${PKG}.tar.xz" \
           "https://nodejs.org/dist/v${NODE_VERSION}/${PKG}.tar.xz"; do
    echo "→ 下载 $U"
    if curl -fL --connect-timeout 15 --retry 2 -o /tmp/n.txz "$U"; then got=1; break; fi
  done
  if [ "$got" != "1" ]; then
    echo "✗ Node 下载失败：这台机器连不上镜像源" >&2
    exit 1
  fi
  tar -xJf /tmp/n.txz -C "$PREFIX" --strip-components=1 || { echo "✗ 解压失败（tar 可能不支持 xz）" >&2; exit 1; }
  rm -f /tmp/n.txz
  export PATH="$PREFIX/bin:$PATH"
  echo "✓ node $($PREFIX/bin/node -v) → $PREFIX/bin"
  echo "  以后单独使用时： export PATH=\"$PREFIX/bin:\$PATH\""
fi
echo "node $(node -v)"

# ── 2. 依赖源 ────────────────────────────────────────────
command -v npm >/dev/null 2>&1 && npm config set registry https://registry.npmmirror.com >/dev/null 2>&1
echo "npm registry: $(npm config get registry 2>/dev/null || echo '-')"

# ── 3. 打补丁 ────────────────────────────────────────────
echo "→ 打补丁（幂等）"
node harmony/patches/apply-patch.mjs . || { echo "✗ 打补丁失败" >&2; exit 1; }

# ── 4. 装依赖 + 构建 ─────────────────────────────────────
if command -v pnpm >/dev/null 2>&1; then
  echo "→ 安装依赖（pnpm）"
  pnpm install --frozen-lockfile
  echo "→ 构建前端（pnpm）"
  pnpm run build
else
  echo "→ 安装依赖（npm）"
  npm install --no-audit --no-fund
  echo "→ 构建前端（npm）"
  npm run build
fi

[ -f dist/index.html ] || { echo "✗ 构建没有产出 dist/index.html" >&2; exit 1; }

# ── 5. 同步 ──────────────────────────────────────────────
DEST="harmony/entry/src/main/resources/rawfile/www"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -r dist/. "$DEST/"

echo
echo "✓ 完成：$(find "$DEST" -type f | wc -l | tr -d ' ') 个文件 → $(pwd)/$DEST"
ls -1 "$DEST" | head -8
echo "  现在回 DevEco / hvigor 重新 Build HAP。"
