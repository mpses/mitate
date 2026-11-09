import {
  useCallback,
  useEffect,
  useImperativeHandle,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type Ref,
} from "react";

import { css } from "@bakutan-org/ui/styled-system/css";

import type { ShotView, SourceStatus } from "./api";
import { columnCount, layout, neighbor, visible, type Direction, type Layout } from "./masonry";
import { animateOnce, fallbackAspect, motion, useReducedMotion } from "./motion";
import { fitText, readMetrics, type TextMetrics } from "./textFit";
import { shotAt, TextFace, Tile } from "./Tile";
import { releaseVideo, stopHoverPlaybackIn } from "./video";

export interface ShotWallHandle {
  /** 今の壁を写し取って上に重ね、差し替えの間に消す。クロスフェードの古い側になる */
  snapshot(): void;
  /** その Shot のタイルへ焦点を移す。描いていなければ描いてから移す。壁に無い Shot なら false */
  focus(id: string): boolean;
  element(id: string): HTMLElement | undefined;
}

export interface ShotWallProps {
  ref?: Ref<ShotWallHandle>;
  shots: readonly ShotView[];
  /** 変わるたびに新しい壁をフェードインする */
  generation: number;
  columnWidth: number;
  sources: ReadonlyMap<string, SourceStatus>;
  selected: ReadonlySet<string>;
  fresh?: ReadonlySet<string>;
  /** 次の問いの応答を待っている。今の壁は古いので、薄くして操作を止める */
  stale?: boolean;
  /** 描いている範囲が壁の末尾に近づいた */
  onNearEnd?: () => void;
  /** 列の先頭で ↑ を押した */
  onExitTop?: () => void;
  onOpen: (shot: ShotView, from: DOMRect) => void;
  onToggle: (shot: ShotView) => void;
  onDragOut: (shot: ShotView, event: DragEvent) => void;
}

const styles = {
  wall: css({
    "--wall-gap": "token(spacing.3)",
    position: "relative",
    transitionDuration: "fast",
    transitionProperty: "opacity",
    transitionTimingFunction: "out",
    w: "full",
    "&[data-stale]": { opacity: 0.5, pointerEvents: "none" },
  }),
  sample: css({
    insetBlockStart: "0",
    insetInlineStart: "0",
    pointerEvents: "none",
    position: "absolute",
    visibility: "hidden",
  }),
};

const arrows: Record<string, Direction> = {
  ArrowLeft: "left",
  ArrowRight: "right",
  ArrowUp: "up",
  ArrowDown: "down",
};

// 描く範囲の上下端をこの幅で丸め、スクロールのたびに描き直さないようにする
const RANGE_STEP = 240;

function readGap(element: HTMLElement): number {
  const gap = Number.parseFloat(getComputedStyle(element).getPropertyValue("--wall-gap"));
  if (Number.isNaN(gap)) throw new Error("--wall-gap を読めない");
  return gap;
}

/** 壁をスクロールさせている要素。焦点表示の中の壁は Popup、外の壁は文書 */
function scrollerOf(element: HTMLElement): Element {
  for (let node = element.parentElement; node; node = node.parentElement) {
    const { overflowY } = getComputedStyle(node);
    if (overflowY === "auto" || overflowY === "scroll") return node;
  }
  const root = document.scrollingElement;
  if (!root) throw new Error("document.scrollingElement が無い");
  return root;
}

/**
 * 列の組み替えの前に見ていたタイルと、その窓の中の高さ。焦点があればそのタイル、無ければ表示範囲の先頭。
 * wallTop は組み替え前の壁の上端。組み替えで壁が縮むとスクロールが詰められるので、前に測った値を使う
 */
function anchorOf(
  before: { grid: Layout; shots: readonly ShotView[] },
  element: HTMLElement,
  wallTop: number,
): { id: string; top: number } | undefined {
  const focused = element.contains(document.activeElement)
    ? shotAt(document.activeElement)
    : undefined;
  const index = focused
    ? before.shots.findIndex((shot) => shot.id === focused.id)
    : before.grid.boxes.findIndex((box) => box.y + box.h > -wallTop);
  if (index < 0) return undefined;
  return { id: before.shots[index].id, top: wallTop + before.grid.boxes[index].y };
}

/** 縦横比を保ったマソンリー。表示範囲の前後 1 画面ぶんだけタイルを描く */
export function ShotWall({
  ref,
  shots,
  generation,
  columnWidth,
  sources,
  selected,
  fresh,
  stale = false,
  onNearEnd,
  onExitTop,
  onOpen,
  onToggle,
  onDragOut,
}: ShotWallProps) {
  const container = useRef<HTMLDivElement>(null);
  const elements = useRef(new Map<string, HTMLElement>());
  const pendingFocus = useRef<string>(undefined);
  const reducedMotion = useReducedMotion();
  const [size, setSize] = useState({ width: 0, gap: 0 });
  const [range, setRange] = useState({ top: 0, bottom: 0 });
  const [measured, setMeasured] = useState<ReadonlyMap<string, number>>(new Map());
  const [active, setActive] = useState<string>();
  const sample = useRef<HTMLSpanElement>(null);
  const [metrics, setMetrics] = useState<TextMetrics>();

  const count = columnCount(size.width, columnWidth, size.gap);
  const tileWidth = (size.width - size.gap * (count - 1)) / count;

  // 文字のタイルは、列幅で何行になるかを測って高さを決める
  useLayoutEffect(() => {
    const element = sample.current;
    if (!element || tileWidth <= 0) return;
    const first = readMetrics(element);
    setMetrics(first);
    // 最初の計測は代替のフォントで測っていることがある。使うフォントを読み終えてから測り直す
    let current = true;
    Promise.all([document.fonts.load(first.title.font), document.fonts.load(first.body.font)]).then(
      () => {
        if (current) setMetrics(readMetrics(element));
      },
    );
    return () => {
      current = false;
    };
  }, [tileWidth]);

  const fits = useMemo(
    () =>
      new Map(
        metrics
          ? shots.filter((s) => s.kind === "text").map((s) => [s.id, fitText(s, metrics)])
          : [],
      ),
    [shots, metrics],
  );

  const grid = useMemo(() => {
    const aspects = shots.map((shot) => {
      const fit = fits.get(shot.id);
      if (fit) return tileWidth / fit.height;
      return shot.aspect ?? measured.get(shot.id) ?? fallbackAspect;
    });
    return layout(aspects, size.width, columnWidth, size.gap);
  }, [shots, fits, tileWidth, measured, size, columnWidth]);

  const indexOf = useMemo(() => new Map(shots.map((shot, i) => [shot.id, i])), [shots]);
  const activeIndex = active === undefined ? undefined : indexOf.get(active);
  const tabbableIndex = activeIndex ?? 0;

  // 列幅が変わると全タイルの y が変わる。見ていたタイルが同じ高さに残るようスクロールを合わせる。
  // 列幅の直後に文字のタイルの測り直しでもう一度組み替わるので、同じ描画の間は合わせ続ける
  const previous = useRef<{ grid: Layout; shots: readonly ShotView[]; tileWidth: number }>(
    undefined,
  );
  const anchor = useRef<{ id: string; top: number }>(undefined);
  const wallTop = useRef(0);
  useLayoutEffect(() => {
    const before = previous.current;
    previous.current = { grid, shots, tileWidth };
    const element = container.current;
    if (!element) return;
    if (before && before.tileWidth > 0 && before.tileWidth !== tileWidth) {
      anchor.current = anchorOf(before, element, wallTop.current);
      queueMicrotask(() => {
        anchor.current = undefined;
      });
    }
    const target = anchor.current;
    const index = target && indexOf.get(target.id);
    if (!target || index === undefined) return;
    const now = element.getBoundingClientRect().top + grid.boxes[index].y;
    scrollerOf(element).scrollBy({ top: now - target.top, behavior: "instant" });
  }, [grid, shots, tileWidth, indexOf]);

  useLayoutEffect(() => {
    const element = container.current;
    if (!element) return;
    const measure = () => {
      const rect = element.getBoundingClientRect();
      wallTop.current = rect.top;
      const top = Math.floor(-rect.top / RANGE_STEP) * RANGE_STEP;
      const bottom = Math.ceil((window.innerHeight - rect.top) / RANGE_STEP) * RANGE_STEP;
      setRange((prev) => (prev.top === top && prev.bottom === bottom ? prev : { top, bottom }));
    };
    const resize = new ResizeObserver(([entry]) => {
      setSize({ width: entry.contentRect.width, gap: readGap(element) });
      measure();
    });
    resize.observe(element);
    let frame = 0;
    const onScroll = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(measure);
    };
    // 焦点表示の中の壁は Popup の中でスクロールする。どちらのスクロールも capture で拾う
    document.addEventListener("scroll", onScroll, { capture: true, passive: true });
    window.addEventListener("resize", onScroll);
    measure();
    return () => {
      resize.disconnect();
      cancelAnimationFrame(frame);
      document.removeEventListener("scroll", onScroll, { capture: true });
      window.removeEventListener("resize", onScroll);
    };
  }, []);

  /** 古い壁を写して上に重ねた。次の差し替えでは新しい壁をフェードインしない */
  const overlaid = useRef(false);
  useLayoutEffect(() => {
    const element = container.current;
    if (generation === 0 || !element) return;
    // 差し替えの後も同じ Shot のタイルは残る。その上のホバー再生は止める
    stopHoverPlaybackIn(element);
    // 重ねた古い壁が消えていく下では、新しい壁を初めから見せる。両方を同時に薄くすると、間で背景が透けてちらつく
    if (overlaid.current) {
      overlaid.current = false;
      return;
    }
    animateOnce(element, [{ opacity: 0 }, { opacity: 1 }], {
      duration: motion.fast,
      easing: motion.out,
    });
  }, [generation]);

  // live で足したタイルは最初に描くときだけフェードインする。仮想化で描き直すたびにはやり直さない
  const drawn = useRef(new Set<string>());
  useLayoutEffect(() => {
    drawn.current.clear();
  }, [generation]);

  const overscan = range.bottom - range.top;
  const shown = useMemo(() => {
    const indices = visible(grid, range.top - overscan, range.bottom + overscan);
    if (activeIndex !== undefined && !indices.includes(activeIndex)) indices.push(activeIndex);
    return indices;
  }, [grid, range, overscan, activeIndex]);

  useEffect(() => {
    for (const i of shown) if (fresh?.has(shots[i].id)) drawn.current.add(shots[i].id);
  }, [shown, shots, fresh]);

  useEffect(() => {
    if (onNearEnd && shots.length > 0 && range.bottom + overscan >= grid.height) onNearEnd();
  }, [onNearEnd, shots.length, range, overscan, grid.height]);

  // キーで移るたびに動かすと、押し続けたときに画面が焦点に追いつかない。スクロールは即座に済ませる
  const focusNow = (id: string) => {
    const element = elements.current.get(id);
    if (!element) return false;
    element.focus({ preventScroll: true });
    element.scrollIntoView({ block: "nearest", behavior: "instant" });
    return true;
  };

  useLayoutEffect(() => {
    const id = pendingFocus.current;
    if (id !== undefined && focusNow(id)) pendingFocus.current = undefined;
  });

  useImperativeHandle(ref, () => ({
    snapshot() {
      const element = container.current;
      if (!element || element.childElementCount === 0) return;
      const rect = element.getBoundingClientRect();
      // 待ちの間に薄くした壁は、その濃さから消していく
      const opacity = Number(getComputedStyle(element).opacity);
      const clone = element.cloneNode(true) as HTMLElement;
      // 写した <video> も src を持って読み込みを始めるので、元と同じ手順で放す
      for (const video of clone.querySelectorAll("video")) {
        releaseVideo(video);
        video.remove();
      }
      for (const tile of clone.querySelectorAll("[data-fresh]")) tile.removeAttribute("data-fresh");
      // 写した画像は描き直しになる。復号を待たずに空のまま描くと、消えていく側が先に抜けて見える
      for (const image of clone.querySelectorAll("img")) image.decoding = "sync";
      clone.removeAttribute("data-stale");
      clone.inert = true;
      clone.setAttribute("aria-hidden", "true");
      Object.assign(clone.style, {
        position: "fixed",
        top: `${rect.top}px`,
        left: `${rect.left}px`,
        width: `${rect.width}px`,
        height: `${rect.height}px`,
        pointerEvents: "none",
      });
      document.body.append(clone);
      overlaid.current = true;
      animateOnce(clone, [{ opacity }, { opacity: 0 }], {
        duration: motion.fast,
        easing: motion.out,
      }).finished.then(() => clone.remove());
    },
    focus(id) {
      if (!indexOf.has(id)) return false;
      if (!focusNow(id)) pendingFocus.current = id;
      setActive(id);
      return true;
    },
    element: (id) => elements.current.get(id),
  }));

  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    const direction = arrows[event.key];
    const shot = shotAt(event.target as Element);
    if (!direction || !shot || event.metaKey || event.altKey || event.ctrlKey) return;
    const index = indexOf.get(shot.id);
    if (index === undefined) return;
    event.preventDefault();
    event.stopPropagation();
    const next = neighbor(grid, index, direction);
    if (next === undefined) {
      if (direction === "up") onExitTop?.();
      return;
    }
    const id = shots[next].id;
    if (!focusNow(id)) pendingFocus.current = id;
    setActive(id);
  };

  // 読み込んだ画像の縦横比は 1 フレームぶんまとめて反映し、組み替えを 1 回で済ませる
  const aspects = useRef(new Map<string, number>());
  const aspectFrame = useRef(0);
  const onAspect = useCallback((id: string, aspect: number) => {
    aspects.current.set(id, aspect);
    if (aspectFrame.current !== 0) return;
    aspectFrame.current = requestAnimationFrame(() => {
      aspectFrame.current = 0;
      const batch = aspects.current;
      aspects.current = new Map();
      setMeasured((prev) => new Map([...prev, ...batch]));
    });
  }, []);
  useEffect(() => () => cancelAnimationFrame(aspectFrame.current), []);

  const onElement = useCallback((id: string, element: HTMLElement | null) => {
    if (element) elements.current.set(id, element);
    else elements.current.delete(id);
  }, []);

  return (
    <>
      <span ref={sample} aria-hidden className={styles.sample} style={{ width: tileWidth }}>
        <TextFace
          selected={false}
          title="M"
          text="M"
          lines={{ title: 1, body: 1 }}
          source={undefined}
          sourceId="M"
        />
      </span>
      <div
        ref={container}
        className={styles.wall}
        data-stale={stale ? "" : undefined}
        style={{ height: grid.height }}
        onKeyDown={onKeyDown}
        onFocus={(event) => {
          const shot = shotAt(event.target);
          if (shot) setActive(shot.id);
        }}
      >
        {size.width > 0 && metrics
          ? shown.map((i) => {
              const shot = shots[i];
              return (
                <Tile
                  key={shot.id}
                  shot={shot}
                  box={grid.boxes[i]}
                  lines={fits.get(shot.id)?.lines}
                  source={sources.get(shot.source)}
                  selected={selected.has(shot.id)}
                  fresh={(fresh?.has(shot.id) ?? false) && !drawn.current.has(shot.id)}
                  tabbable={i === tabbableIndex}
                  reducedMotion={reducedMotion}
                  onOpen={onOpen}
                  onToggle={onToggle}
                  onDragOut={onDragOut}
                  onAspect={onAspect}
                  onElement={onElement}
                />
              );
            })
          : null}
      </div>
    </>
  );
}
