// 利用規約が自動取得を禁じるので、利用者が確定した検索 1 回につき、X 自身の検索画面が描いた分だけを読む。
defineSource({
  name: "X",
  home: "https://x.com/",
  login: {
    url: "https://x.com/i/jf/onboarding/web?mode=login",
    check: async () => {
      // 未ログインだと /home は / へ 307 で転送される。
      const r = await fetch("/home", { redirect: "manual" });
      return r.type !== "opaqueredirect" && r.ok;
    },
  },
  pace: 4000,

  async search(query, cursor) {
    if (!cursor) {
      return {
        shots: [],
        next: "opened",
        goto: `https://x.com/search?q=${encodeURIComponent(query)}&f=media`,
      };
    }
    const found = new Map();
    await mitate.waitFor(
      () => collect(found) || document.querySelector('[data-testid="emptyState"]'),
      20000,
    );
    if (!found.size) return { shots: [], next: null };
    for (let step = 0; ; step++) {
      // 画像を読み込む前に読むと寸法が 0 になる。
      await mitate.sleep(1500);
      if (collect(found) >= 20 || step === 4) break;
      scrollBy(0, innerHeight * 2);
    }
    return { shots: [...found.values()].slice(0, 40), next: null };
  },
});

// 一覧は画面外へ出た投稿を DOM から外すので、スクロールのたびに読み足す。
function collect(found) {
  if (location.pathname !== "/search")
    throw new Error(`X の検索画面を開けず ${location.href} に移った。ログインが要る`);
  for (const shot of readShots()) found.set(shot.id, shot);
  return found.size;
}

function readShots() {
  const shots = [];
  for (const el of document.querySelectorAll(
    'a[href*="/status/"], article video[poster^="https://"]',
  )) {
    if (el.tagName === "A") {
      const m = el.pathname.match(/^\/(\w+)\/status\/(\d+)\/(photo|video)\/(\d+)$/);
      const img = m && el.querySelector('img[src^="https://pbs.twimg.com/"]');
      if (img)
        shots.push(toShot(m[1], m[2], m[3] + m[4], el.closest("article"), "image", still(img)));
      continue;
    }
    const article = el.closest("article");
    const m = permalink(article);
    if (!m) continue;
    const n = [...article.querySelectorAll('video[poster^="https://"]')].indexOf(el) + 1;
    const stream = [el.src, el.currentSrc, el.querySelector("source")?.src].find((u) =>
      u?.startsWith("https://"),
    );
    // 再生が blob: の動画は取得できる URL が DOM に無いので、静止画として扱う。
    const media = stream ? { src: stream, poster: el.poster } : { src: el.poster };
    shots.push(toShot(m[1], m[2], `video${n}`, article, stream ? "video" : "image", media));
  }
  return shots;
}

function permalink(article) {
  return article
    ?.querySelector("time")
    ?.closest("a")
    ?.pathname.match(/^\/(\w+)\/status\/(\d+)$/);
}

function toShot(handle, status, key, article, kind, media) {
  // 引用された投稿のメディアには、外側の投稿の本文と日時を付けない。
  const own = permalink(article)?.[2] === status;
  return {
    id: `${status}-${key}`,
    url: `https://x.com/${handle}/status/${status}`,
    kind,
    media,
    text:
      (own && article.querySelector('[data-testid="tweetText"]')?.innerText.trim()) || undefined,
    tags: [],
    author: `@${handle}`,
    publishedAt: own ? article.querySelector("time").dateTime : undefined,
  };
}

// naturalWidth は表示中の small の寸法だが、縦横比は medium と同じ。
function still(img) {
  const u = new URL(img.src);
  if (u.pathname.startsWith("/media/")) u.searchParams.set("name", "medium");
  return {
    src: u.href,
    width: img.naturalWidth || undefined,
    height: img.naturalHeight || undefined,
  };
}
