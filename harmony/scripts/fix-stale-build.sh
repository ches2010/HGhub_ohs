#!/usr/bin/env bash
# 把鸿蒙移植的最新源码同步到已有的构建目录（解压副本不会自动跟随仓库）。
#
#   ./fix-stale-build.sh /mnt/workspace/projects/_unzip/harmony
#   REF=<commit> ./fix-stale-build.sh <dir>     # 需要钉住某个提交时
#
# 背景：DevEco 的构建目录常常是「解压副本」而不是 git clone，
# 它会一直拿旧文件编译，报错也就一直是同一批（clearCache / toArrayBuffer / getContext / onConsole）。
set -euo pipefail

DIR="${1:-}"
if [ -z "$DIR" ] || [ ! -d "$DIR/entry/src/main/ets" ]; then
  echo "用法：$0 <harmony 目录>   例如：$0 /mnt/workspace/projects/_unzip/harmony" >&2
  exit 1
fi

REPO="ches2010/HGhub_ohs"
# 默认跟 main（持续修 bug 时最省事）；要复现某个版本就传 REF=<sha>
REF="${REF:-main}"
BASE="https://raw.githubusercontent.com/${REPO}/${REF}"

FILES=(
  "entry/src/main/ets/core/Media.ets"
  "entry/src/main/ets/core/Bridge.ets"
  "entry/src/main/ets/core/Http.ets"
  "entry/src/main/ets/core/LocalServer.ets"
  "entry/src/main/ets/pages/Index.ets"
  "scripts/build-web.sh"
)

for rel in "${FILES[@]}"; do
  dst="${DIR}/${rel}"
  mkdir -p "$(dirname "$dst")"
  echo "→ ${rel}"
  curl -fsSL -o "$dst" "${BASE}/harmony/${rel}"
  case "$rel" in *.sh) chmod +x "$dst" ;; esac
done

E="${DIR}/entry/src/main/ets"
echo
echo "── 源码校验（必须全部 OK）──"
grep -q 'toArrayBuffer'            "$E/core/Media.ets"      && echo "✗ Media.ets 仍是旧版"      || echo "OK  Media.ets 用 Uint8Array"
grep -q 'controller.clearCache()'  "$E/core/Bridge.ets"     && echo "✗ Bridge.ets 仍是旧版"     || echo "OK  Bridge.ets 已移除 clearCache()"
grep -q 'let resp: http.HttpResponse' "$E/core/Http.ets"    && echo "OK  Http.ets 已加 try/catch" || echo "✗ Http.ets 仍是旧版"
grep -q 'hasBundle'                "$E/core/LocalServer.ets" && echo "OK  LocalServer 有产物探测" || echo "✗ LocalServer.ets 仍是旧版"
grep -q 'onConsole((event): boolean' "$E/pages/Index.ets"   && echo "OK  Index.ets onConsole 返回 boolean" || echo "✗ Index.ets 仍是旧版"
grep -q 'diagnosePanel'            "$E/pages/Index.ets"     && echo "OK  Index.ets 有诊断面板"    || echo "✗ Index.ets 仍是旧版"

WWW="${DIR}/entry/src/main/resources/rawfile/www"
echo
if [ -f "${WWW}/index.html" ]; then
  echo "OK  rawfile/www 已有前端产物（$(find "$WWW" -type f | wc -l | tr -d ' ') 个文件）"
else
  echo "⚠ rawfile/www 里没有 index.html —— 这样装到手机上仍然白屏！"
  echo "   在仓库根执行：harmony/scripts/build-web.sh"
fi

echo
echo "同步完成。回 DevEco 重新 Build（无需清缓存）。"
