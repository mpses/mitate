// Vault の一覧はログイン後のページにしか描かれないので、goto で /vault を開いて DOM から読む。
const ORIGIN = "https://aiforui.dev";

defineSource({
  name: "AI for UI",
  home: `${ORIGIN}/`,
  login: {
    url: `${ORIGIN}/login`,
    check: async () => (await lessonIndex()) !== null,
  },

  async list(cursor) {
    if (cursor === "vault") {
      if (location.pathname !== "/vault")
        throw new Error(`ログインしていない（/vault が ${location.pathname} へ転送された）`);
      const images = await mitate.waitFor(() => {
        const found = [...document.images].filter(vaultPath);
        return found.length > 0 && found;
      });
      return { shots: images.map(vaultShot), next: null };
    }
    const index = await lessonIndex();
    if (!index) throw new Error("ログインしていない（/learn/search-index が /login へ転送された）");
    return { shots: index.map(lessonShot), next: "vault", goto: `${ORIGIN}/vault` };
  },
});

// レッスンの索引はログイン済みのときだけ返る。未ログインだと /login へ 307 で転送されるので、転送を追わずに見分けて null を返す。
// 200 でも索引の形をしていなければ、ログイン済みとはみなさずに例外にする。
async function lessonIndex() {
  const r = await fetch("/learn/search-index", { redirect: "manual" });
  if (r.type === "opaqueredirect") return null;
  if (!r.ok) throw new Error(`HTTP ${r.status} /learn/search-index`);
  const index = await r.json().catch(() => null);
  if (!Array.isArray(index) || !index.length || !index.every((e) => typeof e?.href === "string"))
    throw new Error("/learn/search-index の応答がレッスンの索引（href を持つ項目の配列）ではない");
  return index;
}

function lessonShot(entry) {
  return {
    id: entry.href,
    url: new URL(entry.href, ORIGIN).href,
    kind: "text",
    title: entry.title,
    text: entry.text,
    tags: [entry.page].filter(Boolean),
  };
}

// next/image は /_next/image?url=/vault/... で描くので、元の画像のパスに戻す。
function vaultPath(img) {
  const u = new URL(img.currentSrc || img.src);
  const raw = u.pathname === "/_next/image" ? u.searchParams.get("url") : u.pathname;
  const path = raw && new URL(raw, ORIGIN).pathname;
  return path?.startsWith("/vault/") ? path : null;
}

function vaultShot(img) {
  const path = vaultPath(img);
  const a = img.closest("a[href]");
  if (!a) throw new Error(`Vault の画像 ${path} がリンクの中に無い`);
  const external = a.host !== location.host;
  return {
    id: path,
    url: external ? `${ORIGIN}/vault` : a.href,
    origin: external ? a.href : undefined,
    kind: "image",
    media: {
      src: new URL(path, ORIGIN).href,
      width: img.naturalWidth || undefined,
      height: img.naturalHeight || undefined,
    },
    title: img.alt.trim() || undefined,
    text: a.innerText.trim() || undefined,
    tags: [],
  };
}
