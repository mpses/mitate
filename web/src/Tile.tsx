import {
  memo,
  useCallback,
  useEffect,
  useRef,
  useState,
  type MouseEvent,
  type PointerEvent,
  type Ref,
} from "react";

import { Icon, Skeleton } from "@bakutan-org/ui";
import { css, cva, cx } from "@bakutan-org/ui/styled-system/css";

import type { ShotView, SourceStatus } from "./api";
import type { Box } from "./masonry";
import { canDragOut } from "./drag";
import { SourceIcon } from "./SourceIcon";
import type { TextLines } from "./textFit";
import { claimHoverPlayback, endHoverPlayback, useVideoSource } from "./video";

/** ホバーしてから動画を再生し始めるまでの待ち。通り過ぎただけのタイルを動かさない */
const HOVER_DWELL_MS = 120;

/** 壁に並べる画像。動画は poster、画像は手元のサムネイル */
export const stillOf = (shot: ShotView): string | undefined =>
  shot.thumb ?? (shot.kind === "video" ? shot.media?.poster : shot.media?.src);

const shots = new WeakMap<Element, ShotView>();

/** 要素に Shot を載せる。載せた要素には data-shot-id も付ける */
export const registerShot = (element: Element, shot: ShotView) => shots.set(element, shot);

/** 焦点のある要素が載せている Shot。キー操作の対象を DOM から引く */
export const shotAt = (element: Element | null): ShotView | undefined => {
  const tile = element?.closest("[data-shot-id]");
  return tile ? shots.get(tile) : undefined;
};

export interface TileProps {
  shot: ShotView;
  box: Box;
  /** 文字のタイルの行数。列幅から測った値で、タイルの高さと合わせてある */
  lines: TextLines | undefined;
  source: SourceStatus | undefined;
  selected: boolean;
  /** live で足したばかりで、まだ一度も描いていない。描き始めにフェードインする */
  fresh: boolean;
  tabbable: boolean;
  reducedMotion: boolean;
  onOpen: (shot: ShotView, from: DOMRect) => void;
  onToggle: (shot: ShotView) => void;
  /** タイルをほかのアプリへドラッグし始めた */
  onDragOut: (shot: ShotView, event: DragEvent) => void;
  onAspect: (id: string, aspect: number) => void;
  onElement: (id: string, element: HTMLElement | null) => void;
}

const styles = {
  tile: css({
    borderRadius: "md",
    cursor: "pointer",
    insetBlockStart: "0",
    insetInlineStart: "0",
    isolation: "isolate",
    position: "absolute",
    scrollMarginBlockEnd: "96px",
    scrollMarginBlockStart: "96px",
    textAlign: "start",
    _focusVisible: { outline: "2px solid", outlineColor: "focus.default", outlineOffset: "2px" },
    "&[data-fresh]": {
      transitionDuration: "normal",
      transitionProperty: "opacity",
      transitionTimingFunction: "out",
      _starting: { opacity: 0 },
    },
    // ほぼ同じ画像をまとめたタイルは、下に紙が 1 枚重なっているように端を覗かせる
    "&[data-duplicates]::before": {
      bg: "border.default",
      borderRadius: "md",
      content: '""',
      insetBlockEnd: "-1",
      insetBlockStart: "1",
      insetInline: "2",
      position: "absolute",
      zIndex: -1,
    },
  }),
  face: cva({
    base: {
      bg: "bg.subtle",
      borderRadius: "md",
      display: "block",
      h: "full",
      overflow: "hidden",
      position: "relative",
      w: "full",
    },
    variants: {
      text: {
        true: {
          bg: "surface.subtle",
          display: "flex",
          flexDirection: "column",
          gap: "1",
          h: "auto",
          minH: "full",
          p: "3",
        },
        // 白地の画像でも壁の白と見分けられるよう、画像の上に内側の細い線を重ねる
        false: {
          "&::after": {
            borderRadius: "md",
            boxShadow: "inset 0 0 0 token(borderWidths.normal) token(colors.border.subtle)",
            content: '""',
            inset: "0",
            pointerEvents: "none",
            position: "absolute",
          },
        },
      },
    },
  }),
  skeleton: css({ h: "full", inset: "0", position: "absolute" }),
  media: css({
    display: "block",
    h: "full",
    inset: "0",
    objectFit: "cover",
    opacity: 0,
    position: "absolute",
    transitionDuration: "fast",
    transitionProperty: "opacity",
    transitionTimingFunction: "out",
    w: "full",
    "&[data-shown]": { opacity: 1 },
    // 読み込み済みの画像を描き直したときは、フェードをやり直さない
    "&[data-instant]": { transitionDuration: "0s" },
  }),
  broken: css({
    alignItems: "center",
    color: "text.disabled",
    display: "flex",
    inset: "0",
    justifyContent: "center",
    position: "absolute",
  }),
  title: cva({
    base: {
      color: "text.strong",
      overflowWrap: "anywhere",
      textStyle: "type.sm.bold",
    },
    variants: { lines: { 1: { lineClamp: 1 }, 2: { lineClamp: 2 } } },
  }),
  body: cva({
    base: { color: "text.subtle", overflowWrap: "anywhere", textStyle: "type.xs.normal" },
    variants: {
      lines: { 1: { lineClamp: 1 }, 2: { lineClamp: 2 }, 3: { lineClamp: 3 }, 4: { lineClamp: 4 } },
    },
  }),
  textIcon: css({
    alignItems: "center",
    display: "flex",
    justifyContent: "space-between",
    mt: "auto",
    pt: "1",
  }),
  // メディアのタイルのサイトのアイコンは、ホバーと焦点のときだけ左下に出す
  badge: css({
    display: "flex",
    insetBlockEnd: "2",
    insetInlineStart: "2",
    opacity: 0,
    position: "absolute",
    transitionDuration: "fast",
    transitionProperty: "opacity",
    transitionTimingFunction: "out",
    "[data-shot-id]:is(:hover, :focus-visible) &": { opacity: 1 },
  }),
  selected: css({
    alignItems: "center",
    // ui の Checkbox が選んだ状態で使う配色にそろえる
    bg: "brand.primary",
    borderRadius: "full",
    color: "bg.default",
    display: "flex",
    h: "icon.md",
    justifyContent: "center",
    w: "icon.md",
  }),
  // メディアのタイルでは選んだ印を右上に重ねる。文字のタイルでは行を削らないよう、アイコンの行の右端に置く
  corner: css({ insetBlockStart: "2", insetInlineEnd: "2", position: "absolute" }),
};

export interface TextFaceProps {
  ref?: Ref<HTMLSpanElement>;
  selected: boolean;
  title: string | undefined;
  text: string;
  lines: TextLines;
  source: SourceStatus | undefined;
  sourceId: string;
}

function SelectedMark({ className }: { className?: string }) {
  return (
    <span aria-hidden className={cx(styles.selected, className)}>
      <Icon name="check" size="xs" />
    </span>
  );
}

/** 文字のタイルの中身。タイトルと本文の冒頭、左下にサイトのアイコン */
export function TextFace({ ref, selected, title, text, lines, source, sourceId }: TextFaceProps) {
  return (
    <span ref={ref} className={styles.face({ text: true })}>
      {title ? (
        <span className={styles.title({ lines: lines.title || 1 })} data-part="title">
          {title}
        </span>
      ) : null}
      <span className={styles.body({ lines: lines.body })} data-part="body">
        {text}
      </span>
      <span className={styles.textIcon}>
        <SourceIcon id={sourceId} source={source} />
        {selected ? <SelectedMark /> : null}
      </span>
    </span>
  );
}

/** 一度読み終えた画像の URL。描き直したタイルではキャッシュから出るので、Skeleton とフェードを挟まない */
const loadedStills = new Set<string>();
/** 覚えておく URL の数。WebKit のメモリキャッシュが持てる枚数より古いものは、どのみち読み直しになる */
const LOADED_STILLS_LIMIT = 2000;

function rememberLoaded(src: string) {
  loadedStills.delete(src);
  loadedStills.add(src);
  if (loadedStills.size > LOADED_STILLS_LIMIT) {
    // Set は足した順に並ぶので、先頭がいちばん前に読んだ URL
    const [oldest] = loadedStills;
    loadedStills.delete(oldest);
  }
}

function Still({ shot, onAspect }: Pick<TileProps, "shot" | "onAspect">) {
  const src = stillOf(shot);
  // 仮想化で描き直したタイルの画像は、すでに読み終えていることが多い。最初の描画から出しておく
  const [seen] = useState(() => src !== undefined && loadedStills.has(src));
  const [state, setState] = useState<"loading" | "shown" | "broken">(seen ? "shown" : "loading");

  if (!src || state === "broken") {
    return (
      <span className={styles.broken}>
        <Icon name="photo-off" size="lg" />
      </span>
    );
  }
  return (
    <>
      {state === "loading" ? <Skeleton type="block" className={styles.skeleton} /> : null}
      <img
        alt=""
        className={styles.media}
        data-shown={state === "shown" ? "" : undefined}
        data-instant={seen ? "" : undefined}
        decoding="async"
        draggable={false}
        src={src}
        onError={() => setState("broken")}
        onLoad={(event) => {
          rememberLoaded(src);
          const { naturalWidth, naturalHeight } = event.currentTarget;
          if (shot.aspect === undefined && naturalHeight > 0) {
            onAspect(shot.id, naturalWidth / naturalHeight);
          }
          setState("shown");
        }}
      />
    </>
  );
}

/**
 * ホバーして少し留まったら muted で再生し、離れたら要素ごと外して資源を放す。
 * 再生するタイルは壁全体で 1 つまで。ほかのタイルが再生を始めたら、このタイルは止まる
 */
function useHoverPlayback(enabled: boolean) {
  const timer = useRef<number>(undefined);
  const [armed, setArmed] = useState(false);
  /** 最初のフレームが届いた。それまでは poster を見せ続ける */
  const [rolling, setRolling] = useState(false);

  const stop = useCallback(() => {
    window.clearTimeout(timer.current);
    setArmed(false);
    setRolling(false);
  }, []);

  // 描く範囲から外れたタイルは、動画ごと外れる。待っている再生も取り消す
  useEffect(
    () => () => {
      window.clearTimeout(timer.current);
      endHoverPlayback(stop);
    },
    [stop],
  );

  return {
    armed,
    rolling,
    onPlaying: () => setRolling(true),
    enter: (event: PointerEvent<HTMLElement>) => {
      if (!enabled) return;
      const tile = event.currentTarget;
      window.clearTimeout(timer.current);
      timer.current = window.setTimeout(() => {
        claimHoverPlayback(tile, stop);
        setArmed(true);
      }, HOVER_DWELL_MS);
    },
    leave: () => {
      endHoverPlayback(stop);
      stop();
    },
  };
}

/** ホバー再生の動画。この要素がある間だけ src を持ち、外れるときに資源を放す */
function HoverVideo({
  src,
  rolling,
  onPlaying,
}: {
  src: string;
  rolling: boolean;
  onPlaying: () => void;
}) {
  const source = useVideoSource(src);
  return (
    <video
      ref={source}
      className={styles.media}
      data-shown={rolling ? "" : undefined}
      autoPlay
      loop
      muted
      playsInline
      onPlaying={onPlaying}
    />
  );
}

function textLines(shot: ShotView, lines: TextLines | undefined): TextLines {
  if (!lines) throw new Error(`文字のタイルの行数を測っていない: ${shot.id}`);
  return lines;
}

export const Tile = memo(function Tile({
  shot,
  box,
  lines,
  source,
  selected,
  fresh,
  tabbable,
  reducedMotion,
  onOpen,
  onToggle,
  onDragOut,
  onAspect,
  onElement,
}: TileProps) {
  const playback = useHoverPlayback(shot.kind === "video" && !reducedMotion);
  const text = shot.kind === "text";
  // フェードインは描き始めの 1 回だけ。描いている間に印を外すと動きが途中で切れる
  const [entering] = useState(fresh);

  const click = (event: MouseEvent<HTMLButtonElement>) => {
    if (event.shiftKey) onToggle(shot);
    else onOpen(shot, event.currentTarget.getBoundingClientRect());
  };

  return (
    <button
      ref={(element) => {
        if (element) registerShot(element, shot);
        onElement(shot.id, element);
      }}
      type="button"
      aria-label={shot.title ?? source?.name ?? shot.source}
      className={styles.tile}
      data-shot-id={shot.id}
      data-fresh={entering ? "" : undefined}
      data-duplicates={shot.duplicates >= 2 ? "" : undefined}
      data-selected={selected ? "" : undefined}
      tabIndex={tabbable ? 0 : -1}
      draggable={canDragOut()}
      style={{ transform: `translate(${box.x}px, ${box.y}px)`, width: box.w, height: box.h }}
      onClick={click}
      onDragStart={(event) => onDragOut(shot, event.nativeEvent)}
      onPointerEnter={playback.enter}
      onPointerLeave={playback.leave}
    >
      {text ? (
        <TextFace
          selected={selected}
          title={shot.title}
          text={shot.text ?? ""}
          lines={textLines(shot, lines)}
          source={source}
          sourceId={shot.source}
        />
      ) : (
        <span className={styles.face({ text: false })}>
          <Still shot={shot} onAspect={onAspect} />
          {playback.armed && shot.media ? (
            <HoverVideo
              src={shot.media.src}
              rolling={playback.rolling}
              onPlaying={playback.onPlaying}
            />
          ) : null}
        </span>
      )}
      {text ? null : (
        <span className={styles.badge}>
          <SourceIcon id={shot.source} source={source} />
        </span>
      )}
      {selected && !text ? <SelectedMark className={styles.corner} /> : null}
    </button>
  );
});
