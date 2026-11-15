/**
 * 线路（数据源 base）存储：鸿蒙版用 localStorage，替代 Rust 的 line.json。
 */
const LS_BASE = "hghubx_hon_base";
const LS_CUSTOM = "hghubx_hon_custom";
const DEFAULT_BASE = "https://huangguoai.com";

export const lineStateStore = {
  get(): string {
    const saved = localStorage.getItem(LS_BASE);
    if (saved && /^https:\/\/[^/]+$/.test(saved)) return saved;
    return DEFAULT_BASE;
  },
  set(url: string): void {
    localStorage.setItem(LS_BASE, url);
    localStorage.removeItem(LS_CUSTOM);
  },
  setCustom(url: string): void {
    localStorage.setItem(LS_BASE, url);
    localStorage.setItem(LS_CUSTOM, "1");
  },
  isCustom(): boolean {
    return localStorage.getItem(LS_CUSTOM) === "1";
  },
  reset(): void {
    localStorage.setItem(LS_BASE, DEFAULT_BASE);
    localStorage.removeItem(LS_CUSTOM);
  },
};
