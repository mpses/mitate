import { useCallback, useEffect, useReducer, useRef, useState } from "react";

import { browse, getSources, search, similar, type SimilarTarget, type SourceStatus } from "./api";
import type { Query, Seed } from "./history";
import { emptyWall, sameShots, shortOfStock, wallReducer, type Wall, type WallMode } from "./wall";

const PAGE = 80;
const SOURCES_INTERVAL_MS = 5000;

/** 取り消した要求の失敗は捨て、それ以外はそのまま投げる */
const unlessAborted = (signal: AbortSignal) => (error: unknown) => {
  if (!signal.aborted) throw error;
};

const seedTarget = (seed: Seed): SimilarTarget =>
  seed.type === "shot" ? { id: seed.shot.id } : seed.image;

/** サイトの状態。同期の進み具合とログインを映すため、間を空けて引き直す */
export function useSources(): [readonly SourceStatus[], () => void] {
  const [sources, setSources] = useState<readonly SourceStatus[]>([]);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    const controller = new AbortController();
    const load = () => {
      getSources(controller.signal)
        // 中身が同じなら前の配列を使い続け、アイコンとタイルを描き直さない
        .then((loaded) =>
          setSources((prev) => (JSON.stringify(prev) === JSON.stringify(loaded) ? prev : loaded)),
        )
        .catch(unlessAborted(controller.signal));
    };
    load();
    const timer = window.setInterval(load, SOURCES_INTERVAL_MS);
    return () => {
      window.clearInterval(timer);
      controller.abort();
    };
  }, [tick]);
  return [sources, useCallback(() => setTick((n) => n + 1), [])];
}

export interface WallRun {
  query: Query;
  scope: string | undefined;
  /** live で引くときの合図。Enter のたびに新しい値にする */
  live: object | undefined;
  /** scope のサイトが手元に持つ件数の合計 */
  stock: number;
  /** live で問い合わせるサイト。走り出した時点の値を使う */
  searchable: () => readonly string[];
  /** 壁を別の並びに差し替える直前に呼ぶ。古い壁を写し取ってクロスフェードさせる */
  beforeReplace: () => void;
}

/** 問いから壁を引く。検索語が無ければ browse、種があれば similar、語があれば search */
export function useWall({ query, scope, live, stock, searchable, beforeReplace }: WallRun) {
  const [wall, dispatch] = useReducer(wallReducer, emptyWall);
  const latest = useRef<Wall>(wall);
  const run = useRef<{ signal: AbortSignal; browsing: boolean; loading: boolean }>(undefined);
  const hooks = useRef({ searchable, beforeReplace });
  useEffect(() => {
    latest.current = wall;
    hooks.current = { searchable, beforeReplace };
  });

  // 同期で件数が増えても、読み終えた短い壁は自分からは伸びない。件数の変化を合図に browse を引き直す
  const [restock, setRestock] = useState(0);
  const short = shortOfStock(wall, stock, PAGE);
  useEffect(() => {
    if (short) setRestock((n) => n + 1);
  }, [short, stock]);

  useEffect(() => {
    const controller = new AbortController();
    const { signal } = controller;
    const state = { signal, browsing: false, loading: false };
    run.current = state;
    const scoped = { sources: scope, signal };
    const replace = (mode: WallMode, shots: Wall["shots"], complete: boolean) => {
      if (signal.aborted) return;
      if (!sameShots(latest.current.shots, shots)) hooks.current.beforeReplace();
      dispatch({ type: "replace", mode, shots, complete });
    };
    dispatch({ type: "start", asking: live ? hooks.current.searchable() : [] });
    const text = query.text.trim();
    let finished = false;
    const work = query.seed
      ? similar(seedTarget(query.seed), scoped).then((shots) => replace("similar", shots, true))
      : text
        ? search(text, live !== undefined, scoped, (event) => {
            if (signal.aborted) return;
            if (event.type === "local") replace("search", event.shots, true);
            else if (event.type === "live") dispatch(event);
            else if (event.type === "error") dispatch({ type: "failed", source: event.source });
            else {
              finished = true;
              dispatch({ type: "done" });
            }
          }).then(() => {
            // 応答は必ず done で終わる。途中で切れたら問い合わせ中のサイトを回し続けない
            if (!signal.aborted && !finished) {
              throw new Error("done を受けずに検索の応答が終わった");
            }
          })
        : browse(0, PAGE, scoped).then((shots) => {
            replace("browse", shots, shots.length < PAGE);
            state.browsing = true;
          });
    work.catch((error: unknown) => {
      if (signal.aborted) return;
      dispatch({ type: "abandoned" });
      throw error;
    });
    return () => controller.abort();
  }, [query, scope, live, restock]);

  // 壁の子（ShotWall）の effect から呼ばれる。子の effect は latest を更新する親の effect より先に走るので、描いた時点の値で閉じる。
  // 件数が変わるたびに別の関数になり、子は窓が埋まるまで続けて呼び直す
  const loaded = wall.shots.length;
  const complete = wall.complete;
  /** browse の続きのページを読む。読んでいる間と最後まで読んだ後は何もしない */
  const loadMore = useCallback(() => {
    const state = run.current;
    if (!state?.browsing || state.loading || complete) return;
    state.loading = true;
    browse(loaded, PAGE, { sources: scope, signal: state.signal })
      .then((shots) => {
        // 足した後の描画で次のページを読めるよう、dispatch より先に空ける
        state.loading = false;
        if (!state.signal.aborted) dispatch({ type: "more", shots, complete: shots.length < PAGE });
      })
      .catch(unlessAborted(state.signal))
      .finally(() => {
        state.loading = false;
      });
  }, [scope, loaded, complete]);

  const shuffle = useCallback(() => {
    if (latest.current.mode !== "browse") return false;
    hooks.current.beforeReplace();
    dispatch({ type: "shuffle", random: Math.random });
    return true;
  }, []);

  return { wall, loadMore, shuffle };
}
