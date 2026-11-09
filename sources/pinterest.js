// 検索は全件を写せないので、検索のたびにサイトの検索 API へ問い合わせる。ログインしていると、結果がそのアカウントの好みに寄る。
// list は、ログインした本人のボードに保存したピンを返す。
defineSource({
  name: "Pinterest",
  home: "https://jp.pinterest.com/",
  login: {
    url: "https://jp.pinterest.com/login/",
    check: async () => Boolean(await me()),
  },
  pace: 4000,

  async search(query, cursor) {
    const sourceUrl = `/search/pins/?q=${encodeURIComponent(query)}`;
    const options = {
      query,
      scope: "pins",
      rs: "typed",
      page_size: 50,
      redux_normalize_feed: true,
      source_url: sourceUrl,
      bookmarks: cursor ? [cursor.bookmark] : [],
    };
    const page = await resource("BaseSearchResource", options, sourceUrl, "www/search/[scope].js");
    // 検索はページをまたいで同じピンを返すので、既出の id をカーソルで持ち回る。
    const seen = new Set(cursor?.seen);
    const shots = toShots(page.data?.results, seen);
    return { shots, next: page.next ? { bookmark: page.next, seen: [...seen] } : null };
  },

  async list(cursor) {
    let c = cursor;
    if (!c) {
      const username = await me();
      if (!username) throw new Error("Pinterest にログインしていない");
      c = {
        username,
        boards: [],
        boardsBookmark: null,
        boardsDone: false,
        board: 0,
        bookmark: null,
      };
      await mitate.sleep(300);
    }
    if (c.board >= c.boards.length && !c.boardsDone) {
      const options = {
        username: c.username,
        sort: "last_pinned_to",
        field_set_key: "profile_grid_item",
        filter_stories: false,
        bookmarks: c.boardsBookmark ? [c.boardsBookmark] : [],
      };
      const page = await resource(
        "BoardsFeedResource",
        options,
        `/${c.username}/`,
        "www/[username].js",
      );
      if (!Array.isArray(page.data))
        throw new Error("BoardsFeedResource の応答にボードの配列が無い");
      const boards = page.data
        .filter((b) => b?.type === "board" && b.pin_count > 0)
        .map((b) => ({ id: b.id, url: b.url }));
      c = {
        ...c,
        boards: [...c.boards, ...boards],
        boardsBookmark: page.next,
        boardsDone: !page.next,
      };
      await mitate.sleep(300);
    }
    const board = c.boards[c.board];
    if (!board) return { shots: [], next: c.boardsDone ? null : c };
    const options = {
      board_id: board.id,
      page_size: 25,
      field_set_key: "react_grid_pin",
      filter_section_pins: false,
      is_react: true,
      prepend: false,
      redux_normalize_feed: true,
      add_vase: true,
      gated: true,
      bookmarks: c.bookmark ? [c.bookmark] : [],
    };
    const page = await resource(
      "BoardFeedResource",
      options,
      board.url,
      "www/[username]/[slug].js",
    );
    const shots = toShots(page.data);
    // ボードのこのページが全部取り込み済みなら、続きも取り込み済みとみなして次のボードへ移る
    const known = await mitate.known(shots.map((s) => s.id));
    const caughtUp = shots.length > 0 && known.every(Boolean);
    const next =
      page.next && !caughtUp
        ? { ...c, bookmark: page.next }
        : { ...c, board: c.board + 1, bookmark: null };
    return {
      shots,
      next: next.board >= next.boards.length && next.boardsDone ? null : next,
    };
  },
});

// PWS-Handler が無いと 403 "Invalid Resource Request" になる。
function request(name, options, sourceUrl, handler) {
  const params = new URLSearchParams({
    source_url: sourceUrl,
    data: JSON.stringify({ options, context: {} }),
  });
  return fetch(`/resource/${name}/get/?${params}`, {
    headers: {
      Accept: "application/json, text/javascript, */*; q=0.01",
      "X-Requested-With": "XMLHttpRequest",
      "X-Pinterest-AppState": "active",
      "X-Pinterest-Source-Url": sourceUrl,
      "X-Pinterest-PWS-Handler": handler,
    },
  });
}

async function resource(name, options, sourceUrl, handler) {
  const r = await request(name, options, sourceUrl, handler);
  if (!r.ok) throw new Error(`${name}: HTTP ${r.status}`);
  const rr = (await r.json())?.resource_response;
  if (rr?.status !== "success")
    throw new Error(`${name}: ${rr?.message ?? "status が success ではない"}`);
  return { data: rr.data, next: rr.bookmark && rr.bookmark !== "-end-" ? rr.bookmark : null };
}

// 未ログインでは 401 が返る。
async function me() {
  const r = await request("UserSettingsResource", {}, "/", "www/index.js");
  if (r.status === 401) return null;
  if (!r.ok) throw new Error(`UserSettingsResource: HTTP ${r.status}`);
  return (await r.json())?.resource_response?.data?.username ?? null;
}

function toShots(pins, seen = new Set()) {
  if (!Array.isArray(pins)) throw new Error("応答にピンの配列が無い");
  const shots = [];
  for (const pin of pins) {
    if (pin?.type !== "pin" || !pin.images || seen.has(pin.id)) continue;
    seen.add(pin.id);
    shots.push(toShot(pin));
  }
  return shots;
}

function toShot(pin) {
  const image = pin.images["736x"] ?? pin.images.orig ?? Object.values(pin.images)[0];
  const video = hls(pin);
  const size = video ?? pin.images.orig ?? image;
  return {
    id: pin.id,
    url: mitate.abs(`/pin/${pin.id}/`),
    origin: /^https?:\/\//.test(pin.link ?? "") ? pin.link : undefined,
    kind: video ? "video" : "image",
    media: {
      src: video?.url ?? image.url,
      poster: video ? image.url : undefined,
      width: size.width,
      height: size.height,
    },
    title: pin.grid_title || pin.title || undefined,
    text: pin.description?.trim() || undefined,
    tags: pin.pin_join?.visual_annotation ?? [],
    author: pin.pinner?.full_name || pin.native_creator?.full_name || undefined,
    publishedAt: pin.created_at ? new Date(pin.created_at).toISOString() : undefined,
  };
}

// 動画は mp4 の直リンクが無いピンもあるので、どのピンにもある HLS を選ぶ。
function hls(pin) {
  const blocks = (pin.story_pin_data?.pages ?? []).flatMap((page) => page.blocks ?? []);
  return (
    [pin.videos, ...blocks.map((b) => b.video)]
      .flatMap((v) => Object.values(v?.video_list ?? {}))
      .find((v) => v?.url?.endsWith(".m3u8")) ?? null
  );
}
