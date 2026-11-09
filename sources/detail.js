// 一覧 API（/api/）は robots.txt が Disallow なので、sitemap の slug を詳細ページの RSC から数件ずつ読む。
// ホーム（/）は無限スクロールで /api/ を読むので、実行時に開くページは about にする。
const PAGE_SIZE = 4;

defineSource({
  name: "Detail",
  home: "https://detail.design/about",
  login: null,

  async list(cursor) {
    const paths = cursor ?? (await allPaths());
    // 手元にある slug の詳細ページは取り直さない
    const known = await mitate.known(paths.map(slugOf));
    const todo = paths.filter((_, i) => !known[i]);
    const shots = [];
    for (const path of todo.slice(0, PAGE_SIZE)) shots.push(await shotOf(path));
    const rest = todo.slice(PAGE_SIZE);
    return { shots, next: rest.length ? rest : null };
  },
});

// 呼び出しをまたいでも間隔が空くように、最初のリクエストの前にも待つ。
async function get(path) {
  await mitate.sleep(1000);
  return mitate.text(path);
}

// sitemap は slug の辞書順なので、ホームに載る最新の数件を先頭に置く。それより後ろは新しい順にならない。
async function allPaths() {
  const locs = [
    ...(await get("/sitemap.xml")).matchAll(/<loc>https:\/\/detail\.design(\/[^<]*)<\/loc>/g),
  ].map((m) => m[1]);
  const en = locs.filter((l) => l.startsWith("/detail/"));
  const enSlugs = new Set(en.map(slugOf));
  // 中国語版にしか無い項目は /zh/ から取る
  const zhOnly = locs.filter((l) => l.startsWith("/zh/detail/") && !enSlugs.has(slugOf(l)));
  if (en.length === 0) throw new Error("sitemap.xml に /detail/ が無い");
  const newest = jsonAfter(rscOf(await get("/")), '"initialContent":', "[").map(
    (d) => `/detail/${d.slug}`,
  );
  return [...new Set([...newest, ...en, ...zhOnly])];
}

async function shotOf(path) {
  const rsc = rscOf(await get(path));
  const d = jsonAfter(rsc, '"detail":', `{"slug":"${slugOf(path)}"`);
  // media は 1 件のオブジェクト、配列、無しのどれか
  const m = [d.media ?? []].flat()[0];
  return {
    id: d.slug,
    url: `https://detail.design${path}`,
    origin: m?.seenAt
      ? /^https?:\/\//.test(m.seenAt)
        ? m.seenAt
        : `https://${m.seenAt}`
      : undefined,
    kind: m ? m.type : "text",
    media: m ? { src: m.src, poster: m.poster, width: m.width, height: m.height } : undefined,
    title: d.title,
    text: d.summary || (m ? undefined : excerpt(rsc, d.rawContent)),
    tags: d.type ?? [],
    publishedAt: d.publishedAt ? new Date(d.publishedAt).toISOString() : undefined,
  };
}

// 規約が全文の転載を禁じているので、本文は冒頭だけ持つ
function excerpt(rsc, raw) {
  const body = /^\$[0-9a-f]+$/.test(raw ?? "") ? textRow(rsc, raw) : raw;
  return body?.trim().slice(0, 200) || undefined;
}

const slugOf = (path) => path.split("/").pop();

const rscOf = (html) =>
  [...html.matchAll(/self\.__next_f\.push\(\[1,"((?:[^"\\]|\\.)*)"\]\)/g)]
    .map((m) => JSON.parse(`"${m[1]}"`))
    .join("");

// RSC は JSON の断片の連なりなので、文字列を飛ばしながら対応する括弧まで読む
function jsonAfter(rsc, key, head) {
  const start = rsc.indexOf(key + head) + key.length;
  if (start < key.length) throw new Error(`RSC に ${key}${head} が無い`);
  let depth = 0;
  let inString = false;
  for (let i = start; i < rsc.length; i++) {
    const c = rsc[i];
    if (inString) {
      if (c === "\\") i++;
      else if (c === '"') inString = false;
    } else if (c === '"') inString = true;
    else if (c === "{" || c === "[") depth++;
    else if ((c === "}" || c === "]") && --depth === 0)
      return JSON.parse(rsc.slice(start, i + 1), revive);
  }
  throw new Error(`RSC の ${key} が閉じていない`);
}

function revive(_, v) {
  if (typeof v !== "string" || !v.startsWith("$")) return v;
  if (v === "$undefined") return undefined;
  if (v.startsWith("$$")) return v.slice(1);
  return v.startsWith("$D") ? v.slice(2) : v;
}

// 長い文字列は "$<id>" の参照になり、本体は "<id>:T<UTF-8 バイト長 16 進>,<本文>" の行に入る。T 行は改行で終わらないので先頭から順に読む
function textRow(rsc, ref) {
  const bytes = new TextEncoder().encode(rsc);
  const ascii = (a, b) => String.fromCharCode(...bytes.subarray(a, b));
  for (let i = 0; i < bytes.length;) {
    const colon = bytes.indexOf(0x3a, i);
    if (colon < 0) break;
    if (bytes[colon + 1] !== 0x54) {
      const nl = bytes.indexOf(0x0a, colon);
      i = nl < 0 ? bytes.length : nl + 1;
      continue;
    }
    const comma = bytes.indexOf(0x2c, colon);
    const end = comma + 1 + parseInt(ascii(colon + 2, comma), 16);
    if (ascii(i, colon) === ref.slice(1))
      return new TextDecoder().decode(bytes.subarray(comma + 1, end));
    i = end;
  }
  throw new Error(`RSC に ${ref} の T 行が無い`);
}
