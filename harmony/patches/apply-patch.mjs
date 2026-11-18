#!/usr/bin/env node
/**
 * 把鸿蒙移植层打进 HGhubX 源码树（基线：上游 v2.2.0，src/shared/api/api.ts）。
 *
 *   node patches/apply-patch.mjs /path/to/HGhubX
 *
 * 做的事（幂等，可重复跑）：
 *   1. 复制 src/hg-bridge/*（invoke 复刻层）
 *   2. 改 src/shared/api/api.ts：识别鸿蒙 UA、按移动端布局、媒体基址指向 loopback 服务
 *   3. 改 vite.config.ts：把 @tauri-apps/* 指到 hg-bridge（函数式配置内注入 alias）
 */
import { copyFileSync, mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const target = resolve(process.argv[2] ?? ".");
const here = dirname(fileURLToPath(import.meta.url));
const LOCAL_ORIGIN = "http://127.0.0.1:17860"; // 必须与 Index.ets 里的 PORT 一致

function fail(msg) {
  console.error(`\n✗ ${msg}\n`);
  process.exit(1);
}

const apiCandidates = [
  join(target, "src", "shared", "api", "api.ts"), // 上游 v2.2.0+
  join(target, "src", "api.ts"),                  // 上游 v2.0.0（旧基线兼容）
];
const apiPath = apiCandidates.find((p) => existsSync(p));
if (!apiPath) {
  fail(`看起来不是 HGhubX 源码目录：${target}（找不到 src/shared/api/api.ts 或 src/api.ts）`);
}

/* 1. 复制桥接层 */
const srcDir = join(target, "src", "hg-bridge");
mkdirSync(srcDir, { recursive: true });
for (const f of ["core.ts", "line.ts", "lines.ts", "update.ts", "window.ts", "clipboard.ts"]) {
  copyFileSync(join(here, "src", "hg-bridge", f), join(srcDir, f));
  console.log(`  ✓ src/hg-bridge/${f}`);
}

/* 2. api.ts 平台识别 */
let api = readFileSync(apiPath, "utf8");
const original = api;

function replaceOnce(oldText, newText, label) {
  if (api.includes(newText)) {
    console.log(`  = ${label}（已是目标状态）`);
    return;
  }
  if (!api.includes(oldText)) {
    fail(`${label}：找不到预期原文，可能上游改版了，请手动修改 ${apiPath}`);
  }
  api = api.replace(oldText, newText);
  console.log(`  ✓ ${label}`);
}

replaceOnce(
  "const ua = navigator.userAgent;",
  'const ua = navigator.userAgent;\n/** 鸿蒙 ArkWeb：UA 带 OpenHarmony / ArkWeb，不能落进 windows 分支 */\nexport const isHarmony = /OpenHarmony|ArkWeb|HarmonyOS/i.test(ua);',
  "新增 isHarmony",
);

replaceOnce(
  'export const platform: "android" | "ios" | "windows" | "macos" | "linux" =\n  isAndroid ? "android" :',
  'export const platform: "android" | "ios" | "windows" | "macos" | "linux" =\n  isAndroid || isHarmony ? "android" :',
  "platform 归入移动端布局",
);

replaceOnce(
  "export const isMobile = isAndroid || isIos;",
  "export const isMobile = isAndroid || isIos || isHarmony;",
  "isMobile 含鸿蒙",
);

replaceOnce(
  'export const LOCAL =\n  isMacos || isIos ? "hg://localhost" : isLinux ? "http://127.0.0.1:17650" : "http://hg.localhost";',
  `export const LOCAL =\n  isHarmony ? "${LOCAL_ORIGIN}" : isMacos || isIos ? "hg://localhost" : isLinux ? "http://127.0.0.1:17650" : "http://hg.localhost";`,
  "媒体基址指向本地 loopback 服务",
);

if (api !== original) writeFileSync(apiPath, api);

/* 3. vite.config.ts 模块别名（上游 v2.2.0 为函数式配置） */
const vitePath = join(target, "vite.config.ts");
let vite = readFileSync(vitePath, "utf8");
const viteOriginal = vite;

if (!vite.includes("node:url")) {
  vite = vite.replace(
    'import { readFileSync } from "node:fs";',
    'import { readFileSync } from "node:fs";\nimport { fileURLToPath } from "node:url";',
  );
  if (!vite.includes("node:url")) fail("vite.config.ts：找不到 node:fs 导入行");
  console.log("  ✓ vite.config.ts 引入 node:url");
}

if (!vite.includes("hg-bridge")) {
  const anchor = '        "@edition-bootstrap": fileURLToPath(';
  if (!vite.includes(anchor)) fail("vite.config.ts：找不到 @edition-bootstrap alias 锚点");
  vite = vite.replace(
    anchor,
    `        // 鸿蒙移植层：把 Tauri 的模块换成 window.hghub 桥（本仓库移植新增）。\n` +
    `        "@tauri-apps/api/core": fileURLToPath(new URL("./src/hg-bridge/core.ts", import.meta.url)),\n` +
    `        "@tauri-apps/api/window": fileURLToPath(new URL("./src/hg-bridge/window.ts", import.meta.url)),\n` +
    `        "@tauri-apps/plugin-clipboard-manager": fileURLToPath(new URL("./src/hg-bridge/clipboard.ts", import.meta.url)),\n` +
    anchor,
  );
  console.log("  ✓ vite.config.ts 写入别名");
} else {
  console.log("  = vite.config.ts 别名（已存在）");
}

if (vite !== viteOriginal) writeFileSync(vitePath, vite);

console.log(`\n✓ 完成。下一步：\n  pnpm install && pnpm build\n  harmony/scripts/build-web.sh   # 构建并同步进 rawfile/www\n`);
