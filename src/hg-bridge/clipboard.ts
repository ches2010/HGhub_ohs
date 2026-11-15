/**
 * @tauri-apps/plugin-clipboard-manager 的替代：走浏览器 Clipboard API。
 * ArkWeb 在 http 源（本机 loopback）下 clipboard.writeText 可用；
 * 若被拒绝则退回 execCommand 兜底。
 */
export async function writeText(text: string): Promise<void> {
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
