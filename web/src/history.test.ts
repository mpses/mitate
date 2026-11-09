import { describe, expect, it } from "vitest";

import { parseShots } from "./api";
import browse from "./fixtures/browse.json";
import {
  back,
  commit,
  current,
  edit,
  forward,
  HISTORY_LIMIT,
  initialHistory,
  push,
} from "./history";

const shot = parseShots(browse)[0];
const texts = (h: typeof initialHistory) => h.entries.map((q) => q.text);

describe("history", () => {
  it("続けて打つと同じ項目を書き換え、確定すると次の入力は新しい項目になる", () => {
    let h = edit(edit(initialHistory, "to"), "toggle");
    expect(texts(h)).toEqual(["", "toggle"]);
    h = edit(commit(h), "button");
    expect(texts(h)).toEqual(["", "toggle", "button"]);
  });

  it("打ち直して 1 つ前と同じ語に戻ると、打ち込み中の項目を消す", () => {
    const h = edit(edit(initialHistory, "a"), "");
    expect(texts(h)).toEqual([""]);
    expect(h.draft).toBe(false);
  });

  it("前へ戻ってから打つと、先の項目を捨てる", () => {
    let h = commit(edit(commit(edit(initialHistory, "a")), "b"));
    h = back(h);
    expect(current(h).text).toBe("a");
    h = edit(h, "c");
    expect(texts(h)).toEqual(["", "a", "c"]);
    expect(forward(h)).toBe(h);
  });

  it("種のある項目で打つと、種を語で置き換えた新しい項目にする", () => {
    let h = push(initialHistory, { text: "", seed: { type: "shot", shot } });
    h = edit(h, "x");
    expect(h.entries).toHaveLength(3);
    expect(current(h)).toEqual({ text: "x" });
    expect(current(back(h)).seed?.type).toBe("shot");
  });

  it("項目が上限を超えたら古いものから捨て、今の項目を指し続ける", () => {
    let h = initialHistory;
    for (let i = 0; i < HISTORY_LIMIT + 10; i++) h = push(h, { text: `q${i}` });
    expect(h.entries).toHaveLength(HISTORY_LIMIT);
    expect(texts(h)[0]).toBe("q10");
    expect(current(h).text).toBe(`q${HISTORY_LIMIT + 9}`);
    expect(current(back(h)).text).toBe(`q${HISTORY_LIMIT + 8}`);
  });

  it("端では戻りも進みもしない", () => {
    expect(back(initialHistory)).toBe(initialHistory);
    expect(forward(initialHistory)).toBe(initialHistory);
  });
});
