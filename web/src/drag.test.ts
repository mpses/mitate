// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";

import { parseShots } from "./api";
import { canDragOut, draggingOut, dragOut, installDragOut, NATIVE_DRAG_HANDLER } from "./drag";
import browse from "./fixtures/browse.json";

const shots = parseShots(browse).slice(0, 2);

function withNative() {
  const postMessage = vi.fn();
  window.webkit = { messageHandlers: { [NATIVE_DRAG_HANDLER]: { postMessage } } };
  return postMessage;
}

function dragStart() {
  const data = { effectAllowed: "uninitialized", setData: vi.fn() };
  return { event: { dataTransfer: data } as unknown as DragEvent, data };
}

installDragOut();

afterEach(() => {
  window.dispatchEvent(new Event("dragend"));
  delete window.webkit;
});

describe("ほかのアプリへのドラッグ", () => {
  it("アプリの窓の外では使えない", () => {
    expect(canDragOut()).toBe(false);
    expect(() => dragOut(dragStart().event, shots)).toThrow(NATIVE_DRAG_HANDLER);
  });

  it("Shot の id を native に知らせ、写すドラッグにする", () => {
    const postMessage = withNative();
    const { event, data } = dragStart();
    expect(canDragOut()).toBe(true);
    dragOut(event, shots);
    expect(postMessage).toHaveBeenCalledWith({ ids: shots.map((s) => s.id) });
    expect(data.effectAllowed).toBe("copy");
    expect(data.setData).toHaveBeenCalledWith(
      "text/uri-list",
      shots.map((s) => s.url).join("\r\n"),
    );
    expect(draggingOut()).toBe(true);
  });

  it("ドラッグが終わったら native に知らせ、窓へのドロップを受けられるよう戻す", () => {
    const postMessage = withNative();
    dragOut(dragStart().event, shots);
    window.dispatchEvent(new Event("dragend"));
    expect(postMessage).toHaveBeenLastCalledWith({ ids: [] });
    expect(draggingOut()).toBe(false);
  });

  it("dragend が届かなくても、次に押したときに終わったとみなす", () => {
    withNative();
    dragOut(dragStart().event, shots);
    window.dispatchEvent(new Event("pointerdown"));
    expect(draggingOut()).toBe(false);
  });
});
