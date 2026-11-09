// Collect UI は SPA で HTML にデータが無いので、サイトと同じく Supabase の REST を bundle の公開キーで読む。
const HOME = "https://collectui.com/";
const PAGE = 500;
// X の投稿はメディアを最大 4 件持つ
const SLOTS = [0, 1, 2, 3];
const SELECT = [
  "id,title,source_url,media_url,media_type,thumbnail,categories,published_at,created_at,designer_username,designer:x_profiles!designer_x_profile_id(name)",
  ...SLOTS.map(
    (s) =>
      `k${s}:metadata->entities->media->${s}->>media_url_https,w${s}:metadata->entities->media->${s}->original_info->width,h${s}:metadata->entities->media->${s}->original_info->height`,
  ),
].join(",");

defineSource({
  name: "Collect UI",
  home: HOME,
  login: null,

  async list(cursor) {
    const api = await supabase();
    await mitate.sleep(300);
    const names = Object.fromEntries(
      (await api("collectui_categories", { select: "slug,name" })).map((c) => [c.slug, c.name]),
    );
    await mitate.sleep(300);
    const params = {
      select: SELECT,
      status: "eq.Published",
      // created_at は公開順と食い違うので published_at で並べ、公開日時の無い古い行は末尾に回す
      order: "published_at.desc.nullslast,created_at.desc,id.desc",
      limit: PAGE,
    };
    // 取得の途中で新しい投稿が先頭に入っても続きがずれないよう、前のページの最後の行より後ろを並びの値で絞る
    if (cursor) params.or = after(cursor);
    const rows = await api("collectui_posts", params);
    if (!Array.isArray(rows)) throw new Error("collectui_posts の応答が配列ではない");
    if (!cursor && rows.length === 0) throw new Error("collectui_posts が 0 件を返した");
    // categories が空の投稿にはサイト上のページが無い
    const shots = rows.filter((r) => r.categories?.length).map((r) => toShot(r, names));
    const last = rows.at(-1);
    return {
      shots,
      next:
        rows.length === PAGE
          ? { at: last.published_at, created: last.created_at, id: last.id }
          : null,
    };
  },
});

// order と同じ並びで cursor より後ろにある行の条件。published_at が null の行は末尾に並ぶ
function after({ at, created, id }) {
  const rest = `or(created_at.lt."${created}",and(created_at.eq."${created}",id.lt."${id}"))`;
  return at
    ? `(published_at.lt."${at}",and(published_at.eq."${at}",${rest}),published_at.is.null)`
    : `(and(published_at.is.null,${rest}))`;
}

async function supabase() {
  // サイトが Supabase へ問い合わせた時点で、URL とキーを持つ chunk は読み込み済みになっている
  await mitate.waitFor(() =>
    performance.getEntriesByType("resource").some((e) => e.name.includes(".supabase.co/")),
  );
  const chunks = new Set(
    performance
      .getEntriesByType("resource")
      .map((e) => e.name)
      .filter((name) => name.startsWith(`${location.origin}/_app/`) && name.endsWith(".js")),
  );
  for (const chunk of chunks) {
    // ページが読み込んだ chunk をキャッシュから読むだけなので、サイトへのリクエストは増えない
    const js = await mitate.text(chunk, { cache: "only-if-cached", mode: "same-origin" });
    const url = js.match(/https:\/\/[a-z0-9]+\.supabase\.co/)?.[0];
    const key = js.match(/eyJ[\w-]+\.eyJ[\w-]+\.[\w-]+/g)?.find((k) => jwtRole(k) === "anon");
    if (url && key) {
      // サイトのクライアントは db.schema に collectui を指定している
      const headers = {
        apikey: key,
        Authorization: `Bearer ${key}`,
        "Accept-Profile": "collectui",
      };
      return (table, params) =>
        mitate.json(`${url}/rest/v1/${table}?${new URLSearchParams(params)}`, { headers });
    }
  }
  throw new Error(
    `collectui の chunk ${chunks.size} 個に Supabase の URL と anon キーが見つからない`,
  );
}

function jwtRole(token) {
  return JSON.parse(atob(token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))).role;
}

function toShot(r, names) {
  const [width, height] = size(r);
  return {
    id: r.id,
    url: `${HOME}designs/${r.categories[0]}-ui-design-inspiration/${r.id}`,
    origin: r.source_url?.match(/^https:\/\/x\.com\/\w+\/status\/\d+/)?.[0],
    kind: r.media_type,
    media: {
      src: r.media_url,
      // thumbnail は拡張子が .mp4 のものも中身は AVIF の静止画
      poster: (r.media_type === "video" && r.thumbnail) || undefined,
      width,
      height,
    },
    title: r.title || undefined,
    // カテゴリ表に無い slug は、サイトと同じく slug のまま出す
    tags: r.categories.map((slug) => names[slug] ?? slug),
    author: r.designer?.name || r.designer_username || undefined,
    publishedAt: r.published_at ? new Date(r.published_at).toISOString() : undefined,
  };
}

// metadata の media の並びは media_index と一致しないことがあるので、メディアの名前で探す
function size(r) {
  const name = new URL(r.media_url).pathname.match(/^\/\w+\/([\w-]+?)(?:-optimized)?[./]/)?.[1];
  const s = name ? SLOTS.find((s) => r[`k${s}`]?.includes(name)) : undefined;
  if (s !== undefined) return [r[`w${s}`], r[`h${s}`]];
  const m = r.media_url.match(/\/(\d+)x(\d+)\//);
  return m ? [Number(m[1]), Number(m[2])] : [];
}
