// 追加日（addedAt）は詳細 API にしか無く、1 件ずつ取ると 1 ページ 1 リクエストに収まらないので publishedAt は持たない。
defineSource({
  name: "Designeer",
  home: "https://designeer.xyz/tools",
  login: null,

  async list(cursor) {
    const params = new URLSearchParams({ collection: "tools", sort: "recent", limit: "24" });
    if (cursor) params.set("cursor", cursor);
    const page = await mitate.json(`/api/catalog?${params}`, {
      headers: { Accept: "application/json" },
    });
    if (!Array.isArray(page?.items)) throw new Error("/api/catalog の応答に items が無い");
    return { shots: page.items.map(toShot), next: page.nextCursor ?? null };
  },
});

function toShot(item) {
  // tile.mp4 は 640x360 と小さいので、1280x720 の録画を先に選ぶ。
  const video = item.videoUrl ?? item.tileVideoUrl;
  return {
    id: item.id,
    url: `https://designeer.xyz/tools/${item.slug}`,
    origin: item.url,
    kind: video ? "video" : "image",
    media: {
      src: video ?? item.poster.url,
      poster: video ? item.poster.url : undefined,
      width: item.poster.width,
      height: item.poster.height,
    },
    title: item.name,
    text: item.tagline || undefined,
    tags: [item.category?.name, item.pricing].filter(Boolean),
  };
}
