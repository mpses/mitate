import { describe, expect, it } from "vitest";

import { parseShots } from "./api";
import selection from "./fixtures/selection.json";
import { selectionMarkdown } from "./markdown";

const [first] = parseShots(selection);

describe("selectionMarkdown", () => {
  it("タイトル、url、origin、メモを 1 件ずつ箇条書きにする", () => {
    const shot = {
      ...first,
      title: "A",
      url: "https://a.test/1",
      origin: "https://o.test",
      note: undefined,
    };
    expect(
      selectionMarkdown([
        { ...shot, note: "余白" },
        { ...shot, origin: undefined },
      ]),
    ).toBe(
      [
        "- [A](https://a.test/1)",
        "  - origin: https://o.test",
        "  - メモ: 余白",
        "- [A](https://a.test/1)",
      ].join("\n"),
    );
  });

  it("タイトルが無ければ url を出し、角括弧と括弧を壊さない", () => {
    const shot = { ...first, title: undefined, origin: undefined, note: undefined };
    expect(selectionMarkdown([{ ...shot, url: "https://a.test/x_(y)" }])).toBe(
      "- [https://a.test/x_(y)](<https://a.test/x_(y)>)",
    );
    expect(selectionMarkdown([{ ...shot, title: "[draft] UI", url: "https://a.test" }])).toBe(
      "- [\\[draft\\] UI](https://a.test)",
    );
  });

  it("fixture の選択をすべて書き出す", () => {
    const shots = parseShots(selection);
    expect(selectionMarkdown(shots).match(/^- \[/gm)).toHaveLength(shots.length);
  });
});
