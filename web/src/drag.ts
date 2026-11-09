import type { ShotView } from "./api";

/**
 * タイルのドラッグを知らせる WKScriptMessageHandler の名前。送る形は `{ ids }` で、空の配列はドラッグの終わり。
 * native は WebKit がドラッグを始める直前に、中身をこの Shot のファイルに差し替える
 */
export const NATIVE_DRAG_HANDLER = "mitateDrag";

const native = () => window.webkit?.messageHandlers?.[NATIVE_DRAG_HANDLER];

/** アプリの窓の中で動いている。Shot をファイルとして、端末やエージェントのチャットへドラッグできる */
export const canDragOut = (): boolean => native() !== undefined;

let outgoing = false;

/** dragstart で呼ぶ。shots をファイルにして渡すよう native に頼む */
export function dragOut(event: DragEvent, shots: readonly ShotView[]) {
  const handler = native();
  const data = event.dataTransfer;
  if (!handler) throw new Error(`${NATIVE_DRAG_HANDLER} の handler が無い窓でドラッグを始めた`);
  if (!data) throw new Error("dragstart に dataTransfer が無い");
  data.effectAllowed = "copy";
  // native がファイルに差し替える前の中身。差し替えられなかったときは URL が渡る
  data.setData("text/uri-list", shots.map((shot) => shot.url).join("\r\n"));
  handler.postMessage({ ids: shots.map((shot) => shot.id) });
  outgoing = true;
}

/** この窓から始めたドラッグの最中。窓に落としても検索の種にしない */
export const draggingOut = () => outgoing;

function end() {
  if (!outgoing) return;
  outgoing = false;
  native()?.postMessage({ ids: [] });
}

export function installDragOut() {
  window.addEventListener("dragend", end, true);
  // 始めたタイルが描く範囲から外れると dragend が窓まで届かない。次の操作で終わったとみなす
  window.addEventListener("pointerdown", end, true);
}
