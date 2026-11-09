import { describe, expect, it } from "vitest";

import { keyCommand, type FocusArea, type KeyInput } from "./keys";

const press = (key: string, mods: Partial<KeyInput> = {}): KeyInput => ({
  key,
  keyCode: 0,
  metaKey: false,
  ctrlKey: false,
  altKey: false,
  shiftKey: false,
  isComposing: false,
  ...mods,
});
const at = (focus: FocusArea, lightbox = false, searchEmpty = false) => ({
  focus,
  lightbox,
  searchEmpty,
});

describe("keyCommand", () => {
  it("/ と ⌘F で検索欄へ移り、検索欄の中の / はそのまま打つ", () => {
    expect(keyCommand(press("/"), at("tile"))).toEqual({ type: "focusSearch" });
    expect(keyCommand(press("f", { metaKey: true }), at("search"))).toEqual({
      type: "focusSearch",
    });
    expect(keyCommand(press("/"), at("search"))).toBeUndefined();
  });

  it("検索欄の ↓ と Tab は壁へ、Shift+Tab は既定に任せる", () => {
    expect(keyCommand(press("ArrowDown"), at("search"))).toEqual({ type: "toWall" });
    expect(keyCommand(press("Tab"), at("search"))).toEqual({ type: "toWall" });
    expect(keyCommand(press("Tab", { shiftKey: true }), at("search"))).toBeUndefined();
  });

  it("空の検索欄の Backspace だけが種を外す", () => {
    expect(keyCommand(press("Backspace"), at("search", false, true))).toEqual({ type: "unseed" });
    expect(keyCommand(press("Backspace"), at("search"))).toBeUndefined();
  });

  it("壁で打った字は検索欄へ入り、V・S・O・R・N は操作になる", () => {
    expect(keyCommand(press("a"), at("tile"))).toEqual({ type: "type" });
    expect(keyCommand(press("A", { shiftKey: true }), at("other"))).toEqual({ type: "type" });
    expect(keyCommand(press("v"), at("tile"))).toEqual({ type: "seed" });
    expect(keyCommand(press("S", { shiftKey: true }), at("tile"))).toEqual({ type: "select" });
    expect(keyCommand(press("O", { shiftKey: true }), at("tile"))).toEqual({
      type: "openUrl",
      origin: true,
    });
    expect(keyCommand(press("r"), at("tile"))).toEqual({ type: "shuffle" });
    expect(keyCommand(press("n"), at("other"))).toBeUndefined();
    expect(keyCommand(press(" "), at("tile"))).toBeUndefined();
  });

  it("⌘C はタイルなら画像、どこにも焦点が無ければ選択、検索欄では既定のコピー", () => {
    const copy = press("c", { metaKey: true });
    expect(keyCommand(copy, at("tile"))).toEqual({ type: "copyImage" });
    expect(keyCommand(copy, at("other", true))).toEqual({ type: "copyImage" });
    expect(keyCommand(copy, at("other"))).toEqual({ type: "copySelection" });
    expect(keyCommand(copy, at("search"))).toBeUndefined();
  });

  it("焦点表示では ← → で前後へ移り、Esc は Dialog に任せ、字は検索欄へ入れない", () => {
    expect(keyCommand(press("ArrowRight"), at("other", true))).toEqual({ type: "step", delta: 1 });
    expect(keyCommand(press("ArrowLeft"), at("tile", true))).toBeUndefined();
    expect(keyCommand(press("Escape"), at("other", true))).toBeUndefined();
    expect(keyCommand(press("a"), at("other", true))).toBeUndefined();
    expect(keyCommand(press("v"), at("other", true))).toEqual({ type: "seed" });
    expect(keyCommand(press("[", { metaKey: true }), at("other", true))).toBeUndefined();
  });

  it("Esc と ⌘[ で戻り、⌘] で進む", () => {
    expect(keyCommand(press("Escape"), at("search"))).toEqual({ type: "back" });
    expect(keyCommand(press("Escape"), at("tile"))).toEqual({ type: "back" });
    expect(keyCommand(press("[", { metaKey: true }), at("search"))).toEqual({ type: "back" });
    expect(keyCommand(press("]", { metaKey: true }), at("tile"))).toEqual({ type: "forward" });
  });

  it("⌘= ⌘- ⌘0 で密度を変える", () => {
    expect(keyCommand(press("=", { metaKey: true }), at("tile"))).toEqual({
      type: "density",
      step: 1,
    });
    expect(keyCommand(press("-", { metaKey: true }), at("search"))).toEqual({
      type: "density",
      step: -1,
    });
    expect(keyCommand(press("0", { metaKey: true }), at("other"))).toEqual({
      type: "density",
      step: 0,
    });
  });

  it("IME の入力中は検索欄の Enter を live にしない", () => {
    expect(keyCommand(press("Enter", { keyCode: 229 }), at("search"))).toBeUndefined();
    expect(keyCommand(press("Enter", { isComposing: true }), at("search"))).toBeUndefined();
  });

  it("壁で IME が組み立て始めた打鍵は、検索欄で受ける字として扱う", () => {
    expect(keyCommand(press("k", { keyCode: 229 }), at("tile"))).toEqual({ type: "type" });
    expect(keyCommand(press("k", { keyCode: 229 }), at("other", true))).toBeUndefined();
  });

  it("メモの入力欄では何も奪わない", () => {
    expect(keyCommand(press("Escape"), at("field"))).toBeUndefined();
    expect(keyCommand(press("c", { metaKey: true }), at("field"))).toBeUndefined();
  });
});
