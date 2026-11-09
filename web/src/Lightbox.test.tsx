// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi, type MockInstance } from "vitest";

import { parseShots, type ShotView } from "./api";
import browse from "./fixtures/browse.json";
import { Lightbox, type LightboxTarget } from "./Lightbox";
import { FakeTransition, installWallDom } from "./test-utils";
import { Tray } from "./Tray";

// motion.ts は読み込んだ時点で matchMedia を引くので、import より先に置く。動きを減らす設定は試験ごとに切り替える
const prefers = vi.hoisted(() => {
  const state = { reducedMotion: false };
  window.matchMedia = (media: string) =>
    ({
      get matches() {
        return state.reducedMotion;
      },
      media,
      addEventListener: () => {},
      removeEventListener: () => {},
    }) as unknown as MediaQueryList;
  return state;
});

/** 近いものの壁の応答。undefined の間は応答を待たせたままにする */
const nearby = vi.hoisted(() => ({ shots: undefined as ShotView[] | undefined }));

// 本文は応答を待たせたままにする
vi.mock("./api", async (importOriginal) => ({
  ...(await importOriginal<typeof import("./api")>()),
  similar: () => (nearby.shots ? Promise.resolve(nearby.shots) : new Promise(() => {})),
  getShot: () => new Promise(() => {}),
}));

function imageShot(): ShotView {
  const found = parseShots(browse).find((s) => s.kind === "image");
  if (!found) throw new Error("fixture に画像の Shot が無い");
  return found;
}

const shot = imageShot();

let load: MockInstance<HTMLMediaElement["load"]>;
let play: MockInstance<HTMLMediaElement["play"]>;

beforeEach(() => {
  installWallDom();
  vi.spyOn(HTMLMediaElement.prototype, "pause").mockImplementation(() => {});
  load = vi.spyOn(HTMLMediaElement.prototype, "load").mockImplementation(() => {});
  play = vi.spyOn(HTMLMediaElement.prototype, "play").mockResolvedValue();
});

afterEach(() => {
  cleanup();
  nearby.shots = undefined;
  prefers.reducedMotion = false;
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

function renderLightbox(
  editing: string | undefined,
  handlers: { onClose: () => void; onEditEnd: (id: string, note: string | undefined) => void },
) {
  const tray = (
    <Tray
      shots={[shot]}
      sources={new Map()}
      editing={editing}
      handoff
      onEditEnd={handlers.onEditEnd}
      onOpen={() => {}}
      onToggle={() => {}}
      onCopy={async () => {}}
      onClear={() => {}}
    />
  );
  return (
    <Lightbox
      target={{ shot }}
      scope={undefined}
      columnWidth={220}
      sources={new Map()}
      selected={new Set([shot.id])}
      tray={tray}
      trayShown
      onClose={handlers.onClose}
      onClosed={() => {}}
      onOpenSimilar={() => {}}
      onToggle={() => {}}
      onDragOut={() => {}}
    />
  );
}

// Base UI は開いた 1 拍後に初期焦点を移す。負荷が高いと既定の 1 秒では届かない
const INITIAL_FOCUS_TIMEOUT_MS = 5000;

/** 焦点表示を開き、Base UI が初期焦点を移し終えてからメモ欄を出す */
async function openWithNote() {
  const onClose = vi.fn();
  const onEditEnd = vi.fn();
  const view = render(renderLightbox(undefined, { onClose, onEditEnd }));
  await waitFor(
    () => expect(screen.getByRole("dialog").contains(document.activeElement)).toBe(true),
    { timeout: INITIAL_FOCUS_TIMEOUT_MS },
  );
  view.rerender(renderLightbox(shot.id, { onClose, onEditEnd }));
  const note = screen.getByRole("textbox", { name: "メモ" });
  expect(document.activeElement).toBe(note);
  return { note, onClose, onEditEnd };
}

describe("焦点表示の中の選択の列", () => {
  it("メモ欄の Esc はメモを取り消すだけで、焦点表示は開いたまま", async () => {
    const { note, onClose, onEditEnd } = await openWithNote();
    fireEvent.keyDown(note, { key: "Escape" });
    expect(onEditEnd).toHaveBeenCalledWith(shot.id, undefined);
    expect(onClose).not.toHaveBeenCalled();
  });

  it("メモ欄の Enter はメモを確定するだけで、焦点表示は開いたまま", async () => {
    const { note, onClose, onEditEnd } = await openWithNote();
    fireEvent.change(note, { target: { value: "余白" } });
    fireEvent.keyDown(note, { key: "Enter" });
    expect(onEditEnd).toHaveBeenCalledWith(shot.id, "余白");
    expect(onClose).not.toHaveBeenCalled();
  });

  it("メモ欄の外の Esc では焦点表示を閉じる", async () => {
    const onClose = vi.fn();
    render(renderLightbox(undefined, { onClose, onEditEnd: () => {} }));
    const dialog = screen.getByRole("dialog");
    await waitFor(() => expect(dialog.contains(document.activeElement)).toBe(true), {
      timeout: INITIAL_FOCUS_TIMEOUT_MS,
    });
    fireEvent.keyDown(dialog, { key: "Escape" });
    expect(onClose).toHaveBeenCalled();
  });
});

const shots = parseShots(browse);
const videoShots = shots.filter((s) => s.kind === "video");
const imageShots = shots.filter((s) => s.kind === "image");

function lightboxAt(target: LightboxTarget | undefined) {
  return (
    <Lightbox
      target={target}
      scope={undefined}
      columnWidth={220}
      sources={new Map()}
      selected={new Set()}
      tray={null}
      trayShown={false}
      onClose={() => {}}
      onClosed={() => {}}
      onOpenSimilar={() => {}}
      onToggle={() => {}}
      onDragOut={() => {}}
    />
  );
}

const videos = () => [...document.querySelectorAll("video")];

/** 外した <video> は DOM から外れ、src を持たず、load() で資源を放している */
function expectReleased(video: HTMLVideoElement) {
  expect(video.isConnected).toBe(false);
  expect(video.hasAttribute("src")).toBe(false);
  expect(load.mock.contexts).toContain(video);
}

/** 近いものの壁のタイルにカーソルを載せ、再生を始めるまで留まる */
async function hoverNearby() {
  const tile = await waitFor(() => {
    const found = screen.getByRole("dialog").querySelector("section [data-shot-id]");
    if (!found) throw new Error("近いものの壁をまだ描いていない");
    return found;
  });
  fireEvent.pointerEnter(tile);
  await act(() => new Promise((resolve) => setTimeout(resolve, 200)));
}

describe("焦点表示の動画", () => {
  it("標準の操作を出さず、押すと止まり、もう一度押すと動く", () => {
    render(lightboxAt({ shot: videoShots[0] }));
    const [video] = videos();
    expect(video.hasAttribute("controls")).toBe(false);

    let paused = false;
    Object.defineProperty(video, "paused", { configurable: true, get: () => paused });
    fireEvent.click(video);
    expect(HTMLMediaElement.prototype.pause).toHaveBeenCalled();
    paused = true;
    fireEvent.click(video);
    expect(play.mock.contexts).toContain(video);
  });

  it("最初のフレームが届くまでは動画を見せず、下の静止画を見せる", () => {
    render(lightboxAt({ shot: videoShots[0] }));
    const [video] = videos();
    expect(video.hasAttribute("data-shown")).toBe(false);
    expect(screen.getByRole("dialog").querySelector("img")?.getAttribute("src")).toBe(
      videoShots[0].thumb,
    );
    fireEvent.playing(video);
    expect(video.hasAttribute("data-shown")).toBe(true);
  });

  it("音のある動画にだけ消音の切り替えを出す", () => {
    render(lightboxAt({ shot: videoShots[0] }));
    const [video] = videos();
    fireEvent.loadedMetadata(video);
    expect(screen.queryByRole("button", { name: "消音" })).toBeNull();

    Object.defineProperty(video, "audioTracks", { configurable: true, value: { length: 1 } });
    fireEvent.loadedMetadata(video);
    fireEvent.click(screen.getByRole("button", { name: "消音" }));
    expect(video.muted).toBe(true);
    expect(screen.getByRole("button", { name: "音を出す" })).toBeTruthy();
  });

  it("次の Shot へ移ると前の動画を放し、閉じ終えたら今の動画も放す", async () => {
    const [first, second] = videoShots;
    const view = render(lightboxAt({ shot: first }));
    const [before] = videos();
    expect(before.getAttribute("src")).toBe(first.media?.src);

    view.rerender(lightboxAt({ shot: second }));
    const [after] = videos();
    expect(after.getAttribute("src")).toBe(second.media?.src);
    expectReleased(before);

    view.rerender(lightboxAt(undefined));
    await waitFor(() => expect(videos()).toHaveLength(0));
    expectReleased(after);
  });

  it("近いものの壁で再生した動画も、次の Shot へ移るときと閉じるときに放す", async () => {
    nearby.shots = videoShots;
    const view = render(lightboxAt({ shot: imageShots[0] }));
    await hoverNearby();
    const [stepped] = videos();
    expect(stepped.closest("section")).not.toBeNull();

    view.rerender(lightboxAt({ shot: imageShots[1] }));
    expect(videos()).toHaveLength(0);
    expectReleased(stepped);

    await hoverNearby();
    const [closed] = videos();
    view.rerender(lightboxAt(undefined));
    await waitFor(() => expect(videos()).toHaveLength(0));
    expectReleased(closed);
  });

  it("キーボードでも、ボタンで再生と一時停止を切り替え、スライダーで再生位置を送れる", () => {
    render(lightboxAt({ shot: videoShots[0] }));
    const [video] = videos();
    let paused = false;
    Object.defineProperty(video, "paused", { configurable: true, get: () => paused });
    Object.defineProperty(video, "duration", { configurable: true, value: 10 });
    Object.defineProperty(video, "currentTime", { configurable: true, writable: true, value: 0 });
    fireEvent.loadedMetadata(video);

    fireEvent.click(screen.getByRole("button", { name: "一時停止" }));
    expect(HTMLMediaElement.prototype.pause).toHaveBeenCalled();
    paused = true;
    fireEvent.pause(video);
    fireEvent.click(screen.getByRole("button", { name: "再生" }));
    expect(play.mock.contexts).toContain(video);

    const position = screen.getByRole("slider", { name: "再生位置" });
    expect(position.getAttribute("max")).toBe("10");
    fireEvent.change(position, { target: { value: "4" } });
    expect(video.currentTime).toBe(4);
  });

  it("焦点が操作の中にある間は、線とスライダーを今の再生位置に合わせる", () => {
    render(lightboxAt({ shot: videoShots[0] }));
    const [video] = videos();
    Object.defineProperty(video, "duration", { configurable: true, value: 10 });
    Object.defineProperty(video, "currentTime", { configurable: true, writable: true, value: 5 });
    fireEvent.loadedMetadata(video);
    const position = screen.getByRole<HTMLInputElement>("slider", { name: "再生位置" });
    const line = position.nextElementSibling?.firstElementChild;
    if (!(line instanceof HTMLElement)) throw new Error("線が無い");
    expect(line.style.getPropertyValue("--progress")).toBe("");

    act(() => screen.getByRole("button", { name: "一時停止" }).focus());
    expect(line.style.getPropertyValue("--progress")).toBe("0.5");
    expect(position.value).toBe("5");
  });

  it("押した再生を、最初のフレームの前に止めて打ち切っても失敗にしない", async () => {
    // vi.fn は返した Promise に then を付けて結果を記録するので、reject が拾われたことになる。素の関数で差し替える
    const played: HTMLMediaElement[] = [];
    HTMLMediaElement.prototype.play = function (this: HTMLMediaElement) {
      played.push(this);
      return Promise.reject(new DOMException("The operation was aborted.", "AbortError"));
    };
    const unhandled = vi.fn();
    process.on("unhandledRejection", unhandled);
    try {
      render(lightboxAt({ shot: videoShots[0] }));
      const [video] = videos();
      Object.defineProperty(video, "paused", { configurable: true, get: () => true });
      fireEvent.click(video);
      expect(played).toEqual([video]);
      await act(() => new Promise((resolve) => setTimeout(resolve, 0)));
      expect(unhandled).not.toHaveBeenCalled();
    } finally {
      process.off("unhandledRejection", unhandled);
    }
  });

  it("消音は次の Shot の動画にも引き継ぐ", () => {
    const [first, second] = videoShots;
    const view = render(lightboxAt({ shot: first }));
    const [before] = videos();
    Object.defineProperty(before, "audioTracks", { configurable: true, value: { length: 1 } });
    fireEvent.loadedMetadata(before);
    fireEvent.click(screen.getByRole("button", { name: "消音" }));
    expect(before.muted).toBe(true);

    view.rerender(lightboxAt({ shot: second }));
    const [after] = videos();
    expect(after.muted).toBe(true);
    Object.defineProperty(after, "audioTracks", { configurable: true, value: { length: 1 } });
    fireEvent.loadedMetadata(after);
    fireEvent.click(screen.getByRole("button", { name: "音を出す" }));
    expect(after.muted).toBe(false);
  });

  it("動きを減らす設定では自動再生せず、止まった動画に再生のボタンを出したままにする", () => {
    prefers.reducedMotion = true;
    render(lightboxAt({ shot: videoShots[0] }));
    const [video] = videos();
    expect(video.autoplay).toBe(false);
    const resume = screen.getByRole("button", { name: "再生" });
    expect(resume.closest("[data-paused]")).not.toBeNull();
  });
});

describe("焦点表示の広がり", () => {
  it("近いものの壁から開くと、Popup を先頭へ戻してから広がりの終点を測る", async () => {
    nearby.shots = imageShots;
    const view = render(lightboxAt({ shot: imageShots[0], from: new DOMRect(0, 0, 100, 100) }));
    await waitFor(() => {
      if (!document.querySelector("section [data-shot-id]"))
        throw new Error("近いものの壁をまだ描いていない");
    });
    const popup = screen.getByRole("dialog");
    // Popup を 900px 下へ送った状態。どの要素も、内容の上端から 100px の位置にスクロール量を引いた所にあるとみなす
    let scrollTop = 900;
    vi.spyOn(Element.prototype, "getBoundingClientRect").mockImplementation(
      () => new DOMRect(300, 100 - scrollTop, 400, 300),
    );
    vi.spyOn(Element.prototype, "scrollTo").mockImplementation(function (this: Element) {
      if (this === popup) scrollTop = 0;
    });
    const animate = vi.spyOn(Element.prototype, "animate");

    // 窓の中の y=400 にあるタイルを押した
    view.rerender(lightboxAt({ shot: imageShots[1], from: new DOMRect(300, 400, 200, 150) }));
    const [keyframes] = animate.mock.calls.at(-1) ?? [];
    expect((keyframes as Keyframe[])[0].transform).toBe("translate(-100px, 225px) scale(0.5)");
  });
});

describe("焦点表示の開閉の動き", () => {
  it("Popup 自身の transition は、終わったら放す", async () => {
    vi.stubGlobal("CSSTransition", FakeTransition);
    render(lightboxAt({ shot: imageShots[0] }));
    const popup = screen.getByRole("dialog");
    const transition = new FakeTransition();
    popup.getAnimations = () => [transition.asAnimation()];

    fireEvent(popup, new Event("transitionrun", { bubbles: true }));
    transition.finish();
    await waitFor(() => expect(transition.timeline).toBeNull());
    expect(transition.effect).toBeNull();
  });
});
