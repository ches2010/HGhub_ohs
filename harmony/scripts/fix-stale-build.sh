#!/usr/bin/env bash
# 把鸿蒙移植的「编译修复版」5 个文件同步到已有的构建目录。
#
#   ./fix-stale-build.sh /mnt/workspace/projects/_unzip/harmony
#
# 背景：如果构建目录是「解压副本」而不是 git clone，它不会跟着仓库更新，
# DevEco 会一直拿旧文件编译，报错也就一直是同一批（clearCache / toArrayBuffer / getContext）。
set -euo pipefail

DIR="${1:-}"
if [ -z "$DIR" ] || [ ! -d "$DIR/entry/src/main/ets" ]; then
  echo "用法：$0 <harmony 目录>   例如：$0 /mnt/workspace/projects/_unzip/harmony" >&2
  exit 1
fi

REPO="ches2010/HGhub_ohs"
# 钉住提交，避免拉到中间态：14d544b = 编译修复 + 文档
REF="${REF:-14d544be0356395a066ea751a01309480d2e4a61}"
BASE="https://raw.githubusercontent.com/${REPO}/${REF}"

FILES=(
  "entry/src/main/ets/core/Media.ets"
  "entry/src/main/ets/core/Bridge.ets"
  "entry/src/main/ets/core/Http.ets"
  "entry/src/main/ets/core/LocalServer.ets"
  "entry/src/main/ets/pages/Index.ets"
)

for rel in "${FILES[@]}"; do
  dst="${DIR}/${rel}"
  echo "→ ${rel}"
  curl -fsSL -o "$dst" "${BASE}/harmony/${rel}"
done

echo
echo "── 校验（必须全部为「OK」）──"
grep -q 'toArrayBuffer' "${DIR}/entry/src/main/ets/core/Media.ets" \
  && echo "✗ Media.ets 还是旧版本" || echo "OK  Media.ets 已用 Uint8Array（无 toArrayBuffer）"
grep -q 'controller.clearCache()' "${DIR}/entry/src/main/ets/core/Bridge.ets" \
  && echo "✗ Bridge.ets 还是旧版本" || echo "OK  Bridge.ets 已移除 clearCache()"
grep -q 'getHostContext' "${DIR}/entry/src/main/ets/pages/Index.ets" \
  && echo "OK  Index.ets 已用 getUIContext().getHostContext()" || echo "✗ Index.ets 还是旧版本"
grep -q 'let resp: http.HttpResponse' "${DIR}/entry/src/main/ets/core/Http.ets" \
  && echo "OK  Http.ets 已加 try/catch" || echo "✗ Http.ets 还是旧版本"
grep -q '本地服务无法监听' "${DIR}/entry/src/main/ets/core/LocalServer.ets" \
  && echo "OK  LocalServer.ets 已加 try/catch" || echo "✗ LocalServer.ets 还是旧版本"

echo
echo "5 个文件已更新。回 DevEco 直接重新 Build（hvigor 会自行重新编译改动过的文件，不用清缓存）。"
