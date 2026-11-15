/**
 * 更新检查（对应 src-tauri/src/api.rs 的 check_update）
 * ---------------------------------------------------------------
 * 拿 GitHub Release 的 tag 和本地版本比。踩过的坑都保留了：
 *   · tag 不是纯版本号（`hgfix-1.2.1-r5`），整串比会从第一位判负 → 先抠 x.y.z
 *   · 只比较数字段，`1.0.10 > 1.0.9`
 *   · 404 表示"还没发过 release"，不是错误
 *
 * 鸿蒙特有的差异：GitHub 上没有 .hap 产物，所以 asset 恒为 null，
 * 界面侧本来就用 `url` 打开 Release 页面（见 Settings.tsx 的 doUpdate）。
 */

export interface ReleaseAsset {
  name: string;
  url: string;
}

export interface ReleasePayload {
  tag: string;
  htmlUrl: string;
  notes: string;
  name: string;
  publishedAt: string;
  assets: ReleaseAsset[];
}

/** `v1.0.2` → [1,0,2]；解析不出的段按 0 处理（与 Rust 的 ver_parts 一致） */
export function verParts(version: string): number[] {
  return version
    .trim()
    .replace(/^[vV]+/, "")
    .split(/[.\-+]/)
    .map((part) => {
      const value = Number.parseInt(part.trim(), 10);
      return Number.isFinite(value) ? value : 0;
    });
}

/** 只比数字段：`v1.0.10` 要比 `1.0.9` 新 */
export function isNewer(latest: string, current: string): boolean {
  const a = verParts(latest);
  const b = verParts(current);
  const length = Math.max(a.length, b.length);
  for (let i = 0; i < length; i++) {
    const x = a[i] ?? 0;
    const y = b[i] ?? 0;
    if (x !== y) return x > y;
  }
  return false;
}

/**
 * 从 tag / release name 里抠出 `x.y.z`（对应 Rust 的 version_in）。
 * `hgfix-1.2.1-r5` → `1.2.1`；找不到返回空串。
 */
export function versionIn(text: string): string {
  const chars = Array.from(text);
  let i = 0;
  while (i < chars.length) {
    if (!/[0-9]/.test(chars[i])) {
      i += 1;
      continue;
    }
    const start = i;
    let dots = 0;
    let j = i;
    while (j < chars.length && (/[0-9]/.test(chars[j]) || (chars[j] === "." && dots < 2))) {
      if (chars[j] === ".") dots += 1;
      j += 1;
    }
    if (dots === 2) {
      return chars.slice(start, j).join("");
    }
    i = Math.max(j, i + 1);
  }
  return "";
}

/**
 * 这个平台该用哪个包，数字越大越优先。
 * Rust 版按 Android/Windows/macOS/Linux 的扩展名给分；鸿蒙这里只认 `.hap`，
 * 其余一律 0（等于"本次 release 没给本平台出包"）。
 */
export function assetRank(name: string): number {
  const lower = name.toLowerCase();
  if (lower.endsWith(".hap")) return 3;
  return 0;
}

export function pickAsset(assets: ReleaseAsset[]): ReleaseAsset | null {
  let best: ReleaseAsset | null = null;
  let bestRank = 0;
  for (const asset of assets) {
    const rank = assetRank(asset.name);
    if (rank > bestRank) {
      best = asset;
      bestRank = rank;
    }
  }
  return best;
}

/** 把 Release JSON 归一成前端 `UpdateInfo`（字段名与 api.ts 的类型一一对应） */
export function buildUpdateInfo(
  payload: ReleasePayload,
  current: string,
  fallbackUrl: string,
): Record<string, unknown> {
  const found = versionIn(payload.tag);
  const latest = found.length > 0 ? found : payload.tag.replace(/^[vV]+/, "");
  const asset = pickAsset(payload.assets);
  return {
    current,
    latest,
    tag: payload.tag,
    has_update: latest.length > 0 && isNewer(latest, current),
    asset,
    url: payload.htmlUrl.length > 0 ? payload.htmlUrl : fallbackUrl,
    name: payload.name,
    published_at: payload.publishedAt,
    // Rust 用 chars().take(800)，这里按码点截断保持一致
    notes: Array.from(payload.notes).slice(0, 800).join(""),
  };
}

/** 没发过 release 时的返回（与 Rust 的 404 分支一致） */
export function noReleaseInfo(current: string, fallbackUrl: string): Record<string, unknown> {
  return { current, latest: "", has_update: false, url: fallbackUrl };
}
