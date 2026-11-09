import { describe, expect, it } from "vitest";

import { parseShots } from "./api";
import browse from "./fixtures/browse.json";
import { emptyWall, shortOfStock, wallReducer, type WallAction } from "./wall";

const shots = parseShots(browse);
const run = (...actions: WallAction[]) => actions.reduce(wallReducer, emptyWall);
const ids = (list: readonly { id: string }[]) => list.map((s) => s.id);

describe("wallReducer", () => {
  it("違う並びに差し替えると generation が進み、同じ並びなら進まない", () => {
    const wall = run({ type: "replace", mode: "search", shots: shots.slice(0, 3), complete: true });
    expect(wall.generation).toBe(1);
    const again = wallReducer(wall, {
      type: "replace",
      mode: "search",
      shots: shots.slice(0, 3),
      complete: true,
    });
    expect(again.generation).toBe(1);
  });

  it("live の結果は並びを動かさず末尾へ足し、重複は落とし、足したものを fresh にする", () => {
    const wall = run(
      { type: "start", asking: ["pinterest", "x"] },
      { type: "replace", mode: "search", shots: shots.slice(0, 3), complete: true },
      { type: "live", source: "pinterest", shots: [shots[1], shots[3], shots[4]] },
    );
    expect(ids(wall.shots)).toEqual(ids(shots.slice(0, 5)));
    expect([...wall.fresh]).toEqual(ids(shots.slice(3, 5)));
    expect([...wall.pending]).toEqual(["x"]);
  });

  it("error のサイトは問い合わせ中から外して failed に入れ、次の start で消す", () => {
    let wall = run({ type: "start", asking: ["x"] }, { type: "failed", source: "x" });
    expect([...wall.pending]).toEqual([]);
    expect([...wall.failed]).toEqual(["x"]);
    wall = wallReducer(wall, { type: "start", asking: [] });
    expect([...wall.failed]).toEqual([]);
  });

  it("done で問い合わせ中を空にする", () => {
    const wall = run({ type: "start", asking: ["pinterest"] }, { type: "done" });
    expect(wall.pending.size).toBe(0);
  });

  it("start から最初の並びが届くまでを読み込み中とする", () => {
    const started = run({ type: "start", asking: [] });
    expect(started.loading).toBe(true);
    const replaced = wallReducer(started, {
      type: "replace",
      mode: "search",
      shots: [],
      complete: true,
    });
    expect(replaced.loading).toBe(false);
  });

  it("応答が途中で切れたら、問い合わせ中のサイトを失敗に回して読み込みを終える", () => {
    const wall = run(
      { type: "start", asking: ["pinterest", "x"] },
      { type: "failed", source: "x" },
      { type: "abandoned" },
    );
    expect(wall.pending.size).toBe(0);
    expect([...wall.failed].toSorted()).toEqual(["pinterest", "x"]);
    expect(wall.loading).toBe(false);
  });

  it("browse の続きは重複を落として足す", () => {
    const wall = run(
      { type: "replace", mode: "browse", shots: shots.slice(0, 4), complete: false },
      { type: "more", shots: shots.slice(2, 6), complete: true },
    );
    expect(ids(wall.shots)).toEqual(ids(shots.slice(0, 6)));
    expect(wall.complete).toBe(true);
  });

  it("並べ替えは同じ Shot を別の順に並べ、差し替えとして扱う", () => {
    const wall = run(
      { type: "replace", mode: "browse", shots: shots.slice(0, 8), complete: false },
      { type: "shuffle", random: () => 0 },
    );
    expect(wall.generation).toBe(2);
    expect(new Set(ids(wall.shots))).toEqual(new Set(ids(shots.slice(0, 8))));
    expect(ids(wall.shots)).not.toEqual(ids(shots.slice(0, 8)));
  });
});

describe("shortOfStock", () => {
  it("読み終えた browse の壁が 1 ページに満たず、手元の件数が多いときだけ引き直す", () => {
    const empty = run({ type: "replace", mode: "browse", shots: [], complete: true });
    expect(shortOfStock(empty, 0, 80)).toBe(false);
    expect(shortOfStock(empty, 496, 80)).toBe(true);
    const few = run({ type: "replace", mode: "browse", shots: shots.slice(0, 3), complete: true });
    expect(shortOfStock(few, 3, 80)).toBe(false);
    expect(shortOfStock(few, 5, 80)).toBe(true);
  });

  it("続きのページがある壁、問い合わせ中の壁、検索の結果は引き直さない", () => {
    const paged = run({
      type: "replace",
      mode: "browse",
      shots: shots.slice(0, 3),
      complete: false,
    });
    expect(shortOfStock(paged, 500, 80)).toBe(false);
    expect(shortOfStock(run({ type: "start", asking: [] }), 500, 80)).toBe(false);
    const found = run({ type: "replace", mode: "search", shots: [], complete: true });
    expect(shortOfStock(found, 500, 80)).toBe(false);
  });
});
