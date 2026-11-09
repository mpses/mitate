// サイトは Supabase の REST を anon キーで直接読む。キーの差し替えに追従するため、キーと URL は毎回 bundle から探す。
const HOME = "https://bestdesignsonx.com/";
const PAGE = 500;
const SELECT = "id,author_name,handle,tweet_text,post_url,media,created_at,published_at,tags";

defineSource({
  name: "Best Designs On X",
  home: HOME,
  login: null,

  // 公開した時刻が published_at に入り、作成順と公開順は食い違うので、published_at の降順で新着を先頭に置く。
  async list(cursor) {
    const { rest, key } = await supabase();
    const params = new URLSearchParams({
      select: SELECT,
      status: "eq.Published",
      order: "published_at.desc.nullslast,id.desc",
      limit: PAGE,
    });
    if (cursor) {
      const at = `"${cursor.at}"`;
      params.set(
        "or",
        cursor.at
          ? `(published_at.lt.${at},and(published_at.eq.${at},id.lt.${cursor.id}),published_at.is.null)`
          : `(and(published_at.is.null,id.lt.${cursor.id}))`,
      );
    }
    await mitate.sleep(300);
    const rows = await mitate.json(`${rest}/bdox_designs?${params}`, {
      headers: { apikey: key, Authorization: `Bearer ${key}`, "Accept-Profile": "bdox" },
    });
    if (!Array.isArray(rows)) throw new Error("bdox_designs の応答が配列ではない");
    if (!cursor && rows.length === 0) throw new Error("bdox_designs が 0 件を返した");
    const last = rows.at(-1);
    return {
      shots: rows.map(toShot),
      next: rows.length < PAGE ? null : { at: last.published_at, id: last.id },
    };
  },
});

// Supabase の client は Link ヘッダの末尾の chunk に入っているので、後ろから探す。
async function supabase() {
  const res = await fetch(HOME);
  if (!res.ok) throw new Error(`HTTP ${res.status} ${HOME}`);
  const chunks = [...(res.headers.get("link") ?? "").matchAll(/<(\/_app\/[^>]+\.js)>/g)]
    .map((m) => m[1])
    .reverse();
  if (!chunks.length) throw new Error("トップページの Link ヘッダに chunk が無い");
  for (const path of chunks) {
    await mitate.sleep(300);
    const js = await mitate.text(path);
    const url = js.match(/https:\/\/[a-z0-9]+\.supabase\.co/)?.[0];
    const key = js.match(/eyJ[\w-]+\.eyJ[\w-]+\.[\w-]+/g)?.find((k) => jwtRole(k) === "anon");
    if (url && key) return { rest: `${url}/rest/v1`, key };
  }
  throw new Error("chunk に Supabase の URL と anon キーが見つからない");
}

function jwtRole(jwt) {
  try {
    return JSON.parse(atob(jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))).role;
  } catch {
    return null;
  }
}

function toShot(r) {
  const m = r.media?.[0] ?? {};
  // animated_gif も実体は mp4。古い行は拡張子の無い URL と thumbnail だけを持つ。
  const video = m.type === "video" || m.type === "animated_gif";
  const src = video ? m.video_url : (m.image ?? m.thumbnail);
  const text = (r.tweet_text ?? "").replace(/https:\/\/t\.co\/\w+/g, "").trim();
  const strip = (s) => (s ?? "").trim().replace(/^@+/, "");
  return {
    id: String(r.id),
    url: new URL(r.post_url, HOME).href,
    origin: `https://x.com${r.post_url}`,
    kind: video ? "video" : "image",
    media: src
      ? {
          src,
          poster: video ? (m.thumbnail ?? m.cover) : undefined,
          // 約半数の行は寸法を文字列で持つ。
          width: Number(m.width) || undefined,
          height: Number(m.height) || undefined,
        }
      : undefined,
    title: text.split("\n")[0].trim() || undefined,
    text: text || undefined,
    tags: r.tags ?? [],
    author: strip(r.author_name) || strip(r.handle) || undefined,
    publishedAt: new Date(r.published_at ?? r.created_at).toISOString(),
  };
}
