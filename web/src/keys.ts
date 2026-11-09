/** 焦点がどこにあるか。tile は壁（焦点表示の中の壁も含む）のタイル、field は検索欄以外の入力欄 */
export type FocusArea = "search" | "tile" | "field" | "other";

export interface KeyContext {
  focus: FocusArea;
  lightbox: boolean;
  /** 検索欄が空 */
  searchEmpty: boolean;
}

export interface KeyInput {
  key: string;
  keyCode: number;
  metaKey: boolean;
  ctrlKey: boolean;
  altKey: boolean;
  shiftKey: boolean;
  isComposing: boolean;
}

export type Command =
  | { type: "focusSearch" }
  /** 打った字を検索欄で受ける。字の挿入はブラウザと IME に任せる */
  | { type: "type" }
  | { type: "back" }
  | { type: "forward" }
  | { type: "density"; step: -1 | 0 | 1 }
  | { type: "toWall" }
  | { type: "live" }
  | { type: "unseed" }
  | { type: "step"; delta: -1 | 1 }
  | { type: "seed" }
  | { type: "select" }
  | { type: "note" }
  | { type: "openUrl"; origin: boolean }
  | { type: "copyImage" }
  | { type: "copySelection" }
  | { type: "shuffle" };

/** 単キーの操作に当てた字。打っても検索欄へは入れない */
const actionKeys = new Set(["v", "s", "o", "r", "n"]);

function withMeta(key: string, context: KeyContext): Command | undefined {
  if (key === "=" || key === "+") return { type: "density", step: 1 };
  if (key === "-") return { type: "density", step: -1 };
  if (key === "0") return { type: "density", step: 0 };
  if (context.focus === "field") return undefined;
  if (key === "c") {
    if (context.focus === "tile" || (context.lightbox && context.focus === "other")) {
      return { type: "copyImage" };
    }
    return context.focus === "other" ? { type: "copySelection" } : undefined;
  }
  // 焦点表示の中では、外の検索欄と壁を動かさない
  if (context.lightbox) return undefined;
  if (key === "f") return { type: "focusSearch" };
  if (key === "[") return { type: "back" };
  if (key === "]") return { type: "forward" };
  return undefined;
}

function inSearch(event: KeyInput, context: KeyContext): Command | undefined {
  if (event.key === "ArrowDown" || (event.key === "Tab" && !event.shiftKey)) {
    return { type: "toWall" };
  }
  if (event.key === "Enter") return { type: "live" };
  if (event.key === "Escape") return { type: "back" };
  if (event.key === "Backspace" && context.searchEmpty) return { type: "unseed" };
  return undefined;
}

/** キー入力を操作に写す。どの操作にも当たらなければ undefined で、既定の動作に任せる */
export function keyCommand(event: KeyInput, context: KeyContext): Command | undefined {
  // Safari は IME の確定の Enter を isComposing なしで送り、keyCode だけが 229 になる
  if (event.isComposing || event.keyCode === 229) {
    return context.focus === "tile" || (context.focus === "other" && !context.lightbox)
      ? { type: "type" }
      : undefined;
  }
  const key = event.key.length === 1 ? event.key.toLowerCase() : event.key;
  if (event.metaKey && !event.ctrlKey && !event.altKey) return withMeta(key, context);
  if (event.metaKey || event.ctrlKey || event.altKey) return undefined;
  if (context.focus === "field") return undefined;
  if (context.focus === "search") return inSearch(event, context);

  const onShot = context.focus === "tile" || context.lightbox;
  if (key === "o" && onShot) return { type: "openUrl", origin: event.shiftKey };
  if (key === "v" && onShot) return { type: "seed" };
  if (key === "s" && onShot) return { type: "select" };
  if (key === "n" && onShot) return { type: "note" };
  if (context.lightbox) {
    if (key === "ArrowLeft" && context.focus !== "tile") return { type: "step", delta: -1 };
    if (key === "ArrowRight" && context.focus !== "tile") return { type: "step", delta: 1 };
    return undefined;
  }
  if (key === "r") return { type: "shuffle" };
  if (key === "Escape") return { type: "back" };
  if (key === "/") return { type: "focusSearch" };
  if (key.length === 1 && key !== " " && !actionKeys.has(key)) {
    return { type: "type" };
  }
  return undefined;
}
