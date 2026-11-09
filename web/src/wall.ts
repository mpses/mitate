import type { ShotView } from "./api";

export type WallMode = "browse" | "search" | "similar";

export interface Wall {
  /** 壁を別の結果に差し替えるたびに増える。クロスフェードと先頭へのスクロールの合図 */
  generation: number;
  mode: WallMode;
  shots: readonly ShotView[];
  /** live で後から足した Shot。フェードインで出す */
  fresh: ReadonlySet<string>;
  /** browse でこれ以上のページが無い */
  complete: boolean;
  /** live で問い合わせ中のサイト */
  pending: ReadonlySet<string>;
  /** live で error を返したサイト */
  failed: ReadonlySet<string>;
  /** 問いを投げてから最初の並びが届くまで。この間の壁は前の問いの結果 */
  loading: boolean;
}

export type WallAction =
  | { type: "start"; asking: readonly string[] }
  | { type: "replace"; mode: WallMode; shots: readonly ShotView[]; complete: boolean }
  | { type: "more"; shots: readonly ShotView[]; complete: boolean }
  | { type: "live"; source: string; shots: readonly ShotView[] }
  | { type: "failed"; source: string }
  | { type: "done" }
  /** 応答が途中で切れた。問い合わせ中のサイトを失敗に回す */
  | { type: "abandoned" }
  | { type: "shuffle"; random: () => number };

export const emptyWall: Wall = {
  generation: 0,
  mode: "browse",
  shots: [],
  fresh: new Set(),
  complete: false,
  pending: new Set(),
  failed: new Set(),
  loading: true,
};

export const sameShots = (a: readonly ShotView[], b: readonly ShotView[]) =>
  a.length === b.length && a.every((shot, i) => shot.id === b[i].id);

/** browse を最後まで読んだのに 1 ページに満たず、手元の件数（stock）の方が多い。最初の同期の途中で開いた壁がこうなる */
export const shortOfStock = (wall: Wall, stock: number, page: number) =>
  wall.mode === "browse" &&
  !wall.loading &&
  wall.complete &&
  wall.shots.length < page &&
  stock > wall.shots.length;

/** 並びを動かさず、まだ無い Shot だけを末尾へ足す */
function append(shots: readonly ShotView[], more: readonly ShotView[]): ShotView[] {
  const known = new Set(shots.map((s) => s.id));
  const added = more.filter((shot) => {
    if (known.has(shot.id)) return false;
    known.add(shot.id);
    return true;
  });
  return [...shots, ...added];
}

const without = (set: ReadonlySet<string>, value: string) => {
  const next = new Set(set);
  next.delete(value);
  return next;
};

export function wallReducer(wall: Wall, action: WallAction): Wall {
  switch (action.type) {
    case "start":
      return { ...wall, pending: new Set(action.asking), failed: new Set(), loading: true };
    case "replace": {
      // live の引き直しで同じ並びが届いたときは、差し替えとして扱わない
      const same = wall.mode === action.mode && sameShots(wall.shots, action.shots);
      return {
        ...wall,
        generation: same ? wall.generation : wall.generation + 1,
        mode: action.mode,
        shots: action.shots,
        fresh: same ? wall.fresh : new Set(),
        complete: action.complete,
        loading: false,
      };
    }
    case "more":
      return { ...wall, shots: append(wall.shots, action.shots), complete: action.complete };
    case "live": {
      const shots = append(wall.shots, action.shots);
      const fresh = new Set(wall.fresh);
      for (const shot of shots.slice(wall.shots.length)) fresh.add(shot.id);
      return { ...wall, shots, fresh, pending: without(wall.pending, action.source) };
    }
    case "failed":
      return {
        ...wall,
        pending: without(wall.pending, action.source),
        failed: new Set(wall.failed).add(action.source),
      };
    case "done":
      return { ...wall, pending: new Set() };
    case "abandoned":
      return {
        ...wall,
        pending: new Set(),
        failed: new Set([...wall.failed, ...wall.pending]),
        loading: false,
      };
    case "shuffle": {
      const shots = [...wall.shots];
      for (let i = shots.length - 1; i > 0; i--) {
        const j = Math.floor(action.random() * (i + 1));
        [shots[i], shots[j]] = [shots[j], shots[i]];
      }
      return { ...wall, shots, generation: wall.generation + 1, fresh: new Set() };
    }
  }
}
