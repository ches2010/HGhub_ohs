/**
 * @tauri-apps/api/window 的空实现：鸿蒙版没有桌面窗口装饰。
 * 只有 DesktopChrome / ResizeHandles 会用到，而它们在移动端不会渲染。
 */
export function getCurrentWindow() {
  const noop = async () => undefined;
  return new Proxy(
    {},
    {
      get(_target, key) {
        if (key === "label") return "main";
        return noop;
      },
    },
  ) as Record<string, (...args: unknown[]) => Promise<unknown>> & { label: string };
}

export const isTauri = true;
