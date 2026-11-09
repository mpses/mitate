import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type PointerEvent,
  type ReactNode,
  type RefObject,
} from "react";

import { Dialog } from "@base-ui/react/dialog";
import { Icon, IconButton } from "@bakutan-org/ui";
import { css, cva } from "@bakutan-org/ui/styled-system/css";

import { getShot, openInBrowser, similar, type ShotView, type SourceStatus } from "./api";
import { canDragOut } from "./drag";
import { ShotWall } from "./ShotWall";
import {
  animateOnce,
  fallbackAspect,
  motion,
  releaseOwnTransitions,
  useReducedMotion,
} from "./motion";
import { SourceIcon } from "./SourceIcon";
import { useStableCallback } from "./stable";
import { stillOf } from "./Tile";
import { playVideo, useVideoSource } from "./video";

export interface LightboxTarget {
  shot: ShotView;
  /** 開いたタイルの位置。ここから広がる */
  from?: DOMRect;
}

export interface LightboxProps {
  target: LightboxTarget | undefined;
  scope: string | undefined;
  columnWidth: number;
  sources: ReadonlyMap<string, SourceStatus>;
  selected: ReadonlySet<string>;
  /** 窓の下端に重ねる選択の列。焦点表示の間は焦点が外へ出られないので、中に描く */
  tray: ReactNode;
  trayShown: boolean;
  onClose: () => void;
  /** 閉じ終えた。元のタイルへ焦点を戻す */
  onClosed: () => void;
  onOpenSimilar: (shots: readonly ShotView[], index: number, from: DOMRect) => void;
  onToggle: (shot: ShotView) => void;
  onDragOut: (shot: ShotView, event: DragEvent) => void;
}

const styles = {
  // scrim は Popup 自身の背景にする。Base UI は Popup の transition を待って閉じ終えるので、
  // 中身のフェードもこの transition と同じ長さにそろえる。
  // 選択の列はシートの縁より上に置き、下へ続きがあるという合図を隠さない
  popup: css({
    "--tray-bottom": "calc(token(spacing.6) + token(spacing.4))",
    bg: "overlay.scrim/50",
    inset: "0",
    outline: "none",
    overflowY: "auto",
    overscrollBehavior: "contain",
    position: "fixed",
    zIndex: 30,
    transitionDuration: "normal",
    transitionProperty: "background-color",
    transitionTimingFunction: "out",
    "&[data-starting-style], &[data-ending-style]": { bg: "transparent" },
    // WebKit は、スクロールする箱の中身が小さい間に描いた面を、中身が伸びたときに放さない。中身の高さが決まるまでスクロールさせない
    "&[data-pending]": { overflowY: "hidden" },
  }),
  // 説明の行とシートは scrim と一緒に現れて消える。選択の列は開閉の前後で同じ位置に残るので含めない
  fade: css({
    transitionDuration: "normal",
    transitionProperty: "opacity",
    transitionTimingFunction: "out",
    "[data-starting-style] &, [data-ending-style] &": { opacity: 0 },
  }),
  // 画像は開いたタイルから広がって現れるので、消すのは閉じるときだけ
  fadeOut: css({
    transitionDuration: "normal",
    transitionProperty: "opacity",
    transitionTimingFunction: "out",
    "[data-ending-style] &": { opacity: 0 },
  }),
  // 窓の上端 28px はネイティブ側のドラッグ領域。下端はシートの縁を覗かせ、下へ続きがあると分かるようにする
  stage: cva({
    base: {
      alignItems: "center",
      boxSizing: "border-box",
      display: "flex",
      flexDirection: "column",
      gap: "3",
      h: "calc(100dvh - token(spacing.6))",
      pt: "calc(28px + token(spacing.4))",
      px: "12",
    },
    // 選択の列（窓の下端から spacing.6 + spacing.4 の位置、高さ 56px）の上端は、stage の下端から 72px 上。そこから spacing.6 空ける
    variants: { tray: { true: { pb: "24" }, false: { pb: "6" } } },
  }),
  view: css({
    alignItems: "center",
    containerType: "size",
    display: "flex",
    flex: "1",
    justifyContent: "center",
    minH: "0",
    w: "full",
  }),
  frame: css({
    borderRadius: "md",
    flexShrink: 0,
    overflow: "hidden",
    position: "relative",
  }),
  // 動画の操作は動画に影を重ねず、ホバーの間と止まっている間だけ、左上の再生、下端の線、右上の消音を出す
  controls: css({
    opacity: 0,
    transitionDuration: "fast",
    transitionProperty: "opacity",
    transitionTimingFunction: "out",
    "&[data-scrubbing], &[data-paused]": { opacity: 1 },
    "[data-video]:hover &": { opacity: 1 },
    _focusWithin: { opacity: 1 },
  }),
  // 押せる範囲は線より高くとり、細い線でも狙わずに送れるようにする
  scrub: css({
    alignItems: "flex-end",
    cursor: "pointer",
    display: "flex",
    h: "8",
    insetBlockEnd: "0",
    insetInline: "0",
    pb: "3",
    position: "absolute",
    px: "3",
  }),
  track: css({
    bg: "surface.default",
    borderRadius: "full",
    boxShadow: "overlay",
    h: "1",
    overflow: "hidden",
    w: "full",
    // スライダーは見えないので、焦点の輪は線に描く
    "[data-position]:focus-visible + * &": {
      outline: "2px solid",
      outlineColor: "focus.default",
      outlineOffset: "2px",
    },
  }),
  fill: css({
    bg: "text.strong",
    display: "block",
    h: "full",
    transform: "scaleX(var(--progress, 0))",
    transformOrigin: "left",
  }),
  position: css({ srOnly: true }),
  toggle: css({ insetBlockStart: "3", insetInlineStart: "3", position: "absolute" }),
  sound: css({ insetBlockStart: "3", insetInlineEnd: "3", position: "absolute" }),
  media: css({
    display: "block",
    h: "full",
    inset: "0",
    objectFit: "contain",
    position: "absolute",
    w: "full",
  }),
  full: css({
    opacity: 0,
    transitionDuration: "fast",
    transitionProperty: "opacity",
    transitionTimingFunction: "out",
    "&[data-shown]": { opacity: 1 },
  }),
  card: css({
    bg: "surface.default",
    borderRadius: "lg",
    display: "flex",
    flexDirection: "column",
    gap: "3",
    maxH: "full",
    maxW: "prose",
    overflowY: "auto",
    p: "8",
    w: "full",
    // 本文の全文が届くまではスクロールさせない（popup と同じ理由）
    "&[data-pending]": { overflowY: "hidden" },
  }),
  cardTitle: css({
    color: "text.strong",
    textStyle: "heading.3",
    "& a": { color: "inherit", textDecoration: "none", _hover: { textDecoration: "underline" } },
    "& a:focus-visible": {
      borderRadius: "xs",
      outline: "2px solid",
      outlineColor: "focus.default",
      outlineOffset: "2px",
    },
  }),
  cardText: css({ color: "text.default", textStyle: "type.base.normal", whiteSpace: "pre-wrap" }),
  sheet: css({
    bg: "surface.default",
    borderTopRadius: "lg",
    minH: "100dvh",
    pb: "24",
    pt: "4",
    px: "4",
  }),
  // 暗い scrim の上でも読めるよう、1 行の説明は面に載せる。外形 36px の中に 24px のアイコンを同心に置く
  caption: cva({
    base: {
      alignItems: "center",
      bg: "surface.default",
      borderRadius: "full",
      display: "flex",
      flexShrink: 0,
      gap: "2",
      h: "36px",
      maxW: "full",
      minW: "0",
      ps: "1-5",
    },
    // アイコンだけのときは左右の余白をそろえて円にする
    variants: { iconOnly: { true: { pe: "1-5" }, false: { pe: "4" } } },
  }),
  title: css({
    color: "text.strong",
    minW: "0",
    overflow: "hidden",
    textOverflow: "ellipsis",
    textStyle: "type.sm.bold",
    whiteSpace: "nowrap",
    "& a": { color: "inherit", textDecoration: "none", _hover: { textDecoration: "underline" } },
    "& a:focus-visible": {
      borderRadius: "xs",
      outline: "2px solid",
      outlineColor: "focus.default",
      outlineOffset: "2px",
    },
  }),
  // タイトルと並ぶときは、長い作者名がタイトルを押し出さないよう幅を抑える
  author: cva({
    base: {
      color: "text.subtle",
      flexShrink: 0,
      overflow: "hidden",
      textOverflow: "ellipsis",
      textStyle: "type.sm.normal",
      whiteSpace: "nowrap",
    },
    variants: { besideTitle: { true: { maxW: "40%" }, false: {} } },
  }),
  close: css({
    insetBlockStart: "calc(28px + token(spacing.2))",
    insetInlineEnd: "3",
    position: "fixed",
    // マウスでは窓の外側を押せば閉じる。キーボードで辿ったときだけ見せる
    "&:not(:focus-within)": { clipPath: "inset(50%)", opacity: 0 },
  }),
};

/** 見出しのリンク。既定のブラウザで開く */
function ShotLink({ shot, label }: { shot: ShotView; label: string }) {
  return (
    <a
      href={shot.url}
      onClick={(event) => {
        event.preventDefault();
        void openInBrowser(shot.url);
      }}
    >
      {label}
    </a>
  );
}

const hasAudio = (video: HTMLVideoElement) =>
  ((video as HTMLVideoElement & { audioTracks?: { length: number } }).audioTracks?.length ?? 0) > 0;

/**
 * 焦点表示の動画。WebKit の標準の操作はホバーで動画を暗くするので使わない。押すと止まり、もう一度押すと動く。
 * キーボードと支援技術には、再生と一時停止のボタンと、再生位置のスライダーで同じ操作を渡す。
 * 次の Shot へ移るときと閉じ終えたときに外れ、そこで資源を放す
 */
function FullVideo({
  src,
  poster,
  autoPlay,
  muted,
  onMutedChange,
}: {
  src: string;
  poster: string | undefined;
  autoPlay: boolean;
  muted: boolean;
  onMutedChange: (muted: boolean) => void;
}) {
  const source = useVideoSource(src);
  const video = useRef<HTMLVideoElement>(null);
  const track = useRef<HTMLSpanElement>(null);
  const position = useRef<HTMLInputElement>(null);
  const [hovering, setHovering] = useState(false);
  const [focused, setFocused] = useState(false);
  const [scrubbing, setScrubbing] = useState(false);
  // 自動再生する動画は、最初のフレームが届く前から動いているものとして扱う
  const [paused, setPaused] = useState(!autoPlay);
  const resume = useRef(false);
  // 最初のフレームが届くまでは、下に敷いた静止画を見せる（タイルのホバー再生と同じ）
  const [rolling, setRolling] = useState(false);
  const [audible, setAudible] = useState(false);
  const [duration, setDuration] = useState(0);

  const attach = useCallback(
    (element: HTMLVideoElement) => {
      video.current = element;
      const release = source(element);
      return () => {
        video.current = null;
        if (typeof release === "function") release();
      };
    },
    [source],
  );

  /** 線と再生位置のスライダーを、動画の今の位置に合わせる */
  const showPosition = useCallback(() => {
    const element = video.current;
    if (!element || !(element.duration > 0)) return;
    track.current?.style.setProperty("--progress", String(element.currentTime / element.duration));
    if (position.current) position.current.value = String(element.currentTime);
  }, []);

  // 線は見えている間だけ書く。動いている間は毎フレーム（timeupdate は 4Hz ほどで、線が飛んで見える）、止まっている間は 1 度と送ったときだけ
  const shown = hovering || focused || scrubbing || paused;
  useEffect(() => {
    if (!shown) return;
    let frame = 0;
    const tick = () => {
      showPosition();
      if (!paused) frame = requestAnimationFrame(tick);
    };
    tick();
    return () => cancelAnimationFrame(frame);
  }, [shown, paused, showPosition]);

  const toggle = () => {
    const element = video.current;
    if (!element) return;
    if (element.paused) void playVideo(element);
    else element.pause();
  };

  const seek = (event: PointerEvent<HTMLElement>) => {
    const element = video.current;
    const line = track.current;
    if (!element || !line || !(element.duration > 0)) return;
    const rect = line.getBoundingClientRect();
    const ratio = Math.min(1, Math.max(0, (event.clientX - rect.left) / rect.width));
    element.currentTime = ratio * element.duration;
    showPosition();
  };

  return (
    <>
      <video
        ref={attach}
        className={`${styles.media} ${styles.full}`}
        data-shown={rolling ? "" : undefined}
        autoPlay={autoPlay}
        loop
        muted={muted}
        playsInline
        poster={poster}
        preload="metadata"
        onClick={toggle}
        onLoadedMetadata={(event) => {
          setAudible(hasAudio(event.currentTarget));
          setDuration(event.currentTarget.duration);
        }}
        onPlay={() => setPaused(false)}
        onPause={() => setPaused(true)}
        onPlaying={() => setRolling(true)}
        onSeeked={() => setRolling(true)}
        onPointerEnter={() => setHovering(true)}
        onPointerLeave={() => setHovering(false)}
      />
      <span
        className={styles.controls}
        data-paused={paused ? "" : undefined}
        data-scrubbing={scrubbing ? "" : undefined}
        onPointerEnter={() => setHovering(true)}
        onPointerLeave={() => setHovering(false)}
        onFocus={() => setFocused(true)}
        onBlur={(event) =>
          setFocused(
            event.relatedTarget instanceof Node &&
              event.currentTarget.contains(event.relatedTarget),
          )
        }
      >
        <span className={styles.toggle}>
          <IconButton
            aria-label={paused ? "再生" : "一時停止"}
            variant="secondary"
            size="small"
            onClick={toggle}
          >
            <Icon name={paused ? "player-play" : "player-pause"} size="sm" />
          </IconButton>
        </span>
        {/* 線はポインターで送り、キーボードと支援技術はこのスライダーで送る。見た目は線が受け持つ */}
        <input
          ref={position}
          type="range"
          className={styles.position}
          data-position=""
          aria-label="再生位置"
          min={0}
          max={duration}
          step={1}
          defaultValue={0}
          onChange={(event) => {
            const element = video.current;
            if (!element) return;
            element.currentTime = event.currentTarget.valueAsNumber;
            showPosition();
          }}
        />
        <span
          aria-hidden
          className={styles.scrub}
          onPointerDown={(event) => {
            const element = video.current;
            if (!element) return;
            event.currentTarget.setPointerCapture(event.pointerId);
            resume.current = !element.paused;
            element.pause();
            setScrubbing(true);
            seek(event);
          }}
          onPointerMove={(event) => {
            if (event.currentTarget.hasPointerCapture(event.pointerId)) seek(event);
          }}
          onLostPointerCapture={() => {
            setScrubbing(false);
            if (resume.current && video.current) void playVideo(video.current);
          }}
        >
          <span ref={track} className={styles.track}>
            <span className={styles.fill} />
          </span>
        </span>
        {audible ? (
          <span className={styles.sound}>
            <IconButton
              aria-label={muted ? "音を出す" : "消音"}
              variant="secondary"
              size="small"
              onClick={() => onMutedChange(!muted)}
            >
              <Icon name={muted ? "volume-off" : "volume"} size="sm" />
            </IconButton>
          </span>
        ) : null}
      </span>
    </>
  );
}

function Media({
  shot,
  label,
  from,
  popup,
  reducedMotion,
  muted,
  onMutedChange,
  onDragOut,
}: {
  shot: ShotView;
  label: string;
  from: DOMRect | undefined;
  /** スクロールする Popup。新しい Shot はその先頭から見せる */
  popup: RefObject<HTMLDivElement | null>;
  reducedMotion: boolean;
  muted: boolean;
  onMutedChange: (muted: boolean) => void;
  onDragOut: (shot: ShotView, event: DragEvent) => void;
}) {
  const frame = useRef<HTMLDivElement>(null);
  const [aspect, setAspect] = useState(
    () => shot.aspect ?? (from && from.height > 0 ? from.width / from.height : fallbackAspect),
  );
  const [loaded, setLoaded] = useState(false);
  const still = stillOf(shot);

  // メディアは開いたタイルの位置から、窓に収まる最大の大きさへ広げる。縦横で倍率を変えると中身が歪むので一様に縮める。
  // 文字のカードはタイルと縦横比が大きく違い、広げると字が潰れて見えるので、その場で少しだけ拡大して現れる。
  // 終点は Popup を先頭へ戻してから測る。親の effect は子より後に走るので、親で戻すとスクロールした分だけ起点がずれる
  useLayoutEffect(() => {
    popup.current?.scrollTo({ top: 0 });
    const element = frame.current;
    if (!element || !from) return;
    let keyframes: Keyframe[];
    if (reducedMotion) {
      keyframes = [{ opacity: 0 }, { opacity: 1 }];
    } else if (shot.kind === "text") {
      keyframes = [
        { opacity: 0, transform: "scale(0.96)" },
        { opacity: 1, transform: "none" },
      ];
    } else {
      const to = element.getBoundingClientRect();
      const scale = Math.min(from.width / to.width, from.height / to.height);
      const dx = from.left + from.width / 2 - (to.left + to.width / 2);
      const dy = from.top + from.height / 2 - (to.top + to.height / 2);
      keyframes = [
        { transform: `translate(${dx}px, ${dy}px) scale(${scale})` },
        { transform: "none" },
      ];
    }
    animateOnce(element, keyframes, { duration: motion.normal, easing: motion.out });
  }, [popup, from, reducedMotion, shot.kind]);

  if (shot.kind === "text") return <TextCard shot={shot} label={label} frame={frame} />;
  return (
    <div
      ref={frame}
      className={styles.frame}
      data-video={shot.kind === "video" ? "" : undefined}
      draggable={canDragOut()}
      style={{ aspectRatio: aspect, width: `min(100cqw, 100cqh * ${aspect})` }}
      onDragStart={(event) => {
        // 動画の線を送っている間は、枠ごとのドラッグにしない
        if (event.currentTarget.querySelector("[data-scrubbing]")) {
          event.preventDefault();
          return;
        }
        onDragOut(shot, event.nativeEvent);
      }}
    >
      {/* 広がり始めのフレームから見えるよう、復号を待ってから描く */}
      {still ? (
        <img alt="" className={styles.media} decoding="sync" draggable={false} src={still} />
      ) : null}
      {shot.kind === "video" && shot.media ? (
        <FullVideo
          src={shot.media.src}
          poster={still}
          autoPlay={!reducedMotion}
          muted={muted}
          onMutedChange={onMutedChange}
        />
      ) : shot.media ? (
        <img
          alt={shot.title ?? ""}
          className={`${styles.media} ${styles.full}`}
          data-shown={loaded ? "" : undefined}
          draggable={false}
          src={shot.media.src}
          onLoad={(event) => {
            const { naturalWidth, naturalHeight } = event.currentTarget;
            if (naturalHeight > 0) setAspect(naturalWidth / naturalHeight);
            setLoaded(true);
          }}
        />
      ) : null}
    </div>
  );
}

/** 文字の Shot は見出しがタイトルを持つ。下の説明の行には繰り返さない */
function TextCard({
  shot,
  label,
  frame,
}: {
  shot: ShotView;
  label: string;
  frame: RefObject<HTMLDivElement | null>;
}) {
  const [full, setFull] = useState<ShotView>();
  useEffect(() => {
    const controller = new AbortController();
    getShot(shot.id, controller.signal)
      .then(setFull)
      .catch((error: unknown) => {
        if (!controller.signal.aborted) throw error;
      });
    return () => controller.abort();
  }, [shot.id]);
  return (
    <div ref={frame} className={styles.card} data-pending={full ? undefined : ""}>
      <Dialog.Title className={styles.cardTitle}>
        <ShotLink shot={shot} label={label} />
      </Dialog.Title>
      <p className={styles.cardText}>{full ? full.text : shot.text}</p>
    </div>
  );
}

/** その Shot に近いもの。届くまでは undefined */
function useSimilar(
  id: string | undefined,
  scope: string | undefined,
): readonly ShotView[] | undefined {
  const [result, setResult] = useState<{ id: string; shots: readonly ShotView[] }>();
  useEffect(() => {
    if (id === undefined) return;
    const controller = new AbortController();
    similar({ id }, { sources: scope, signal: controller.signal })
      .then((shots) => setResult({ id, shots }))
      .catch((error: unknown) => {
        if (!controller.signal.aborted) throw error;
      });
    return () => controller.abort();
  }, [id, scope]);
  return result && result.id === id ? result.shots : undefined;
}

const noShots: readonly ShotView[] = [];

/** タイルを大きく見せ、その下に近いものの壁を続ける。開閉と焦点の閉じ込めは Base UI の Dialog が持つ */
export function Lightbox({
  target,
  scope,
  columnWidth,
  sources,
  selected,
  tray,
  trayShown,
  onClose,
  onClosed,
  onOpenSimilar,
  onToggle,
  onDragOut,
}: LightboxProps) {
  const popup = useRef<HTMLDivElement>(null);
  const reducedMotion = useReducedMotion();
  // 消音は次の Shot の動画にも引き継ぐ
  const [muted, setMuted] = useState(false);
  // 閉じる間も、消えていく中身を描き続ける
  const [kept, setKept] = useState(target);
  if (target && target !== kept) setKept(target);
  const view = target ?? kept;
  const shot = view?.shot;
  const similarShots = useSimilar(shot?.id, scope);
  const nearby = similarShots ?? noShots;
  const openNearby = useStableCallback((next: ShotView, from: DOMRect) =>
    onOpenSimilar(nearby, nearby.indexOf(next), from),
  );

  const label = shot ? (shot.title ?? sources.get(shot.source)?.name ?? shot.source) : "";
  const text = shot?.kind === "text";

  return (
    <Dialog.Root
      open={target !== undefined}
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      onOpenChangeComplete={(open) => {
        if (!open) onClosed();
      }}
    >
      <Dialog.Portal>
        <Dialog.Popup
          ref={popup}
          className={styles.popup}
          data-pending={similarShots ? undefined : ""}
          initialFocus={popup}
          finalFocus={false}
          onTransitionRun={releaseOwnTransitions}
        >
          {shot ? (
            <>
              <div
                className={styles.stage({ tray: trayShown })}
                data-backdrop=""
                onClick={(event) => {
                  if (event.target instanceof HTMLElement && "backdrop" in event.target.dataset) {
                    onClose();
                  }
                }}
              >
                <div className={`${styles.view} ${styles.fadeOut}`} data-backdrop="">
                  <Media
                    key={shot.id}
                    shot={shot}
                    label={label}
                    from={view?.from}
                    popup={popup}
                    reducedMotion={reducedMotion}
                    muted={muted}
                    onMutedChange={setMuted}
                    onDragOut={onDragOut}
                  />
                </div>
                <div
                  className={`${styles.caption({ iconOnly: text && !shot.author })} ${styles.fade}`}
                >
                  <SourceIcon id={shot.source} source={sources.get(shot.source)} />
                  {text ? null : (
                    <Dialog.Title className={styles.title}>
                      <ShotLink shot={shot} label={label} />
                    </Dialog.Title>
                  )}
                  {shot.author ? (
                    <span className={styles.author({ besideTitle: !text })}>{shot.author}</span>
                  ) : null}
                </div>
              </div>
              <section className={`${styles.sheet} ${styles.fade}`}>
                <ShotWall
                  shots={nearby}
                  generation={0}
                  columnWidth={columnWidth}
                  sources={sources}
                  selected={selected}
                  onOpen={openNearby}
                  onToggle={onToggle}
                  onDragOut={onDragOut}
                />
              </section>
              <span className={styles.close}>
                <Dialog.Close
                  render={
                    <IconButton aria-label="閉じる" variant="secondary" size="large">
                      <Icon name="x" size="lg" />
                    </IconButton>
                  }
                />
              </span>
              {tray}
            </>
          ) : null}
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
