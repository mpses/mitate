import { useEffect, useLayoutEffect, useRef, useState } from "react";

import { ActiveIndicator, Icon, IconButton, Tooltip } from "@bakutan-org/ui";
import { css } from "@bakutan-org/ui/styled-system/css";

import type { ShotView, SourceStatus } from "./api";
import { canDragOut, dragOut } from "./drag";
import { SourceIcon } from "./SourceIcon";
import { registerShot, stillOf } from "./Tile";

export interface TrayProps {
  shots: readonly ShotView[];
  sources: ReadonlyMap<string, SourceStatus>;
  /** メモを打っている Shot */
  editing: string | undefined;
  /** メモを打ち終えた。note が undefined なら取り消し */
  onEditEnd: (id: string, note: string | undefined) => void;
  onOpen: (shot: ShotView, from: DOMRect) => void;
  onToggle: (shot: ShotView) => void;
  onCopy: () => Promise<void>;
  onClear: () => void;
  /** 壁と焦点表示の間で描き直した列。すでに見えていたので入場の動きを付けない */
  handoff: boolean;
}

// 外形 lg の角丸とサムネイルまでの余白 8px から、サムネイルの角丸は xs にそろえる
const styles = {
  // 左端を壁の左端にそろえ、項目が増えても右へだけ伸ばす。焦点表示の中では --tray-bottom で持ち上げる
  tray: css({
    alignItems: "center",
    bg: "surface.default",
    borderRadius: "lg",
    boxShadow: "overlay",
    display: "flex",
    gap: "1",
    insetBlockEnd: "var(--tray-bottom, token(spacing.4))",
    insetInlineStart: "4",
    maxW: "calc(100vw - token(spacing.8))",
    pe: "2",
    position: "fixed",
    ps: "1",
    py: "1",
    zIndex: 20,
    transitionDuration: "normal",
    transitionProperty: "opacity, translate",
    transitionTimingFunction: "out",
    _starting: { opacity: 0, translate: "0 token(spacing.2)" },
    _motionReduce: { transitionProperty: "opacity" },
    "&[data-handoff]": { transitionProperty: "none" },
  }),
  // 溢れている側の端だけを薄くして、続きがあると分かるようにする。
  // 横スクロールの箱は中身を切るので、焦点の輪（外へ 4px）とメモの点（外へ 2px）が収まるだけ内側を空ける。
  // この余白と列の余白を足して、サムネイルの周りを 8px にそろえる
  list: css({
    display: "flex",
    gap: "2",
    listStyle: "none",
    m: "0",
    minW: "0",
    overflowX: "auto",
    p: "1",
    scrollbarWidth: "none",
    "&[data-overflow=start]": {
      maskImage: "linear-gradient(to right, transparent, black token(spacing.4))",
    },
    "&[data-overflow=end]": {
      maskImage: "linear-gradient(to left, transparent, black token(spacing.4))",
    },
    "&[data-overflow=both]": {
      maskImage:
        "linear-gradient(to right, transparent, black token(spacing.4), black calc(100% - token(spacing.4)), transparent)",
    },
  }),
  item: css({ alignItems: "center", display: "flex", flexShrink: 0, gap: "1-5" }),
  thumbBox: css({ display: "flex", flexShrink: 0, position: "relative" }),
  thumb: css({
    alignItems: "center",
    bg: "surface.subtle",
    borderRadius: "xs",
    cursor: "pointer",
    display: "flex",
    flexShrink: 0,
    h: "40px",
    justifyContent: "center",
    overflow: "hidden",
    transitionDuration: "fast",
    transitionProperty: "scale",
    transitionTimingFunction: "out",
    _active: { scale: "0.97" },
    _focusVisible: { outline: "2px solid", outlineColor: "focus.default", outlineOffset: "2px" },
    _motionReduce: { transitionProperty: "none", _active: { scale: "1" } },
    "& img": { display: "block", h: "full", objectFit: "cover", w: "full" },
  }),
  // メモがあることだけを角の点で示す。中身はホバーと焦点の Tooltip で読む
  noteMark: css({
    insetBlockStart: "-0.5",
    insetInlineEnd: "-0.5",
    pointerEvents: "none",
    position: "absolute",
  }),
  input: css({
    bg: "surface.subtle",
    border: "none",
    borderRadius: "xs",
    color: "text.default",
    h: "28px",
    px: "2",
    textStyle: "type.xs.normal",
    w: "180px",
    _focusVisible: { outline: "2px solid", outlineColor: "focus.default", outlineOffset: "2px" },
  }),
  actions: css({ display: "flex", flexShrink: 0, gap: "1" }),
};

// サムネイルは高さ 40px にそろえ、横長も縦長もこの幅の範囲に収める
const thumbWidth = (shot: ShotView) => Math.min(72, Math.max(30, 40 * (shot.aspect ?? 1)));

type Overflow = "start" | "end" | "both" | undefined;

function overflowOf(list: HTMLElement): Overflow {
  const start = list.scrollLeft > 0;
  const end = list.scrollLeft + list.clientWidth < list.scrollWidth - 1;
  if (start && end) return "both";
  return start ? "start" : end ? "end" : undefined;
}

/** 横に溢れた列の端の状態を追い、マウスの縦ホイールでも横へ送れるようにする */
function useHorizontalList(changed: unknown) {
  const list = useRef<HTMLUListElement>(null);
  const [overflow, setOverflow] = useState<Overflow>();

  useLayoutEffect(() => {
    const element = list.current;
    if (element) setOverflow(overflowOf(element));
  }, [changed]);

  useEffect(() => {
    const element = list.current;
    if (!element) return;
    const update = () => setOverflow(overflowOf(element));
    const resize = new ResizeObserver(update);
    resize.observe(element);
    // トラックパッドの横の動きはそのまま任せ、縦の動きだけを横へ回す。端まで来たら窓のスクロールへ譲る
    const onWheel = (event: WheelEvent) => {
      if (Math.abs(event.deltaY) <= Math.abs(event.deltaX)) return;
      const max = element.scrollWidth - element.clientWidth;
      const room = event.deltaY > 0 ? element.scrollLeft < max : element.scrollLeft > 0;
      if (!room) return;
      event.preventDefault();
      element.scrollLeft += event.deltaY;
    };
    element.addEventListener("scroll", update, { passive: true });
    element.addEventListener("wheel", onWheel, { passive: false });
    return () => {
      resize.disconnect();
      element.removeEventListener("scroll", update);
      element.removeEventListener("wheel", onWheel);
    };
  }, []);

  return { list, overflow };
}

function NoteField({ shot, onEditEnd }: { shot: ShotView; onEditEnd: TrayProps["onEditEnd"] }) {
  const ended = useRef(false);
  const end = (note: string | undefined) => {
    if (ended.current) return;
    ended.current = true;
    onEditEnd(shot.id, note);
  };
  return (
    <input
      ref={(element) => element?.scrollIntoView({ block: "nearest", inline: "nearest" })}
      aria-label="メモ"
      autoFocus
      className={styles.input}
      defaultValue={shot.note}
      enterKeyHint="done"
      onBlur={(event) => end(event.currentTarget.value)}
      onKeyDown={(event) => {
        if (event.nativeEvent.isComposing || event.keyCode === 229) return;
        if (event.key !== "Enter" && event.key !== "Escape") return;
        // 焦点表示の Dialog は document で Esc を受けて閉じる。メモの確定と取り消しはここで止める
        event.stopPropagation();
        end(event.key === "Enter" ? event.currentTarget.value : undefined);
      }}
    />
  );
}

function Thumb({
  shot,
  sources,
  onOpen,
  onToggle,
  onDragOut,
}: Pick<TrayProps, "sources" | "onOpen" | "onToggle"> & {
  shot: ShotView;
  onDragOut: (event: DragEvent) => void;
}) {
  const still = shot.kind === "text" ? undefined : stillOf(shot);
  const button = (
    <button
      type="button"
      aria-label={shot.title ?? sources.get(shot.source)?.name ?? shot.source}
      className={styles.thumb}
      style={{ width: still ? thumbWidth(shot) : 40 }}
      draggable={canDragOut()}
      onDragStart={(event) => onDragOut(event.nativeEvent)}
      onClick={(event) => {
        if (event.shiftKey) onToggle(shot);
        else onOpen(shot, event.currentTarget.getBoundingClientRect());
      }}
    >
      {still ? (
        <img alt="" draggable={false} src={still} />
      ) : (
        <SourceIcon id={shot.source} source={sources.get(shot.source)} />
      )}
    </button>
  );
  // Tooltip は中の要素の ref を差し替えるので、Shot は外側の箱に載せる
  return (
    <span
      ref={(element) => {
        if (element) registerShot(element, shot);
      }}
      className={styles.thumbBox}
      data-shot-id={shot.id}
    >
      {shot.note ? <Tooltip label={shot.note}>{button}</Tooltip> : button}
      {shot.note ? <ActiveIndicator className={styles.noteMark} /> : null}
    </span>
  );
}

/** 選んだ Shot のサムネイルを窓の下端に並べる。AI に参考を渡す出口になる */
export function Tray({
  shots,
  sources,
  editing,
  onEditEnd,
  onOpen,
  onToggle,
  onCopy,
  onClear,
  handoff,
}: TrayProps) {
  const [copied, setCopied] = useState(false);
  // 入場の動きを付けるかは描き始めで決める。途中で外すと動きが途中で切れる
  const [handedOff] = useState(handoff);
  const { list, overflow } = useHorizontalList(`${shots.length}:${editing}`);
  useEffect(() => {
    if (!copied) return;
    const timer = window.setTimeout(() => setCopied(false), 1200);
    return () => window.clearTimeout(timer);
  }, [copied]);

  return (
    <aside
      aria-label="選んだもの"
      className={styles.tray}
      data-handoff={handedOff ? "" : undefined}
    >
      <ul ref={list} className={styles.list} data-overflow={overflow}>
        {shots.map((shot) => (
          <li key={shot.id} className={styles.item}>
            <Thumb
              shot={shot}
              sources={sources}
              onOpen={onOpen}
              onToggle={onToggle}
              onDragOut={(event) => dragOut(event, shots)}
            />
            {editing === shot.id ? <NoteField shot={shot} onEditEnd={onEditEnd} /> : null}
          </li>
        ))}
      </ul>
      <div className={styles.actions}>
        <Tooltip label="Markdown でコピー">
          <IconButton
            aria-label="Markdown でコピー"
            variant="ghost"
            size="medium"
            onClick={() => void onCopy().then(() => setCopied(true))}
          >
            <Icon name={copied ? "check" : "copy"} size="md" />
          </IconButton>
        </Tooltip>
        <Tooltip label="選択をすべて外す">
          <IconButton aria-label="選択をすべて外す" variant="ghost" size="medium" onClick={onClear}>
            <Icon name="x" size="md" />
          </IconButton>
        </Tooltip>
      </div>
    </aside>
  );
}
