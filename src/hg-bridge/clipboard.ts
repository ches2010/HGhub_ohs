/**
 * @tauri-apps/plugin-clipboard-manager 的替代：走浏览器 Clipboard API。
 * ArkWeb 在 http 源（本机 loopback）下 clipboard.writeText 可用；
 * 若被拒绝则退回 execCommand 兜底。
 */
import { hasHarmonyBridge } from "./core";

export async function writeText(text: string): Promise<void> {
  if (!hasHarmonyBridge()) {
    // 测试 fixture / Tauri 桌面：走 Tauri 剪贴板插件 IPC（fixture 监听该命令）。
    const internals = (window as unknown as {
      __TAURI_INTERNALS__?: { invoke: (cmd: string, args?: Record<string, unknown>) => Promise<unknown> };
    }).__TAURI_INTERNALS__;
    if (internals) {
      // text 供测试 fixture 读取；data/label 是 Tauri v2 官方插件参数
      await internals.invoke("plugin:clipboard-manager|write_text", { label: null, data: text, text });
      return;
    }
  }
  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      return;
    }
  } catch {
    /* 继续走兜底 */
  }
  const area = document.createElement("textarea");
  area.value = text;
  area.style.position = "fixed";
  area.style.opacity = "0";
  document.body.appendChild(area);
  area.select();
  try {
    document.execCommand("copy");
  } finally {
    document.body.removeChild(area);
  }
}

export async function readText(): Promise<string> {
  if (navigator.clipboard && window.isSecureContext) {
    return navigator.clipboard.readText();
  }
  return "";
}
