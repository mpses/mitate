// @vitest-environment jsdom
import { createRef } from "react";

import { act, cleanup, fireEvent, render } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi, type MockInstance } from "vitest";

import { parseShots, type ShotView } from "./api";
import browse from "./fixtures/browse.json";
import { ShotWall, type ShotWallHandle } from "./ShotWall";
import { installWallDom } from "./test-utils";

// motion.ts は読み込んだ時点で matchMedia を引くので、import より先に置く
vi.hoisted(() => {
  window.matchMedia = (media: string) =>
    ({
      matches: false,
      media,
      addEventListener: () => {},
      removeEventListener: () => {},
    }) as unknown as MediaQueryList;
});

const videoShots = parseShots(browse).filter((shot) => shot.kind === "video");

function Wall({
  shots,
  generation = 0,
  onDragOut = () => {},
}: {
  shots: readonly ShotView[];
  generation?: number;
  onDragOut?: (shot: ShotView, event: DragEvent) => void;
}) {
  return (
    <ShotWall
      shots={shots}
      generation={generation}
      columnWidth={220}
      sources={new Map()}
      selected={new Set()}
      onOpen={() => {}}
      onToggle={() => {}}
      onDragOut={onDragOut}
    />
  );
}

let load: MockInstance<HTMLMediaElement["load"]>;

beforeEach(() => {
  installWallDom();
  vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
  vi.spyOn(HTMLMediaElement.prototype, "pause").mockImplementation(() => {});
  load = vi.spyOn(HTMLMediaElement.prototype, "load").mockImplementation(() => {});
});

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.restoreAllMocks();
});

const videos = () => [...document.querySelectorAll("video")];

function tileOf(container: HTMLElement, shot: ShotView): HTMLElement {
  const tile = container.querySelector<HTMLElement>(`[data-shot-id="${CSS.escape(shot.id)}"]`);
  if (!tile) throw new Error(`タイルを描いていない: ${shot.id}`);
  return tile;
}

/** タイルにカーソルを載せ、再生を始めるまで留まる */
function hover(tile: HTMLElement) {
  fireEvent.pointerEnter(tile);
  act(() => {
    vi.advanceTimersByTime(200);
  });
}

/** 外した <video> は DOM から外れ、src を持たず、load() で資源を放している */
function expectReleased(video: HTMLVideoElement) {
  expect(video.isConnected).toBe(false);
  expect(video.hasAttribute("src")).toBe(false);
  expect(load.mock.contexts).toContain(video);
}

describe("タイルのホバー再生", () => {
  it("載せて留まると、そのタイルの動画を muted で再生する", () => {
    const { container } = render(<Wall shots={videoShots} />);
    hover(tileOf(container, videoShots[0]));
    const [video] = videos();
    expect(video.getAttribute("src")).toBe(videoShots[0].media?.src);
    expect(video.muted).toBe(true);
    expect(video.autoplay).toBe(true);
  });

  it("載せては離れるのを繰り返しても <video> は 1 つまでで、離れるたびに動画を放す", () => {
    const { container } = render(<Wall shots={videoShots} />);
    for (const shot of videoShots.slice(0, 10)) {
      const tile = tileOf(container, shot);
      hover(tile);
      const [video] = videos();
      expect(videos()).toHaveLength(1);
      fireEvent.pointerLeave(tile);
      expect(videos()).toHaveLength(0);
      expectReleased(video);
    }
  });

  it("離れる知らせが来ないまま別のタイルで再生を始めても、前のタイルの動画を放す", () => {
    const { container } = render(<Wall shots={videoShots} />);
    let previous: HTMLVideoElement | undefined;
    for (const shot of videoShots.slice(0, 4)) {
      hover(tileOf(container, shot));
      expect(videos()).toHaveLength(1);
      const [video] = videos();
      expect(video.getAttribute("src")).toBe(shot.media?.src);
      if (previous) expectReleased(previous);
      previous = video;
    }
  });

  it("留まる前に離れたら、再生を始めない", () => {
    const { container } = render(<Wall shots={videoShots} />);
    const tile = tileOf(container, videoShots[0]);
    fireEvent.pointerEnter(tile);
    fireEvent.pointerLeave(tile);
    act(() => {
      vi.advanceTimersByTime(200);
    });
    expect(videos()).toHaveLength(0);
  });

  it("タイルが描く範囲から外れると、その動画を放す", async () => {
    const { container } = render(<Wall shots={videoShots} />);
    const first = tileOf(container, videoShots[0]);
    hover(first);
    const [video] = videos();
    const wall = first.parentElement;
    if (!wall) throw new Error("タイルの親が無い");
    // 壁を窓の上へ大きく送った位置にする
    wall.getBoundingClientRect = () => ({ top: -3000 }) as DOMRect;
    fireEvent.scroll(document);
    await act(() => new Promise((resolve) => requestAnimationFrame(resolve)));
    expect(first.isConnected).toBe(false);
    expect(videos()).toHaveLength(0);
    expectReleased(video);
  });

  it("壁が差し替わると、残ったタイルの上の再生も止めて動画を放す", () => {
    const { container, rerender } = render(<Wall shots={videoShots} generation={1} />);
    const tile = tileOf(container, videoShots[0]);
    hover(tile);
    const [video] = videos();
    rerender(<Wall shots={videoShots} generation={2} />);
    expect(tile.isConnected).toBe(true);
    expect(videos()).toHaveLength(0);
    expectReleased(video);
  });
});

describe("タイルのドラッグ", () => {
  afterEach(() => {
    delete window.webkit;
  });

  it("アプリの窓の中では、ドラッグを始めたタイルの Shot を渡す", () => {
    window.webkit = { messageHandlers: { mitateDrag: { postMessage: () => {} } } };
    const onDragOut = vi.fn();
    const { container } = render(<Wall shots={videoShots} onDragOut={onDragOut} />);
    const tile = tileOf(container, videoShots[1]);
    expect(tile.getAttribute("draggable")).toBe("true");
    fireEvent.dragStart(tile);
    expect(onDragOut).toHaveBeenCalledWith(videoShots[1], expect.any(Event));
  });

  it("アプリの窓の外ではタイルをドラッグさせない", () => {
    const { container } = render(<Wall shots={videoShots} />);
    expect(tileOf(container, videoShots[0]).getAttribute("draggable")).toBe("false");
  });
});

describe("壁の差し替え", () => {
  const imageShots = parseShots(browse).filter((shot) => shot.kind === "image");
  const fadesIn = (calls: unknown[][]) =>
    calls.some(
      ([keyframes]) =>
        JSON.stringify(keyframes) === JSON.stringify([{ opacity: 0 }, { opacity: 1 }]),
    );

  function wallAt(generation: number, ref: React.Ref<ShotWallHandle>) {
    return (
      <ShotWall
        ref={ref}
        shots={imageShots.slice(generation, generation + 8)}
        generation={generation}
        columnWidth={220}
        sources={new Map()}
        selected={new Set()}
        onOpen={() => {}}
        onToggle={() => {}}
        onDragOut={() => {}}
      />
    );
  }

  it("古い壁を写して重ねたときは、その下の新しい壁を薄くせずに見せる", () => {
    const animate = vi.spyOn(Element.prototype, "animate");
    const ref = createRef<ShotWallHandle>();
    const view = render(wallAt(1, ref));
    expect(fadesIn(animate.mock.calls)).toBe(true);

    animate.mockClear();
    act(() => ref.current?.snapshot());
    const clone = document.body.lastElementChild;
    expect(clone?.getAttribute("aria-hidden")).toBe("true");
    const images = [...(clone?.querySelectorAll("img") ?? [])];
    expect(images.length).toBeGreaterThan(0);
    expect(images.every((image) => image.decoding === "sync")).toBe(true);

    view.rerender(wallAt(2, ref));
    expect(fadesIn(animate.mock.calls)).toBe(false);

    // 重ねずに差し替えたときは、これまでどおりフェードインする
    view.rerender(wallAt(3, ref));
    expect(fadesIn(animate.mock.calls)).toBe(true);
  });
});
