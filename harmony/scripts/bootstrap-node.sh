#!/usr/bin/env bash
# 给「没有 node 的构建环境」准备一个可用的 Node（无需 root），随后配合 build-web.sh 使用。
#
#   bash harmony/scripts/bootstrap-node.sh            # 自动：node 已存在则直接退出
#   bash harmony/scripts/bootstrap-node.sh --mirror   # 额外把 npm 源设为国内镜像
#
# 典型场景：ModelScope / 云上 CPU 实例、CI 容器，只有 hvigor，没有 node。
set -euo pipefail

NODE_VERSION="${NODE_VERSION:-22.20.0}"
MIRROR=0
for arg in "$@"; do
  case "$arg" in
    --mirror) MIRROR=1 ;;
    *) echo "未知参数：$arg" >&2; exit 1 ;;
  esac
done

if command -v node >/dev/null 2>&1; then
  echo "已存在 node $(node -v)，无需安装。"
  command -v npm >/dev/null 2>&1 && echo "npm $(npm -v)"
else
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) NODE_ARCH="x64" ;;
    aarch64|arm64) NODE_ARCH="arm64" ;;
    *) echo "不支持的架构：$ARCH" >&2; exit 1 ;;
  esac
  PKG="node-v${NODE_VERSION}-linux-${NODE_ARCH}"
  PREFIX="${HOME}/.local/node"
  mkdir -p "$PREFIX"

  echo "→ 下载 Node ${NODE_VERSION} (${NODE_ARCH}) 到 ${PREFIX}"
  URLS=(
    "https://npmmirror.com/mirrors/node/v${NODE_VERSION}/${PKG}.tar.xz"
    "https://nodejs.org/dist/v${NODE_VERSION}/${PKG}.tar.xz"
  )
  TARBALL="/tmp/${PKG}.tar.xz"
  ok=0
  for u in "${URLS[@]}"; do
    echo "   尝试 $u"
    if curl -fL --connect-timeout 15 -o "$TARBALL" "$u"; then ok=1; break; fi
  done
  if [ "$ok" != "1" ]; then
    echo "✗ 下载失败。这台机器可能没有外网，或需要走代理：" >&2
    echo "    export https_proxy=http://<proxy>:<port>  再重试" >&2
    exit 1
  fi

  tar -xJf "$TARBALL" -C "$PREFIX" --strip-components=1
  rm -f "$TARBALL"
  export PATH="${PREFIX}/bin:${PATH}"
  echo "✓ 已解压：${PREFIX}/bin/node ($(${PREFIX}/bin/node -v))"
  echo
  echo "本脚本内的 PATH 只在当前 shell 生效；若要在别的终端用，执行："
  echo "  export PATH=\"${PREFIX}/bin:\$PATH\""
  echo "  或写入：echo 'export PATH=\"${PREFIX}/bin:\$PATH\"' >> ~/.bashrc"
fi

if [ "$MIRROR" = "1" ]; then
  if command -v npm >/dev/null 2>&1; then
    npm config set registry https://registry.npmmirror.com
    echo "✓ npm registry → https://registry.npmmirror.com"
  fi
fi

echo
echo "下一步：bash harmony/scripts/build-web.sh"
