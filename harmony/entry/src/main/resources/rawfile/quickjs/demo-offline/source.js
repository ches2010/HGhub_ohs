// Zero-network offline demo source for UI preview without media playback.

const BLACK_COVER = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 360 480"><rect width="360" height="480" fill="#000000"/></svg>',
)}`;

const CATALOG = [
  {
    id: 90001,
    title: "示例视频 1",
    cover: BLACK_COVER,
    tags: ["示例", "都市"],
    score: 9.6,
    episode_count: 12,
    total_episodes: 12,
    hot: 128000,
    like_count: 3200,
    collect_count: 1850,
    comment_count: 42,
    is_finished: true,
    is_original: 1,
    description: "",
    author: { id: 1, name: "示例作者" },
  },
  {
    id: 90002,
    title: "示例视频 2",
    cover: BLACK_COVER,
    tags: ["示例", "科幻"],
    score: 9.1,
    episode_count: 8,
    total_episodes: 8,
    hot: 86000,
    like_count: 1900,
    collect_count: 920,
    comment_count: 18,
    is_finished: true,
    is_original: 0,
    description: "",
    author: { id: 1, name: "示例作者" },
  },
];

const HOT_TAGS = [
  { name: "示例", slug: "demo" },
  { name: "都市", slug: "dushi" },
  { name: "科幻", slug: "scifi" },
];

function buildTagCategories() {
  const tags = HOT_TAGS.map((item, idx) => ({
    id: idx + 1,
    name: item.name,
    slug: item.slug,
    video_count: CATALOG.filter((v) => v.tags.includes(item.name)).length,
  }));
  return [{ id: 1, name: "示例标签", tags }];
}

module.exports = {
  init() {
    return { ok: true, offline: true, demo: true, items: CATALOG.length };
  },
  home({ page = 1, size = 20 }) {
    return {
      items: page === 1 ? CATALOG : [],
      pagination: { page, pages: 1, size, total: CATALOG.length },
    };
  },
  search({ q = "", page = 1, size = 20 }) {
    const kw = String(q).trim().toLowerCase();
    const items = kw
      ? CATALOG.filter(
          (it) =>
            it.title.toLowerCase().includes(kw) ||
            it.tags.some((t) => t.toLowerCase().includes(kw)),
        )
      : CATALOG;
    return {
      items: page === 1 ? items : [],
      pagination: { page, pages: 1, size, total: items.length },
      keyword: q,
    };
  },
  tags() {
    return { categories: buildTagCategories() };
  },
  hotTags() {
    return { items: HOT_TAGS };
  },
  tagVideos({ tag = "", page = 1, size = 20 }) {
    const key = String(tag).trim().toLowerCase();
    const items = key
      ? CATALOG.filter((it) => it.tags.some((t) => t.toLowerCase() === key))
      : CATALOG;
    return {
      items: page === 1 ? items : [],
      pagination: { page, pages: 1, size, total: items.length },
    };
  },
  detail({ id }) {
    const found = CATALOG.find((x) => x.id === Number(id)) || CATALOG[0];
    return {
      ...found,
      counts: {
        like: found.like_count,
        collect: found.collect_count,
        comment: found.comment_count,
        hot: found.hot,
      },
      episodes: Array.from({ length: found.total_episodes }, (_, idx) => ({
        ep_num: idx + 1,
        title: `第 ${idx + 1} 集`,
        duration: 90,
        status: 1,
      })),
    };
  },
  playback({ id, ep }) {
    const found = CATALOG.find((x) => x.id === Number(id)) || CATALOG[0];
    return {
      id: String(found.id),
      ep: ep || 1,
      title: `${found.title} · 第 ${ep || 1} 集`,
      video_url: "",
    };
  },
};
