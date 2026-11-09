// feed "all" は x と websites しか返さないので、bundle にある feed の一覧をすべて読み、新しい順に混ぜて返す。
defineSource({
  name: "Recent",
  home: "https://recent.design/",
  login: null,

  async list(cursor) {
    const lanes = cursor ?? (await feeds()).map((feed) => ({ feed, done: false, buf: [] }));
    let sent = !cursor;
    for (const lane of lanes.filter((l) => !l.done && !l.buf.length)) {
      if (sent) await mitate.sleep(300);
      sent = true;
      const { items, nextCursor } = (
        await mitate.json("https://api.recent.design/rpc/items/list", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            json: { feed: lane.feed, sort: "recent", limit: 250, cursor: lane.after },
          }),
        })
      ).json;
      // tools は sort: "recent" でも公開日の順に並ばないので、並べ直す。
      lane.buf = items.sort((a, b) => b.publishedAt - a.publishedAt).map(toShot);
      lane.after = nextCursor ?? undefined;
      lane.done = !nextCursor || !items.length;
    }
    // 続きのある feed がすべて先頭を持っている間だけ取り出せば、feed をまたいでも新しい順になる。
    const shots = [];
    while (lanes.every((l) => l.done || l.buf.length)) {
      const open = lanes.filter((l) => l.buf.length);
      if (!open.length) break;
      shots.push(
        open.reduce((a, b) => (b.buf[0].publishedAt > a.buf[0].publishedAt ? b : a)).buf.shift(),
      );
    }
    return { shots, next: lanes.some((l) => !l.done || l.buf.length) ? lanes : null };
  },
});

async function feeds() {
  const entry = document.querySelector('link[rel="modulepreload"][href*="/main-"]');
  if (!entry) throw new Error("recent: main の bundle が見つからない");
  const found = (await mitate.text(entry.href)).match(/\["all"(?:,"[a-z0-9-]+")+\]/);
  if (!found) throw new Error("recent: bundle に feed の一覧が見つからない");
  // "all" は x と websites を合わせた一覧で、ほかの feed と重なる。
  return JSON.parse(found[0]).filter((f) => f !== "all");
}

// tool と skill は説明文が主役で、/i/ の詳細ページも持たない。
const TEXT_FORMATS = new Set(["tool", "skill"]);

function toShot(item) {
  const m = item.cover;
  const textual = TEXT_FORMATS.has(item.format);
  return {
    id: item.id,
    url: textual ? item.source.url : `https://recent.design/i/${item.id}-${item.slug}`,
    origin: item.source?.url,
    kind: textual ? "text" : m?.mediaType === "image" ? "image" : "video",
    media: m ? toMedia(m) : undefined,
    title: item.title,
    text: [item.tagline, item.description].filter(Boolean).join("\n") || undefined,
    tags: [item.category?.name, ...item.tags.map((t) => t.name)].filter(Boolean),
    author: item.creator?.name,
    publishedAt: new Date(item.publishedAt).toISOString(),
  };
}

// gif も実体は mp4 なので、image 以外は動画の寸法で選ぶ。
function toMedia(m) {
  const src = m.mediaType === "image" ? pick(m, 700, 1600) : pick(m, 720, 1280);
  return {
    src: src.url,
    poster: m.poster ? pick(m.poster, 700, 1600).url : undefined,
    width: src.width,
    height: src.height,
  };
}

// 長辺が lo〜hi に最も近いものを選び、同じ近さなら大きいほうを取る。
function pick(m, lo, hi) {
  const all = [
    ...(m.renditions ?? []),
    { url: m.url, width: m.mediaWidth ?? m.width, height: m.mediaHeight ?? m.height },
  ];
  const long = (r) => Math.max(r.width, r.height);
  const gap = (r) => Math.max(0, lo - long(r), long(r) - hi);
  return all.sort((a, b) => gap(a) - gap(b) || long(b) - long(a))[0];
}
